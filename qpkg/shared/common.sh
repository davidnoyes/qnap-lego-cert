#!/bin/sh
# Shared helpers, sourced by legocert.sh, renew.sh and install-cert.sh.
# QTS /bin/sh is busybox ash: keep this POSIX.

QPKG_NAME=LegoCert
QPKG_ROOT=$(/sbin/getcfg "$QPKG_NAME" Install_Path -f /etc/config/qpkg.conf)
CONF="$QPKG_ROOT/legocert.conf"
LOG_DIR="$QPKG_ROOT/log"
LOG="$LOG_DIR/legocert.log"
LOCK="$QPKG_ROOT/.lock"
# shellcheck disable=SC2034  # used by install-cert.sh
STUNNEL_DIR=/etc/stunnel

log() {
	mkdir -p "$LOG_DIR"
	printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG"
}

# Keep the log bounded: last 2000 lines once it passes ~1 MB.
trim_log() {
	[ -f "$LOG" ] || return 0
	if [ "$(wc -c <"$LOG")" -gt 1048576 ]; then
		tail -n 2000 "$LOG" >"$LOG.tmp" && mv "$LOG.tmp" "$LOG"
	fi
}

# notify LEVEL MESSAGE   (LEVEL: info|warn|error)
# Writes to the QTS system event log (QuLog Center). Notification Center alert
# rules matching severity + the keyword "LegoCert" deliver it by email, push or
# instant message (see README). The message always starts with [LegoCert].
notify() {
	level=$1
	shift
	log "[$level] $*"
	case $level in
	info) t=0 ;;
	warn) t=1 ;;
	*) t=2 ;;
	esac
	if ! /sbin/log_tool --append "[$QPKG_NAME] $*" --type "$t" --app_name "$QPKG_NAME" >/dev/null 2>&1; then
		log "[warn] log_tool failed: the message above did not reach the QTS system log"
	fi
}

# --- configuration --------------------------------------------------------------
# legocert.conf is read as data, never as code: KEY=VALUE lines with known keys only.
# It must be root-owned and mode 600 (it holds the token). The settings page and the
# scripts share read_conf / validate_conf / write_conf, so both apply the same rules.

conf_perms_ok() {
	[ "$(ls -ln "$CONF" | awk '{print $1, $3}')" = "-rw------- 0" ]
}

# read_conf: parse into DOMAIN EMAIL CF_DNS_TOKEN CF_ZONE_TOKEN ACME_SERVER
# DNS_RESOLVERS HTTPS_PORT (raw values, no defaults). On failure sets ERR.
read_conf() {
	DOMAIN="" EMAIL="" CF_DNS_TOKEN="" CF_ZONE_TOKEN="" ACME_SERVER="" DNS_RESOLVERS="" HTTPS_PORT=""
	ERR=""
	if [ ! -f "$CONF" ]; then
		ERR="$CONF is missing"
		return 1
	fi
	while IFS= read -r line || [ -n "$line" ]; do
		case $line in '' | '#'*) continue ;; esac
		key=${line%%=*}
		val=${line#*=}
		if [ "$key" = "$line" ]; then
			ERR="legocert.conf has a line without '=' (starts: $(printf '%s' "$line" | cut -c1-12)...)"
			return 1
		fi
		case $val in
		\"*\") val=${val#\"} val=${val%\"} ;;
		\'*\') val=${val#\'} val=${val%\'} ;;
		esac
		case $key in
		DOMAIN) DOMAIN=$val ;;
		EMAIL) EMAIL=$val ;;
		CLOUDFLARE_DNS_API_TOKEN) CF_DNS_TOKEN=$val ;;
		CLOUDFLARE_ZONE_API_TOKEN) CF_ZONE_TOKEN=$val ;;
		ACME_SERVER) ACME_SERVER=$val ;;
		DNS_RESOLVERS) DNS_RESOLVERS=$val ;;
		HTTPS_PORT) HTTPS_PORT=$val ;;
		*)
			ERR="legocert.conf has an unknown setting: $key"
			return 1
			;;
		esac
	done <"$CONF"
}

# validate_conf: check the current values. On failure sets ERR (safe to show:
# never contains a token).
# shellcheck disable=SC2034  # ERR_FIELD is read by ui/index.cgi
validate_conf() { # sets ERR (short, safe to show) and ERR_FIELD (domain|email|token)
	ERR="" ERR_FIELD=""
	case $DOMAIN in
	'') ERR="Enter the NAS name." ERR_FIELD=domain ;;
	.* | *. | *..* | *[!A-Za-z0-9.-]*) ERR="Enter a valid NAS name, like nas.example.com." ERR_FIELD=domain ;;
	*.*[!0-9.]*) ;;
	*.*) ERR="Enter the NAS's name, not its IP address. Let's Encrypt only issues certificates for names." ERR_FIELD=domain ;;
	*) ERR="Enter the full name, like nas.example.com." ERR_FIELD=domain ;;
	esac
	# The last label must contain a letter (a top-level domain), e.g. not 10.0.0.1x.5
	case ${DOMAIN##*.} in *[A-Za-z]*) ;; *) [ -n "$ERR" ] || { ERR="Enter the NAS's name, not its IP address. Let's Encrypt only issues certificates for names." ERR_FIELD=domain; } ;; esac
	[ -z "$ERR" ] || return 1
	case $EMAIL in
	'') ERR="Enter an email address." ;;
	*[!A-Za-z0-9.@_+-]* | *@*@* | @* | *@) ERR="Enter a valid email address." ;;
	?*@?*.?*) ;;
	*) ERR="Enter a valid email address." ;;
	esac
	[ -z "$ERR" ] || { ERR_FIELD=email; return 1; }
	case $CF_DNS_TOKEN in
	'') ERR="Enter the Cloudflare API token." ERR_FIELD=token ;;
	*[!A-Za-z0-9_-]*) ERR="The token has unexpected characters. Paste only the token." ERR_FIELD=token ;;
	esac
	case $CF_ZONE_TOKEN in *[!A-Za-z0-9_-]*) ERR="The zone token has unexpected characters" ;; esac
	case $ACME_SERVER in *[!A-Za-z0-9:/._-]*) ERR="ACME_SERVER contains unexpected characters" ;; esac
	case $DNS_RESOLVERS in *[!0-9A-Fa-f.:,\[\]]*) ERR="DNS_RESOLVERS contains unexpected characters" ;; esac
	case $HTTPS_PORT in *[!0-9]*) ERR="HTTPS_PORT is not a number" ;; esac
	[ -z "$ERR" ]
}

# write_conf: write the current (validated) values, atomically, root:root 0600.
write_conf() {
	tmp="$CONF.new.$$"
	(
		umask 077
		{
			echo "# LegoCert configuration. Written by the LegoCert settings page; KEY=VALUE data,"
			echo "# never executed. Must be root:root 0600. Token guide: the settings page."
			echo "DOMAIN=$DOMAIN"
			echo "EMAIL=$EMAIL"
			echo "CLOUDFLARE_DNS_API_TOKEN=$CF_DNS_TOKEN"
			[ -n "$CF_ZONE_TOKEN" ] && echo "CLOUDFLARE_ZONE_API_TOKEN=$CF_ZONE_TOKEN"
			[ -n "$ACME_SERVER" ] && echo "ACME_SERVER=$ACME_SERVER"
			[ -n "$DNS_RESOLVERS" ] && echo "DNS_RESOLVERS=$DNS_RESOLVERS"
			[ -n "$HTTPS_PORT" ] && echo "HTTPS_PORT=$HTTPS_PORT"
			true # optional lines above may "fail"; that must not fail the write
		} >"$tmp"
	) && chown 0:0 "$tmp" && chmod 600 "$tmp" && mv "$tmp" "$CONF"
	rc=$?
	rm -f "$tmp"
	return "$rc"
}

# load_conf: for the scripts. Read, check permissions, validate, apply defaults.
load_conf() {
	if [ ! -f "$CONF" ]; then
		log "[error] $CONF missing"
		return 1
	fi
	if ! conf_perms_ok; then
		log "[error] $CONF must be owned by root with mode 600 (is: $(ls -ln "$CONF" | awk '{print $1, $3}'))"
		return 1
	fi
	if ! read_conf || ! validate_conf; then
		log "[error] Settings: $ERR"
		return 1
	fi
	ACME_SERVER=${ACME_SERVER:-letsencrypt}
	DNS_RESOLVERS=${DNS_RESOLVERS:-1.1.1.1:53,1.0.0.1:53}
	HTTPS_PORT=${HTTPS_PORT:-$(/sbin/getcfg Stunnel Port -d 443 -f /etc/config/uLinux.conf)}
	case $HTTPS_PORT in '' | *[!0-9]*)
		log "[error] HTTPS port '$HTTPS_PORT' is not a number"
		return 1
		;;
	esac
}

# One run at a time. A lock left by a crashed run or a power cut (its pid no
# longer alive) is taken over; the service script also clears it at boot.
acquire_lock() {
	if mkdir "$LOCK" 2>/dev/null; then
		echo $$ >"$LOCK/pid"
		return 0
	fi
	pid=$(cat "$LOCK/pid" 2>/dev/null)
	if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
		return 1
	fi
	log "[warn] taking over stale lock (pid ${pid:-unknown})"
	rm -rf "$LOCK"
	mkdir "$LOCK" 2>/dev/null || return 1
	echo $$ >"$LOCK/pid"
}

release_lock() {
	rm -rf "$LOCK"
}

# First certificate of a PEM bundle (the leaf).
leaf_of() {
	awk '/BEGIN CERTIFICATE/{n++} n==1' "$1"
}

fingerprint() {
	openssl x509 -noout -fingerprint -sha256 2>/dev/null
}

# The certificate QTS is serving right now, as PEM on stdout (empty if none).
served_cert() {
	echo | openssl s_client -connect "127.0.0.1:$HTTPS_PORT" -servername "$DOMAIN" 2>/dev/null |
		openssl x509 2>/dev/null
}

# --- certificate lifetime ---------------------------------------------------------
# Expiry warnings are relative to each certificate's own lifetime, not fixed days:
# Let's Encrypt is moving from 90-day to shorter certificates (45 days, and optional
# 6-day ones). lego renews when a third of the lifetime is left, so:
#   less than 1/4 left -> warning (renewal is overdue)
#   less than 1/8 left -> error

# openssl_date_epoch "Nov 24 22:35:53 2026 GMT" -> seconds since the epoch. Plain awk:
# QTS's busybox date can't parse openssl's format.
openssl_date_epoch() {
	printf '%s\n' "$1" | awk '{
		mon = (index("JanFebMarAprMayJunJulAugSepOctNovDec", $1) + 2) / 3
		split($3, t, ":"); d = $2 + 0; y = $4 + 0
		yy = y - (mon <= 2); era = int(yy / 400); yoe = yy - era * 400
		doy = int((153 * ((mon + 9) % 12) + 2) / 5) + d - 1
		doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
		printf "%d\n", (era * 146097 + doe - 719468) * 86400 + t[1] * 3600 + t[2] * 60 + t[3] }'
}

# shellcheck disable=SC2034  # CERT_LIFE/CERT_LEFT are read by renew.sh and the UI
# cert_times PEMFILE: sets CERT_LIFE (seconds, notBefore..notAfter) and CERT_LEFT
# (seconds until notAfter; negative once expired). Falls back to a 90-day lifetime.
cert_times() {
	nb=$(openssl x509 -noout -startdate -in "$1" 2>/dev/null | cut -d= -f2)
	na=$(openssl x509 -noout -enddate -in "$1" 2>/dev/null | cut -d= -f2)
	if [ -n "$nb" ] && [ -n "$na" ]; then
		nb=$(openssl_date_epoch "$nb") na=$(openssl_date_epoch "$na")
		CERT_LIFE=$((na - nb))
		CERT_LEFT=$((na - $(date +%s)))
	else
		CERT_LIFE=7776000 CERT_LEFT=0
	fi
	[ "$CERT_LIFE" -gt 0 ] || CERT_LIFE=7776000
}

# human_left SECONDS -> "12 days", "2 days", "18 hours"
human_left() {
	if [ "$1" -ge 172800 ]; then
		echo "$((($1 + 43200) / 86400)) days" # to the nearest day
	elif [ "$1" -ge 3600 ]; then
		echo "$((($1 + 1800) / 3600)) hours"
	else
		echo "less than an hour"
	fi
}

