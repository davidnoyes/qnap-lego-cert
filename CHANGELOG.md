# Changelog

## [0.6.3](https://github.com/davidnoyes/qnap-lego-cert/compare/v0.6.2...v0.6.3) (2026-11-28)


### Bug Fixes

* **deps:** bump github.com/go-acme/lego/v5 from 5.6.0 to 5.7.0 in /tools ([#9](https://github.com/davidnoyes/qnap-lego-cert/issues/9)) ([7359552](https://github.com/davidnoyes/qnap-lego-cert/commit/7359552c60a2a9e39cf7c5d2d29402c4214859f8))

## [0.6.2](https://github.com/davidnoyes/qnap-lego-cert/compare/v0.6.1...v0.6.2) (2026-11-19)


### Bug Fixes

* no "Broken pipe" line from Check token ([fbced61](https://github.com/davidnoyes/qnap-lego-cert/commit/fbced6174178a47b0d70b3c2e6a3d6b35466f7f4))

## [0.6.1](https://github.com/davidnoyes/qnap-lego-cert/compare/v0.6.0...v0.6.1) (2026-11-19)


### Bug Fixes

* **ui:** choosing a DNS provider shows it at once; nothing changes until Apply ([1c106b4](https://github.com/davidnoyes/qnap-lego-cert/commit/1c106b40f6be305c30c1473e15f7dea8138c4d8b))


### Documentation

* App Center only re-reads repository feeds on its own schedule; how to check now ([3c8b491](https://github.com/davidnoyes/qnap-lego-cert/commit/3c8b491c95a6c11811f769d385783e6f239a1a61))

## [0.6.0](https://github.com/davidnoyes/qnap-lego-cert/compare/v0.5.7...v0.6.0) (2026-11-19)


### Features

* choose the DNS provider: Cloudflare, DuckDNS, Porkbun, Route 53, DigitalOcean, Hetzner, OVHcloud, Gandi, deSEC, or any lego provider ([7df289e](https://github.com/davidnoyes/qnap-lego-cert/commit/7df289ed4fc52194935031e2746f7e9912fafbd1))

## [0.5.7](https://github.com/davidnoyes/qnap-lego-cert/compare/v0.5.6...v0.5.7) (2026-11-19)


### Bug Fixes

* **ui:** drop the stale "Progress shows under Run now" from run messages ([9aa9ac2](https://github.com/davidnoyes/qnap-lego-cert/commit/9aa9ac24a5687814b768f4796219bd03ebec1385))
* **ui:** show the version in the app window, plain name in App Center ([3e70ae0](https://github.com/davidnoyes/qnap-lego-cert/commit/3e70ae04f1425e0c141e6e7eecf2d954b7e81af4))

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
