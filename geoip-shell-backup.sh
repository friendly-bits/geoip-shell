#!/bin/sh
# shellcheck disable=SC2015,SC2317,SC2034,SC2154,SC2086,SC1090

# geoip-shell-backup.sh

# Copyright: friendly bits
# github.com/friendly-bits

#### Initial setup
p_name="geoip-shell"
script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)

. "$script_dir/${p_name}-common.sh" || exit 1
. "$lib_dir/${p_name}-lib-backup-$_fw_backend.sh" || exit 1

check_root

san_args "$@"
newifs "$delim"
set -- $_args; oldifs


#### USAGE

usage() {
cat <<EOF

Usage: $me <action> [-d] [-h]

Creates a backup of the current firewall state and current ip sets or restores them from backup.

Actions:
  create-backup|restore  : create a backup of, or restore config, geoip ip sets and firewall rules

Options:
  -d    : Debug
  -h    : This help

EOF
}

#### PARSE ARGUMENTS

action="$1"

# process the rest of the args
shift 1
while getopts ":dh" opt; do
	case $opt in
		d) debugmode_args=1 ;;
		h) usage; exit 0 ;;
		*) unknownopt
	esac
done
shift $((OPTIND-1))

extra_args "$@"

echo

setdebug

debugentermsg


# detects archive type (if any) of file passed in 1st argument by its extension
# and sets the $extract_cmd variable accordingly
set_extract_cmd() {
	set_extr_cmd() { checkutil "$1" && extract_cmd="$1 -cd" ||
		die "$ERR backup archive type is '$1' but the $1 utility is not found."; }

	case "$1" in
		bz2 ) set_extr_cmd bzip2 ;;
		xz ) set_extr_cmd xz ;;
		gz ) set_extr_cmd gunzip ;;
		* ) extract_cmd="cat" ;;
	esac
}

# detects the best available archive type and sets $compr_cmd and $archive_ext accordingly
set_archive_type() {
	arch_bzip2="bzip2 -zc@bz2"
	arch_xz="xz -zc@xz"
	arch_gzip="gzip -c@gz"
	arch_cat="cat@"
	for _util in bzip2 xz gzip cat; do
		checkutil "$_util" && {
			eval "compr_cmd=\"\${arch_$_util%@*}\"; archive_ext=\"\${arch_$_util#*@}\""
			break
		}
	done
}

#### VARIABLES

getconfig Families families
getconfig Lists config_lists

conf_file_bak="$datadir/${p_name}.conf.bak"
status_file_bak="$datadir/status.bak"
iplist_dir="${datadir}/ip_lists"
status_file="$iplist_dir/status"
bk_dir="$datadir/backup"

#### CHECKS

[ ! -f "$conf_file" ] && die "Config file '$conf_file' doesn't exist! Run the installation script again."

#### MAIN

set +f
case "$action" in
	create-backup)
		create_backup
		printf '%s\n\n' "Successfully created backup of $p_name config, ip sets and firewall rules." ;;
	restore)
		restorebackup
		printf '%s\n\n' "Successfully restored $p_name state from backup."
		statustip ;;
	*) unknownact
esac

:
