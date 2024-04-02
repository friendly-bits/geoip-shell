#!/bin/sh
# shellcheck disable=SC2154

# geoip-shell-lib-uninstall.sh

# library used to uninstall or reset geoip-shell

# Copyright: antonk (antonk.d3v@gmail.com)
# github.com/friendly-bits


rm_iplists_rules() {
	echo "Removing $p_name ip lists and firewall rules..."

	# kill any related processes which may be running in the background
	kill_geo_pids

	# remove the lock file
	rm_lock

	### Remove geoip firewall rules
	rm_all_georules || return 1

	set +f
	rm -f "${iplist_dir:?}"/*.iplist 2>/dev/null
	rm -rf "${datadir:?}"/* 2>/dev/null
	set -f
	:
}

rm_cron_jobs() {
	echo "Removing cron jobs..."
	crontab -u root -l 2>/dev/null | grep -v "${p_name}-run.sh" | crontab -u root -
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
	rm -f "${install_dir}/${p_name}" 2>/dev/null
}

rm_scripts() {
	printf '%s\n' "Deleting the main $p_name scripts from $install_dir..."
	for script_name in fetch apply manage cronsetup run backup mk-fw-include fw-include detect-lan uninstall geoinit; do
		rm -f "${install_dir}/${p_name}-$script_name.sh" 2>/dev/null
	done

	rm_geodir "$lib_dir" "library scripts"
	:
}

rm_config() {
	rm_geodir "$conf_dir" config
	:
}
