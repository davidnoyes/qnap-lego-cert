#!/bin/sh
# Check the REAL lego binary still has everything renew.sh relies on: the flags it
# passes and the Cloudflare provider's variable names. tests/harness.sh uses a fake
# lego, so without this a lego update that renamed a flag would pass CI.
#
#   make lego-flags   (runs this in Alpine, against the fetched binary)
set -u

case $(uname -m) in
x86_64) LEGO=/src/qpkg/x86_64/lego ;;
aarch64) LEGO=/src/qpkg/arm_64/lego ;;
*) echo "unsupported arch $(uname -m)"; exit 1 ;;
esac
[ -x "$LEGO" ] || { echo "no lego binary at $LEGO (run make fetch)"; exit 1; }

failed=0
echo "lego: $("$LEGO" --version 2>&1 | head -n 1)"
help=$("$LEGO" run --help 2>&1)

# Every flag renew.sh passes to `lego run` (keep in step with run_lego in renew.sh).
for flag in --accept-tos --email --domains --server --path --dns --dns.resolvers \
	--renew-force --no-random-sleep --always-deactivate-authorizations; do
	if printf '%s\n' "$help" | grep -q -- "$flag\\b"; then
		echo "  ok   lego run $flag"
	else
		echo "  FAIL lego run $flag (missing from 'lego run --help')"
		failed=1
	fi
done
# The flag renew.sh relies on must also be accepted, not just documented.
for code in cloudflare exec; do
	if "$LEGO" dnshelp --code "$code" >/dev/null 2>&1; then
		echo "  ok   DNS provider '$code' exists"
	else
		echo "  FAIL DNS provider '$code' missing"
		failed=1
	fi
done
cf=$("$LEGO" dnshelp --code cloudflare 2>&1)
for var in CLOUDFLARE_DNS_API_TOKEN CLOUDFLARE_ZONE_API_TOKEN; do
	if printf '%s\n' "$cf" | grep -q "$var"; then
		echo "  ok   cloudflare reads $var"
	else
		echo "  FAIL cloudflare no longer documents $var (legocert.conf passes the token in it)"
		failed=1
	fi
done
[ "$failed" = 0 ] && echo "real lego: all flags and variables present" || echo "real lego: MISMATCH"
exit "$failed"
