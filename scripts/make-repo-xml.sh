#!/usr/bin/env bash
# make-repo-xml.sh TAG OUTDIR
# Write the QNAP App Center repository feed for release TAG (e.g. v0.5.5) into
# OUTDIR: repo.xml, the app icons, and a small index page. Published to GitHub
# Pages; in App Center: Settings > App Repository > Add, with <pages url>/repo.xml.
#
# Format follows working third-party feeds (myqnap.org, qnaputilities.com, the Emby
# feed): one <item> per app, one <platform> per QTS platform ID, <location> pointing
# at the release's .qpkg. No <signature>: the packages are not QNAP-signed.
set -euo pipefail

tag=${1:?usage: $0 TAG OUTDIR}
out=${2:?usage: $0 TAG OUTDIR}
version=${tag#v}
repo=${GITHUB_REPOSITORY:-davidnoyes/qnap-lego-cert}
owner=${repo%%/*}
name=${repo#*/}
pages="https://${owner}.github.io/${name}"
dl="https://github.com/${repo}/releases/download/${tag}"

cd "$(dirname "$0")/.."
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "bad tag: $tag" >&2; exit 1; }
fwver=$(sed -n 's/^QTS_MINI_VERSION="\(.*\)"$/\1/p' qpkg/qpkg.cfg)

# QTS platform IDs per package, from the feeds above.
x86_ids="TS-NASX86 TS-X73 TVS-873 TVS-873e"
arm64_ids="TS-NASARM_64 TS-X16 TS-X28A TS-XA28A TS-X32 TS-X32U TS-X33 TS-X33U TS-X33EU TS-X35 TS-X35A TS-X35EU TS-X42"

platforms() { # platforms "IDS" ARCH
	local id
	for id in $1; do
		printf '    <platform>\n      <platformID>%s</platformID>\n      <location>%s/LegoCert_%s_%s.qpkg</location>\n    </platform>\n' \
			"$id" "$dl" "$version" "$2"
	done
}

mkdir -p "$out"
cp assets/icon_80.png assets/icon_100.png "$out"/

{
	cat <<EOF
<?xml version="1.0" encoding="utf-8"?>
<plugins>
  <cachechk>$(date -u +%Y%m%d%H%M%S)</cachechk>
  <item>
    <name>LegoCert</name>
    <internalName>LegoCert</internalName>
    <changeLog>https://github.com/${repo}/releases/tag/${tag}</changeLog>
    <category>Security</category>
    <type>Security</type>
    <icon80>${pages}/icon_80.png</icon80>
    <icon100>${pages}/icon_100.png</icon100>
    <description><![CDATA[Keeps the QTS web certificate valid with Let's Encrypt, using DNS validation (Cloudflare, Route 53, Porkbun, DuckDNS and more), so it works for internal names that QTS's built-in Let's Encrypt can't do. Renews automatically, installs the certificate into QTS, and reports problems to Notification Center.]]></description>
    <moreDescription><![CDATA[Open LegoCert from App Center to set it up: choose your DNS provider and create access there (the app shows how), enter the NAS name and your email, then Test run and Renew now. Source, changelog and documentation: https://github.com/${repo}]]></moreDescription>
    <fwVersion>${fwver}</fwVersion>
    <version>${version}</version>
EOF
	platforms "$x86_ids" x86_64
	platforms "$arm64_ids" arm_64
	cat <<EOF
    <publishedDate>$(date -u '+%Y-%m-%d %H:%M:%S')</publishedDate>
    <maintainer><![CDATA[${owner}]]></maintainer>
    <developer><![CDATA[${owner}]]></developer>
    <forumLink><![CDATA[https://github.com/${repo}/issues]]></forumLink>
    <language><![CDATA[English]]></language>
    <tutorialLink><![CDATA[https://github.com/${repo}#readme]]></tutorialLink>
  </item>
</plugins>
EOF
} >"$out/repo.xml"

cat >"$out/index.html" <<EOF
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>LegoCert App Center repository</title>
<style>body{font:16px/1.55 system-ui,sans-serif;max-width:640px;margin:40px auto;padding:0 16px;color:#222;background:#fff}code{background:#f2f4f7;padding:2px 5px;border-radius:3px}img{vertical-align:middle;margin-right:10px}
@media (prefers-color-scheme:dark){body{color:#e6e6e6;background:#141414}code{background:#262626}}</style></head>
<body><h1><img src="icon_80.png" width="48" height="48" alt="">LegoCert ${version}</h1>
<p>QNAP App Center repository for <a href="https://github.com/${repo}">LegoCert</a>.</p>
<p>In QTS: <b>App Center → ⚙ Settings → App Repository → Add</b>, name <code>LegoCert</code>, URL:</p>
<p><code>${pages}/repo.xml</code></p>
<p>LegoCert is not signed by QNAP, so App Center also needs <b>Settings → General → Allow installation of applications without a valid digital signature</b>.</p>
</body></html>
EOF

echo "wrote $out/repo.xml for $tag ($(grep -c '<platform>' "$out/repo.xml") platforms)"
