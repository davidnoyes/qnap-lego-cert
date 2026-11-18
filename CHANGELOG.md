# Changelog

## [0.5.6](https://github.com/davidnoyes/qnap-lego-cert/compare/v0.5.5...v0.5.6) (2026-11-18)


### Bug Fixes

* expiry warnings follow each certificate's lifetime ([a22e3f4](https://github.com/davidnoyes/qnap-lego-cert/commit/a22e3f494411db365d0785d7b430e82ccb0cd52f))
* short App Center name with the version, listed under Security ([823a106](https://github.com/davidnoyes/qnap-lego-cert/commit/823a106755d4c5ad39f3dfeb310ba5745733f673))

## [0.5.5](https://github.com/davidnoyes/qnap-lego-cert/releases/tag/v0.5.5) (2026-11-18)

First public release. Earlier versions were developed and tested on a single NAS.

### Bug Fixes

* **Test run** now really exercises Cloudflare DNS-01 every time. Let's Encrypt reuses a
  validated authorization for about 30 days, so tests after the first had skipped the DNS
  step and never used the token. Test runs now give the authorization up afterwards
  (`--always-deactivate-authorizations`), and a test that reused one says it was only
  partly checked.

## 0.5.4 (2026-11-18)

### Bug Fixes

* Settings survive upgrades. QDK's installer replaces a `QPKG_CONFIG` file when the shipped
  template changes (moving the user's copy to `legocert.conf.qdksave`), which lost the
  settings on the upgrade to 0.5.2. The package now ships only `legocert.conf.example`, and
  installing restores a `.qdksave` that holds a token.

## 0.5.3 (2026-11-18)

### Features

* **Renew now** always leaves a QuLog Center entry, including "not due yet, nothing to do".
  Scheduled checks stay quiet unless something is wrong.

## 0.5.2 (2026-11-18)

### Features

* Progress line for Test run and Renew now: a ball moving along the stages (DNS record,
  Let's Encrypt check, certificate, install), stopping red with a plain-English reason on
  failure. Replaces the Log page; events link to QuLog Center and the technical log is a
  download.

### Bug Fixes

* A run that finished before the page's first check left the progress line frozen; runs are
  now matched by their start time.

## Before 0.5.2

Built and tested on a QTS 5 NAS on 2026-11-18:

* QPKG with a daily scheduled check re-added at every boot, lego (Cloudflare DNS-01), and an
  installer that validates the certificate, backs up `/etc/stunnel`, verifies QTS serves the
  new certificate and rolls back if not.
* Each run reconciles the served certificate with lego's, so a failed install or a firmware
  reset of `/etc/stunnel` is repaired on the next run.
* Settings page in a QTS desktop window, styled like QTS 5's apps: administrators only
  (checked against QTS's `authLogin.cgi` on loopback), CSRF tokens, token write-only, a
  step-by-step Cloudflare token guide.
* Notifications through the QTS system log and Notification Center.
* Scheduled runs only renew; the first certificate comes from Renew now. Button runs skip
  lego's random renewal delay. Clear errors for IP addresses or bare names as the NAS name.
