# shellcheck disable=all
. "$install_dir/${p_name}-owrt-common.sh" || exit 1

die() {
	logger -t "$me" "$1"
	printf '%s\n' "$me: $1" >&2
	exit 1
}

# add OpenWrt firewall include
mk_fw_include() {
	[ "$p_name_c" ] && [ "$_OWRTFW" ] && [ "$fw_include_path" ] || die "Error: essential variables are unset."
	uci -q get firewall."$p_name_c" 1>/dev/null && return 0
	rel=
	[ "$_OWRTFW" = 3 ] && rel=".reload=1" # fw3
	uci_cmds="$(
		for o in "=include" ".enabled=1" ".type=script" ".path=$fw_include_path" "$rel"; do
			[ "$o" ] && printf '%s\n' "set firewall.$p_name_c$o"
		done
	)"
	errors="$(printf '%s\n' "$uci_cmds" | uci batch && uci commit firewall)" ||
		die "Failed to add firewall include. Errors: $(printf %s "$errors" | tr '\n' ' ')."
	service firewall restart
}

mk_fw_include