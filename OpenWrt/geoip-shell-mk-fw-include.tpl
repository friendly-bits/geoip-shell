# intended to be run from procd init script
# makes sure that OpenWrt firewall include exists. if not then adds it.

# the -install.sh script prepends the shebang and values for variables $install_dir and $p_name

. "$install_dir/${p_name}-owrt-common.sh" || exit 1

die() {
	logger -t "$me" -p user.err "$1"
	printf '%s\n' "$me: $1" >&2
	exit 1
}

# add OpenWrt firewall include
mk_fw_include() {
	[ "$p_name_c" ] && [ "$_OWRTFW" ] && [ "$fw_include_path" ] || die "Error: essential variables are unset."
	check_owrt_include && return 0
	rel=
	[ "$_OWRTFW" = 3 ] && rel=".reload=1" # fw3
	uci_cmds="$(
		delete firewall."$p_name_c" 1>/dev/null 2>/dev/null
		for o in "=include" ".enabled=1" ".type=script" ".path=$fw_include_path" "$rel"; do
			[ "$o" ] && printf '%s\n' "set firewall.$p_name_c$o"
		done
	)"
	errors="$(printf '%s\n' "$uci_cmds" | uci batch && uci commit firewall)" ||
		die "Failed to add firewall include. Errors: $(printf %s "$errors" | tr '\n' ' ')."
	service firewall restart
}

mk_fw_include