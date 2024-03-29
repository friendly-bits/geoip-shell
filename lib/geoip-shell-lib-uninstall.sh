#!/bin/sh
# shellcheck disable=SC2317,SC2154,SC2086,SC2034,SC1090

# geoip-shell-lib-uninstall

# Copyright: friendly bits
# github.com/friendly-bits

# library used to uninstall or reset geoip-shell

rm_iplists_rules() {
	echo "Removing $p_name ip lists and firewall rules..."

	# kill any related processes which may be running in the background
	kill_geo_pids

	# remove the lock file
	rm_lock

	### Remove geoip firewall rules
	rm_all_georules || rerturn 1

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

rm_data() {
	[ "$datadir" ] && {
		printf '%s\n' "Deleting the data folder $datadir..."
		rm -rf "${datadir:?}" 2>/dev/null
	}
	:
}

rm_symlink() {
	rm -f "${install_dir}/${p_name}" 2>/dev/null
}

rm_scripts() {
	printf '%s\n' "Deleting scripts from $install_dir..."
	for script_name in fetch apply manage cronsetup run backup mk-fw-include fw-include detect-lan uninstall geoinit; do
		rm -f "${install_dir}/${p_name}-$script_name.sh" 2>/dev/null
	done

	printf '%s\n' "Deleting library scripts from $lib_dir..."
	for script_name in uninstall owrt-common common ipt nft ip-regex arrays apply-ipt apply-nft backup-ipt \
		backup-nft status status-ipt status-nft check-compat setup; do
			rm -f "$_lib-$script_name.sh" 2>/dev/null
	done
	:
}

rm_config() {
	echo "Removing config..."
	rm -rf "$conf_dir" 2>/dev/null
	:
}