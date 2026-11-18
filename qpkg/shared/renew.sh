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
#   renew.sh --check    skip lego: reconcile + expiry check only (no network to Cloudflare)
#   renew.sh --staging  lego against Let's Encrypt staging into data-staging/;
#                       installs nothing (a staging certificate is untrusted)
#   renew.sh --check-token
#                       ask Cloudflare whether the token is active and which zones
#                       it can see; changes nothing (docs/cloudflare-token.md)

QPKG_NAME=LegoCert
QPKG_ROOT=$(/sbin/getcfg "$QPKG_NAME" Install_Path -f /etc/config/qpkg.conf)
. "$QPKG_ROOT/common.sh"

LEGO_TIMEOUT=900 # seconds; lego is killed if it hangs past this

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
if [ "$MODE" != token ] && read_conf 2>/dev/null && [ -z "$EMAIL" ] && [ -z "$CF_DNS_TOKEN" ]; then
	log "not set up yet (open LegoCert to configure); nothing to do"
	exit 0
fi

if ! load_conf; then
	[ "$MODE" = token ] && tail -n 1 "$LOG" >&2
	notify error "configuration problem; nothing renewed or checked (details: $LOG)"
	exit 1
fi

# --- check-token: interactive, read-only ---------------------------------------
# The token goes to curl in a config file on stdin (printf is a shell builtin), so
# it never appears in a process's argument list.
cf_get() { # cf_get TOKEN PATH
	printf 'header = "Authorization: Bearer %s"\n' "$1" |
		curl -sS -m 20 -K - "https://api.cloudflare.com/client/v4$2" 2>&1
}
if [ "$MODE" = token ]; then
	rc=0
	out=$(cf_get "$CF_DNS_TOKEN" /user/tokens/verify)
	if printf '%s' "$out" | grep -q '"status" *: *"active"'; then
		echo "token: active"
	else
		echo "token: NOT active or not accepted. Cloudflare said:"
		printf '%s\n' "$out" | grep -o '"code" *: *[0-9]*\|"message" *: *"[^"]*"' | sed 's/^/  /'
		[ -n "$out" ] || echo "  (no response: check the NAS can reach api.cloudflare.com)"
		exit 1
	fi
	# Zones the token can read (with a separate zone token, that one does the lookup).
	ztoken=${CF_ZONE_TOKEN:-$CF_DNS_TOKEN}
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

# Run lego with the token in its environment only: not exported to this shell,
# never on a command line (where ps would show it).
run_lego() { # run_lego DATA_DIR SERVER
	set -- run --accept-tos --email "$EMAIL" --domains "$DOMAIN" \
		--server "$2" --path "$1" \
		--dns cloudflare --dns.resolvers "$DNS_RESOLVERS"
	[ "$FORCE" = 1 ] && set -- "$@" --renew-force
	# lego waits a random 0-8 min before renewing when not on a terminal, so that
	# scheduled renewals everywhere don't hit Let's Encrypt at the same moment. Keep
	# that for scheduled runs; skip it when someone has just clicked a button.
	[ "$AUTO" = 1 ] || set -- "$@" --no-random-sleep
	log "lego $*"
	if [ -n "$CF_ZONE_TOKEN" ]; then
		CLOUDFLARE_DNS_API_TOKEN=$CF_DNS_TOKEN CLOUDFLARE_ZONE_API_TOKEN=$CF_ZONE_TOKEN \
			"$QPKG_ROOT/lego" "$@" >>"$LOG" 2>&1 &
	else
		CLOUDFLARE_DNS_API_TOKEN=$CF_DNS_TOKEN \
			"$QPKG_ROOT/lego" "$@" >>"$LOG" 2>&1 &
	fi
	lego_pid=$!
	(sleep "$LEGO_TIMEOUT" && kill "$lego_pid" 2>/dev/null && log "[error] lego exceeded ${LEGO_TIMEOUT}s; killed") &
	watchdog=$!
	wait "$lego_pid"
	rc=$?
	kill "$watchdog" 2>/dev/null
	return "$rc"
}

# --- staging: prove DNS-01 + Cloudflare work, install nothing ----------------
if [ "$MODE" = staging ]; then
	# Always a full issuance: a test that lego skips ("not due yet") proves nothing.
	# Safe on staging: separate rate limits, and nothing is installed.
	FORCE=1
	mkdir -p "$QPKG_ROOT/data-staging" && chmod 700 "$QPKG_ROOT/data-staging"
	if run_lego "$QPKG_ROOT/data-staging" letsencrypt-staging; then
		notify info "Test run OK: Let's Encrypt's test service issued a certificate for $DOMAIN (nothing installed)"
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
days_ok() { openssl x509 -noout -checkend $(($1 * 86400)) -in "$TMP/served.pem" >/dev/null 2>&1; }
if [ ! -s "$TMP/served.pem" ]; then
	notify error "could not read the certificate QTS serves on port $HTTPS_PORT"
	status=1
elif ! days_ok 0; then
	notify error "the certificate QTS serves for $DOMAIN has EXPIRED"
	status=1
elif ! days_ok 7; then
	notify error "the certificate QTS serves for $DOMAIN expires within 7 days"
	status=1
elif ! days_ok 21; then
	# lego renews ~30 days out, so this means renewals have been failing.
	notify warn "the certificate QTS serves for $DOMAIN expires within 21 days"
fi

# --- report lego failures, graded by how much time is left ----------------------
if [ "$lego_rc" != 0 ]; then
	if [ -s "$TMP/served.pem" ] && days_ok 14; then
		notify warn "renewal attempt failed (lego exit $lego_rc); will retry tomorrow. See $LOG"
	else
		notify error "renewal failed (lego exit $lego_rc) and the certificate expires within 14 days. See $LOG"
	fi
	status=1
fi

[ "$status" = 0 ] && log "$RUN_NAME finished OK"
exit "$status"
