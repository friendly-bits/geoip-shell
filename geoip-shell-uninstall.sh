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
. "$geoinit_path" &&
. "$_lib-uninstall.sh" &&
. "$_lib-$_fw_backend.sh" || exit 1


san_args "$@"
newifs "$delim"
set -- $_args; oldifs
debugentermsg

#### USAGE

usage() {
cat <<EOF
v$curr_ver

Usage: $me [-h]

1) Removes geoip firewall rules
2) Removes geoip cron jobs
3) Deletes scripts' data folder (/var/lib/geoip-shell or /etc/geoip-shell/data on OpenWrt)
4) Deletes the scripts from /usr/sbin
5) Deletes the config folder /etc/geoip-shell

Options:
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

lib_dir="/usr/lib"
_lib="$lib_dir/$p_name-lib"


### VARIABLES
old_install_dir="$(command -v "$p_name")"
old_install_dir="${old_install_dir%/*}"
install_dir="${old_install_dir:-"$install_dir"}"

[ ! "$install_dir" ] && die "Can not determine installation directory. Try setting \$install_dir manually"

[ "$script_dir" != "$install_dir" ] && [ -f "$install_dir/${p_name}-uninstall.sh" ] && [ ! "$norecur" ] && {
	export norecur=1 # prevents infinite loop
	call_script "$install_dir/${p_name}-uninstall.sh" && exit 0
}

: "${conf_dir:=/etc/$p_name}"
[ -d "$conf_dir" ] && : "${conf_file:="$conf_dir/$p_name.conf"}"
[ -f "$conf_file" ] && getconfig datadir

#### MAIN

rm_iplists_rules
rm_cron_jobs
rm_data

# For OpenWrt
[ "$_OWRT_install" ] && {
	rm_owrt_init
	rm_owrt_fw_include
	restart_owrt_fw
}

rm_symlink
rm_scripts
rm_config

printf '%s\n\n' "Uninstall complete."
