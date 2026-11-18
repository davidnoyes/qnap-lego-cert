#!/usr/bin/env bash
# Run the end-to-end test (tests/e2e/compose.yml): real lego + LegoCert against
# Pebble. Needs the lego binaries (make fetch) and Docker with compose.
set -euo pipefail
cd "$(dirname "$0")"

compose=(docker compose -f compose.yml)
pebble_image=$(sed -n 's/^ *image: \(ghcr\.io\/letsencrypt\/pebble:.*\)$/\1/p' compose.yml)

# lego must trust Pebble's TLS certificate: take Pebble's test CA from the same image.
container=$(docker create "$pebble_image")
trap 'docker container rm -f "$container" >/dev/null 2>&1 || true; "${compose[@]}" down -v >/dev/null 2>&1 || true' EXIT
docker cp "$container:/test/certs/pebble.minica.pem" .pebble-minica.pem >/dev/null

"${compose[@]}" up --quiet-pull --abort-on-container-exit --exit-code-from legocert
