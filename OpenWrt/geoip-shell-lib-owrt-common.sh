#!/bin/sh
# shellcheck disable=SC2154,SC2034,SC2086

# common functions and variables for OpenWrt-related geoip-shell scripts

# Copyright: antonk (antonk.d3v@gmail.com)
# github.com/friendly-bits


checkutil () { command -v "$1" 1>/dev/null; }

enable_owrt_persist() {
	[ "$no_persist" = true ] && {
		printf '%s\n\n' "Installed without persistence functionality."
		return 1
	}

	rm -f "$conf_dir/no_persist"
	! check_owrt_init && {
		[ -s "$init_script" ] || {
			echolog -err "The init script '$init_script' is missing. Please reinstall $p_name."
			return 1
		}
		printf %s "Enabling the init script... "
		$init_script enable
		check_owrt_init || { FAIL; echolog -err "$FAIL enable '$init_script'."; return 1; }
		OK
	}
	/bin/sh "$install_dir/${p_name}-mk-fw-include.sh"
}

disable_owrt_persist() {
	[ ! -f "$conf_dir/no_persist" ] && touch "$conf_dir/no_persist"
	[ ! -s "$init_script" ] ||
	{
		printf %s "Disabling the init script... "
		$init_script disable && ! check_owrt_init ||
			{ echolog -err "$FAIL disable the init script '$init_script'."; return 1; }
		OK
	} &&
	{
		rm_owrt_fw_include
		reload_owrt_fw
	}
	:
}

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

rm_owrt_fw_include() {
	uci -q get firewall."$p_name_c" 1>/dev/null || return 0
	printf %s "Removing the firewall include... "
	uci -q delete firewall."$p_name_c" 1>/dev/null && OK || FAIL

	echo "Committing fw$_OWRTFW changes..."
	uci commit firewall
	:
}

rm_owrt_init() {
	[ ! -s "$init_script" ] && return 0
	echo "Deleting the init script..."
	$init_script disable 2>/dev/null && rm -f "$init_script"
}

restart_owrt_fw() {
	echo "Restarting firewall$_OWRTFW..."
	fw$_OWRTFW -q restart
	:
}

reload_owrt_fw() {
	echo "Reloading firewall$_OWRTFW..."
	fw$_OWRTFW -q reload
	:
}

me="${0##*/}"
p_name_c="${p_name%%-*}_${p_name#*-}"
_OWRTFW=
init_script="/etc/init.d/${p_name}-init"
conf_dir="/etc/$p_name"

# check for OpenWrt firewall version
checkutil uci && checkutil procd && for i in 3 4; do
	[ -x /sbin/fw$i ] && export _OWRTFW="$i"
done

[ -z "$_OWRTFW" ] && {
	logger -s -t "$me" -p user.warn "Warning: Detected procd init but no OpenWrt firewall."
	return 0
}
curr_sh_g="/bin/sh"
:
