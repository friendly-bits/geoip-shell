# intended to be run from procd init script
# makes sure that OpenWrt firewall include exists. if not then adds it.

# the -install.sh script prepends the shebang and values for required variables

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
	[ "$_OWRTFW" = 3 ] && rel=".reload=1" # fw3
	delete firewall."$p_name_c" 1>/dev/null 2>/dev/null
	uci_cmds="$(
		for o in "=include" ".enabled=1" ".type=script" ".path=$fw_include_path" "$rel"; do
			[ "$o" ] && printf '%s\n' "set firewall.$p_name_c$o"
		done
	)"
	errors="$(printf '%s\n' "$uci_cmds" | uci batch && uci commit firewall)" ||
		die "Failed to add firewall include. Errors: $(printf %s "$errors" | tr '\n' ' ')."
	/etc/init.d/firewall restart
}

mk_fw_include
