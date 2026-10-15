#!/bin/sh
# /usr/share/AdGuardHome/watchconfig.sh
#
#
PATH="/usr/sbin:/usr/bin:/sbin:/bin"

while :; do
	sleep 10

	configpath="$(uci -q get adguardhome.config.config_file)"
	[ -n "$configpath" ] || \
		configpath="/etc/adguardhome/adguardhome.yaml"

	[ -f "$configpath" ] || continue

	if /etc/init.d/adguardhome do_redirect 1; then
		/etc/init.d/adguardhome start >/dev/null 2>&1
		break
	fi

	logger -t adguardhome \
		"watchconfig: failed to apply redirect for $configpath, retrying"
done
