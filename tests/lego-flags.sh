#!/bin/sh
# Check the REAL lego binary still has everything renew.sh relies on: the flags it
# passes, and every listed DNS provider with its variable names. tests/harness.sh uses a fake
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
# Every provider LegoCert offers by name, and every variable it stores for one, must
# exist in this lego (qpkg/shared/providers.sh is the list the settings page uses).
# shellcheck source=../qpkg/shared/providers.sh
. /src/qpkg/shared/providers.sh
for code in $PROVIDERS exec; do
	if ! doc=$("$LEGO" dnshelp --code "$code" 2>&1); then
		echo "  FAIL DNS provider '$code' missing"
		failed=1
		continue
	fi
	echo "  ok   DNS provider '$code' exists"
	for var in $(provider_fields "$code" | cut -d'|' -f1) $(provider_extra_vars "$code"); do
		if printf '%s\n' "$doc" | grep -q "\"$var\""; then
			echo "  ok   $code reads $var"
		else
			echo "  FAIL $code no longer documents $var (legocert.conf passes it under that name)"
			failed=1
		fi
	done
done
[ "$failed" = 0 ] && echo "real lego: all flags and variables present" || echo "real lego: MISMATCH"
exit "$failed"
