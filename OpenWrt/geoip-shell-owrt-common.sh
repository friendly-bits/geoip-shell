#!/bin/sh

# common functions and variables for OpenWrt-related scripts

checkutil () { command -v "$1" 1>/dev/null; }

check_owrt_init() {
	set +f
	for f in /etc/rc.d/S*"${p_name}-init"; do
		[ -s "$f" ] && { set -f; return 0; }
	done
	set -f
	return 1
}

# checks value in uci for firewall.geoip_shell.$1
# 1 - option
# 2 - value
check_uci_ent() { [ "$(uci -q get firewall."$p_name_c.$1")" = "$2" ]; }

# checks the firewall include for geoip-shell in uci
check_owrt_include() {
	check_uci_ent enabled 1 || return 1
	[ "$_OWRTFW" = 4 ] && return 0
	check_uci_ent reload 1
}

# check for OpenWrt firewall version
checkutil uci && checkutil procd && for i in 3 4; do
	[ -x /sbin/fw$i ] && export _OWRTFW="$i"
done || {
	logger -s -t "$me" -p user.err "Failed to detect OpenWrt firewall"
	return 1
}

me="${0##*/}"
p_name_c="${p_name%%-*}_${p_name#*-}"
