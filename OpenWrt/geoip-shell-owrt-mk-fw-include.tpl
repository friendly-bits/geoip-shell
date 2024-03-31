#!/bin/sh
# shellcheck disable=SC1090,SC2154

# geoip-shell-owrt-mk-fw-include.sh

# Copyright: antonk (antonk.d3v@gmail.com)
# github.com/friendly-bits

# intended to be run from procd init script
# makes sure that OpenWrt firewall include exists. if not then adds it.

# the -install script adds values for the required variables

me="${0##*/}"
. "${_lib}-owrt-common.sh" || exit 1

die() {
	logger -s -t "$me" -p user.err "$1"
	exit 1
}

# add OpenWrt firewall include
mk_fw_include() {
	[ "$p_name_c" ] && [ "$_OWRTFW" ] && [ "$fw_include_path" ] || die "Error: essential variables are unset."
	check_owrt_include && return 0
	rel=
	[ "$_OWRTFW" = 3 ] && rel=".reload=1"
	uci delete firewall."$p_name_c" 1>/dev/null 2>/dev/null
	uci_cmds="$(
		for o in "=include" ".enabled=1" ".type=script" ".path=$fw_include_path" "$rel"; do
			[ "$o" ] && printf '%s\n' "set firewall.$p_name_c$o"
		done
	)"
	errors="$(printf '%s\n' "$uci_cmds" | uci batch && uci commit firewall 2>&1)"
	[ "$errors" ] && die "Failed to add firewall include. Errors: $(printf %s "$errors" | tr '\n' ' ')."
	/etc/init.d/firewall reload
}

[ ! -f "$conf_dir/setupdone" ] && [ ! -f "/tmp/$p_name-setupdone" ] &&
	die "$p_name has not been configured. Refusing to create firewall include. Run '$p_name configure' to fix this."
mk_fw_include
