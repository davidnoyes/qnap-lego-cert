# LegoCert design review: secrets, failure handling, notifications

Reviewed 2026-11-18, for version 0.2.0 (not yet run on hardware). The scripts run as root on
the NAS from cron. The behaviour below is covered by `make test` (tests/harness.sh) unless
marked *untested*.

## What changed from the first sketch

| First sketch | Now | Why |
|---|---|---|
| Install ran as lego's `--deploy-hook` | `renew.sh` **reconciles** after every run: if lego's stored certificate differs from the one QTS serves, install it | A failed hook was never retried: lego had already stored the new certificate, so it would not renew again for ~60 days, past the old certificate's expiry. Reconciling also repairs a firmware update resetting `/etc/stunnel`. |
| Hook inherited the whole environment, including the token | No hook; the token is only in lego's environment | lego v5 starts hooks with `os.Environ()` plus its metadata (`cmd/internal/hook/hook.go`). |
| Config `source`d as shell | Parsed as `KEY=VALUE` data; unknown keys and malformed values are rejected | Sourcing runs whatever is in the file, as root. |
| `mkdir` lock with no recovery | Lock records its pid; a dead pid's lock is taken over; boot clears it | A power cut mid-run would otherwise block every later run, with no error raised. |
| Single check 5 s after restart | Polls up to 60 s, then rolls back and checks that the rollback itself worked | A slow restart caused a needless rollback, and a failed rollback was reported as a success. |
| No independent expiry check | Every run checks the certificate QTS actually **serves**: warning under 21 days, error under 7 days or expired | Catches anything lego's own view misses. |
| Discord webhook | QTS system log, delivered by Notification Center | Owner's request: use QNAP's own notifications. It also removes a second secret from the NAS. |
| Lego hang would hold the lock forever | Watchdog kills lego after 15 min | No reliable `timeout` binary on QTS (busybox flags vary). |
| Build image trusted whatever QDK `.deb` it downloaded | sha256 pinned for both arches | Supply chain (see below). |

## Secrets

**What's sensitive on the NAS**
- the Cloudflare token (`legocert.conf`)
- the ACME account key and certificate keys (`data/`)
- private keys in `/etc/stunnel` and its backups

**How it's handled**
- Everything sits under the app's install dir on the data volume (`.qpkg/LegoCert`). That
  isn't an exported share, so NFS and SMB clients, including other machines that mount the
NAS's shares, can't read or modify it.
- `legocert.conf` must be `root:root 0600`, or nothing runs (tested). `data/` is 700.
  Installed key files are written with `umask 077`.
- The token is passed to lego through its environment for that one process. It is never
  exported, never on a command line (`ps` shows command lines to every user; tested), and
  never logged (tested). `/proc/<pid>/environ` is root-only.
- `install-cert.sh` never sees the token.

**The real risk is the token's scope, not where it's stored.** User-facing steps for all of
the following are in [cloudflare-token.md](cloudflare-token.md), and `renew.sh --check-token`
reports how many zones a token can see. A token with DNS:Edit on
`example.com` lets whoever holds it change *every* record in that zone: MX, the public sites,
CAA. That's a domain takeover, which matters far more than a NAS certificate. Ways to
limit it, strongest first:

Cloudflare tokens can be scoped to a zone but not to a single record (a long-standing open
feature request). **Decision (2026-11-18): token on the main zone**, limited by:

1. **Permissions:** Zone > DNS > Edit and Zone > Zone > Read only, on that one zone.
2. **Client IP filtering** to the home WAN address (and IPv6 prefix if used): optional,
   recommended (owner's call: some ISPs change addresses often). With it, a leaked token is
   useless from anywhere else. Trade-off: a WAN IP change makes renewals fail. That
   fails safe and gets reported (a warning, then an error before expiry).
3. **One token per consumer.** Not shared with other tools (a reverse proxy, an existing certbot setup),
   so it can be revoked on its own.

Considered and not adopted: CNAME-delegating `_acme-challenge.<name>` to a validation-only
zone. It would stop a leaked token editing the main zone, but it's an uncommon pattern and
needs a second domain. It stays documented as optional in cloudflare-token.md.

**Residual risk accepted with this choice:** a leaked token could edit any record in the main
zone; with the IP filter, only from the home IP.

**Accepted residual risks**
- **Everything runs as root.** That includes lego, a network client parsing responses
  from Let's Encrypt and Cloudflare. Dropping privileges on QTS would need a dedicated user
  and `su`/`setpriv` behaviour I can't verify. Mitigations: lego is pinned and
  checksum-verified, and it only talks to Let's Encrypt and Cloudflare over TLS.
- **The volume isn't encrypted**, so the token rests on disk in plain text. Anyone with
  root on the NAS can read it, but root on the NAS already owns the certificate.
- **The unsigned-app setting.** Installing needs *Allow installation of applications
  without a valid digital signature*, which applies NAS-wide. Turn it off again after
  installing. *Untested*: whether QTS keeps starting the app with it off.
- **QNAP's own processes** (firmware, QNAP apps) can read the data volume. Unavoidable.

## Settings page

`ui/index.cgi` runs as root (QTS runs CGIs under `/home/httpd/cgi-bin` as admin; the page
refuses to run otherwise) and writes the token, so it's the largest attack surface. It's linked
into `cgi-bin/qpkg/LegoCert` only while the app is enabled.

| Threat | Control | Tested |
|---|---|---|
| Unauthenticated access | Every request needs a QTS session (`NAS_SID`, or `qtoken`+`NAS_USER`) that QTS's `authLogin.cgi` confirms with `authPassed=1` | yes |
| Non-admin user | Also requires `isAdmin=1` | yes |
| Forged check (pointing the session check at a host that says "yes") | The check always goes to `127.0.0.1` (system port, then the HTTPS port with QTS's self-signed certificate). It never uses a URL built from the request. *Tailscale's QPKG derives it from the request URL; we deliberately don't* | yes |
| Session id exposure | Sent to curl in a config on stdin, never on a command line; cookies must match `[A-Za-z0-9._@-]` | yes |
| CSRF (another site making an admin's browser submit the form) | Every POST carries a token = SHA-256(per-install secret, session); wrong, missing or other-session tokens are rejected; POST/redirect/GET | yes |
| Token disclosure | Write-only: the page shows only its last 4 characters; never in the log or in process arguments | yes |
| Config injection (e.g. a newline adding a key) | Same `validate_conf` as the scripts: strict character sets per field; `write_conf` writes known keys only, atomically, root 600 | yes |
| XSS | Everything echoed is HTML-escaped. CSP `default-src 'none'; script-src 'self'`: no inline script; the only script is `progress.js` (run progress), served by the page itself, which builds the progress line with `createElement`/`textContent`, never `innerHTML` | yes |
| Oversized or odd requests | Body capped at 8 KB; unknown actions are rejected | yes |
| Clickjacking | `frame-ancestors 'self'` (QTS may show app pages in its own frame) | no |

Not verified on hardware: that QTS runs this CGI as root; the `[System] Web Access Port` key;
that `authLogin.cgi?sid=` answers on loopback with `authPassed`/`isAdmin`; and the CDATA
format of that response. If the check doesn't pass, the page fails closed (401), and SSH
remains the fallback.

## Supply chain

| Input | Control |
|---|---|
| lego binary | Pinned version (`LEGO_VERSION`), downloaded from the go-acme GitHub release, sha256 checked against the release checksums before packaging |
| QDK | Pinned 2.5.3, `.deb` sha256 checked in the build image |
| Ubuntu / Alpine base images | Version tag only, not digest. Used only to build and test, never shipped. Acceptable |
| The `.qpkg` itself | Unsigned (QNAP signing is internal to QNAP). Built locally from this repo |

## Failure modes

Each run converges on the right state, so most failures retry themselves the next day.
"Notified" means a QTS system log entry at that level, which Notification Center can deliver.

| What goes wrong | What happens | Notified | Tested |
|---|---|---|---|
| Config missing, wrong permissions, unknown key, malformed value | Nothing runs | error, daily | yes |
| Cloudflare/Let's Encrypt/network failure, rate limit, bad token | Retried daily (lego renews ~30 days out, so about 30 attempts before expiry) | warning while more than 14 days are left, then error | yes |
| lego hangs | Killed after 15 min; treated as a lego failure | as above | no |
| New certificate fails validation (bad parse, expired, wrong name, key mismatch) | Nothing touched | error | name check yes |
| Disk full while staging or backing up | Nothing touched | error | no |
| Write into `/etc/stunnel` fails part way | Backup restored, web services restarted | error | no |
| QTS doesn't serve the new certificate after restart | Backup restored and restarted; retried next run | error ("rolled back") | yes |
| Rollback also doesn't bring the old certificate back | Says so: web UI may be down, SSH in, backup path given | error | no |
| Setup in progress when a scheduled run fires (e.g. 5 min after install) | Scheduled runs (`--auto`) only renew an existing LegoCert certificate; the first one needs *Renew now*. Found on the NAS 2026-11-18: 0.3.5's catch-up run issued and installed a certificate (restarting QTS) while the owner was testing | log only | yes |
| A button run finds another run in progress | Skipped, with "…skipped: another run is in progress. Try again in a minute." in the Log | log only | yes |
| Firmware update resets `/etc/stunnel` | Next run sees served ≠ stored and reinstalls | info | yes |
| Firmware update or reboot drops the cron line | Service `start` re-adds it at every boot | none | no (needs hardware) |
| Run cut off (power cut, crash) holding the lock | Next run takes over the stale lock; boot clears it | log only | yes |
| Two runs at once (cron + boot catch-up) | Second one skips | log only | yes |
| Served certificate under 21 / 7 days or expired, whatever the cause | Independent check on every run | warning / error / error | 7-day yes |
| `log_tool` fails (or permissions differ on this firmware) | Recorded in `log/legocert.log` only. **Silent** | none | no |
| App disabled, removed, or blocked by the unsigned-app setting | Nothing runs. **Silent** | none | no |
| NAS off for a long time | Boot catch-up run 5 min after start | as above | no |

**The last two silent rows are why monitoring from outside the NAS is still needed.** The
app can't report that it isn't running. Keep an uptime monitor (e.g. Gatus) on the NAS's name,
with an expiry condition (`[CERTIFICATE_EXPIRATION] > 336h`), so a dead app shows up two
weeks before the certificate does.

## Notifications (QNAP-native)

- `notify` writes with `/sbin/log_tool --append "[LegoCert] …" --type 0|1|2 --app_name LegoCert`
  (0 info, 1 warning, 2 error). The flags are taken from a working community QPKG
  (DuplicacyLog). `log_tool` needs root; cron and the service script run as root.
- Event notification rules need an app registered with Notification Center, which isn't
  available to third-party packages. So use an **alert notification rule**: Notification
  Center → System Notification Rules → Alert Notifications → create rule:
  - severity: Warning and Error (add Information to also hear about successful installs)
  - keyword: `LegoCert`. Only one keyword: multi-keyword filters are reported broken.
  - delivery: email, push to the QNAP mobile app, or instant message, as set up in
    Notification Center.
- Routine no-op runs don't log to the system log, only to `log/legocert.log`, so the rule
  stays quiet unless something happens.

## Verified on the NAS (2026-11-18, v0.3.1)

- The settings page's CGI runs as root under QTS's web server, on both 8080 (HTTP) and 443
  (HTTPS); without a session it returns its own 401.
- `authLogin.cgi` answers in the CDATA XML format the page parses; `webAccessPort` 8080,
  `stunnelPort` 443.
- **Bug found:** with `QPKG_WEBUI` set but no port, App Center linked to the Web Server port
  (80, which is off), so *Open* failed. Fixed in 0.3.2 with `QPKG_USE_PROXY="1"` (as Tailscale
  does), plus the service script recording QTS's ports as `Web_Port`/`Web_SSL_Port`.
- 0.4.x live log: a full-page refresh flashed white in the QTS window (and a URL that
  differed only by `#fragment` didn't reload at all). 0.4.4 updated the text in place.
- 0.5.0 replaces the Log tab with a progress line (stages recognised from the log, errors
  mapped to plain-English reasons); events link to QuLog Center (`/qulog/`), the technical
  log is a download. Checked in Chrome: 1 page load, then status polls, ending on the
  green tick.
- 0.3.3 opens the page in a QTS desktop window (`QPKG_DESKTOP_APP="1"`, 1100x600) like
  QNAP's own apps, instead of a new browser tab.

## Still to verify on the NAS

- Settings page: runs as root, authenticates via `authLogin.cgi` on loopback, opens from App
  Center (`QPKG_WEBUI`), and the link is removed when the app is disabled.
- `log_tool` flags and behaviour on this QTS version. Does an alert rule with keyword
  `LegoCert` fire?
- `/sbin/getcfg Stunnel Port -f /etc/config/uLinux.conf` gives the HTTPS port (otherwise
  set `HTTPS_PORT`).
- QTS `openssl` has `pkey`, `s_client` and `-checkend`.
- `QPKG_CONFIG` keeps `legocert.conf` across an upgrade; `pkg_post_install` permissions apply.
- The cron line survives a reboot and a firmware update; boot catch-up runs.
- The app still starts with the unsigned-app setting turned back off.
