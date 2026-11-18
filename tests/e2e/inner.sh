#!/bin/sh
# Runs inside the "legocert" container of tests/e2e/compose.yml.
# LegoCert's real renew.sh / install-cert.sh / settings page with the REAL lego
# binary, against Pebble (a real ACME server that validates DNS-01 through
# challtestsrv). QTS itself is stubbed as in tests/harness.sh (getcfg, log_tool,
# stunnel = openssl s_server on :8443), but nothing about lego is faked.
set -u

# QTS stubs, fixtures and helpers from the harness (everything before its tests).
sed -n '/^# ---------------------------------------------------------------------- tests/q;p' /src/tests/harness.sh >/tmp/setup.sh
. /tmp/setup.sh

case $(uname -m) in
x86_64) cp /src/qpkg/x86_64/lego "$ROOT/lego" ;;
aarch64) cp /src/qpkg/arm_64/lego "$ROOT/lego" ;;
esac
chmod 755 "$ROOT/lego"
echo "real lego: $("$ROOT/lego" --version 2>&1 | head -n 1)"

CHALL=10.77.0.2
ACME=https://pebble:14000/dir
# lego's "exec" DNS provider: put the challenge record into challtestsrv, which
# Pebble queries. This stands in for Cloudflare; everything else is the real path.
cat >/tmp/dns-exec.sh <<EOF
#!/bin/sh
case \$1 in
present) wget -qO- --post-data="{\\"host\\":\\"\$2\\",\\"value\\":\\"\$3\\"}" http://$CHALL:8055/set-txt >/dev/null ;;
cleanup) wget -qO- --post-data="{\\"host\\":\\"\$2\\"}" http://$CHALL:8055/clear-txt >/dev/null ;;
esac
EOF
chmod 755 /tmp/dns-exec.sh
export LEGOCERT_TEST_DNS_PROVIDER=exec LEGOCERT_TEST_STAGING_SERVER=$ACME
export EXEC_PATH=/tmp/dns-exec.sh EXEC_PROPAGATION_TIMEOUT=60 EXEC_POLLING_INTERVAL=1
export LEGO_CA_CERTIFICATES=/tmp/pebble.minica.pem
# challtestsrv doesn't answer SOA queries (NOTIMP), which lego's authoritative-server
# propagation check needs. Skip only that check (real Cloudflare zones answer SOA);
# lego still confirms the record through the resolver given in DNS_RESOLVERS.
export LEGO_DNS_PROPAGATION_DISABLE_ANS=true
cp /src/tests/e2e/.pebble-minica.pem "$LEGO_CA_CERTIFICATES"

printf 'waiting for Pebble'
i=0
until wget -q --no-check-certificate -O /dev/null "$ACME" 2>/dev/null; do
	i=$((i + 1)); [ $i -gt 60 ] && { echo " - Pebble never came up"; exit 1; }
	printf .; sleep 1
done
echo " up"

reset_box old
printf 'ACME_SERVER=%s\nDNS_RESOLVERS=%s:8053\n' "$ACME" "$CHALL" >>"$ROOT/legocert.conf"
LOGF="$ROOT/log/legocert.log"

# Session stub for the settings page's status endpoint (QTS's authLogin.cgi).
# lego never uses curl; the DNS script uses wget.
cat >/usr/local/bin/curl <<'EOF'
#!/bin/sh
cat >/dev/null
echo '<QDocRoot><authPassed><![CDATA[1]]></authPassed><isAdmin><![CDATA[1]]></isAdmin></QDocRoot>'
EOF
chmod 755 /usr/local/bin/curl
status() { env -i PATH="$PATH" REQUEST_METHOD=GET HTTP_COOKIE="NAS_USER=admin; NAS_SID=x1" QUERY_STRING="status=1" "$ROOT/ui/index.cgi" </dev/null | sed '1,/^\r$/d'; }
sval() { status | sed -n "s/^$1=//p"; }
segment() { awk '/ (Test run|Renew now|Scheduled check|Check) started$/ { buf = "" } { buf = buf $0 "\n" } END { printf "%s", buf }' "$LOGF"; }
seg_has() { segment | grep -q -- "$1"; }
# check() runs its command in this shell, so these helpers can be passed to it by name
# (a "sh -c" child would not see them).
issued_by_pebble() { echo | openssl s_client -connect 127.0.0.1:8443 2>/dev/null | openssl x509 -noout -issuer 2>/dev/null | grep -qi pebble; }
msg_has() { sval msg | grep -Eq -- "$1"; }
seg_matches() { segment | grep -Eq -- "$1"; }
seg_lacks() { ! segment | grep -q -- "$1"; }
served_is() { [ "$(served_fp)" = "$1" ]; }
served_is_not() { [ "$(served_fp)" != "$1" ]; }

section "E1. Renew now: first certificate, issued by Pebble through real DNS-01, installed"
"$ROOT/renew.sh"; rc=$?
check "exit 0" [ "$rc" = 0 ]
check "QTS now serves a certificate issued by Pebble" issued_by_pebble
# The progress line reads these lines from lego's own output. If a lego update
# rewords one, the bar silently stops at a stage: catch that here.
check "lego still logs 'dns01: preparing to solve' (stage: DNS record)" seg_has 'dns01: preparing to solve'
check "lego still logs 'waiting for record propagation' (stage: Let's Encrypt check)" seg_has 'waiting for record propagation'
check "lego still logs 'The server validated our request'" seg_has 'The server validated our request'
check "lego still logs 'Server responded with a certificate' (stage: Certificate)" seg_has 'Server responded with a certificate'
check "install step ran and reported" seg_has 'installed a new certificate'
check "progress: done, green" [ "$(sval state)" = ok ]
check "progress: 'New certificate installed'" msg_has "New certificate installed"
check "Renew now notified (info)" grep -q 'type=0 \[LegoCert\] installed a new certificate' "$SYSLOG"
first=$(served_fp)

section "E2. Renew now again: not due"
rm -f "$SYSLOG"
"$ROOT/renew.sh"; rc=$?
check "exit 0" [ "$rc" = 0 ]
check "lego still logs 'Skip renewal' with the days to go" seg_matches "Skip renewal:.*can be performed in [0-9]+d"
check "progress: 'Not due yet … about N days'" msg_has "Not due yet.*about [0-9]+ days"
check "same certificate still served" served_is "$first"
check "Renew now left a QuLog entry" grep -q 'Renew now: not due yet' "$SYSLOG"

section "E3. Scheduled check, not due: quiet"
rm -f "$SYSLOG"
"$ROOT/renew.sh" --auto; rc=$?
check "exit 0" [ "$rc" = 0 ]
check "no system-log entry" [ ! -s "$SYSLOG" ]

section "E4. Renew --force: renews and installs a new certificate"
"$ROOT/renew.sh" --force; rc=$?
check "exit 0" [ "$rc" = 0 ]
check "a different certificate is now served" served_is_not "$first"
renewed=$(served_fp)

section "E5. Test run twice: each one does the full DNS-01 check"
"$ROOT/renew.sh" --staging; rc1=$?
"$ROOT/renew.sh" --staging; rc2=$?
check "both exit 0" sh -c '[ "$1" = 0 ] && [ "$2" = 0 ]' _ "$rc1" "$rc2"
check "second test did the DNS step (authorization was given up)" seg_has 'dns01: preparing to solve'
check "second test did not reuse an authorization" seg_lacks "Authorization is already valid"
check "progress: 'Everything works'" msg_has "Everything works"
check "test runs installed nothing" served_is "$renewed"

echo
echo "e2e passed: $pass  failed: $failed"
if [ "$failed" != 0 ]; then
	echo "--- legocert.log (last 80 lines) ---"
	tail -n 80 "$LOGF"
fi
[ "$failed" = 0 ]
