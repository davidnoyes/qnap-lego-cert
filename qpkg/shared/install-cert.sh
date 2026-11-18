#!/bin/sh
# install-cert.sh CERT_BUNDLE KEY
# Install a certificate into QTS's web server (/etc/stunnel) and prove it took.
# Called by renew.sh when the certificate lego holds differs from the one QTS
# serves. Never sees the Cloudflare token.
#
# Order matters: validate everything first, back up, write files atomically,
# restart, verify by connecting; on any failure restore the backup and restart.

QPKG_NAME=LegoCert
QPKG_ROOT=$(/sbin/getcfg "$QPKG_NAME" Install_Path -f /etc/config/qpkg.conf)
. "$QPKG_ROOT/common.sh"
load_conf || exit 1

CERT=$1
KEY=$2
VERIFY_SECONDS=${LEGOCERT_VERIFY_SECONDS:-60} # how long QTS gets to serve the new certificate

fail() {
	notify error "install failed: $*"
	exit 1
}

restart_web() {
	/etc/init.d/thttpd.sh restart >/dev/null 2>&1
	/etc/init.d/stunnel.sh restart >/dev/null 2>&1
	/etc/init.d/Qthttpd.sh restart >/dev/null 2>&1
}

# Wait up to VERIFY_SECONDS for QTS to serve the certificate with fingerprint $1.
wait_for_served() {
	waited=0
	while [ "$waited" -lt "$VERIFY_SECONDS" ]; do
		sleep 5
		waited=$((waited + 5))
		[ "$(served_cert | fingerprint)" = "$1" ] && return 0
	done
	return 1
}

[ -s "$CERT" ] && [ -s "$KEY" ] || fail "usage: $0 CERT_BUNDLE KEY (files must exist)"

TMP=$(mktemp -d) || fail "mktemp failed"
trap 'rm -rf "$TMP"' EXIT
umask 077

# 1. Validate: the leaf parses, is in date, names DOMAIN, and matches the key.
leaf_of "$CERT" >"$TMP/leaf.pem"
openssl x509 -noout -in "$TMP/leaf.pem" 2>/dev/null || fail "certificate does not parse"
openssl x509 -noout -checkend 0 -in "$TMP/leaf.pem" >/dev/null 2>&1 || fail "certificate has expired"
openssl x509 -noout -text -in "$TMP/leaf.pem" | grep -q "DNS:$DOMAIN\([,[:space:]]\|$\)" ||
	fail "certificate does not cover $DOMAIN"
cert_pub=$(openssl x509 -noout -pubkey -in "$TMP/leaf.pem" | openssl sha256)
key_pub=$(openssl pkey -pubout -in "$KEY" 2>/dev/null | openssl sha256)
[ "$cert_pub" = "$key_pub" ] || fail "private key does not match certificate"
new_fp=$(fingerprint <"$TMP/leaf.pem")
expiry=$(openssl x509 -noout -enddate -in "$TMP/leaf.pem" | cut -d= -f2)

# Staged copies, so the live files are each replaced by a single rename.
cp "$TMP/leaf.pem" "$TMP/backup.cert" &&
	cp "$KEY" "$TMP/backup.key" &&
	cat "$KEY" "$TMP/leaf.pem" >"$TMP/stunnel.pem" &&
	cp "$CERT" "$TMP/uca.pem" || fail "staging files failed (disk full?)"
old_fp=$(served_cert | fingerprint)

# 2. Back up the current files.
BACKUP="$STUNNEL_DIR/backups/$(date '+%Y%m%d%H%M%S')"
if ! { mkdir -p "$BACKUP" && cp -p "$STUNNEL_DIR"/*.* "$BACKUP"/; }; then
	fail "backup to $BACKUP failed; nothing changed"
fi

rollback() { # rollback REASON
	cp -p "$BACKUP"/*.* "$STUNNEL_DIR"/
	restart_web
	if [ -n "$old_fp" ] && wait_for_served "$old_fp"; then
		fail "$1; rolled back to the previous certificate ($BACKUP)"
	fi
	fail "$1; rollback attempted but QTS is not serving the previous certificate either. The web UI may be down: SSH in and restore from $BACKUP"
}

# 3. Install. Same layout as the old manual install.sh.
for f in backup.cert backup.key stunnel.pem uca.pem; do
	if ! { cp "$TMP/$f" "$STUNNEL_DIR/.$f.new" && mv "$STUNNEL_DIR/.$f.new" "$STUNNEL_DIR/$f"; }; then
		rollback "writing $STUNNEL_DIR/$f failed"
	fi
done

# 4. Restart and verify by connecting.
restart_web
wait_for_served "$new_fp" || rollback "QTS did not serve the new certificate within ${VERIFY_SECONDS}s"

# Keep the 10 newest backups (they contain private keys; root-only like /etc/stunnel).
ls -1d "$STUNNEL_DIR"/backups/*/ 2>/dev/null | sort -r | awk 'NR>10' | while read -r d; do rm -rf "$d"; done

notify info "installed a new certificate for $DOMAIN, valid until $expiry"
