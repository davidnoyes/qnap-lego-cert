#!/bin/sh
# Behaviour tests for the LegoCert scripts, run under busybox ash in Alpine
# (QTS's shell). QTS pieces are stubbed: getcfg, log_tool, the init scripts
# (stunnel = an openssl s_server on 127.0.0.1:8443) and lego (writes a fixture
# certificate). The scripts under test are the real qpkg/shared files.
#
#   make test     (runs this inside docker.io/library/alpine)
set -u

ROOT=/qpkg              # stands in for the QPKG install dir
FIX=/fixtures
SYSLOG=/tmp/syslog      # what log_tool received
export LEGOCERT_VERIFY_SECONDS=10
DOMAIN=nas.home.example.com
pass=0
failed=0

ok() { pass=$((pass + 1)); echo "  ok   $*"; }
bad() { failed=$((failed + 1)); echo "  FAIL $*"; }
check() { # check DESCRIPTION COMMAND...
	d=$1; shift
	if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi
}

# ---------------------------------------------------------------- environment
apk add --no-cache openssl >/dev/null

mkdir -p /sbin /etc/init.d /etc/config "$ROOT" "$FIX" /etc/stunnel
cp -r /src/qpkg/shared/. "$ROOT"/
chmod 755 "$ROOT"/*.sh "$ROOT"/ui/index.cgi

cat >/sbin/getcfg <<'EOF'
#!/bin/sh
case "$1 $2" in
"LegoCert Install_Path") echo /qpkg ;;
"LegoCert Enable") echo TRUE ;;
"Stunnel Port") echo 8443 ;;
*)	# like the real getcfg: print the -d default if given
	d=""; while [ $# -gt 0 ]; do [ "$1" = -d ] && d=$2; shift; done
	[ -n "$d" ] && echo "$d" && exit 0
	echo "getcfg stub: no value" >&2; exit 1 ;;
esac
EOF
cat >/sbin/log_tool <<'EOF'
#!/bin/sh
# log_tool --append MSG --type N --app_name NAME
while [ $# -gt 0 ]; do
	case $1 in --append) msg=$2; shift ;; --type) t=$2; shift ;; esac
	shift
done
echo "type=$t $msg" >>/tmp/syslog
EOF
# "stunnel": serve whatever /etc/stunnel/stunnel.pem holds (key + cert).
# /fixtures/stunnel_broken makes it ignore the new files (QTS not picking them up).
cat >/etc/init.d/stunnel.sh <<'EOF'
#!/bin/sh
[ -f /tmp/s_server.pid ] && kill "$(cat /tmp/s_server.pid)" 2>/dev/null
sleep 0.3
pem=/etc/stunnel/stunnel.pem
[ -f /fixtures/stunnel_broken ] && pem=/fixtures/old.pem
openssl s_server -quiet -accept 8443 -cert "$pem" -www </dev/null >/dev/null 2>&1 &
echo $! >/tmp/s_server.pid
sleep 0.5
EOF
printf '#!/bin/sh\nexit 0\n' >/etc/init.d/thttpd.sh
cp /etc/init.d/thttpd.sh /etc/init.d/Qthttpd.sh
chmod 755 /sbin/getcfg /sbin/log_tool /etc/init.d/*.sh

# lego stub: record how it was called; on success "issue" /fixtures/next.{crt,key}.
cat >"$ROOT/lego" <<'EOF'
#!/bin/sh
echo "argv: $*" >>/tmp/lego_calls
echo "token_in_env: ${CLOUDFLARE_DNS_API_TOKEN:+yes}" >>/tmp/lego_calls
rc=$(cat /fixtures/lego_rc 2>/dev/null || echo 0)
[ "$rc" = 0 ] || exit "$rc"
path=""; dom=""
while [ $# -gt 0 ]; do
	case $1 in --path) path=$2; shift ;; --domains) dom=$2; shift ;; esac
	shift
done
if [ -f /fixtures/skip ]; then
	echo "INFO  Skip renewal: The certificate expires at 2027-02-16T11:42:55Z, the renewal can be performed in 59d15h11m19s. cert-name=$dom"
	exit 0
fi
if [ -f /fixtures/next.crt ]; then
	mkdir -p "$path/certificates"
	cp /fixtures/next.crt "$path/certificates/$dom.crt"
	cp /fixtures/next.key "$path/certificates/$dom.key"
fi
exit 0
EOF
chmod 755 "$ROOT/lego"

# ------------------------------------------------------------- certificates
cd "$FIX" || exit 1
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
	-keyout ca.key -out ca.pem -days 30 -subj /CN=test-ca 2>/dev/null
printf 'subjectAltName=DNS:%s\n' "$DOMAIN" >san.ext
mkcert() { # mkcert NAME LIFETIME_DAYS [CN] [DAYS_ALREADY_USED]
	openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
		-keyout "$1.key" -out "$1.csr" -subj "/CN=${3:-$DOMAIN}" 2>/dev/null
	ext=san.ext
	if [ -n "${3:-}" ]; then printf 'subjectAltName=DNS:%s\n' "$3" >"$1.ext"; ext="$1.ext"; fi
	used=${4:-0} now=$(date +%s)
	nb=$(date -u -d "@$((now - used * 86400))" +%Y%m%d%H%M%SZ)
	na=$(date -u -d "@$((now + ($2 - used) * 86400))" +%Y%m%d%H%M%SZ)
	openssl x509 -req -in "$1.csr" -CA ca.pem -CAkey ca.key -CAcreateserial \
		-not_before "$nb" -not_after "$na" -extfile "$ext" -out "$1.leaf" 2>/dev/null
	cat "$1.leaf" ca.pem >"$1.crt"
	cat "$1.key" "$1.leaf" >"$1.pem"
}
mkcert old 60
mkcert new 90
mkcert short 5
mkcert late 90 "" 85      # 90-day certificate, 5 days left: renewals have failed
mkcert overdue 90 "" 70   # 20 days left: past lego's renewal point (30), under a quarter
mkcert six 6              # a fresh 6-day (short-lived) certificate
mkcert fortyfive 45 "" 25 # 45-day certificate, 20 days left: before lego's renewal point
mkcert wrongname 90 other.example.com
fp() { openssl x509 -noout -fingerprint -sha256 -in "$1"; }
served_fp() { echo | openssl s_client -connect 127.0.0.1:8443 2>/dev/null | openssl x509 -noout -fingerprint -sha256 2>/dev/null; }

reset_box() { # reset_box SERVED_CERT_NAME: stunnel serving that cert, clean app state
	rm -rf "$ROOT/data" "$ROOT/.lock" "$ROOT/log" /etc/stunnel/backups /tmp/lego_calls "$SYSLOG" \
		"$FIX/stunnel_broken" "$FIX/next.crt" "$FIX/next.key" "$FIX/lego_rc"
	cp "$FIX/$1.pem" /etc/stunnel/stunnel.pem
	cp "$FIX/$1.leaf" /etc/stunnel/backup.cert
	cp "$FIX/$1.key" /etc/stunnel/backup.key
	cp "$FIX/$1.crt" /etc/stunnel/uca.pem
	/etc/init.d/stunnel.sh restart
	cat >"$ROOT/legocert.conf" <<EOF
DOMAIN=$DOMAIN
EMAIL=test@example.com
CLOUDFLARE_DNS_API_TOKEN=tok_ABC-123
EOF
	chmod 600 "$ROOT/legocert.conf"
}
issue() { cp "$FIX/$1.crt" "$FIX/next.crt"; cp "$FIX/$1.key" "$FIX/next.key"; }
syslog_has() { grep -q "$1" "$SYSLOG" 2>/dev/null; }

# ---------------------------------------------------------------------- tests
T0=$(date +%s)
section() { echo "[$(($(date +%s) - T0))s] $*"; }
section "1. renewal installs the new certificate"
reset_box old; issue new
"$ROOT/renew.sh"; rc=$?
check "exit 0" [ "$rc" = 0 ]
check "QTS now serves the new certificate" [ "$(served_fp)" = "$(fp "$FIX/new.leaf")" ]
check "info notification sent" syslog_has "type=0 \[LegoCert\] installed a new certificate"
check "backup of the old files made" ls /etc/stunnel/backups/
check "stunnel.pem is mode 600" [ "$(stat -c %a /etc/stunnel/stunnel.pem)" = 600 ]
check "token reached lego via env" grep -q "token_in_env: yes" /tmp/lego_calls
check "token not on lego's command line" sh -c '! grep -q tok_ABC /tmp/lego_calls'
check "token not in the log" sh -c "! grep -rq tok_ABC $ROOT/log"

section "2. scheduled check with nothing to do is silent"
rm -f "$SYSLOG"
"$ROOT/renew.sh" --auto; rc=$?
check "exit 0" [ "$rc" = 0 ]
check "no notifications" [ ! -s "$SYSLOG" ]

section "3. firmware update resets /etc/stunnel -> next run repairs it"
cp "$FIX/old.pem" /etc/stunnel/stunnel.pem; /etc/init.d/stunnel.sh restart
"$ROOT/renew.sh" --check
check "new certificate reinstalled without lego" [ "$(served_fp)" = "$(fp "$FIX/new.leaf")" ]

section "4. QTS does not pick up the new files -> rollback"
reset_box old; issue new; touch "$FIX/stunnel_broken"
"$ROOT/renew.sh"; rc=$?
check "exit non-zero" [ "$rc" != 0 ]
check "old certificate still served" [ "$(served_fp)" = "$(fp "$FIX/old.leaf")" ]
check "old files restored on disk" cmp /etc/stunnel/stunnel.pem "$FIX/old.pem"
check "error notification mentions rollback" syslog_has "type=2 .*rolled back"
echo "   ...and the next run retries once QTS behaves"
rm -f "$FIX/stunnel_broken"
"$ROOT/renew.sh"
check "new certificate installed on retry" [ "$(served_fp)" = "$(fp "$FIX/new.leaf")" ]

section "5. lego fails, plenty of time left -> warning"
reset_box old; echo 1 >"$FIX/lego_rc"
"$ROOT/renew.sh"; rc=$?
check "exit non-zero" [ "$rc" != 0 ]
check "warning (not error)" syslog_has "type=1 .*renewal attempt failed"
check "no error" sh -c "! grep -q 'type=2' $SYSLOG"

section "6. lego fails, 90-day certificate with 5 days left -> errors"
reset_box late; echo 1 >"$FIX/lego_rc"
"$ROOT/renew.sh"
check "expiry error" syslog_has "type=2 .*expires in 5 days and has not been renewed"
check "renewal error" syslog_has "type=2 .*renewal failed .*expires soon"

section "6b. expiry warnings follow the certificate's own lifetime"
for c in six fortyfive; do
	reset_box $c; rm -f "$SYSLOG"
	"$ROOT/renew.sh" --check
	check "fresh/healthy short-lived certificate ($c): no warning" sh -c "! grep -q 'type=[12]' $SYSLOG"
done
reset_box overdue; rm -f "$SYSLOG"
"$ROOT/renew.sh" --check
check "90-day certificate with 20 days left: warning, renewal overdue" syslog_has "type=1 .*expires in 20 days; renewal is overdue"
check "...not an error" sh -c "! grep -q 'type=2' $SYSLOG"
reset_box short; rm -f "$SYSLOG"
"$ROOT/renew.sh" --check
check "fresh 5-day certificate: no warning (it isn't overdue)" sh -c "! grep -q 'type=[12]' $SYSLOG"

section "7. certificate for the wrong name is refused"
reset_box old; issue wrongname
"$ROOT/renew.sh"
check "old certificate still served" [ "$(served_fp)" = "$(fp "$FIX/old.leaf")" ]
check "error says why" syslog_has "does not cover $DOMAIN"

section "8. stale lock from a crashed run is taken over"
reset_box old; issue new
mkdir -p "$ROOT/.lock"; echo 99999 >"$ROOT/.lock/pid"
"$ROOT/renew.sh"
check "run went ahead" [ "$(served_fp)" = "$(fp "$FIX/new.leaf")" ]
check "lock released" [ ! -d "$ROOT/.lock" ]

section "9. live lock from a running job -> skip"
reset_box old; issue new
sleep 30 & live=$!
mkdir -p "$ROOT/.lock"; echo "$live" >"$ROOT/.lock/pid"
"$ROOT/renew.sh"; rc=$?
kill "$live"
check "exit 0 (skipped)" [ "$rc" = 0 ]
check "nothing installed" [ "$(served_fp)" = "$(fp "$FIX/old.leaf")" ]
rm -rf "$ROOT/.lock"

section "10. config is data, not code"
reset_box old
printf 'DOMAIN=$(touch /tmp/pwned)\nEMAIL=a@b.c\nCLOUDFLARE_DNS_API_TOKEN=x\n' >"$ROOT/legocert.conf"
"$ROOT/renew.sh"; rc=$?
check "command substitution not executed" [ ! -e /tmp/pwned ]
check "rejected with an error" [ "$rc" != 0 ]
printf 'DOMAIN=%s\nEMAIL=a@b.c\nCLOUDFLARE_DNS_API_TOKEN=x\nEVIL=1\n' "$DOMAIN" >"$ROOT/legocert.conf"
"$ROOT/renew.sh"; rc=$?
check "unknown key rejected" [ "$rc" != 0 ]

section "11. config readable by others is refused"
reset_box old; chmod 644 "$ROOT/legocert.conf"; rm -f "$SYSLOG"
"$ROOT/renew.sh"; rc=$?
check "exit non-zero" [ "$rc" != 0 ]
check "lego not called" [ ! -e /tmp/lego_calls ]
check "error notification" syslog_has "type=2 .*configuration problem"

section "11b. fresh install, not set up yet -> quiet"
reset_box old
printf 'DOMAIN=%s\nEMAIL=\nCLOUDFLARE_DNS_API_TOKEN=\n' "$DOMAIN" >"$ROOT/legocert.conf"; chmod 600 "$ROOT/legocert.conf"
rm -f "$SYSLOG"
"$ROOT/renew.sh"; rc=$?
check "exit 0" [ "$rc" = 0 ]
check "no system-log entry" [ ! -s "$SYSLOG" ]
check "noted in our own log" grep -q "not set up yet" "$ROOT/log/legocert.log"
printf 'DOMAIN=%s\nEMAIL=\nCLOUDFLARE_DNS_API_TOKEN=tok_x\n' "$DOMAIN" >"$ROOT/legocert.conf"
"$ROOT/renew.sh"; rc=$?
check "half-configured still reports an error" sh -c "[ $rc != 0 ] && grep -q 'type=2' $SYSLOG"
check "...with a readable log line" grep -q "Settings: Enter an email address" "$ROOT/log/legocert.log"

section "11c. scheduled run never gets the FIRST certificate"
reset_box old; issue new
"$ROOT/renew.sh" --auto; rc=$?
check "exit 0" [ "$rc" = 0 ]
check "lego not called" [ ! -e /tmp/lego_calls ]
check "nothing installed" [ "$(served_fp)" = "$(fp "$FIX/old.leaf")" ]
check "log says to use Renew now" grep -q "use Renew now" "$ROOT/log/legocert.log"
check "scheduled run is named as such" grep -q "Scheduled check started" "$ROOT/log/legocert.log"
"$ROOT/renew.sh"
check "Renew now gets the first certificate" [ "$(served_fp)" = "$(fp "$FIX/new.leaf")" ]
rm -f /tmp/lego_calls
"$ROOT/renew.sh" --auto
check "...after which scheduled runs do renew" [ -e /tmp/lego_calls ]
check "scheduled runs keep lego's random delay" sh -c '! grep -q -- "--no-random-sleep" /tmp/lego_calls'

section "11e. Renew now leaves a system-log entry even when nothing is due"
reset_box old; issue new
"$ROOT/renew.sh"            # first certificate (installs; its own info entry)
rm -f "$SYSLOG"; touch "$FIX/skip"
"$ROOT/renew.sh"
check "not due -> info entry with days to go" grep -q "type=0 \[LegoCert\] Renew now: not due yet, nothing to do. Renews automatically in about 59 days." "$SYSLOG"
rm -f "$SYSLOG"
"$ROOT/renew.sh" --auto
check "scheduled not-due check stays quiet" [ ! -s "$SYSLOG" ]
rm -f "$FIX/skip"

section "11d. a button run that finds another run busy says so"
reset_box old
sleep 30 & live=$!
mkdir -p "$ROOT/.lock"; echo "$live" >"$ROOT/.lock/pid"
"$ROOT/renew.sh" --staging
kill "$live"; rm -rf "$ROOT/.lock"
check "Test run skip is visible in the log" grep -q "Test run skipped: another run is in progress. Try again" "$ROOT/log/legocert.log"

section "11f. install/upgrade settings handling (package_routines)"
post_install() { # post_install DIR: run pkg_post_install the way QDK's qinstall.sh does
	(CMD_GREP=grep CMD_ECHO=echo CMD_DATE=date CMD_CP=cp CMD_MV=mv CMD_CHOWN=chown CMD_CHMOD=chmod CMD_MKDIR=mkdir SYS_QPKG_DIR=$1
	 . /src/qpkg/package_routines; pkg_post_install)
}
P=/tmp/pkg; rm -rf $P; mkdir -p $P/ui; cp -r /src/qpkg/shared/. $P/; touch $P/lego
post_install $P
check "fresh install: settings created from the example" cmp -s $P/legocert.conf $P/legocert.conf.example
check "...root 600" [ "$(stat -c '%a %u' $P/legocert.conf)" = "600 0" ]
# 0.5.2's situation: QDK swapped the user's file for the blank template
cp $P/legocert.conf.example $P/legocert.conf
printf 'DOMAIN=nas.example.com\nEMAIL=a@b.co\nCLOUDFLARE_DNS_API_TOKEN=cfut_saved\n' >$P/legocert.conf.qdksave
post_install $P
check "settings recovered from legocert.conf.qdksave" grep -q '^CLOUDFLARE_DNS_API_TOKEN=cfut_saved$' $P/legocert.conf
check "...qdksave set aside, not reused" sh -c '[ ! -e "$1/legocert.conf.qdksave" ] && [ -e "$1/legocert.conf.qdksave.restored" ]' _ $P
check "...and noted in the log" grep -q "settings restored from legocert.conf.qdksave" $P/log/legocert.log
# a later upgrade with valid settings and a stray qdksave: keep the current settings
printf 'DOMAIN=nas.example.com\nEMAIL=a@b.co\nCLOUDFLARE_DNS_API_TOKEN=cfut_current\n' >$P/legocert.conf
printf 'CLOUDFLARE_DNS_API_TOKEN=cfut_old\n' >$P/legocert.conf.qdksave
post_install $P
check "upgrade keeps current settings" grep -q '^CLOUDFLARE_DNS_API_TOKEN=cfut_current$' $P/legocert.conf
check "the package no longer ships legocert.conf" [ ! -e /src/qpkg/shared/legocert.conf ]
check "qpkg.cfg has no QPKG_CONFIG" sh -c '! grep -q "^QPKG_CONFIG=" /src/qpkg/qpkg.cfg'

section "12. staging run installs nothing"
reset_box old; issue new
"$ROOT/renew.sh" --staging
check "old certificate still served" [ "$(served_fp)" = "$(fp "$FIX/old.leaf")" ]
check "used staging server and separate storage" grep -q "letsencrypt-staging --path /qpkg/data-staging" /tmp/lego_calls
check "staging always forces a full issuance" grep -q "letsencrypt-staging.*--renew-force" /tmp/lego_calls
check "button runs skip lego's random delay" grep -q "letsencrypt-staging.*--no-random-sleep" /tmp/lego_calls
check "Test run gives up the approval afterwards (next test is a full check)" grep -q "letsencrypt-staging.*--always-deactivate-authorizations" /tmp/lego_calls
check "log names it 'Test run' when it starts" grep -q "Test run started" "$ROOT/log/legocert.log"
check "...and when it ends" grep -q "Test run OK" "$ROOT/log/legocert.log"

section "13. --check-token"
# curl stub: records argv and the stdin config, answers from /fixtures/cf_*.json.
cat >/usr/local/bin/curl <<'EOF'
#!/bin/sh
echo "argv: $*" >>/tmp/curl_calls
cat >>/tmp/curl_stdin
for a in "$@"; do url=$a; done
case $url in
*/user/tokens/verify) cat /fixtures/cf_verify.json ;;
*/zones*) cat /fixtures/cf_zones.json ;;
esac
EOF
chmod 755 /usr/local/bin/curl
zone() { printf '{"id":"z%s","name":"%s","status":"active","account":{"id":"a1","name":"Example Account"},"plan":{"id":"p","name":"Free Website"}}' "$1" "$2"; }
reset_box old
echo '{"result":{"id":"t1","status":"active"},"success":true,"errors":[],"messages":[]}' >"$FIX/cf_verify.json"
printf '{"result":[%s],"success":true}' "$(zone 1 example-acme.net)" >"$FIX/cf_zones.json"
out=$("$ROOT/renew.sh" --check-token); rc=$?
check "one zone: exit 0" [ "$rc" = 0 ]
check "reports the zone" sh -c "printf '%s' \"\$1\" | grep -q 'can see (1): example-acme.net'" _ "$out"
check "token sent via stdin config" grep -q "Authorization: Bearer tok_ABC-123" /tmp/curl_stdin
check "token not in curl's argv" sh -c '! grep -q tok_ABC /tmp/curl_calls'
printf '{"result":[%s,%s],"success":true}' "$(zone 1 example.com)" "$(zone 2 example-acme.net)" >"$FIX/cf_zones.json"
out=$("$ROOT/renew.sh" --check-token); rc=$?
check "two zones: flagged, exit non-zero" sh -c "[ $rc != 0 ] && printf '%s' \"\$1\" | grep -q 'can see 2 zones'" _ "$out"
echo '{"success":false,"errors":[{"code":9109,"message":"Cannot use the access token from location: 203.0.113.9"}]}' >"$FIX/cf_verify.json"
out=$("$ROOT/renew.sh" --check-token); rc=$?
check "IP-filtered token: exit non-zero, shows Cloudflare's reason" \
	sh -c "[ $rc != 0 ] && printf '%s' \"\$1\" | grep -q '9109' && printf '%s' \"\$1\" | grep -q 'location'" _ "$out"
check "nothing installed or renewed" [ ! -e /tmp/lego_calls ]

section "14. settings page (ui/index.cgi)"
# General curl stub: URL from argv or from a 'url = "..."' line in a -K - config.
cat >/usr/local/bin/curl <<'EOF'
#!/bin/sh
cfg=$(cat)
printf '%s\n' "$cfg" >>/tmp/curl_stdin
echo "argv: $*" >>/tmp/curl_calls
url=$(printf '%s\n' "$cfg" | sed -n 's/^url = "\(.*\)"$/\1/p')
for a in "$@"; do case $a in http*) url=$a ;; esac; done
case $url in
*authLogin.cgi*) cat /fixtures/auth.xml ;;
*/user/tokens/verify) cat /fixtures/cf_verify.json ;;
*/zones*) cat /fixtures/cf_zones.json ;;
*cdn-cgi/trace) echo "ip=203.0.113.7" ;;
esac
EOF
chmod 755 /usr/local/bin/curl
admin_xml='<QDocRoot><authPassed><![CDATA[1]]></authPassed><isAdmin><![CDATA[1]]></isAdmin></QDocRoot>'
user_xml='<QDocRoot><authPassed><![CDATA[1]]></authPassed><isAdmin><![CDATA[0]]></isAdmin></QDocRoot>'
nope_xml='<QDocRoot><authPassed><![CDATA[0]]></authPassed></QDocRoot>'
cgi_get() { # cgi_get COOKIE -> response
	env -i PATH="$PATH" REQUEST_METHOD=GET HTTP_COOKIE="$1" HTTP_HOST=evil.example QUERY_STRING="${2:-}" \
		"$ROOT/ui/index.cgi" </dev/null
}
cgi_post() { # cgi_post COOKIE BODY -> response
	printf '%s' "$2" | env -i PATH="$PATH" REQUEST_METHOD=POST HTTP_COOKIE="$1" HTTP_HOST=evil.example \
		CONTENT_LENGTH="${3:-${#2}}" "$ROOT/ui/index.cgi"
}
status_of() { printf '%s\n' "$1" | sed -n '1s/^Status: \([0-9]*\).*/\1/p' | tr -d '\r'; }
has() { printf '%s' "$1" | grep -q -- "$2"; }
reset_box old
rm -f /tmp/curl_stdin
ADMIN="NAS_USER=admin; NAS_SID=abc123sid"

r=$(cgi_get ""); check "no session -> 401" [ "$(status_of "$r")" = 401 ]
echo "$nope_xml" >"$FIX/auth.xml"
r=$(cgi_get "$ADMIN"); check "session QTS rejects -> 401" [ "$(status_of "$r")" = 401 ]
echo "$user_xml" >"$FIX/auth.xml"
r=$(cgi_get "$ADMIN"); check "logged in but not admin -> 403" [ "$(status_of "$r")" = 403 ]
r=$(cgi_get 'NAS_SID=abc"><x'); check "malformed session cookie -> 401" [ "$(status_of "$r")" = 401 ]

echo "$admin_xml" >"$FIX/auth.xml"
r=$(cgi_get "$ADMIN")
check "admin -> 200" [ "$(status_of "$r")" = 200 ]
check "session checked on loopback, not the request's Host" \
	sh -c 'grep -q "127.0.0.1:.*authLogin.cgi?sid=abc123sid" /tmp/curl_stdin && ! grep -q evil.example /tmp/curl_stdin'
check "session id not on curl's command line" sh -c '! grep -q abc123sid /tmp/curl_calls'
check "token never sent to the browser" sh -c "! printf '%s' \"\$1\" | grep -q tok_ABC" _ "$r"
r2=$(cgi_get "$ADMIN" "tab=settings")
check "shows only the token's last 4 characters" has "$r2" 'ends -123'
check "token not sent on the settings tab either" sh -c "! printf '%s' \"\$1\" | grep -q tok_ABC" _ "$r2"
r2=$(cgi_get "$ADMIN" "tab=token")
check "has the Cloudflare guide" has "$r2" '<span>DNS</span><span class="cb">Read</span><span class="cb on">Edit</span>'
check "IP filter marked optional" has "$r2" 'Optional, recommended'
check "zone hint comes from the NAS name" has "$r2" 'Specific zone → example.com'
sed -i 's/^DOMAIN=.*/DOMAIN=nas.example.co.uk/' "$ROOT/legocert.conf"
r3=$(cgi_get "$ADMIN" "tab=token")
check "zone hint handles two-level suffixes (co.uk)" has "$r3" 'Specific zone → example.co.uk'
sed -i 's/^DOMAIN=.*/DOMAIN=nas.example.com/' "$ROOT/legocert.conf"
r3=$(cgi_get "$ADMIN" "tab=token")
check "zone hint for a plain domain" has "$r3" 'Specific zone → example.com'
sed -i "s/^DOMAIN=.*/DOMAIN=$DOMAIN/" "$ROOT/legocert.conf"
r2=$(cgi_get "$ADMIN" "tab=%3Cscript%3E")
check "unknown tab falls back safely" sh -c "! printf '%s' \"\$1\" | grep -qi '<script>'" _ "$r2"
check "strict CSP header" has "$r" "Content-Security-Policy: default-src 'none'"
CSRF=$(printf '%s' "$r" | grep -o 'name="csrf" value="[0-9a-f]*"' | head -n 1 | cut -d'"' -f4)
check "page carries a CSRF token" [ -n "$CSRF" ]

r=$(cgi_post "$ADMIN" "action=save&domain=$DOMAIN&email=new%40example.com&token=")
check "save without CSRF token -> 403" [ "$(status_of "$r")" = 403 ]
r=$(cgi_post "$ADMIN" "csrf=deadbeef&action=save&domain=$DOMAIN&email=new%40example.com&token=")
check "save with wrong CSRF token -> 403" [ "$(status_of "$r")" = 403 ]
check "config unchanged after rejected saves" sh -c "! grep -q new@example.com $ROOT/legocert.conf"
r=$(cgi_post "NAS_USER=admin; NAS_SID=othersession" "csrf=$CSRF&action=save&domain=$DOMAIN&email=new%40example.com&token=")
check "CSRF token from another session -> 403" [ "$(status_of "$r")" = 403 ]

r=$(cgi_post "$ADMIN" "csrf=$CSRF&action=save&domain=$DOMAIN&email=new%40example.com&token=")
check "valid save -> 303 redirect" [ "$(status_of "$r")" = 303 ]
check "email updated" grep -q '^EMAIL=new@example.com$' "$ROOT/legocert.conf"
check "blank token field keeps the token" grep -q '^CLOUDFLARE_DNS_API_TOKEN=tok_ABC-123$' "$ROOT/legocert.conf"
check "config still root 600" [ "$(stat -c '%a %u' "$ROOT/legocert.conf")" = "600 0" ]

r=$(cgi_post "$ADMIN" "csrf=$CSRF&action=save&domain=$DOMAIN&email=a%40b.co&token=cfut_new%0AEVIL%3D1")
check "token with injected line rejected" sh -c "! grep -q EVIL $ROOT/legocert.conf"
check "...with a readable error" has "$r" 'unexpected characters'
r=$(cgi_post "$ADMIN" "csrf=$CSRF&action=save&domain=%3Cscript%3Ealert(1)%3C%2Fscript%3E&email=a%40b.co&token=")
check "bad NAS name rejected" sh -c "! grep -q script $ROOT/legocert.conf"
check "...and echoed back escaped, never raw" sh -c "! printf '%s' \"\$1\" | grep -q '<script>' && printf '%s' \"\$1\" | grep -q '&lt;script&gt;'" _ "$r"
for bad in 192.168.1.10 nas 10.0.0.1; do
	r=$(cgi_post "$ADMIN" "csrf=$CSRF&action=save&domain=$bad&email=a%40b.co&token=")
	check "NAS name '$bad' rejected" sh -c "! grep -q '^DOMAIN=$bad\$' $ROOT/legocert.conf"
done
check "...IP gets a clear message" sh -c "printf '%s' \"\$1\" | grep -q 'not its IP address'" _ "$(cgi_post "$ADMIN" "csrf=$CSRF&action=save&domain=192.168.1.10&email=a%40b.co&token=")"
r=$(cgi_post "$ADMIN" "csrf=$CSRF&action=save&domain=$DOMAIN&email=a%40b.co%0ADOMAIN%3Devil&token=")
check "email with injected line rejected" sh -c "! grep -q evil $ROOT/legocert.conf"

r=$(cgi_post "$ADMIN" "csrf=$CSRF&action=save&domain=$DOMAIN&email=a%40b.co&token=cfut_fresh_Token-9")
check "new token saved" grep -q '^CLOUDFLARE_DNS_API_TOKEN=cfut_fresh_Token-9$' "$ROOT/legocert.conf"

echo '{"result":{"id":"t1","status":"active"},"success":true}' >"$FIX/cf_verify.json"
printf '{"result":[%s],"success":true}' "$(zone 1 example.com)" >"$FIX/cf_zones.json"
r=$(cgi_post "$ADMIN" "csrf=$CSRF&action=check_token")
check "Check token shows Cloudflare's verdict" has "$r" 'limited to a single zone'
r=$(cgi_post "$ADMIN" "csrf=$CSRF&action=ip")
check "public-address helper shows the address" has "$r" '203.0.113.7'
# --- progress line: state machine from the log ---
LOGF="$ROOT/log/legocert.log"
st() { cgi_get "$ADMIN" "status=1" | sed '1,/^\r$/d'; }   # status body
stv() { printf '%s\n' "$1" | sed -n "s/^$2=//p"; }          # stv BODY KEY
: >"$LOGF"
s=$(st); check "no runs yet: idle" [ "$(stv "$s" state)" = idle ]
r=$(cgi_get "$ADMIN" "tab=overview")
check "idle: progress box hidden" has "$r" 'id="prog" data-src="/cgi-bin/qpkg/LegoCert/index.cgi?status=1" data-state="idle" data-since="" hidden'
printf '2026-11-18 15:02:20 Test run started\n2026-11-18 15:02:20 lego run --server letsencrypt-staging\n2026-11-18T15:02:21Z INFO  dns01: preparing to solve the challenge.\n' >>"$LOGF"
sleep 30 & live=$!; mkdir -p "$ROOT/.lock"; echo "$live" >"$ROOT/.lock/pid"
s=$(st)
check "running Test run at stage DNS record" sh -c '[ "$1" = running ] && [ "$2" = 1 ]' _ "$(stv "$s" state)" "$(stv "$s" idx)"
check "...with a message saying what it's doing" sh -c 'printf "%s" "$1" | grep -q "DNS record in Cloudflare"' _ "$(stv "$s" msg)"
check "...named, with its stages" sh -c '[ "$1" = "Test run" ] && [ "$2" = "Starting|DNS record|Let'"'"'s Encrypt check|Certificate|Done" ]' _ "$(stv "$s" run)" "$(stv "$s" stages)"
r=$(cgi_get "$ADMIN" "tab=overview")
check "overview renders the running ball" has "$r" '<div class="ball running" style="left:25%"></div>'
check "...and loads progress.js" has "$r" '<script src="/cgi-bin/qpkg/LegoCert/index.cgi?asset=progress.js" defer></script>'
printf '2026-11-18T15:02:23Z INFO  dns01: waiting for record propagation.\n' >>"$LOGF"
check "propagation -> Let's Encrypt check" [ "$(stv "$(st)" idx)" = 2 ]
printf '2026-11-18T15:02:30Z INFO  The server validated our request.\n2026-11-18 15:02:33 [info] Test run OK: Let'"'"'s Encrypt ...\n' >>"$LOGF"
kill "$live"; rm -rf "$ROOT/.lock"
s=$(st)
check "Test run OK -> done, green" sh -c '[ "$1" = ok ] && [ "$2" = 4 ]' _ "$(stv "$s" state)" "$(stv "$s" idx)"
: >"$LOGF"; printf '2026-11-18 20:31:05 Test run started\nINFO  Authorization is already valid; skipping the challenge.\n2026-11-18 20:31:09 [info] Test run OK, partly: x\n' >>"$LOGF"
check "reused approval -> says it was only partly checked" sh -c 'printf "%s" "$1" | grep -q "Partly checked"' _ "$(stv "$(st)" msg)"
: >"$LOGF"
printf '2026-11-18 15:10:00 Renew now started\n2026-11-18 15:10:00 lego run --server letsencrypt\nINFO  Skip renewal: The certificate expires at 2027-01-21T13:56:50Z, the renewal can be performed in 42d14h54m. \n2026-11-18 15:10:01 Renew now finished OK\n' >>"$LOGF"
s=$(st)
check "not due -> short line, done, days to go" sh -c '[ "$1" = ok ] && [ "$2" = 2 ] && [ "$4" = "Starting|Renewal due?|Done" ] && printf "%s" "$3" | grep -q "about 42 days"' _ "$(stv "$s" state)" "$(stv "$s" idx)" "$(stv "$s" msg)" "$(stv "$s" stages)"
r=$(cgi_get "$ADMIN" "tab=overview")
check "every stage gets its label, including the last" has "$r" '<span class="lbl">Done</span>'
: >"$LOGF"
printf '2026-11-18 15:20:00 Renew now started\n2026-11-18 15:20:00 lego run\nINFO  dns01: preparing to solve the challenge.\nINFO  The server validated our request.\n2026-11-18 15:20:20 served certificate (x) differs from lego'"'"'s (y); installing\n2026-11-18 15:21:08 [info] installed a new certificate for n, valid until Feb 16 11:42:55 2027 GMT\n2026-11-18 15:21:08 Renew now finished OK\n' >>"$LOGF"
s=$(st)
check "installed -> done, says until when" sh -c '[ "$1" = ok ] && printf "%s" "$2" | grep -q "valid until 16 Feb 2027"' _ "$(stv "$s" state)" "$(stv "$s" msg)"
for case in "9109|Cannot use the access token from location: 1.2.3.4|IP filter" "zone|could not find zone for domain|zone" "prop|propagation: time limit exceeded|in time" "rate|urn:ietf:params:acme:error:rateLimited|rate limit" "net|dial tcp: lookup acme: no such host|internet connection"; do
	key=${case##*|}; line=$(printf '%s' "$case" | cut -d'|' -f2)
	: >"$LOGF"
	printf '2026-11-18 15:30:00 Renew now started\n2026-11-18 15:30:00 lego run\nINFO  dns01: preparing to solve the challenge.\nERROR %s\n2026-11-18 15:30:09 [warn] renewal attempt failed (lego exit 1); will retry tomorrow.\n' "$line" >>"$LOGF"
	s=$(st)
	check "error ($key) stops at DNS record, red, plain reason" sh -c '[ "$1" = error ] && [ "$2" = 2 ] && printf "%s" "$3" | grep -q "$4"' _ "$(stv "$s" state)" "$(stv "$s" idx)" "$(stv "$s" msg)" "$key"
done
r=$(cgi_get "$ADMIN" "tab=overview")
check "'Download details' is available" has "$r" '<p class="hint" id="prog-detail"><a href="/cgi-bin/qpkg/LegoCert/index.cgi?download=log">'
check "progress sits at the top, above Status" sh -c "printf '%s' \"\$1\" | awk '/id=\"prog\"/{p=NR} /<h3>Status<\/h3>/{s=NR} END{exit !(p && s && p<=s)}'" _ "$r"
: >"$LOGF"
printf '2026-11-18 15:40:00 Test run started\n2026-11-18 15:40:01 Test run skipped: another run is in progress. Try again in a minute.\n' >>"$LOGF"
check "skipped run shown as skipped" [ "$(stv "$(st)" state)" = skipped ]
: >"$LOGF"
printf '2026-11-18 15:50:00 Test run started\n2026-11-18 15:50:00 lego run\n' >>"$LOGF"
check "a run that died without finishing -> error" [ "$(stv "$(st)" state)" = error ]
p=$(cgi_get "" "status=1"); check "status needs a login" [ "$(status_of "$p")" = 401 ]
: >"$LOGF"; printf '2026-11-18 20:31:00 Test run started\n2026-11-18 20:31:09 [info] Test run OK: x\n' >>"$LOGF"
check "status carries the run's start time" [ "$(stv "$(st)" start)" = "2026-11-18 20:31:00" ]
r=$(cgi_get "$ADMIN" "tab=overview&msg=renew&since=2026-11-18%2020%3A31%3A35")
check "just clicked, new run not logged yet: shows it starting, not the old result" sh -c "printf '%s' \"\$1\" | grep -q '<b>Renew now</b>' && printf '%s' \"\$1\" | grep -q 'prog-msg running\">Starting'" _ "$r"
check "...and hands the click time to the script" has "$r" 'data-since="2026-11-18 20:31:35"'
printf '2026-11-18 20:31:35 Renew now started\nINFO  Skip renewal: the renewal can be performed in 59d1h.\n2026-11-18 20:31:36 Renew now finished OK\n' >>"$LOGF"
r=$(cgi_get "$ADMIN" "tab=overview&msg=renew&since=2026-11-18%2020%3A31%3A35")
check "a run that already finished is shown finished" has "$r" 'Not due yet'
r=$(cgi_post "$ADMIN" "csrf=$CSRF&action=renew")
check "Renew now redirect carries the click time" sh -c "printf '%s' \"\$1\" | grep -Eq 'Location: [^ ]*msg=renew&since=[0-9]{4}-[0-9]{2}-[0-9]{2}%20[0-9]{2}%3A[0-9]{2}%3A[0-9]{2}'" _ "$r"
sleep 2
d=$(cgi_get "$ADMIN" "download=log"); check "technical log downloads as a file" has "$d" 'Content-Disposition: attachment; filename="legocert.log"'
d=$(cgi_get "" "download=log"); check "...only when logged in" [ "$(status_of "$d")" = 401 ]
j=$(cgi_get "" "asset=progress.js")
check "progress.js served as JavaScript" has "$j" 'Content-Type: application/javascript'
check "progress.js never uses innerHTML" sh -c "printf '%s' \"\$1\" | grep -q 'textContent' && ! printf '%s' \"\$1\" | grep -q '\\.innerHTML'" _ "$j"
r=$(cgi_get "$ADMIN" "tab=log")
check "old Log tab falls back to the Overview" has "$r" '<div class="title">Overview</div>'
check "no Log in the sidebar" sh -c "! printf '%s' \"\$1\" | grep -q 'tab=log\"'" _ "$r"
check "QuLog Center link" has "$r" 'href="/qulog/"'
: >"$LOGF"
r=$(cgi_post "$ADMIN" "csrf=$CSRF&action=staging")
check "Test run button stays on the Overview" has "$r" 'Location: /cgi-bin/qpkg/LegoCert/index.cgi?tab=overview&msg=staging'
r=$(cgi_post "$ADMIN" "csrf=$CSRF&action=bogus")
check "unknown action -> 400" [ "$(status_of "$r")" = 400 ]
r=$(cgi_post "$ADMIN" "csrf=$CSRF&action=save" 999999)
check "oversized request -> 413" [ "$(status_of "$r")" = 413 ]

echo
echo "passed: $pass  failed: $failed"
[ "$failed" = 0 ]
