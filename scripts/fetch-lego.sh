#!/usr/bin/env bash
# Download the pinned lego release for each NAS architecture into the QDK
# arch directories (qpkg/x86_64/lego, qpkg/arm_64/lego), verifying each
# tarball against the release's checksums file.
set -euo pipefail

cd "$(dirname "$0")/.."
version=$(tr -d '[:space:]' <LEGO_VERSION) # e.g. 5.6.0
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
	tar -xzf "$tmp/$tarball" -C "$tmp" lego
	install -m 0755 "$tmp/lego" "qpkg/$qdk/lego"
	rm "$tmp/lego"
	echo "qpkg/$qdk/lego <- $tarball (sha256 ok)"
done
