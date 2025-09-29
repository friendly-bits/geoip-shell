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
in_uninstall=1

case "$script_dir" in
	"/usr/bin"|'')
		geoinit_dir=/usr/bin
		lib_src_dir="$lib_dir" ;;
	*)
		geoinit_dir="$script_dir"
		lib_src_dir="$script_dir/lib"
esac

geoinit_path="${geoinit_dir}/${p_name}-geoinit.sh"
[ -f "$geoinit_path" ] && . "$geoinit_path" || { printf '%s\n' "Can not find '${geoinit_path}'." >&2; exit 1; }

san_args "$@"
newifs "$delim"
set -- $_args
oldifs

debugentermsg

#### USAGE

usage() {
cat <<EOF
Usage: $me [-r] [-V] [-d] [-h]

1) Removes geoip firewall rules
2) Removes geoip cron jobs
3) Deletes scripts' data folder (/var/lib/geoip-shell or /etc/geoip-shell/data on OpenWrt)
4) Deletes the scripts from /usr/sbin
5) Deletes the config folder /etc/geoip-shell

Options:
  -r  : Leave the config file and the backup files in place
  -V  : Version
  -d  : Debug
  -h  : This help

EOF
}

rm_scripts() {
	printed=
	for script_name in fetch apply manage cronsetup run backup mk-fw-include fw-include uninstall geoinit; do
		s_path="${install_dir}/${p_name}-$script_name.sh"
		[ -f "$s_path" ] && {
			[ ! "$printed" ] && { printf '%s\n' "Deleting $p_name main scripts from $install_dir..."; printed=1; }
			rm -f "$s_path"
		}
	done

	rm_geodir "$lib_dir" "library scripts"
	:
}


#### PARSE ARGUMENTS

while getopts ":rVdh" opt; do
	case $opt in
		r) keepdata="-r" ;;
		V) echo "$curr_ver"; die 0 ;;
		d) debugmode=1 ;;
		h) usage; die 0 ;;
		*) ;;
	esac
done
shift $((OPTIND-1))

is_root_ok || die

source_lib uninstall "$lib_src_dir" || die


### VARIABLES
old_install_dir="$(command -v "$p_name")"
old_install_dir="${old_install_dir%/*}"
install_dir="${old_install_dir:-"$install_dir"}"

[ ! "$install_dir" ] && die "Can not determine installation directory. Try setting \$install_dir manually."

[ "$script_dir" != "$install_dir" ] && [ -f "$install_dir/${p_name}-uninstall.sh" ] && [ ! "$norecur" ] && {
	# prevents infinite loop
	export norecur=1
	call_script "$install_dir/${p_name}-uninstall.sh" "$keepdata" && die 0
}

: "${conf_dir:=/etc/$p_name}"
[ -d "$conf_dir" ] && : "${conf_file:="$conf_dir/$p_name.conf"}"
[ -s "$conf_file" ] && nodie=1 getconfig datadir ||
	{
		[ ! "$first_setup" ] &&
			echolog -warn "Config file doesn't exist or failed to read config." \
				"Firewall rules may not be removed by the uninstaller. Please restart the machine after uninstallation."
	}
: "${datadir:="/var/lib/$p_name"}"
[ -s "$conf_file" ] && nodie=1 getconfig local_iplists_dir
: "${local_iplists_dir:="/var/lib/$p_name/local_iplists"}"

#### MAIN

rm_setupdone

# kill any related processes which may be running in the background
kill_geo_pids

# remove the lock file
rm_lock

### Remove geoblocking rules

if [ -z "$_fw_backend" ] && [ -n "$old_install_dir" ] && detect_fw_backends; then
	case "$_FW_BACKEND_DEF" in
		'') ;;
		ipt|nft) _fw_backend="$_FW_BACKEND_DEF" ;;
		ask)
			# resort to heuristics
			if [ "$IPT_OK" ]; then
				_fw_backend=ipt
			elif [ "$NFT_OK" ]; then
				_fw_backend=nft
			fi
			# if not re-installing
			[ "$_fw_backend" ] && [ ! "$keepdata" ] &&
				echolog -warn "Based on heuristics, using firewall backend '${_fw_backend}ables' to remove existing geoblocking rules."
	esac
fi

lib_src_dir="$lib_src_dir" rm_iplists_rules
rm_cron_jobs

[ -n "$keepdata" ] && die 0

# For OpenWrt
[ "$_OWRT_install" ] && {
	rm_owrt_init
	rm_owrt_fw_include
	reload_owrt_fw
}

rm_symlink
rm_scripts
rm_config
rm_all_data

printf '%s\n\n' "Uninstall complete."

die 0