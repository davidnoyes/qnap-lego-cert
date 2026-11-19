#!/bin/sh
# LegoCert settings page: /cgi-bin/qpkg/LegoCert/index.cgi (QPKG_WEBUI).
# Served by QTS's own web server; linked into /home/httpd/cgi-bin/qpkg by legocert.sh.
#
# Security model (docs/design-review.md, "Settings page"):
#  - every request must carry a QTS session of an ADMINISTRATOR, checked by asking
#    QTS's authLogin.cgi on loopback (never a URL built from the request);
#  - state-changing requests are POST + a CSRF token bound to that session;
#  - the Cloudflare token is write-only: never sent back to the browser;
#  - everything shown is HTML-escaped; inputs pass the same validate_conf as the scripts;
#  - nothing from the request reaches a shell command line or eval;
#  - no JavaScript at all (navigation is plain links), so CSP allows no scripts.
#
# Look: QTS 5 app style (dark app bar, blue sidebar, white panels, label-left forms,
# QTS's own "QTS Font" from /v3_menu/css/qts-font.css on the same origin).

QPKG_NAME=LegoCert
QPKG_ROOT=$(/sbin/getcfg "$QPKG_NAME" Install_Path -f /etc/config/qpkg.conf)
QPKG_VERSION=$(/sbin/getcfg "$QPKG_NAME" Version -d "" -f /etc/config/qpkg.conf)
. "$QPKG_ROOT/common.sh"

SELF=/cgi-bin/qpkg/LegoCert/index.cgi
TMP_PEM=$(mktemp) || TMP_PEM=/tmp/legocert-ui.$$
trap 'rm -f "$TMP_PEM"' EXIT
RESTART_NOTE="<b>Expect a short interruption when a new certificate is installed.</b> The NAS web interface restarts, and QTS may show <i>&ldquo;The server is busy or the network is disconnected&rdquo;</i> for up to a minute. Wait, then reload the page. This also happens when the daily check renews the certificate, about every 60 days."
CSRF_KEY="$QPKG_ROOT/.csrf_key"

# ------------------------------------------------------------------- output
esc() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g' -e "s/'/\&#39;/g"; }

headers() { # headers STATUS
	printf 'Status: %s\r\n' "$1"
	printf 'Content-Type: text/html; charset=utf-8\r\n'
	printf 'Cache-Control: no-store\r\n'
	printf 'X-Content-Type-Options: nosniff\r\n'
	printf 'Referrer-Policy: no-referrer\r\n'
	printf "Content-Security-Policy: default-src 'none'; script-src 'self'; connect-src 'self'; style-src 'self' 'unsafe-inline'; font-src 'self'; img-src 'self' data:; form-action 'self'; frame-ancestors 'self'; base-uri 'none'\r\n"
	printf '\r\n'
}

STYLE='
:root{--bar:#2b2b2b;--side1:#6f93db;--side2:#3c6cc2;--sidesel:#1f3a8a;--bg:#eceff3;--panel:#fff;--line:#c9ced6;
--input:#a9a9a9;--text:#333;--muted:#6b7480;--blue:#1a6fc4;--btn:#3d86d6;--btnb:#2a6fbe;--ok:#2e8b3d;--warn:#d9822b;--err:#d0312d;--note:#eaf3fd}
*{box-sizing:border-box}html,body{margin:0;height:100%}
body{font:15px/1.5 "QTS Font",Roboto,Arial,sans-serif;color:var(--text);background:var(--bg)}
a{color:var(--blue);text-decoration:none}a:hover{text-decoration:underline}
.appbar{height:52px;background:var(--bar);color:#fff;display:flex;align-items:center;gap:12px;padding:0 18px;font-size:22px;font-weight:700}
.appbar svg{width:34px;height:34px;flex:none}
.appbar .ver{font-size:13px;font-weight:400;opacity:.75;margin-left:-4px;padding-top:7px}
.layout{display:flex;min-height:calc(100% - 52px)}
.side{width:220px;flex:none;background:linear-gradient(180deg,var(--side1),var(--side2));color:#fff;padding:10px 0}
.side .grp{display:flex;align-items:center;gap:10px;padding:10px 18px 4px;font-size:16px;font-weight:700}
.side .grp svg{width:20px;height:20px;flex:none}
.side a{display:block;color:#fff;padding:8px 18px 8px 48px;font-size:15px}
.side a.top{padding-left:18px;font-weight:700;font-size:16px;display:flex;align-items:center;gap:10px}
.side a svg{width:20px;height:20px;flex:none}
.side a:hover{background:rgba(255,255,255,.12);text-decoration:none}
.side a.sel{background:var(--sidesel)}
.main{flex:1;min-width:0;background:#fff;display:flex;flex-direction:column}
.title{padding:18px 28px 12px;font-size:19px;font-weight:700;border-bottom:1px solid var(--line)}
.tabs{display:flex;gap:4px;padding:6px 28px 0;border-bottom:1px solid var(--line)}
.tabs span{padding:8px 16px;color:var(--blue);border-bottom:3px solid var(--btn)}
.content{padding:18px 28px 32px;background:#fff}
.desc{margin:0 0 16px}
.panel{border:1px solid var(--line);border-radius:4px;margin:0 0 18px;background:var(--panel)}
.panel h3{margin:0;padding:12px 18px;font-size:16px;font-weight:700;border-bottom:1px solid var(--line)}
.panel .body{padding:14px 18px}
.section{display:flex;align-items:center;gap:12px;font-size:16px;font-weight:700;margin:20px 0 10px}
.section:after{content:"";flex:1;border-top:1px solid var(--line)}
.row{display:flex;align-items:flex-start;gap:16px;margin:0 0 14px}
.row>label,.row>.lbl{width:200px;flex:none;padding-top:7px}
.row .ctl{flex:1;min-width:0;max-width:460px}
input[type=text],input[type=email],input[type=password]{width:100%;height:36px;padding:0 10px;border:1px solid var(--input);border-radius:2px;font:inherit;color:var(--text);background:#fff}
input:focus{border-color:var(--btn);outline:none}input.bad{border-color:var(--err);background:#fff6f6}
.hint{font-size:13px;color:var(--muted);margin:4px 0 0}
.btn{font:inherit;height:36px;min-width:96px;padding:0 18px;border:1px solid #8c8c8c;border-radius:2px;background:#fff;color:#222;cursor:pointer}
.btn:hover{background:#f3f5f8}.btn.primary{background:var(--btn);border-color:var(--btnb);color:#fff}.btn.primary:hover{background:var(--btnb)}
.actions{display:flex;gap:10px;justify-content:flex-end;padding:12px 18px;border-top:1px solid var(--line)}
.inline{display:inline}
table.kv{border-collapse:collapse;width:100%}table.kv th,table.kv td{text-align:left;padding:8px 10px;border-bottom:1px solid #e3e6ea;vertical-align:top}
table.kv th{width:200px;font-weight:400;color:var(--muted)}
table.grid{border-collapse:collapse;margin:8px 0}table.grid td,table.grid th{border:1px solid var(--line);padding:6px 14px;text-align:left}table.grid th{background:#f2f4f7;font-weight:700}
.cf{max-width:420px;margin:8px 0 0;border:1px solid var(--line);border-radius:4px}
.cfrow{display:flex;align-items:center;gap:16px;padding:8px 14px;font-size:14px}.cfrow+.cfrow{border-top:1px dashed var(--line)}
.cfrow span:first-child{flex:1}
.cb{display:inline-flex;align-items:center;gap:6px}
.cb:before{content:"";width:16px;height:16px;border:1px solid #9aa3ad;border-radius:3px;background:#fff;box-sizing:border-box}
.cb.on{font-weight:700}.cb.on:before{content:"\2713";background:#111;border-color:#111;color:#fff;font-size:12px;line-height:14px;text-align:center}
.dot{display:inline-block;width:10px;height:10px;border-radius:50%;margin-right:6px;vertical-align:0}
.ok{color:var(--ok)}.warn{color:var(--warn)}.err{color:var(--err)}.muted{color:var(--muted)}
.dot.ok{background:var(--ok)}.dot.warn{background:var(--warn)}.dot.err{background:var(--err)}
.note{display:flex;gap:10px;background:var(--note);border:1px solid #b9d6f5;border-radius:3px;padding:10px 14px;margin:0 0 16px}
.note.err{background:#fdecec;border-color:#f3b4b2;color:var(--text)}.note.ok{background:#eaf6ec;border-color:#b5dcbc;color:var(--text)}
.note.warn{background:#fff6e9;border-color:#f1c98f;color:var(--text)}
.runrow{display:flex;align-items:center;gap:16px;padding:10px 0}.runrow+.runrow{border-top:1px solid #e3e6ea}
.runrow form{flex:none}.runrow .btn{width:130px}
.prog{margin-top:16px;padding:14px 18px 12px;border:1px solid var(--line);border-radius:4px;background:#fafbfc}
.prog[hidden]{display:none}.prog-head{font-size:14px;margin-bottom:4px}
.track{position:relative;height:58px;margin:6px 10px 0}
.track .line{position:absolute;left:0;right:0;top:9px;height:4px;background:#dfe3e8;border-radius:2px}
.track .fill{position:absolute;left:0;top:9px;height:4px;background:var(--btn);border-radius:2px;transition:width .6s ease}
.track .fill.ok{background:var(--ok)}.track .fill.error{background:var(--err)}.track .fill.skipped{background:var(--warn)}
.stop{position:absolute;top:4px;width:14px;height:14px;margin-left:-7px;border-radius:50%;background:#fff;border:2px solid #c3c9d1}
.stop.done{background:var(--btn);border-color:var(--btn)}
.stop .lbl{position:absolute;top:22px;left:50%;transform:translateX(-50%);white-space:nowrap;font-size:12px;color:var(--muted)}
.stop.first .lbl{left:-7px;transform:none}.stop.last .lbl{left:auto;right:-7px;transform:none}
.stop.done .lbl,.stop.cur .lbl{color:var(--text)}
.ball{position:absolute;top:1px;width:20px;height:20px;margin-left:-10px;border-radius:50%;background:var(--btn);box-shadow:0 0 0 4px rgba(61,134,214,.22);transition:left .6s ease,background .3s;color:#fff;font-size:12px;line-height:20px;text-align:center;font-weight:700}
.ball.running{animation:lcpulse 1.2s ease-in-out infinite}
@keyframes lcpulse{50%{box-shadow:0 0 0 9px rgba(61,134,214,.06)}}
.ball.ok{background:var(--ok);box-shadow:0 0 0 4px rgba(46,139,61,.18)}.ball.ok:after{content:"\2713"}
.ball.error{background:var(--err);box-shadow:0 0 0 4px rgba(208,49,45,.18)}.ball.error:after{content:"\2715"}
.ball.skipped{background:var(--warn);box-shadow:0 0 0 4px rgba(217,130,43,.18)}.ball.skipped:after{content:"!"}
.prog-msg{font-size:14px}.prog-msg.ok{color:var(--ok)}.prog-msg.error{color:var(--err)}.prog-msg.skipped{color:var(--warn)}
.note svg{width:18px;height:18px;flex:none;margin-top:2px}
.steps{list-style:none;padding:0;margin:0;counter-reset:s}
.steps>li{counter-increment:s;position:relative;padding:0 0 18px 42px}
.steps>li:before{content:counter(s);position:absolute;left:0;top:0;width:26px;height:26px;border:1px solid #555;border-radius:50%;text-align:center;line-height:24px;font-size:14px}
.steps b.t{display:block;margin-bottom:2px}
.tag{display:inline-block;font-size:12px;padding:0 6px;border-radius:2px;border:1px solid var(--line);color:var(--muted);margin-left:6px;vertical-align:1px}
.tag.rec{border-color:#9cc3ef;color:var(--blue)}
code,pre{font:13px/1.45 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace}
pre{margin:0;padding:12px;background:#f7f8fa;border:1px solid var(--line);border-radius:2px;overflow:auto;white-space:pre-wrap;max-height:420px}
pre.log{max-height:none}
@media (max-width:760px){.layout{flex-direction:column}.side{width:auto}.row{flex-direction:column;gap:4px}.row>label,.row>.lbl{width:auto;padding:0}}
'

ICON_APP='<svg viewBox="0 0 160 160" aria-hidden="true"><defs><linearGradient id="lcbg" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#21c3ee"/><stop offset="1" stop-color="#1b5fe0"/></linearGradient></defs><rect x="6" y="6" width="148" height="148" rx="34" fill="url(#lcbg)"/><path d="M80 28l40 15v29c0 26-17 46-40 56-23-10-40-30-40-56V43z" fill="#fff"/><path d="M68 76v-8a12 12 0 0 1 24 0v8" fill="none" stroke="#1b6fe3" stroke-width="7" stroke-linecap="round"/><rect x="61" y="74" width="38" height="30" rx="6" fill="#1b6fe3"/><circle cx="80" cy="86" r="4.5" fill="#fff"/><rect x="78" y="88" width="4" height="9" rx="2" fill="#fff"/></svg>'
ICON_INFO='<svg viewBox="0 0 20 20" aria-hidden="true"><circle cx="10" cy="10" r="9" fill="#1a6fc4"/><rect x="9" y="8.5" width="2" height="6.5" fill="#fff"/><circle cx="10" cy="5.7" r="1.2" fill="#fff"/></svg>'
ICON_ERR='<svg viewBox="0 0 20 20" aria-hidden="true"><circle cx="10" cy="10" r="9" fill="#d0312d"/><path d="M6.5 6.5l7 7M13.5 6.5l-7 7" stroke="#fff" stroke-width="2"/></svg>'
ICON_WARN='<svg viewBox="0 0 20 20" aria-hidden="true"><path d="M10 1.8l8.6 15.4H1.4z" fill="#d9822b"/><rect x="9" y="7" width="2" height="5.5" fill="#fff"/><circle cx="10" cy="14.6" r="1.1" fill="#fff"/></svg>'
ICON_OK='<svg viewBox="0 0 20 20" aria-hidden="true"><circle cx="10" cy="10" r="9" fill="#2e8b3d"/><path d="M5.8 10.3l2.8 2.8 5.6-5.8" fill="none" stroke="#fff" stroke-width="2"/></svg>'
ICON_HOME='<svg viewBox="0 0 20 20" aria-hidden="true"><path d="M2 9l8-6 8 6v9h-5v-6H7v6H2z" fill="none" stroke="#fff" stroke-width="1.6"/></svg>'
ICON_SETUP='<svg viewBox="0 0 20 20" aria-hidden="true"><circle cx="10" cy="10" r="3" fill="none" stroke="#fff" stroke-width="1.6"/><path d="M10 1.5v3M10 15.5v3M1.5 10h3M15.5 10h3M4 4l2.1 2.1M13.9 13.9L16 16M4 16l2.1-2.1M13.9 6.1L16 4" stroke="#fff" stroke-width="1.6"/></svg>'
ICON_BELL='<svg viewBox="0 0 20 20" aria-hidden="true"><path d="M5 14V9a5 5 0 0110 0v5l1.5 2h-13zM8.5 18h3" fill="none" stroke="#fff" stroke-width="1.6"/></svg>'

page_start() { # page_start CURRENT_TAB
	cat <<EOF
<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>LegoCert</title>
<link rel="stylesheet" href="/v3_menu/css/qts-font.css">
<style>$STYLE</style></head><body>
<div class="appbar">$ICON_APP LegoCert<span class="ver">$(esc "$QPKG_VERSION")</span></div>
<div class="layout">
EOF
	[ -n "${1:-}" ] && side_nav "$1"
	printf '<div class="main">'
}
page_end() { printf '</div></div></body></html>\n'; }

nav_link() { # nav_link TAB LABEL CURRENT [class]
	cls=${4:-}
	[ "$1" = "$3" ] && cls="$cls sel"
	printf '<a class="%s" href="%s?tab=%s">%s</a>' "$cls" "$SELF" "$1" "$2"
}
side_nav() {
	printf '<nav class="side">'
	nav_link overview "$ICON_HOME Overview" "$1" top
	printf '<div class="grp">%s Setup</div>' "$ICON_SETUP"
	nav_link token "Cloudflare token" "$1"
	nav_link settings "Settings" "$1"
	nav_link notify "$ICON_BELL Notifications" "$1" top
	printf '</nav>'
}

title() { # title TEXT: page heading, then any message for this request
	printf '<div class="title">%s</div><div class="content">' "$(esc "$1")"
	banner "$(query_param msg)"
	[ -n "${CONF_ERR:-}" ] && note err "$(esc "$CONF_ERR")"
}

note() { # note info|err|ok HTML
	case $1 in err) i=$ICON_ERR ;; ok) i=$ICON_OK ;; warn) i=$ICON_WARN ;; *) i=$ICON_INFO ;; esac
	printf '<div class="note %s">%s<div>%s</div></div>' "$1" "$i" "$2"
}

fail_page() { # fail_page STATUS MESSAGE
	headers "$1"
	page_start ""
	CONF_ERR=$2
	title "LegoCert"
	printf '</div>'
	page_end
	exit 0
}

# ------------------------------------------------------------- authentication
cookie() { # cookie NAME -> value
	printf '%s' "${HTTP_COOKIE:-}" | tr ';' '\n' | sed 's/^ *//' |
		awk -v k="$1" 'index($0, k "=") == 1 { print substr($0, length(k) + 2); exit }'
}

xml_val() { # xml_val TAG < xml   (QTS wraps values in CDATA)
	sed -n "s:.*<$1><!\[CDATA\[\([^]]*\)\]\]></$1>.*:\1:p; s:.*<$1>\([^<]*\)</$1>.*:\1:p" | head -n 1
}

# Ask QTS whether this browser's session is a logged-in administrator. Always on
# loopback: a URL derived from the request's Host header could point the check at a
# server that answers "yes". Session values go to curl via a config on stdin, never
# on the command line. Returns 0 admin, 1 not logged in, 2 logged in but not admin.
authenticate() {
	sid=$(cookie NAS_SID)
	qtoken=$(cookie qtoken)
	user=$(cookie NAS_USER)
	case "$sid$qtoken$user" in *[!A-Za-z0-9._@-]*) return 1 ;; esac
	if [ -n "$qtoken" ] && [ -n "$user" ]; then
		query="qtoken=$qtoken&user=$user"
		SESSION="qtoken:$user:$qtoken"
	elif [ -n "$sid" ]; then
		query="sid=$sid"
		SESSION="sid:$sid"
	else
		return 1
	fi
	port=$(/sbin/getcfg System "Web Access Port" -d 8080 -f /etc/config/uLinux.conf)
	sslport=$(/sbin/getcfg Stunnel Port -d 443 -f /etc/config/uLinux.conf)
	resp=$(printf 'url = "http://127.0.0.1:%s/cgi-bin/authLogin.cgi?%s"\n' "$port" "$query" |
		curl -sS -m 10 -K - 2>/dev/null)
	if [ -z "$(printf '%s' "$resp" | xml_val authPassed)" ]; then
		# "Force HTTPS" setups: QTS's own self-signed loopback certificate, so -k.
		resp=$(printf 'url = "https://127.0.0.1:%s/cgi-bin/authLogin.cgi?%s"\ninsecure\n' "$sslport" "$query" |
			curl -sS -m 10 -K - 2>/dev/null)
	fi
	[ "$(printf '%s' "$resp" | xml_val authPassed)" = 1 ] || return 1
	[ "$(printf '%s' "$resp" | xml_val isAdmin)" = 1 ] || return 2
	return 0
}

# CSRF token: digest of the session with a per-install secret.
csrf_token() {
	if [ ! -s "$CSRF_KEY" ]; then
		(umask 077 && head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' >"$CSRF_KEY")
	fi
	printf '%s:%s' "$(cat "$CSRF_KEY")" "$SESSION" | openssl sha256 | awk '{print $NF}'
}

# ------------------------------------------------------------------- request
urldecode() {
	awk 'BEGIN { for (i = 1; i < 256; i++) { h[sprintf("%02X", i)] = sprintf("%c", i); h[sprintf("%02x", i)] = sprintf("%c", i) } }
	{ gsub(/\+/, " "); out = ""
	  while (match($0, /%[0-9A-Fa-f][0-9A-Fa-f]/)) { out = out substr($0, 1, RSTART - 1) h[substr($0, RSTART + 1, 2)]; $0 = substr($0, RSTART + 3) }
	  printf "%s", out $0 }'
}
field() { # field NAME -> decoded value from the POST body (first occurrence)
	printf '%s' "$BODY" | tr '&' '\n' | awk -v k="$1" 'index($0, k "=") == 1 { print substr($0, length(k) + 2); exit }' | urldecode
}
query_param() {
	printf '%s' "${QUERY_STRING:-}" | tr '&' '\n' | awk -v k="$1" 'index($0, k "=") == 1 { print substr($0, length(k) + 2); exit }'
}

redirect() { # redirect TAB MSGCODE [SINCE]  (POST/redirect/GET, so a reload never resubmits)
	extra=""
	[ -n "${3:-}" ] && extra="&since=$(printf '%s' "$3" | sed 's/ /%20/g; s/:/%3A/g')"
	printf 'Status: 303 See Other\r\nLocation: %s?tab=%s&msg=%s%s\r\nCache-Control: no-store\r\n\r\n' "$SELF" "$1" "$2" "$extra"
	exit 0
}

run_background() { # run_background ARGS...  (detached: the page returns at once)
	("$QPKG_ROOT/renew.sh" "$@" </dev/null >/dev/null 2>&1 &)
}

button_form() { # button_form ACTION LABEL [primary]
	printf '<form class="inline" method="post" action="%s"><input type="hidden" name="csrf" value="%s"><input type="hidden" name="action" value="%s"><button class="btn %s" type="submit">%s</button></form>' \
		"$SELF" "$CSRF" "$1" "${3:-}" "$2"
}

# ------------------------------------------------------------------- tabs
tab_overview() {
	title "Overview"
	render_progress
	if [ -z "$DOMAIN" ] || [ -z "$CF_DNS_TOKEN" ]; then
		note info "Not set up yet. Start with <a href=\"$SELF?tab=token\">Cloudflare token</a>."
	fi
	printf '<div class="panel"><h3>Status</h3><div class="body"><table class="kv">'
	if [ -n "$DOMAIN" ]; then
		eff=${HTTPS_PORT:-$(/sbin/getcfg Stunnel Port -d 443 -f /etc/config/uLinux.conf)}
		saved_port=$HTTPS_PORT
		HTTPS_PORT=$eff
		pem=$(served_cert)
		HTTPS_PORT=$saved_port
		printf '<tr><th>NAS name</th><td>%s</td></tr>' "$(esc "$DOMAIN")"
		if [ -n "$pem" ]; then
			issuer=$(printf '%s\n' "$pem" | openssl x509 -noout -issuer 2>/dev/null | sed 's/^issuer= *//')
			# "O = Let's Encrypt" reads better than the whole subject; fall back to CN.
			org=$(printf '%s' "$issuer" | sed -n 's/.*O *= *\([^,]*\).*/\1/p')
			[ -n "$org" ] || org=$(printf '%s' "$issuer" | sed -n 's/.*CN *= *\([^,]*\).*/\1/p')
			issuer=${org:-$issuer}
			# "Jan 17 11:55:37 2027 GMT" -> "17 Jan 2027", plus days left (by -checkend bisection:
			# no reliable date parsing on QTS's busybox).
			until=$(printf '%s\n' "$pem" | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2 | awk '{print $2, $1, $4}')
			lo=0 hi=800
			while [ $((hi - lo)) -gt 1 ]; do
				mid=$(((lo + hi) / 2))
				if printf '%s\n' "$pem" | openssl x509 -noout -checkend $((mid * 86400)) >/dev/null 2>&1; then lo=$mid; else hi=$mid; fi
			done
			if printf '%s\n' "$pem" | openssl x509 -noout -checkend 0 >/dev/null 2>&1; then
				until="$until ($lo days)"
			fi
			if ! printf '%s\n' "$pem" | openssl x509 -noout -checkend 0 >/dev/null 2>&1; then
				state='<span class="dot err"></span>Expired'
			elif printf '%s\n' "$pem" >"$TMP_PEM" && cert_times "$TMP_PEM" && [ "$CERT_LEFT" -lt $((CERT_LIFE / 4)) ]; then
				# same rule as renew.sh: under a quarter of its lifetime left = overdue
				state='<span class="dot warn"></span>Expires soon'
			else
				state='<span class="dot ok"></span>Valid'
			fi
			printf '<tr><th>Certificate</th><td>%s</td></tr><tr><th>Expires</th><td>%s</td></tr><tr><th>Issuer</th><td>%s</td></tr>' \
				"$state" "$(esc "$until")" "$(esc "$issuer")"
		else
			printf '<tr><th>Certificate</th><td><span class="dot err"></span>Not found on port %s</td></tr>' "$(esc "$eff")"
		fi
	fi
	if grep -qF "# $QPKG_NAME" /etc/config/crontab 2>/dev/null; then
		printf '<tr><th>Daily check</th><td><span class="dot ok"></span>On</td></tr>'
	else
		printf '<tr><th>Daily check</th><td><span class="dot err"></span>Off. Enable LegoCert in App Center.</td></tr>'
	fi
	last=$(grep -E 'finished OK|\[(warn|error)\]|installed a new|Test run OK' "$LOG" 2>/dev/null | tail -n 1)
	if [ -n "$last" ]; then
		when=$(printf '%s' "$last" | awk '{split($1, d, "-"); m = substr("JanFebMarAprMayJunJulAugSepOctNovDec", d[2] * 3 - 2, 3); print d[3] + 0, m, substr($2, 1, 5)}')
		msg=$(printf '%s' "$last" | cut -d' ' -f3-)
		case $msg in
		"run finished OK") msg='<span class="dot ok"></span>OK' ;;
		"[info] Test run OK"*) msg='<span class="dot ok"></span>OK (Test run)' ;;
		*"finished OK") msg="<span class=\"dot ok\"></span>OK ($(esc "${msg% finished OK}"))" ;;
		"[warn]"*) msg="<span class=\"dot warn\"></span>$(esc "${msg#\[warn\] }")" ;;
		"[error]"*) msg="<span class=\"dot err\"></span>$(esc "${msg#\[error\] }")" ;;
		*) msg="<span class=\"dot ok\"></span>$(esc "${msg#\[info\] }")" ;;
		esac
		printf '<tr><th>Last check</th><td>%s <span class="muted">· %s</span></td></tr>' "$msg" "$(esc "$when")"
	fi
	printf '</table></div></div>'

	printf '<div class="panel"><h3>Run now</h3><div class="body">'
	printf '<p class="desc">LegoCert checks once a day by itself. Its events also appear in <a href="/qulog/" target="_blank" rel="noopener">QuLog Center</a>.</p>'
	printf '<div class="runrow">'; button_form staging "Test run"; printf '<div>Checks that everything works, using Let&#39;s Encrypt&#39;s test service.<br><span class="muted">Installs nothing.</span></div></div>'
	printf '<div class="runrow">'; button_form renew "Renew now" primary; printf '<div>Gets a new certificate if one is due, and installs it.<br><span class="muted">If nothing is due, nothing changes.</span></div></div>'
	note warn "$RESTART_NOTE"
}

# The Cloudflare zone a NAS name most likely belongs to: its last two labels, or three
# under common two-level country suffixes (nas.example.co.uk -> example.co.uk). Only a
# hint for the instructions; nothing depends on it being right.
guess_zone() {
	printf '%s' "$1" | awk -F. '
	NF >= 3 && length($NF) == 2 && $(NF-1) ~ /^(co|com|org|net|gov|ac|edu|ltd|plc|me|sch|nhs|or|ne|go|gv|nom|id)$/ { print $(NF-2) "." $(NF-1) "." $NF; next }
	NF >= 2 { print $(NF-1) "." $NF }'
}

tab_token() {
	title "Cloudflare token"
	zone=$(guess_zone "$DOMAIN")
	printf '<p class="desc">LegoCert uses a Cloudflare API token to prove you own the NAS name. Create one as follows.</p>'
	printf '<div class="panel"><div class="body"><ol class="steps">'
	printf '<li>In Cloudflare, open <a href="https://dash.cloudflare.com/profile/api-tokens" target="_blank" rel="noopener noreferrer">My Profile → API Tokens</a> and click <b>Create Token</b>.</li>'
	printf '<li><b>Token name:</b> for example <code>LegoCert NAS</code>.</li>'
	if [ -n "$zone" ]; then
		printf '<li>Under <b>Policies</b>, set <b>Include → Specific zone → %s</b> (the domain your NAS name is in).</li>' "$(esc "$zone")"
	else
		printf '<li>Under <b>Policies</b>, set <b>Include → Specific zone →</b> the domain your NAS name is in.</li>'
	fi
	printf '<li>Open <b>DNS &amp; Zones</b> and tick only these two:'
	printf '<div class="cf"><div class="cfrow"><span>DNS</span><span class="cb">Read</span><span class="cb on">Edit</span></div>'
	printf '<div class="cfrow"><span>Zone</span><span class="cb on">Read</span><span class="cb">Edit</span></div></div></li>'
	printf '<li>Leave <b>Token expiration</b> empty.</li>'
	printf '<li><b>Client IP Address Filtering</b> <span class="tag rec">Optional, recommended</span><br>Choose <b>Is in</b> and add your public IP address. Update it if your IP changes.<br>'
	button_form ip "Show my public IP"
	printf '%s</li>' "$IP_RESULT"
	printf '<li>Click <b>Create Token</b>, copy the token (it is shown only once) and paste it in <a href="%s?tab=settings">Settings</a>.</li>' "$SELF"
	printf '</ol></div></div>'
}

tab_settings() {
	title "Settings"
	if [ -n "$CF_DNS_TOKEN" ]; then
		tok_state="Saved (ends $(esc "$(printf '%s' "$CF_DNS_TOKEN" | tail -c 4)")). Leave empty to keep."
	else
		tok_state="Not set. <a href=\"$SELF?tab=token\">How to create one</a>"
	fi
	# Suggest the name this page was opened with, if it is a name (not an IP). Shown as
	# placeholder text only (escaped); never saved unless the user types it.
	host=${HTTP_HOST%:*}
	case $host in *.*[A-Za-z]* | *[A-Za-z]*.*) case ${host##*.} in *[A-Za-z]*) ;; *) host="" ;; esac ;; *) host="" ;; esac
	case $host in *[!A-Za-z0-9.-]*) host="" ;; esac
	placeholder=${host:-nas.example.com}
	bad_domain="" bad_email="" bad_token=""
	case ${ERR_FIELD:-} in domain) bad_domain=' class="bad"' ;; email) bad_email=' class="bad"' ;; token) bad_token=' class="bad"' ;; esac
	cat <<EOF
<form method="post" action="$SELF" autocomplete="off">
<input type="hidden" name="csrf" value="$CSRF"><input type="hidden" name="action" value="save">
<div class="panel"><div class="body">
<div class="row"><label for="domain">NAS name:</label><div class="ctl">
<input$bad_domain type="text" id="domain" name="domain" value="$(esc "$DOMAIN")" placeholder="$(esc "$placeholder")" required>
<p class="hint">The name you use to open the NAS, e.g. nas.example.com. Not an IP address.</p></div></div>
<div class="row"><label for="email">Email:</label><div class="ctl">
<input$bad_email type="email" id="email" name="email" value="$(esc "$EMAIL")" placeholder="you@example.com" required>
<p class="hint">For your Let's Encrypt account.</p></div></div>
<div class="row"><label for="token">Cloudflare API token:</label><div class="ctl">
<input$bad_token type="password" id="token" name="token" value="" placeholder="cfut_…" autocomplete="new-password">
<p class="hint">$tok_state</p></div></div>
</div><div class="actions"><button class="btn primary" type="submit">Apply</button></div></div></form>
EOF
	printf '<div class="panel"><h3>Check token</h3><div class="body"><p class="desc">Checks that the token works and can reach only one domain.</p>'
	button_form check_token "Check token"
	printf '%s</div></div>' "$CHECK_RESULT"
}

tab_notify() {
	title "Notifications"
	printf '<p class="desc">LegoCert writes to the system log as <code>[LegoCert]</code>. To get alerts:</p>'
	printf '<div class="panel"><div class="body"><ol class="steps">'
	printf '<li>Open <b>Notification Center → System Notification Rules → Alert Notifications</b> and click <b>Create rule</b>.</li>'
	printf '<li>Severity: <b>Warning</b> and <b>Error</b>. Add <b>Information</b> to hear about new certificates.</li>'
	printf '<li>Keyword: <code>LegoCert</code></li>'
	printf '<li>Choose how you want to be notified.</li>'
	printf '</ol></div></div>'
}

# Is a run in progress? (the lock exists and its process is alive). Sets RUN_LABEL
# from the latest "<name> started" line, e.g. "Test run".
run_in_progress() {
	pid=$(cat "$LOCK/pid" 2>/dev/null)
	[ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || return 1
	RUN_LABEL=$(grep ' started$' "$LOG" 2>/dev/null | tail -n 1 | cut -d' ' -f3- | sed 's/ started$//')
	RUN_LABEL=${RUN_LABEL:-A run}
}

# ------------------------------------------------------------- run progress
# The latest run, read from the log: which run, which stage it reached, and how it
# ended. Stages are recognised from LegoCert's own lines and lego's (pinned version).
# Sets ST_RUN ST_WHEN ST_STATE(idle|running|ok|error|skipped) ST_IDX ST_STAGES ST_MSG.
run_status() {
	ST_RUN="" ST_WHEN="" ST_START="" ST_STATE=idle ST_IDX=0 ST_STAGES="" ST_MSG=""
	[ -f "$LOG" ] || return 0
	# The latest run: from its last "<name> started" line (or a button run's "skipped"
	# line) to the end. Scheduled-check skips are ignored.
	seg=$(awk '
		/ (Test run|Renew now|Scheduled check|Check) started$/ { buf = "" }
		/ (Test run|Renew now|Check|Renewal) skipped: / { buf = "" }
		{ buf = buf $0 "\n" }
		END { printf "%s", buf }' "$LOG")
	[ -n "$seg" ] || return 0
	first=$(printf '%s\n' "$seg" | head -n 1)
	ST_START=$(printf '%s' "$first" | cut -c1-19) # "YYYY-MM-DD HH:MM:SS": identifies the run
	ST_WHEN=$(printf '%s' "$first" | awk '{split($1, d, "-"); m = substr("JanFebMarAprMayJunJulAugSepOctNovDec", d[2] * 3 - 2, 3); print d[3] + 0, m, substr($2, 1, 5)}')
	has() { printf '%s' "$seg" | grep -q -- "$1"; }

	case $first in
	*" skipped: "*)
		ST_RUN=$(printf '%s' "$first" | cut -d' ' -f3- | sed 's/ skipped: .*//')
		[ "$ST_RUN" = Renewal ] && ST_RUN="Renew now"
		ST_STATE=skipped
		ST_STAGES="Starting"
		ST_MSG="Skipped: another run was in progress. Try again in a minute."
		return 0
		;;
	*" started") ST_RUN=$(printf '%s' "$first" | cut -d' ' -f3- | sed 's/ started$//') ;;
	*) return 0 ;;
	esac

	if [ "$ST_RUN" = "Test run" ]; then
		ST_STAGES="Starting|DNS record|Let's Encrypt check|Certificate|Done"
		has 'dns01: preparing to solve' && ST_IDX=1
		has 'waiting for record propagation' && ST_IDX=2
		has 'The server validated our request' && ST_IDX=3
		if has 'Test run OK'; then
			ST_IDX=4 ST_STATE=ok
			if has 'Authorization is already valid'; then
				ST_MSG="Partly checked: Let's Encrypt reused a recent check, so the Cloudflare DNS step was skipped. Run the test again for a full check."
			else
				ST_MSG="Everything works. Let's Encrypt's test service issued a certificate (nothing was installed)."
			fi
		fi
	else
		ST_STAGES="Starting|Renewal due?|DNS record|Let's Encrypt check|Certificate|Installing|Done"
		has 'lego run' && ST_IDX=1
		has 'dns01: preparing to solve' && ST_IDX=2
		has 'waiting for record propagation' && ST_IDX=3
		has 'The server validated our request' && ST_IDX=4
		has "differs from lego's; installing" && ST_IDX=5
		if has 'Skip renewal'; then
			in=$(printf '%s' "$seg" | sed -n 's/.*can be performed in \([0-9]*\)d.*/\1/p' | head -n 1)
			# Nothing was renewed: a short line, so it doesn't look like an install.
			ST_STAGES="Starting|Renewal due?|Done" ST_IDX=2 ST_STATE=ok
			ST_MSG="Not due yet, nothing to do.${in:+ It renews automatically in about $in days.}"
		elif has 'installed a new certificate'; then
			until=$(printf '%s' "$seg" | sed -n 's/.*valid until \([A-Za-z]*\) *\([0-9]*\) [0-9:]* \([0-9]*\).*/\2 \1 \3/p' | head -n 1)
			ST_IDX=6 ST_STATE=ok ST_MSG="New certificate installed${until:+, valid until $until}."
		elif has 'no LegoCert certificate yet'; then
			ST_STAGES="Starting|Renewal due?|Done" ST_IDX=2 ST_STATE=ok
			ST_MSG="No certificate from LegoCert yet. Use Renew now to get the first one."
		elif has ' finished OK'; then
			ST_IDX=6 ST_STATE=ok ST_MSG="Done. The certificate is up to date."
		fi
		[ "$ST_IDX" = 5 ] && [ "$ST_STATE" = idle ] &&
			ST_MSG="Installing. The NAS web interface restarts now; this page catches up when it's back."
	fi

	if [ "$ST_STATE" = idle ]; then
		if has '\[error\]' || has 'FAILED' || has 'renewal attempt failed'; then
			ST_STATE=error
			ST_MSG=$(friendly_error)
		elif run_in_progress; then
			ST_STATE=running
		else
			ST_STATE=error
			ST_MSG="The run stopped unexpectedly. Try again."
		fi
	fi
	if [ "$ST_STATE" = running ] && [ -z "$ST_MSG" ]; then
		stage=$(printf '%s' "$ST_STAGES" | cut -d'|' -f$((ST_IDX + 1)))
		case $stage in
		Starting) ST_MSG="Starting…" ;;
		"Renewal due?") ST_MSG="Checking with Let's Encrypt whether a renewal is due…" ;;
		"DNS record") ST_MSG="Adding a temporary DNS record in Cloudflare…" ;;
		"Let's Encrypt check") ST_MSG="Waiting for Let's Encrypt to see the DNS record. This usually takes under a minute." ;;
		Certificate) ST_MSG="Getting the certificate…" ;;
		*) ST_MSG="Working…" ;;
		esac
	fi
	return 0
}

# A plain-English reason for a failed run, from what lego and LegoCert logged.
friendly_error() {
	if has '9109' || has 'Cannot use the access token from location'; then
		echo "Cloudflare refused the token from this NAS's internet address. Check the token's IP filter."
	elif has 'Invalid API Token' || has 'Authentication error' || has 'Invalid request headers'; then
		echo "Cloudflare rejected the token. Check it in Settings, then use Check token."
	elif has 'could not find zone' || has 'zone could not be found' || has 'unable to find zone'; then
		echo "Cloudflare couldn't find the domain for this NAS name. Check the token's zone."
	elif has 'time limit exceeded'; then
		echo "The DNS record didn't show up in time. Try again in a few minutes."
	elif has 'rateLimited' || has 'too many'; then
		echo "Let's Encrypt's rate limit was reached. Try again later."
	elif has 'killed'; then
		echo "The run took too long and was stopped. Try again later."
	elif has 'did not serve the new certificate'; then
		echo "QTS didn't pick up the new certificate, so the previous one was put back. It will be retried tomorrow."
	elif has 'no such host' || has 'connection refused' || has 'i/o timeout' || has 'network is unreachable'; then
		echo "Couldn't reach Let's Encrypt or Cloudflare. Check the NAS's internet connection."
	elif has 'Settings: '; then
		printf '%s' "$seg" | sed -n 's/.*Settings: //p' | head -n 1
	else
		printf '%s' "$seg" | grep -E '\[error\]|\[warn\]' | tail -n 1 | cut -d' ' -f3- | sed 's/^\[[a-z]*\] //'
	fi
}

render_progress() {
	run_status
	expect=""
	case $(query_param msg) in staging | renew) expect=1 ;; esac
	# Just clicked: the run identified by "since" (the click time) may not have logged its
	# start yet. Show it as starting rather than showing the previous run's result.
	since=$(query_param since | urldecode)
	case $since in *[!0-9:\ -]*) since="" ;; esac
	[ -n "$expect" ] || since=""
	if [ -n "$since" ] && awk -v a="$ST_START" -v b="$since" 'BEGIN { exit !(a < b) }'; then
		case $(query_param msg) in
		staging) ST_RUN="Test run" ST_STAGES="Starting|DNS record|Let's Encrypt check|Certificate|Done" ;;
		*) ST_RUN="Renew now" ST_STAGES="Starting|Renewal due?|DNS record|Let's Encrypt check|Certificate|Installing|Done" ;;
		esac
		ST_STATE=running ST_IDX=0 ST_MSG="Starting…" ST_WHEN=""
	fi
	hidden=""
	[ "$ST_STATE" = idle ] && hidden=" hidden"
	printf '<div class="prog" id="prog" data-src="%s?status=1" data-state="%s" data-since="%s"%s>' "$SELF" "$ST_STATE" "$(esc "$since")" "$hidden"
	if [ "$ST_STATE" != idle ]; then
		n=$(printf '%s' "$ST_STAGES" | awk -F'|' '{print NF}')
		pct=0
		[ "$n" -gt 1 ] && pct=$((ST_IDX * 100 / (n - 1)))
		printf '<div class="prog-head"><b>%s</b><span class="muted">  %s</span></div>' "$(esc "$ST_RUN")" "$(esc "$ST_WHEN")"
		printf '<div class="track"><div class="line"></div><div class="fill %s" style="width:%s%%"></div>' "$ST_STATE" "$pct"
		i=0
		printf '%s\n' "$ST_STAGES" | tr '|' '\n' | while IFS= read -r name; do
			if [ "$i" -lt "$ST_IDX" ]; then c="done"; elif [ "$i" = "$ST_IDX" ]; then c=cur; else c=todo; fi
			[ "$i" = 0 ] && c="$c first"
			[ "$i" = $((n - 1)) ] && c="$c last"
			left=0
			[ "$n" -gt 1 ] && left=$((i * 100 / (n - 1)))
			printf '<div class="stop %s" style="left:%s%%"><span class="lbl">%s</span></div>' "$c" "$left" "$(esc "$name")"
			i=$((i + 1))
		done
		printf '<div class="ball %s" style="left:%s%%"></div></div>' "$ST_STATE" "$pct"
		printf '<div class="prog-msg %s">%s</div>' "$ST_STATE" "$(esc "$ST_MSG")"
	fi
	printf '</div>'
	printf '<p class="hint" id="prog-detail"><a href="%s?download=log">Download details</a> (technical log, for troubleshooting)</p>' "$SELF"
	printf '<script src="%s?asset=progress.js" defer></script>' "$SELF"
}

banner() {
	case $1 in
	saved) note ok "Settings applied." ;;
	staging) note ok "Test run started. Progress shows under Run now." ;;
	renew) note ok "Renew now started. Progress shows under Run now." ;;
	esac
}

# ===================================================================== main
# The progress script: static, no secrets. Served by this CGI because files in
# QTS's cgi-bin are not served as plain static files.
if [ "$(query_param asset)" = progress.js ]; then
	printf 'Status: 200 OK\r\nContent-Type: application/javascript; charset=utf-8\r\nCache-Control: no-cache\r\nX-Content-Type-Options: nosniff\r\n\r\n'
	cat "$QPKG_ROOT/ui/progress.js"
	exit 0
fi

[ "$(id -u)" = 0 ] || fail_page "500 Internal Server Error" \
	"This page needs QTS to run app pages as administrator, and on this NAS it doesn't. Configure LegoCert over SSH instead (see the README)."

authenticate
case $? in
0) ;;
2) fail_page "403 Forbidden" "LegoCert's settings are for administrators only." ;;
*) fail_page "401 Unauthorized" "Please sign in to QTS as an administrator, then open LegoCert from App Center again." ;;
esac
CSRF=$(csrf_token)

read_conf 2>/dev/null || CONF_ERR=$ERR
[ -f "$CONF" ] && ! conf_perms_ok && CONF_ERR="legocert.conf has the wrong owner or permissions; applying the settings fixes this."

TAB=$(query_param tab)
case $TAB in overview | token | settings | notify) ;; *)
	if [ -z "$CF_DNS_TOKEN" ]; then TAB=token; else TAB=overview; fi
	;;
esac
IP_RESULT=""
CHECK_RESULT=""

if [ "${REQUEST_METHOD:-GET}" = POST ]; then
	len=${CONTENT_LENGTH:-0}
	case $len in '' | *[!0-9]*) len=0 ;; esac
	[ "$len" -le 8192 ] || fail_page "413 Payload Too Large" "Request too large."
	BODY=$(head -c "$len")
	posted=$(field csrf)
	[ -n "$posted" ] && [ "$posted" = "$CSRF" ] || fail_page "403 Forbidden" "This form has expired. Reload the page and try again."

	case $(field action) in
	save)
		TAB=settings
		DOMAIN=$(field domain)
		EMAIL=$(field email)
		new_token=$(field token | tr -d ' \r\n\t')
		[ -n "$new_token" ] && CF_DNS_TOKEN=$new_token
		if validate_conf; then
			write_conf || fail_page "500 Internal Server Error" "Could not write the settings file."
			log "settings saved from the settings page (user: $(cookie NAS_USER))"
			redirect settings saved
		fi
		CONF_ERR=$ERR
		;;
	check_token)
		TAB=settings
		if out=$("$QPKG_ROOT/renew.sh" --check-token 2>&1); then
			CHECK_RESULT="<div style=\"margin-top:12px\">$(note ok "<pre>$(esc "$out")</pre>")</div>"
		else
			CHECK_RESULT="<div style=\"margin-top:12px\">$(note err "<pre>$(esc "$out")</pre>")</div>"
		fi
		;;
	staging)
		since=$(date '+%Y-%m-%d %H:%M:%S')
		run_background --staging
		redirect overview staging "$since"
		;;
	renew)
		since=$(date '+%Y-%m-%d %H:%M:%S')
		run_background
		redirect overview renew "$since"
		;;
	ip)
		TAB=token
		v4=$(curl -4 -sS -m 6 https://1.1.1.1/cdn-cgi/trace 2>/dev/null | sed -n 's/^ip=//p')
		v6=$(curl -6 -sS -m 6 'https://[2606:4700:4700::1111]/cdn-cgi/trace' 2>/dev/null | sed -n 's/^ip=//p')
		IP_RESULT="<table class=\"grid\"><tr><th>IPv4</th><td><code>$(esc "${v4:-none found}")</code></td></tr><tr><th>IPv6</th><td><code>$(esc "${v6:-none found (fine if your network has no IPv6)}")</code></td></tr></table>"
		;;
	*) fail_page "400 Bad Request" "Unknown action." ;;
	esac
fi

# Progress for progress.js: key=value lines (values are plain text for textContent).
if [ "$(query_param status)" = 1 ]; then
	run_status
	printf 'Status: 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n\r\n'
	printf 'run=%s\nstart=%s\nwhen=%s\nstate=%s\nidx=%s\nstages=%s\nmsg=%s\n' "$ST_RUN" "$ST_START" "$ST_WHEN" "$ST_STATE" "$ST_IDX" "$ST_STAGES" "$ST_MSG" | tr -d '\r'
	exit 0
fi
# The technical log, as a download (for troubleshooting a failed run).
if [ "$(query_param download)" = log ]; then
	printf 'Status: 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Disposition: attachment; filename="legocert.log"\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n\r\n'
	[ -f "$LOG" ] && cat "$LOG"
	exit 0
fi

headers "200 OK"
page_start "$TAB"
case $TAB in
overview) tab_overview ;;
token) tab_token ;;
settings) tab_settings ;;
notify) tab_notify ;;
esac
printf '</div>'
page_end
