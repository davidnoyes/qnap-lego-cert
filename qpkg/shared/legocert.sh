#!/bin/sh
# QPKG service script (QPKG_SERVICE_PROGRAM). QTS runs "start" at boot and when
# the app is enabled, "stop" at shutdown and when it is disabled.
#
# The job here is to keep the renewal cron entry in place. QTS rebuilds the live
# crontab from /etc/config/crontab, and firmware updates can reset that file, so
# start re-adds the entry every boot instead of relying on it surviving.

QPKG_NAME=LegoCert
QPKG_ROOT=$(/sbin/getcfg "$QPKG_NAME" Install_Path -f /etc/config/qpkg.conf)
. "$QPKG_ROOT/common.sh"

CRONTAB=/etc/config/crontab
MARKER="# $QPKG_NAME"
# Daily; lego only contacts Let's Encrypt when renewal is due (1/3 of lifetime left).
SCHEDULE="17 4 * * *"

CGI_LINK=/home/httpd/cgi-bin/qpkg/$QPKG_NAME

ui_link() {
	mkdir -p /home/httpd/cgi-bin/qpkg
	ln -sfn "$QPKG_ROOT/ui" "$CGI_LINK"
	# Point App Center's "Open" at QTS's own ports (the page is served by QTS itself),
	# re-read at every start in case they were changed in Control Panel.
	web=$(/sbin/getcfg System "Web Access Port" -d 8080 -f /etc/config/uLinux.conf)
	ssl=$(/sbin/getcfg Stunnel Port -d 443 -f /etc/config/uLinux.conf)
	/sbin/setcfg "$QPKG_NAME" Web_Port "$web" -f /etc/config/qpkg.conf
	/sbin/setcfg "$QPKG_NAME" Web_SSL_Port "$ssl" -f /etc/config/qpkg.conf
}

ui_unlink() {
	[ -L "$CGI_LINK" ] && rm -f "$CGI_LINK"
}

reload_cron() {
	crontab "$CRONTAB" && /etc/init.d/crond.sh restart >/dev/null 2>&1
}

cron_add() {
	line="$SCHEDULE $QPKG_ROOT/renew.sh --auto $MARKER"
	if ! grep -qF "$line" "$CRONTAB" 2>/dev/null; then
		cron_remove_lines
		echo "$line" >>"$CRONTAB"
		reload_cron
		log "cron entry installed: $line"
	fi
}

cron_remove_lines() {
	if grep -qF "$MARKER" "$CRONTAB" 2>/dev/null; then
		grep -vF "$MARKER" "$CRONTAB" >"$CRONTAB.legocert.tmp" &&
			cat "$CRONTAB.legocert.tmp" >"$CRONTAB" &&
			rm -f "$CRONTAB.legocert.tmp"
		return 0
	fi
	return 1
}

cron_remove() {
	if cron_remove_lines; then
		reload_cron
		log "cron entry removed"
	fi
}

case "$1" in
start)
	ENABLED=$(/sbin/getcfg "$QPKG_NAME" Enable -u -d FALSE -f /etc/config/qpkg.conf)
	if [ "$ENABLED" != "TRUE" ]; then
		echo "$QPKG_NAME is disabled."
		exit 1
	fi
	# Pids do not survive a reboot: any lock left by a run cut off by shutdown is stale.
	release_lock
	ui_link
	cron_add
	# Catch up after the NAS has been off: renew.sh is a no-op unless renewal is due.
	# Delayed so the network and DNS are up; backgrounded to stay within QPKG_TIMEOUT.
	(sleep 300 && "$QPKG_ROOT/renew.sh" --auto) </dev/null >/dev/null 2>&1 &
	;;
stop)
	cron_remove
	ui_unlink
	;;
restart)
	$0 stop
	$0 start
	;;
remove)
	cron_remove
	ui_unlink
	;;
*)
	echo "Usage: $0 {start|stop|restart|remove}"
	exit 1
	;;
esac
exit 0
