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
# legocert.conf is read as data, never as code: KEY=VALUE lines. LegoCert's own keys
# (OWN_KEYS) plus the DNS provider's credentials, stored under lego's own variable
# names (providers.sh). It must be root-owned and mode 600 (it holds credentials).
# The settings page and the scripts share read_conf / validate_conf / write_conf, so
# both apply the same rules.

. "$QPKG_ROOT/providers.sh"

OWN_KEYS="DOMAIN EMAIL DNS_PROVIDER ACME_SERVER DNS_RESOLVERS HTTPS_PORT"

conf_perms_ok() {
	[ "$(ls -ln "$CONF" | awk '{print $1, $3}')" = "-rw------- 0" ]
}

# Never accepted as a credential: they would change how lego or the shell runs.
reserved_var() { # reserved_var NAME
	case $1 in
	PATH | HOME | IFS | ENV | BASH_ENV | SHELL | USER | PWD | TMPDIR | TZ | ZONEINFO | GODEBUG | GOFLAGS | GOMAXPROCS | \
		LD_* | LEGO_* | LEGOCERT_* | SSL_* | *_PROXY | QPKG_* | CREDS | ERR | ERR_FIELD) return 0 ;;
	esac
	case " $OWN_KEYS " in *" $1 "*) return 0 ;; esac
	return 1
}

# CREDS holds the provider's credentials as "NAME=value" lines (no empty values).
cred_get() { # cred_get NAME
	printf '%s\n' "$CREDS" | sed -n "s/^$1=//p" | head -n 1
}
cred_set() { # cred_set NAME VALUE   (empty VALUE removes it)
	CREDS=$(printf '%s\n' "$CREDS" | grep -v "^$1=" | grep .)
	[ -z "$2" ] || CREDS=$(printf '%s\n%s=%s\n' "$CREDS" "$1" "$2" | grep .)
	true
}
cred_names() { printf '%s\n' "$CREDS" | sed -n 's/=.*//p' | tr '\n' ' ' | sed 's/ $//'; }

# Does a named provider use this variable? (Other providers: checked against lego when saved.)
provider_uses() { # provider_uses CODE NAME
	# No `| grep -q`: it exits at the first match and the echo still writing to the
	# pipe prints "write error: Broken pipe" (seen in Check token on the NAS).
	[ -n "$2" ] || return 1
	case " $(provider_fields "$1" | cut -d'|' -f1 | tr '\n' ' ') $(provider_extra_vars "$1") " in
	*" $2 "*) return 0 ;;
	*) return 1 ;;
	esac
}
# A field's label for messages: "Secret key" -> "secret key", "API key" stays.
field_phrase() { # field_phrase LABEL
	printf '%s' "$1" | awk '{ if (substr($0, 2, 1) ~ /[a-z ]/) $0 = tolower(substr($0, 1, 1)) substr($0, 2); print }'
}

# read_conf: parse into DOMAIN EMAIL DNS_PROVIDER CREDS ACME_SERVER DNS_RESOLVERS
# HTTPS_PORT (raw values, no defaults). On failure sets ERR.
read_conf() {
	DOMAIN="" EMAIL="" DNS_PROVIDER="" CREDS="" ACME_SERVER="" DNS_RESOLVERS="" HTTPS_PORT=""
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
		DNS_PROVIDER) DNS_PROVIDER=$val ;;
		ACME_SERVER) ACME_SERVER=$val ;;
		DNS_RESOLVERS) DNS_RESOLVERS=$val ;;
		HTTPS_PORT) HTTPS_PORT=$val ;;
		*)
			case $key in '' | [!A-Z]* | *[!A-Z0-9_]*)
				ERR="legocert.conf has an unknown setting: $(printf '%s' "$key" | cut -c1-30)"
				return 1
				;;
			esac
			if reserved_var "$key"; then
				ERR="legocert.conf can't set $key"
				return 1
			fi
			[ -z "$val" ] || CREDS=$(printf '%s\n%s=%s\n' "$CREDS" "$key" "$val" | grep .)
			;;
		esac
	done <"$CONF"
	# Before 0.6 Cloudflare was the only provider (no DNS_PROVIDER line).
	DNS_PROVIDER=${DNS_PROVIDER:-cloudflare}
}

# validate_conf [all|settings|provider]: check the current values. Formats are always
# checked; "settings" requires the NAS name and email, "provider" the credentials,
# "all" (runs) both. On failure sets ERR (short, safe to show: never contains a
# credential) and ERR_FIELD (domain|email|cred:NAME|other_code|other_env).
# shellcheck disable=SC2034  # ERR_FIELD is read by ui/index.cgi
validate_conf() {
	scope=${1:-all}
	ERR="" ERR_FIELD=""
	if [ -n "$DOMAIN" ] || [ "$scope" != provider ]; then
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
	fi
	if [ -n "$EMAIL" ] || [ "$scope" != provider ]; then
		case $EMAIL in
		'') ERR="Enter an email address." ;;
		*[!A-Za-z0-9.@_+-]* | *@*@* | @* | *@) ERR="Enter a valid email address." ;;
		?*@?*.?*) ;;
		*) ERR="Enter a valid email address." ;;
		esac
		[ -z "$ERR" ] || { ERR_FIELD=email; return 1; }
	fi

	plabel=$(provider_label "$DNS_PROVIDER")
	if ! is_known_provider "$DNS_PROVIDER"; then
		case $DNS_PROVIDER in '' | [!a-z0-9]* | *[!a-z0-9._-]*)
			ERR="Enter a lego provider code, like cloudflare." ERR_FIELD=other_code
			return 1
			;;
		esac
	fi
	old_ifs=$IFS
	IFS='
'
	for kv in $CREDS; do
		name=${kv%%=*} v=${kv#*=}
		if is_known_provider "$DNS_PROVIDER" && ! provider_uses "$DNS_PROVIDER" "$name"; then
			ERR="legocert.conf has a setting $plabel doesn't use: $name"
			break
		fi
		label=$(provider_fields "$DNS_PROVIDER" | grep "^$name|" | cut -d'|' -f3)
		# Printable, no spaces, no quotes or backslashes (read_conf strips surrounding quotes).
		case $v in *[!!-~]* | *[\"\'\`\\]*)
			ERR="The $(field_phrase "${label:-$name}") has unexpected characters. Paste only the value." ERR_FIELD="cred:$name"
			is_known_provider "$DNS_PROVIDER" || ERR_FIELD=other_env
			break
			;;
		esac
	done
	if [ -z "$ERR" ] && [ "$DNS_PROVIDER" = ovh ]; then
		case $(cred_get OVH_ENDPOINT) in '' | ovh-eu | ovh-ca | ovh-us) ;; *) ERR="Choose the OVHcloud region." ERR_FIELD=cred:OVH_ENDPOINT ;; esac
	fi
	if [ -z "$ERR" ] && [ "$scope" != settings ]; then
		if is_known_provider "$DNS_PROVIDER"; then
			for f in $(provider_fields "$DNS_PROVIDER"); do
				name=${f%%|*} kind=$(printf '%s' "$f" | cut -d'|' -f2) label=${f##*|}
				[ "$kind" = optional ] && continue
				if [ -z "$(cred_get "$name")" ]; then
					ERR="Enter the $plabel $(field_phrase "$label")." ERR_FIELD="cred:$name"
					break
				fi
			done
		elif [ -z "$CREDS" ]; then
			ERR="Enter the variables $DNS_PROVIDER needs." ERR_FIELD=other_env
		fi
	fi
	IFS=$old_ifs
	[ -z "$ERR" ] || return 1
	case $ACME_SERVER in *[!A-Za-z0-9:/._-]*) ERR="ACME_SERVER contains unexpected characters" ;; esac
	case $DNS_RESOLVERS in *[!0-9A-Fa-f.:,\[\]]*) ERR="DNS_RESOLVERS contains unexpected characters" ;; esac
	case $HTTPS_PORT in *[!0-9]*) ERR="HTTPS_PORT is not a number" ;; esac
	[ -z "$ERR" ]
}

# Are the DNS provider's credentials all there? (No output; ERR untouched.)
provider_ready() { (validate_conf provider) >/dev/null 2>&1; }

# write_conf: write the current (validated) values, atomically, root:root 0600.
write_conf() {
	tmp="$CONF.new.$$"
	(
		umask 077
		{
			echo "# LegoCert configuration. Written by the LegoCert settings page; KEY=VALUE data,"
			echo "# never executed. Must be root:root 0600. Credentials use lego's variable names."
			echo "DOMAIN=$DOMAIN"
			echo "EMAIL=$EMAIL"
			echo "DNS_PROVIDER=$DNS_PROVIDER"
			[ -n "$CREDS" ] && printf '%s\n' "$CREDS"
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

# export_creds: put the credentials into the environment. Call only in the subshell
# that runs lego: they must never reach a command line or another process.
export_creds() {
	old_ifs=$IFS
	IFS='
'
	set -f
	for kv in $CREDS; do export "${kv?}"; done
	set +f
	IFS=$old_ifs
	# Route 53 is global, but the AWS client still wants a region.
	if [ "$DNS_PROVIDER" = route53 ]; then export AWS_REGION="${AWS_REGION:-us-east-1}"; fi
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
	if ! read_conf || ! validate_conf all; then
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

