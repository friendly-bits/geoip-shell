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

geoinit="${p_name}-geoinit.sh"
for geoinit_path in "$script_dir/$geoinit" "/usr/bin/$geoinit"; do
	[ -f "$geoinit_path" ] && break
done

[ ! "$geoinit_path" ] && die "Cannot uninstall $p_name because ${p_name}-geoinit.sh is missing."

. "$geoinit_path" || exit 1

san_args "$@"
newifs "$delim"
set -- $_args; oldifs
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
		V) echo "$curr_ver"; exit 0 ;;
		d) debugmode=1 ;;
		h) usage; exit 0 ;;
		*) ;;
	esac
done
shift $((OPTIND-1))

is_root_ok || exit 1

old_lib_dir="$_lib"
. "$old_lib_dir-uninstall.sh"  || exit 1

### VARIABLES
lib_dir="/usr/lib/$p_name"
_lib="$lib_dir/$p_name-lib"

old_install_dir="$(command -v "$p_name")"
old_install_dir="${old_install_dir%/*}"
install_dir="${old_install_dir:-"$install_dir"}"

[ ! "$install_dir" ] && die "Can not determine installation directory. Try setting \$install_dir manually."

[ "$script_dir" != "$install_dir" ] && [ -f "$install_dir/${p_name}-uninstall.sh" ] && [ ! "$norecur" ] && {
	# prevents infinite loop
	export norecur=1
	call_script "$install_dir/${p_name}-uninstall.sh" "$keepdata" && exit 0
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
if [ "$_fw_backend" ] || detect_fw_backends; then
	[ -z "$_fw_backend" ] &&
		case "$_fw_backend_def" in
			'') ;;
			ipt|nft) _fw_backend="$_fw_backend_def" ;;
			ask)
				# resort to heuristics
				if [ "$ipt_rules_present" ] && [ "$ipset_present" ]; then
					_fw_backend=ipt
				else
					_fw_backend=nft
				fi
				[ ! "$keepdata" ] && echolog -warn "Based on heuristics, using firewall backend '${_fw_backend}ables' to remove existing geoblocking rules."
		esac

	[ "$_fw_backend" ] && (
		for lib_dir in "$old_lib_dir" "$_lib"; do
			[ -f "$lib_dir-$_fw_backend.sh" ] && . "$lib_dir-$_fw_backend.sh" && break
			false
		done || {
			echolog -err "Failed to source the ${_fw_backend}ables library."
			exit 1
		}
		rm_all_georules || {
			echolog -err "$FAIL remove $p_name firewall rules."
			exit 1
		}
	)
else
	echolog -err "Firewall backend is unknown."
	false
fi || echolog -err "Cannot remove geoblocking rules. Please restart the machine after uninstallation."

case "$iplist_dir" in
	*"$p_name"*) rm_geodir "$iplist_dir" iplist ;;
	*)
		# remove individual iplist files if iplist_dir is shared with non-geoip-shell files
		[ "$iplist_dir" ] && [ -d "$iplist_dir" ] && {
			echo "Removing $p_name IP lists..."
			set +f
			rm -f "${iplist_dir:?}"/*.iplist
			set -f
		}
esac

rm_cron_jobs

# For OpenWrt
[ "$_OWRT_install" ] && {
	rm_owrt_init
	rm_owrt_fw_include
	reload_owrt_fw
}

rm_symlink
rm_scripts
[ ! "$keepdata" ] && {
	rm_config
	rm_all_data
}

printf '%s\n\n' "Uninstall complete."
