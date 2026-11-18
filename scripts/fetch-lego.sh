#!/usr/bin/env bash
# Download the pinned lego release for each NAS architecture into the QDK
# arch directories (qpkg/x86_64/lego, qpkg/arm_64/lego), verifying each
# tarball against the release's checksums file, plus lego's licence (shipped in
# the package: lego is MIT-licensed and redistributed inside it).
#
# The version comes from tools/go.mod, which exists so Dependabot can update it.
set -euo pipefail

cd "$(dirname "$0")/.."
version=$(awk '$1 == "require" && $2 == "github.com/go-acme/lego/v5" { sub(/^v/, "", $3); print $3 }' tools/go.mod) # e.g. 5.6.0
if [[ ! $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
	echo "could not read the lego version from tools/go.mod (got '$version')" >&2
	exit 1
fi
base="https://github.com/go-acme/lego/releases/download/v${version}"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

curl -fsSL -o "$tmp/checksums.txt" "$base/lego_${version}_checksums.txt"

sha256() {
	if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1
}

# QDK arch dir : lego release arch
for pair in x86_64:amd64 arm_64:arm64; do
	qdk=${pair%%:*}
	arch=${pair##*:}
	tarball="lego_v${version}_linux_${arch}.tar.gz"
	curl -fsSL -o "$tmp/$tarball" "$base/$tarball"
	want=$(awk -v f="$tarball" '$2 == f {print $1}' "$tmp/checksums.txt")
	got=$(sha256 "$tmp/$tarball")
	if [[ -z $want || $want != "$got" ]]; then
		echo "checksum mismatch for $tarball (want '$want', got '$got')" >&2
		exit 1
	fi
	tar -xzf "$tmp/$tarball" -C "$tmp" lego LICENSE
	install -m 0755 "$tmp/lego" "qpkg/$qdk/lego"
	install -m 0644 "$tmp/LICENSE" qpkg/shared/LICENSE.lego
	rm "$tmp/lego" "$tmp/LICENSE"
	echo "qpkg/$qdk/lego <- $tarball (sha256 ok)"
done
