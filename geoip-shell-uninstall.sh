#!/bin/sh
# shellcheck disable=SC2317,SC2154,SC2086,SC2034,SC1090

# geoip-shell-uninstall

# Copyright: friendly bits
# github.com/friendly-bits

# uninstalls or resets geoip-shell

#### Initial setup
p_name="geoip-shell"
script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)

manmode=1
nolog=1

geoinit="${p_name}-geoinit.sh"
for geoinit_path in "$script_dir/$geoinit" "/usr/bin/$geoinit"; do
	[ -f "$geoinit_path" ] && break
done
. "$geoinit_path" || exit 1

san_args "$@"
newifs "$delim"
set -- $_args; oldifs

#### USAGE

usage() {
    cat <<EOF

Usage: $me [-l] [-c] [-r] [-h]

1) Removes geoip firewall rules
2) Removes geoip cron jobs
3) Deletes scripts' data folder (/var/lib/geoip-shell or /etc/geoip-shell/data on OpenWrt)
4) Deletes the scripts from /usr/sbin
5) Deletes the config folder /etc/geoip-shell

Options:
  -l  : Reset ip lists and remove firewall geoip rules, don't uninstall
  -c  : Reset ip lists and remove firewall geoip rules and cron jobs, don't uninstall
  -r  : Remove cron jobs, geoip config and firewall geoip rules, don't uninstall
  -h  : This help

EOF
}

#### PARSE ARGUMENTS

while getopts ":rlch" opt; do
	case $opt in
		l) resetonly_lists="-l" ;;
		c) reset_only_lists_cron="-c" ;;
		r) resetonly="-r" ;;
		h) usage; exit 0;;
		*) unknownopt
	esac
done
shift $((OPTIND-1))

extra_args "$@"

check_root || exit 1

fw_backend_lib="$_lib-$_fw_backend.sh"
[ -f "$fw_backend_lib" ] && . "$fw_backend_lib" || die "$fw_backend_lib not found."

debugentermsg

### VARIABLES
old_install_dir="$(command -v "$p_name")"
old_install_dir="${old_install_dir%/*}"
install_dir="${old_install_dir:-"$install_dir"}"
lib_dir="/usr/lib"

[ ! "$install_dir" ] && die "Can not determine installation directory. Try setting \$install_dir manually"

[ "$script_dir" != "$install_dir" ] && [ -f "$install_dir/${p_name}-uninstall.sh" ] && [ ! "$norecur" ] && {
	export norecur=1 # prevents infinite loop
	call_script "$install_dir/${p_name}-uninstall.sh" "$resetonly" "$resetonly_lists" "$reset_only_lists_cron" && exit 0
}

: "${conf_dir:=/etc/$p_name}"

#### CHECKS

#### MAIN

echo "Cleaning up..."

# kill any related processes which may be running in the background
kill_geo_pids

# remove the lock file
rm_lock

### Remove geoip firewall rules
rm_all_georules || die 1

[ -f "$conf_file" ] && setconfig "Lists="
set +f; rm "$iplist_dir"/* 2>/dev/null

rm -rf "${datadir:?}"/* 2>/dev/null
[ "$resetonly_lists" ] && exit 0

### Remove geoip cron jobs
crontab -u root -l 2>/dev/null | grep -v "${p_name}-run.sh" | crontab -u root -

[ "$resetonly_lists_cron" ] && exit 0

# Delete the config file
rm "$conf_file" 2>/dev/null

[ "$resetonly" ] && exit 0

# For OpenWrt
[ "$_OWRT_install" ] && {
	. "$_lib-owrt-common.sh" || exit 1
	echo "Deleting the init script..."
	/etc/init.d/${p_name}-init disable 2>/dev/null && rm "/etc/init.d/${p_name}-init" 2>/dev/null
	echo "Removing the firewall include..."
	uci delete firewall."$p_name_c" 1>/dev/null 2>/dev/null
	echo "Restarting the firewall..."
	/etc/init.d/firewall restart 1>/dev/null 2>/dev/null
}

printf '%s\n' "Deleting the data folder $datadir..."
rm -rf "$datadir"

printf '%s\n' "Deleting scripts from $install_dir..."
rm "${install_dir}/${p_name}" 2>/dev/null
for script_name in fetch apply manage cronsetup run backup mk-fw-include fw-include detect-lan uninstall; do
	rm "${install_dir}/${p_name}-$script_name.sh" 2>/dev/null
done

printf '%s\n' "Deleting library scripts from $lib_dir..."
for script_name in owrt-common common ipt nft ip-regex arrays apply-ipt apply-nft backup-ipt \
	backup-nft status-ipt status-nft check-compat; do
		rm "${lib_dir}/${p_name}-lib-$script_name.sh" 2>/dev/null
done

echo "Deleting config..."
rm -rf "$conf_dir" 2>/dev/null

printf '%s\n\n' "Uninstall complete."
