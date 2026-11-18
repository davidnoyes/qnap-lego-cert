#!/usr/bin/env bash
# Render assets/icon.svg into the GIFs QTS expects in qpkg/icons/:
#   LegoCert.gif       64x64  App Center / main menu (enabled)
#   LegoCert_gray.gif  64x64  same, when the app is disabled
#   LegoCert_80.gif    80x80  the app's details dialog
#   assets/icon_80.png, icon_100.png   App Center repository feed (repo.xml)
# GIF has 1-bit transparency, so edges are blended against a light matte that
# suits QTS 5's light backgrounds. Runs ImageMagick in Docker (no local install).
set -euo pipefail
cd "$(dirname "$0")/.."

docker run --rm -v "$PWD:/w" -w /w docker.io/library/alpine:3.22 sh -c '
	apk add --no-cache imagemagick imagemagick-svg >/dev/null
	render() { # render SIZE OUT [colour adjustments]
		size=$1 out=$2; shift 2
		magick -background none -density 384 assets/icon.svg -resize "${size}x${size}" "$@" /tmp/a.png
		# GIF: keep any pixel with >10% coverage, edge pixels pre-blended on the matte.
		magick /tmp/a.png \( +clone -background "#f2f4f7" -flatten \) \( /tmp/a.png -alpha extract -threshold 10% \) \
			-delete 0 -alpha off -compose CopyOpacity -composite "$out"
	}
	render 64 qpkg/icons/LegoCert.gif
	render 80 qpkg/icons/LegoCert_80.gif
	render 64 qpkg/icons/LegoCert_gray.gif -colorspace Gray -modulate 115
	# PNGs for the App Center feed (repo.xml icon80/icon100)
	magick -background none -density 384 assets/icon.svg -resize 80x80 assets/icon_80.png
	magick -background none -density 384 assets/icon.svg -resize 100x100 assets/icon_100.png
'
ls -l qpkg/icons/*.gif
