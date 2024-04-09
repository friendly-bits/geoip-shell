#!/bin/sh
# shellcheck disable=SC2154,SC2086,SC2034,SC1090

# geoip-shell-uninstall

# Copyright: antonk (antonk.d3v@gmail.com)
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
. "$geoinit_path" &&
. "$_lib-uninstall.sh" || exit 1
[ "$_fw_backend" ] && { . "$_lib-$_fw_backend.sh" || exit 1; }

san_args "$@"
newifs "$delim"
set -- $_args; oldifs
debugentermsg

#### USAGE

usage() {
cat <<EOF
Usage: $me [-V] [-h]

1) Removes geoip firewall rules
2) Removes geoip cron jobs
3) Deletes scripts' data folder (/var/lib/geoip-shell or /etc/geoip-shell/data on OpenWrt)
4) Deletes the scripts from /usr/sbin
5) Deletes the config folder /etc/geoip-shell

Options:
  -V  : Version
  -h  : This help

EOF
}

rm_scripts() {
	printf '%s\n' "Deleting the main $p_name scripts from $install_dir..."
	for script_name in fetch apply manage cronsetup run backup mk-fw-include fw-include detect-lan uninstall geoinit; do
		rm -f "${install_dir}/${p_name}-$script_name.sh" 2>/dev/null
	done

	rm_geodir "$lib_dir" "library scripts"
	:
}


#### PARSE ARGUMENTS

while getopts ":rlcVh" opt; do
	case $opt in
		l) resetonly_lists="-l" ;;
		c) reset_only_lists_cron="-c" ;;
		r) resetonly="-r" ;;
		V) echo "$curr_ver"; exit 0 ;;
		h) usage; exit 0;;
		*) unknownopt
	esac
done
shift $((OPTIND-1))

extra_args "$@"

is_root_ok || exit 1

lib_dir="/usr/lib/$p_name"
_lib="$lib_dir/$p_name-lib"


### VARIABLES
old_install_dir="$(command -v "$p_name")"
old_install_dir="${old_install_dir%/*}"
install_dir="${old_install_dir:-"$install_dir"}"

[ ! "$install_dir" ] && die "Can not determine installation directory. Try setting \$install_dir manually"

[ "$script_dir" != "$install_dir" ] && [ -f "$install_dir/${p_name}-uninstall.sh" ] && [ ! "$norecur" ] && {
	# prevents infinite loop
	export norecur=1
	call_script "$install_dir/${p_name}-uninstall.sh" && exit 0
}

: "${conf_dir:=/etc/$p_name}"
[ -d "$conf_dir" ] && : "${conf_file:="$conf_dir/$p_name.conf"}"
[ -s "$conf_file" ] && getconfig datadir

#### MAIN

[ "$_fw_backend" ] && rm_iplists_rules
rm_cron_jobs
rm_data

# For OpenWrt
[ "$_OWRT_install" ] && [ -f "$_lib-owrt-common.sh" ] && {
	. "$_lib-owrt-common.sh"
	rm -f "$conf_dir/setupdone" 2>/dev/null
	rm_owrt_init
	rm_owrt_fw_include
	restart_owrt_fw
}

rm_symlink
rm_scripts
rm_config

printf '%s\n\n' "Uninstall complete."
