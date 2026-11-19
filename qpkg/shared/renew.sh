#!/bin/sh
# Daily job (cron) and manual entry point. Each run converges the NAS on a
# valid certificate, so a failure anywhere is retried on the next run:
#
#   1. lego run         obtain/renew into data/ (no-op unless renewal is due)
#   2. reconcile        if the certificate lego holds differs from the one QTS
#                       serves (and is valid), install it. No lego deploy hook:
#                       a failed install, or a firmware update resetting
#                       /etc/stunnel, is repaired by the next run.
#   3. expiry check     independent of lego: warn when the certificate QTS is
#                       actually serving gets close to expiry.
#
#   renew.sh            normal run (Renew now): may get the FIRST certificate
#   renew.sh --auto     scheduled run (cron, boot catch-up): only renews a certificate
#                       LegoCert already has; never gets the first one by itself, so
#                       nothing is installed (and QTS restarted) during setup
#   renew.sh --force    renew with lego now, whatever the expiry
#   renew.sh --check    skip lego: reconcile + expiry check only (no DNS provider)
#   renew.sh --staging  lego against Let's Encrypt staging into data-staging/;
#                       installs nothing (a staging certificate is untrusted)
#   renew.sh --check-token
#                       Cloudflare only: ask whether the token is active and which
#                       zones it can see; changes nothing (docs/cloudflare-token.md)

QPKG_NAME=LegoCert
QPKG_ROOT=$(/sbin/getcfg "$QPKG_NAME" Install_Path -f /etc/config/qpkg.conf)
. "$QPKG_ROOT/common.sh"

LEGO_TIMEOUT=900 # seconds; lego is killed if it hangs past this

# Test hooks for tests/e2e (real lego against Pebble). Never set in normal use: cron
# and the service script don't set them, and a web request can't (CGI only passes
# request headers as HTTP_* variables).
TEST_DNS_PROVIDER=${LEGOCERT_TEST_DNS_PROVIDER:-}
STAGING_SERVER=${LEGOCERT_TEST_STAGING_SERVER:-letsencrypt-staging}

MODE=normal
FORCE=0
AUTO=0
for arg in "$@"; do
	case $arg in
	--auto) AUTO=1 ;;
	--force) FORCE=1 ;;
	--check) MODE=check ;;
	--staging) MODE=staging ;;
	--check-token) MODE=token ;;
	*)
		echo "Usage: $0 [--auto] [--force] [--check | --staging | --check-token]" >&2
		exit 2
		;;
	esac
done

# A fresh install runs a catch-up check before anyone has opened Settings. That is
# not a fault: note it in our own log only, so Notification Center stays quiet.
if [ "$MODE" != token ] && read_conf 2>/dev/null && [ -z "$EMAIL" ] && [ -z "$CREDS" ]; then
	log "not set up yet (open LegoCert to configure); nothing to do"
	exit 0
fi

if ! load_conf; then
	[ "$MODE" = token ] && tail -n 1 "$LOG" >&2
	notify error "configuration problem; nothing renewed or checked (details: $LOG)"
	exit 1
fi
[ -z "$TEST_DNS_PROVIDER" ] || DNS_PROVIDER=$TEST_DNS_PROVIDER

# --- check-token: interactive, read-only ---------------------------------------
# The token goes to curl in a config file on stdin (printf is a shell builtin), so
# it never appears in a process's argument list.
cf_get() { # cf_get TOKEN PATH
	printf 'header = "Authorization: Bearer %s"\n' "$1" |
		curl -sS -m 20 -K - "https://api.cloudflare.com/client/v4$2" 2>&1
}
if [ "$MODE" = token ]; then
	if [ "$DNS_PROVIDER" != cloudflare ]; then
		echo "Check token is for Cloudflare. For $(provider_label "$DNS_PROVIDER"), use Test run."
		exit 2
	fi
	rc=0
	out=$(cf_get "$(cred_get CLOUDFLARE_DNS_API_TOKEN)" /user/tokens/verify)
	if printf '%s' "$out" | grep -q '"status" *: *"active"'; then
		echo "token: active"
	else
		echo "token: NOT active or not accepted. Cloudflare said:"
		printf '%s\n' "$out" | grep -o '"code" *: *[0-9]*\|"message" *: *"[^"]*"' | sed 's/^/  /'
		[ -n "$out" ] || echo "  (no response: check the NAS can reach api.cloudflare.com)"
		exit 1
	fi
	# Zones the token can read (with a separate zone token, that one does the lookup).
	ztoken=$(cred_get CLOUDFLARE_ZONE_API_TOKEN)
	ztoken=${ztoken:-$(cred_get CLOUDFLARE_DNS_API_TOKEN)}
	zones=$(cf_get "$ztoken" "/zones?per_page=50" | tr '{' '\n' |
		grep -o '"name" *: *"[^" ]*\.[^" ]*" *, *"status"' | cut -d'"' -f4 | sort -u)
	n=$(printf '%s' "$zones" | grep -c .)
	echo "zones this token can see ($n): $(printf '%s' "$zones" | tr '\n' ' ')"
	case $n in
	0)
		echo "PROBLEM: no zones visible. Add the permission Zone > Zone > Read for the one zone."
		rc=1
		;;
	1) echo "OK: the token is limited to a single zone." ;;
	*)
		echo "PROBLEM: the token can see $n zones. Recreate it with Zone Resources = Specific zone."
		rc=1
		;;
	esac
	log "check-token: zones visible: $n"
	exit "$rc"
fi

if ! acquire_lock; then
	case $MODE in
	staging) what="Test run" ;;
	check) what="Check" ;;
	*) what="Renewal" ;;
	esac
	if [ "$AUTO" = 1 ]; then
		log "scheduled check skipped: another run is in progress"
	else
		log "$what skipped: another run is in progress. Try again in a minute."
	fi
	exit 0
fi
case $MODE in
staging) RUN_NAME="Test run" ;;
check) RUN_NAME="Check" ;;
*) if [ "$AUTO" = 1 ]; then RUN_NAME="Scheduled check"; else RUN_NAME="Renew now"; fi ;;
esac
log "$RUN_NAME started"
trap release_lock EXIT INT TERM
trim_log

# Replace every credential value (from the environment, named in LEGOCERT_REDACT) in
# lego's output with [redacted]. Values under 4 characters are left alone.
REDACT_AWK='BEGIN { n = split(ENVIRON["LEGOCERT_REDACT"], names, " ")
	for (i = 1; i <= n; i++) { v = ENVIRON[names[i]]; if (length(v) >= 4) vals[++m] = v } }
{ for (i = 1; i <= m; i++) while ((p = index($0, vals[i])) > 0) $0 = substr($0, 1, p - 1) "[redacted]" substr($0, p + length(vals[i]))
  print; fflush() }'

# Run lego with the credentials in its environment only: exported in a subshell
# that becomes lego, never on a command line (where ps would show them).
run_lego() { # run_lego DATA_DIR SERVER
	set -- run --accept-tos --email "$EMAIL" --domains "$DOMAIN" \
		--server "$2" --path "$1" \
		--dns "$DNS_PROVIDER" --dns.resolvers "$DNS_RESOLVERS"
	[ "$FORCE" = 1 ] && set -- "$@" --renew-force
	# lego waits a random 0-8 min before renewing when not on a terminal, so that
	# scheduled renewals everywhere don't hit Let's Encrypt at the same moment. Keep
	# that for scheduled runs; skip it when someone has just clicked a button.
	[ "$AUTO" = 1 ] || set -- "$@" --no-random-sleep
	# Test runs give up Let's Encrypt's approval of the name afterwards, so the next test
	# has to prove it again through the DNS provider (otherwise it is reused for ~30 days and a
	# test would not exercise the DNS record or the token at all).
	[ "${DEACTIVATE:-0}" = 1 ] && set -- "$@" --always-deactivate-authorizations
	log "lego $*"
	# lego's messages can quote a credential (DuckDNS's token is part of the URL it
	# prints on errors), so its output reaches the log through a redactor.
	fifo="$QPKG_ROOT/.lego-out.$$"
	rm -f "$fifo"
	redact_pid=""
	if mkfifo -m 600 "$fifo" 2>/dev/null; then
		(
			export_creds
			LEGOCERT_REDACT=$(cred_names)
			export LEGOCERT_REDACT
			exec awk "$REDACT_AWK"
		) <"$fifo" >>"$LOG" 2>&1 &
		redact_pid=$!
		out=$fifo
	else
		log "[warn] mkfifo failed: lego's output is logged unredacted"
		out=$LOG
	fi
	(
		export_creds
		exec "$QPKG_ROOT/lego" "$@"
	) >>"$out" 2>&1 &
	lego_pid=$!
	(sleep "$LEGO_TIMEOUT" && kill "$lego_pid" 2>/dev/null && log "[error] lego exceeded ${LEGO_TIMEOUT}s; killed") &
	watchdog=$!
	wait "$lego_pid"
	rc=$?
	kill "$watchdog" 2>/dev/null
	[ -z "$redact_pid" ] || wait "$redact_pid"
	rm -f "$fifo"
	return "$rc"
}

# --- staging: prove DNS-01 + the DNS provider work, install nothing ----------------
if [ "$MODE" = staging ]; then
	# Always a full issuance: a test that lego skips ("not due yet") proves nothing.
	# Safe on staging: separate rate limits, and nothing is installed.
	FORCE=1
	DEACTIVATE=1
	mkdir -p "$QPKG_ROOT/data-staging" && chmod 700 "$QPKG_ROOT/data-staging"
	log_mark=$(wc -l <"$LOG" 2>/dev/null || echo 0)
	if run_lego "$QPKG_ROOT/data-staging" "$STAGING_SERVER"; then
		if tail -n +"$((log_mark + 1))" "$LOG" | grep -q 'Authorization is already valid'; then
			notify info "Test run OK, partly: Let's Encrypt reused a recent check, so the DNS step was skipped this time. Run the test again for a full check."
		else
			notify info "Test run OK: Let's Encrypt's test service issued a certificate for $DOMAIN (nothing installed)"
		fi
		exit 0
	fi
	notify error "Test run FAILED for $DOMAIN; see the LegoCert log"
	exit 1
fi

DATA="$QPKG_ROOT/data"
mkdir -p "$DATA" && chmod 700 "$DATA"
STORED_CERT="$DATA/certificates/$DOMAIN.crt"
STORED_KEY="$DATA/certificates/$DOMAIN.key"
status=0

# --- 1. lego --------------------------------------------------------------------
lego_rc=0
if [ "$MODE" = normal ] && [ "$AUTO" = 1 ] && [ ! -s "$STORED_CERT" ]; then
	# Scheduled runs only renew. The first certificate comes from Renew now, so
	# setting up never triggers an install (and QTS web restart) by surprise.
	log "no LegoCert certificate yet: use Renew now to get the first one"
elif [ "$MODE" = normal ]; then
	log_mark=$(wc -l <"$LOG" 2>/dev/null || echo 0)
	run_lego "$DATA" "$ACME_SERVER"
	lego_rc=$?
fi

# --- 2. reconcile stored vs served ----------------------------------------------
TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"; release_lock' EXIT INT TERM
served_cert >"$TMP/served.pem"
served_fp=$(fingerprint <"$TMP/served.pem")

if [ -s "$STORED_CERT" ] && [ -s "$STORED_KEY" ]; then
	leaf_of "$STORED_CERT" >"$TMP/stored.pem"
	stored_fp=$(fingerprint <"$TMP/stored.pem")
	if [ -n "$stored_fp" ] && [ "$stored_fp" != "$served_fp" ]; then
		if openssl x509 -noout -checkend 0 -in "$TMP/stored.pem" >/dev/null 2>&1; then
			log "served certificate (${served_fp:-none}) differs from lego's ($stored_fp); installing"
			if "$QPKG_ROOT/install-cert.sh" "$STORED_CERT" "$STORED_KEY"; then
				served_cert >"$TMP/served.pem"
			else
				status=1 # install-cert.sh has already notified
			fi
		else
			log "lego's stored certificate has expired; not installing it"
		fi
	fi
elif [ "$MODE" = normal ] && [ "$lego_rc" = 0 ]; then
	log "[warn] lego succeeded but $STORED_CERT is missing"
fi

# --- 3. expiry of what QTS actually serves --------------------------------------
# Relative to the certificate's own lifetime (see cert_times in common.sh): lego renews
# with a third left, so under a quarter means renewals are failing.
served_level=ok
if [ ! -s "$TMP/served.pem" ]; then
	notify error "could not read the certificate QTS serves on port $HTTPS_PORT"
	served_level=error
	status=1
else
	cert_times "$TMP/served.pem"
	left=$(human_left "$CERT_LEFT")
	if [ "$CERT_LEFT" -le 0 ]; then
		notify error "the certificate QTS serves for $DOMAIN has EXPIRED"
		served_level=error
	elif [ "$CERT_LEFT" -lt $((CERT_LIFE / 8)) ]; then
		notify error "the certificate QTS serves for $DOMAIN expires in $left and has not been renewed"
		served_level=error
	elif [ "$CERT_LEFT" -lt $((CERT_LIFE / 4)) ]; then
		notify warn "the certificate QTS serves for $DOMAIN expires in $left; renewal is overdue"
		served_level=warn
	fi
	[ "$served_level" = error ] && status=1
fi

# --- report lego failures, graded by how much time is left ----------------------
if [ "$lego_rc" != 0 ]; then
	if [ "$served_level" = error ]; then
		notify error "renewal failed (lego exit $lego_rc) and the certificate expires soon. See the LegoCert log"
	else
		notify warn "renewal attempt failed (lego exit $lego_rc); will retry tomorrow. See the LegoCert log"
	fi
	status=1
fi

# Someone pressed Renew now: always leave a system-log entry saying what happened, even
# when nothing was due (an install already sent its own). Scheduled checks stay quiet.
if [ "$status" = 0 ] && [ "$AUTO" = 0 ] && [ "$MODE" = normal ] && [ "$lego_rc" = 0 ]; then
	days=$(tail -n +"$((${log_mark:-0} + 1))" "$LOG" | sed -n 's/.*Skip renewal:.*can be performed in \([0-9]*\)d.*/\1/p' | head -n 1)
	if [ -n "$days" ]; then
		notify info "Renew now: not due yet, nothing to do. Renews automatically in about $days days."
	elif ! tail -n +"$((${log_mark:-0} + 1))" "$LOG" | grep -q "installed a new certificate"; then
		notify info "Renew now: the certificate is up to date."
	fi
fi
[ "$status" = 0 ] && log "$RUN_NAME finished OK"
exit "$status"
