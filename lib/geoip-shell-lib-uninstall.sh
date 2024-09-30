#!/bin/sh
# shellcheck disable=SC2154,SC1090

# geoip-shell-lib-uninstall.sh

# library used to uninstall or reset geoip-shell

# Copyright: antonk (antonk.d3v@gmail.com)
# github.com/friendly-bits


# kills any running geoip-shell scripts
kill_geo_pids() {
	i_kgp=0 _parent="$(grep -o "${p_name}[^[:space:]]*" "/proc/$PPID/comm")"
	while true; do
		i_kgp=$((i_kgp+1)); _killed=
		_geo_ps="$(pgrep -fa "(${p_name}\-|$ripe_url_stats|$ripe_url_api|$ipdeny_ipv4_url|$ipdeny_ipv6_url)" | grep -v pgrep)"
		newifs "$_nl" kgp
		for _p in $_geo_ps; do
			_pid="${_p% *}"
			_p="$p_name${_p##*"$p_name"}"
			_p="${_p%% *}"
			case "$_pid" in "$$"|"$PPID"|*[!0-9]*) continue; esac
			[ "$_p" = "$_parent" ] && continue
			IFS=' '
			for g in run fetch apply cronsetup backup detect-lan; do
				case "$_p" in *${p_name}-$g*)
					kill "$_pid" 2>/dev/null
					_killed=1
				esac
			done
		done
		oldifs kgp
		[ ! "$_killed" ] && return 0
		[ $i_kgp -gt 10 ] && { unisleep; return 0; }
	done
}

rm_iplists_rules() {
	# kill any related processes which may be running in the background
	kill_geo_pids

	# remove the lock file
	rm_lock

	case "$iplist_dir" in
		*"$p_name"*) rm_geodir "$iplist_dir" iplist ;;
		*)
			# remove individual iplist files if iplist_dir is shared with non-geoip-shell files
			[ "$iplist_dir" ] && [ -d "$iplist_dir" ] && {
				echo "Removing $p_name ip lists..."
				set +f
				rm -f "${iplist_dir:?}"/*.iplist
				set -f
			}
	esac

	### Remove geoip firewall rules
	[ "$_fw_backend" ] && rm_all_georules || {
		[ "$in_uninstall" ] && echolog -err "$FAIL remove $p_name firewall rules. Please restart the machine after uninstallation."
	}

	:
}

rm_cron_jobs() {
	case "$(crontab -u root -l 2>/dev/null)" in *"${p_name}-run.sh"*)
		echo "Removing cron jobs..."
		crontab -u root -l 2>/dev/null | grep -v "${p_name}-run.sh" | crontab -u root -
	esac
	:
}

# 1 - dir path
# 2 - dir description
rm_geodir() {
	[ "$1" ] && [ -d "$1" ] && {
		printf '%s\n' "Deleting the $2 directory '$1'..."
		rm -rf "$1"
	}
}

rm_data() {
	rm_geodir "$datadir" data
	:
}

rm_symlink() {
	rm -f "${install_dir}/${p_name}"
}

rm_config() {
	rm_geodir "$conf_dir" config
	:
}

rm_setupdone() {
	rm -f "$conf_dir/setupdone"
}


[ ! "$_fw_backend" ] && [ "$root_ok" ] && {
	if [ "$_OWRTFW" ]; then
		[ "$_OWRTFW" = 4 ] && _fw_backend=nft || _fw_backend=ipt
	elif [ -f "$_lib-check-compat.sh" ]; then
		. "$_lib-check-compat.sh"
		if check_fw_backend nft; then
			_fw_backend=nft
		elif check_fw_backend ipt; then
			_fw_backend=ipt
		fi
	fi 2>/dev/null
}

: