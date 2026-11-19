# qnap-lego-cert

A QNAP app (QPKG), **LegoCert**, that keeps the QTS web UI certificate valid by itself.
[lego](https://github.com/go-acme/lego) obtains and renews a Let's Encrypt certificate using
**DNS-01** through your domain's DNS provider. The app installs it into QTS's `/etc/stunnel`
and reports problems through QNAP's **Notification Center**.

**DNS providers.** Cloudflare, DuckDNS, Porkbun, AWS Route 53, DigitalOcean, Hetzner,
OVHcloud, Gandi and deSEC are offered by name, each with its own setup steps on the settings page.
**Other (advanced)** takes any of [lego's providers](https://go-acme.github.io/lego/dns/)
by its code and variables. Only Cloudflare has been used on a real NAS so far. For the others, CI
checks against the real lego that every variable LegoCert stores is the one lego reads (see
*Testing*), but not against real accounts. Use **Test run** first, and please report how it went.

QTS's built-in Let's Encrypt only validates over HTTP (myQNAPcloud DNS or ports 80/443),
so it can't issue a certificate for an internal-only name like `nas.home.example.com`.
LegoCert replaces the manual alternative: issuing the certificate elsewhere (e.g. certbot with
DNS-01 on another machine) and copying it onto the NAS over SSH every few months.

**Security, failure handling and residual risks: [docs/design-review.md](docs/design-review.md).**

## How it works

A daily cron job runs `renew.sh`, which converges the NAS on a valid certificate:

1. **lego run.** Renews into `data/`. It only contacts Let's Encrypt when renewal is due
   (about 30 days before expiry), so most days it does nothing. The **first** certificate
   only ever comes from *Renew now* (or `./renew.sh` by hand): scheduled runs (`--auto`)
   never install one by surprise during setup.
2. **Reconcile.** If the certificate lego holds differs from the one QTS is serving, and is
   valid, `install-cert.sh` installs it:
   - validates it (parses, in date, covers the domain, matches the key);
   - backs up `/etc/stunnel`;
   - replaces the files (`backup.cert`, `backup.key`, `stunnel.pem` = key + leaf,
     `uca.pem` = chain);
   - restarts thttpd, stunnel and Qthttpd;
   - waits up to 60 s for QTS to serve the new certificate, and rolls back if it doesn't.

   There's no lego deploy hook. Because this check runs every day, a failed install, or a
   firmware update that resets `/etc/stunnel`, gets fixed on the next run.
3. **Expiry check.** Looks at the certificate QTS actually serves: a warning once under
   a quarter of its lifetime is left (about 22 days for a 90-day certificate), an error
   under an eighth (about 11 days) or once expired.

**Settings page.** Opened from App Center (*Open*), administrators only, styled like QTS 5's
own apps (QuLog Center layout, QTS Font). Sidebar: Overview (certificate status, Test run,
Renew now), Setup → DNS provider (choose the provider, follow its steps, enter its credentials;
secrets are write-only, only their last 4 characters are shown; for Cloudflare a *Show my public
IP* button for the optional IP filter and *Check token*) and Settings (NAS name, email),
Notifications (the Notification Center rule). Test run and Renew now show their progress as a ball moving along the stages (DNS record, Let's Encrypt check, certificate, install), stopping red with a plain-English reason if something fails; events also go to QuLog Center, and the technical log is a download for troubleshooting. The only script is a small same-origin progress updater; no inline JavaScript. SSH is only needed if this
firmware doesn't run app pages as root (the page says so).

**Other pieces**
- **Service script `legocert.sh`.** QTS runs it at boot and when the app is enabled or
  disabled. It re-adds the cron line to `/etc/config/crontab` on every boot (firmware
  updates can reset that file), clears any lock left by a power cut, and runs a catch-up
  check 5 minutes after boot. Disabling or uninstalling removes the cron line.
- **Notifications.** Written to the QTS system log (QuLog Center) as `[LegoCert] …` at
  info, warning or error level. A Notification Center rule delivers them (setup below).
  Days with nothing to do log only to `log/legocert.log`.
- **Config `legocert.conf`.** Read as `KEY=VALUE` data, never executed. It must be
  `root:root 0600`, or nothing runs. It's kept across upgrades.

## Build and test

Requires Docker (or Colima) and `shellcheck`.

```sh
make lint        # shellcheck (QTS scripts as POSIX sh, warning level)
make test        # the real scripts under busybox ash, QTS and lego stubbed (tests/harness.sh)
make lego-flags  # the REAL lego binary still has every flag and variable LegoCert uses
make e2e         # LegoCert + the REAL lego against Pebble, Let's Encrypt's test ACME server
make build    # fetch + verify lego (version from tools/go.mod), build the QDK image, run qbuild
# -> qpkg/build/LegoCert_<ver>_x86_64.qpkg and _arm_64.qpkg
```

- **`make test`** stubs `getcfg`, `log_tool`, the init scripts (stunnel becomes an
  `openssl s_server`) and lego. It then checks install, no-op runs, repair after a reset,
  rollback and retry, warning vs error levels, wrong-name refusal, stale and live locks,
  config injection, permissions, staging, `--check-token`, every DNS provider's fields and
  the advanced *Other* path, and that credentials stay out of argv, logs and the page (a
  credential lego prints is redacted from the log).
- **`make e2e`** (tests/e2e) starts Pebble and pebble-challtestsrv (a test DNS server) with
  Docker Compose and runs LegoCert's real scripts with the real lego, using lego's `exec` DNS
  provider in place of Cloudflare. It checks a first certificate is issued through DNS-01 and
  installed, that lego still writes every log line the progress line reads, not-due and
  forced renewals, that consecutive Test runs each do the full DNS check, and that scheduled
  checks stay quiet. Then, for every listed DNS provider: without credentials lego stops at its
  own credential check (asking for exactly the variables LegoCert stores), and with LegoCert's
  fields filled in it gets past that check to the DNS step, with every outside connection sent
  to a dead proxy so no provider is contacted. CI runs it on every change, so a lego update that changes behaviour
  fails before Dependabot can merge it.
- **Updating lego:** the version lives in `tools/go.mod` (a module that is never built, only
  read, so Dependabot can propose updates). Downloads are checked against the release's
  `checksums.txt`, and lego's licence ships in the package as `LICENSE.lego`.
- **App icon:** `assets/icon.svg` is the source; `scripts/make-icons.sh` renders the three
  GIFs QTS needs into `qpkg/icons/` (64px, 64px greyed, 80px). Re-run it after editing the SVG.
- **QDK** 2.5.3 runs in an Ubuntu container (`build-env/`), with the `.deb`'s sha256 pinned.
- **Inspecting a build:** `qbuild --extract` truncates the data archive when unpacking.
  Read the gzip streams in the `.qpkg` directly instead.

## Releases, changelog and updates

- **Versions and changelog** come from [release-please](https://github.com/googleapis/release-please):
  commit messages follow [Conventional Commits](https://www.conventionalcommits.org/)
  (`feat: …`, `fix: …`, `docs: …`). release-please keeps a release PR open with the next
  version and its [CHANGELOG.md](CHANGELOG.md) entry; merging it tags the release.
- **Publishing:** a release builds both packages in CI (after lint and tests), attaches them
  to the GitHub release, and updates the App Center feed on GitHub Pages
  (`repo.xml`), so NAS boxes that added the repository see the update.
- **Dependencies:** Dependabot proposes updates for lego (`tools/go.mod`, as `fix(deps)`:
  a patch release), the QDK build image and the workflow actions (`chore(deps)`: no release).
  Its PRs merge themselves once CI passes; the release workflow's daily run turns merged
  lego updates into a release PR. QDK itself (pinned with a checksum in `build-env/`) is
  updated by hand.
- **CI** (`.github/workflows/ci.yml`) runs `make lint`, `make test` and `make build` on every
  push and pull request.

## Install on the NAS

1. **Allow unsigned apps.** LegoCert isn't signed by QNAP (only QNAP can sign). In App Center
   → ⚙ Settings → General, tick *Allow installation of applications without a valid digital
   signature*.
2. **Add the LegoCert repository** (recommended). App Center → ⚙ Settings → *App Repository*
   → *Add*: name `LegoCert`, URL `https://davidnoyes.github.io/qnap-lego-cert/repo.xml`.
   LegoCert then appears in App Center (under *LegoCert*); install it from there. New
   versions show up in App Center as updates, like QNAP's own apps.

   *Or install manually:* download `LegoCert_<version>_x86_64.qpkg` (or `arm_64`, matching
   the NAS CPU) from [Releases](https://github.com/davidnoyes/qnap-lego-cert/releases), then
   App Center → *Install Manually*.
3. **App Center → LegoCert → Open.** The settings page guides the rest:
   - **DNS provider**: choose yours, follow the steps (for Cloudflare, the full version is in
     [docs/cloudflare-token.md](docs/cloudflare-token.md)), enter the credentials, **Apply**;
     for Cloudflare, **Check token** should report one domain;
   - **Settings**: the NAS name and email, **Apply**;
   - on the Overview, **Test run**, then **Renew now**;
   - set up the Notification Center rule described on the page.
4. **Fallback without the page** (SSH as admin):
   ```sh
   sudo -i
   cd "$(getcfg LegoCert Install_Path -f /etc/config/qpkg.conf)"
   vi legocert.conf && chmod 600 legocert.conf
   ./renew.sh --staging && ./renew.sh
   ```
5. Check that the page shows **Daily check: scheduled**, **reboot the NAS once**, and check again.

**Later** (over SSH, or the page's buttons)
- `./renew.sh --force` renews now.
- `./renew.sh --check` reconciles and checks expiry without contacting the DNS provider.
- `./renew.sh --check-token` re-checks a Cloudflare token, e.g. after rotating it.

## Monitoring from outside

The app can't report that it isn't running (disabled, removed, cron gone). Keep an external
expiry check. In an uptime monitor such as Gatus, on the NAS endpoint:

```yaml
conditions:
  - "[STATUS] == 200"
  - "[CERTIFICATE_EXPIRATION] > 336h"   # red 14 days before expiry
```

## Uninstall

App Center → LegoCert → Remove.
- The cron line is removed.
- The installed certificate stays in `/etc/stunnel`, with backups in `/etc/stunnel/backups/`.
- Config, credentials and the lego account are deleted with the app, so revoke the DNS
  provider credentials too.
