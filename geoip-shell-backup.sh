#!/bin/sh
# shellcheck disable=SC2015,SC2034,SC2154,SC2086,SC1090

# geoip-shell-backup.sh

# Copyright: antonk (antonk.d3v@gmail.com)
# github.com/friendly-bits

#### Initial setup
p_name="geoip-shell"
. "/usr/bin/${p_name}-geoinit.sh" || exit 1

san_args "$@"
newifs "$delim"
set -- $_args
oldifs


#### USAGE

usage() {
cat <<EOF

Usage: $me <action> [-n] [-d] [-V] [-h]

Creates a backup of the current firewall state and current ip sets or restores them from backup.

Actions:
  create-backup|restore  : create a backup of, or restore $p_name config, ip sets and firewall rules

Options:
  -n  : Do not restore config and status files
  -d  : Debug
  -V  : Version
  -h  : This help

EOF
}

#### PARSE ARGUMENTS

# check for valid action
action="$1"
case "$action" in
	create-backup|restore) shift ;;
	* ) unknownact
esac

# process the rest of the args
restore_config=1
while getopts ":ndVh" opt; do
	case $opt in
		n) restore_config= ;;
		d) debugmode_arg=1 ;;
		V) echo "$curr_ver"; exit 0 ;;
		h) usage; exit 0 ;;
		*) unknownopt
	esac
done
shift $((OPTIND-1))

extra_args "$@"

is_root_ok

setdebug
debugentermsg

# detects archive type (if any) of file passed in 1st argument by its extension
# and sets the $extract_cmd variable accordingly
set_extract_cmd() {
	set_extr_cmd() { checkutil "$1" && extract_cmd="$1 -cd" ||
		die "backup archive type is '$1' but the $1 utility is not found."; }

	case "$1" in
		bz2 ) set_extr_cmd bzip2 ;;
		xz ) set_extr_cmd xz ;;
		gz ) set_extr_cmd gunzip ;;
		* ) extract_cmd="cat" ;;
	esac
}

# detects the best available archive type and sets $compr_cmd and $bk_ext accordingly
set_archive_type() {
	arch_bzip2="bzip2 -zc@bz2"
	arch_xz="xz -zc@xz"
	arch_gzip="gzip -c@gz"
	arch_cat="cat@"
	for _util in bzip2 xz gzip cat; do
		checkutil "$_util" && {
			eval "compr_cmd=\"\${arch_$_util%@*}\"; bk_ext=\"\${arch_$_util#*@}\""
			break
		}
	done
}

# checks for diff in new and old config and status files and makes a backup or restores if necessary
# 1 - restore|backup
cp_conf() {
	unset src_f dest_f
	case "$1" in
		restore) src_f=_bak; cp_act=Restoring ;;
		backup) dest_f=_bak; cp_act="Creating backup of" ;;
		*) echolog -err "cp_conf: bad argument '$1'"; return 1
	esac

	for bak_f in status config; do
		eval "cp_src=\"\$${bak_f}_file$src_f\" cp_dest=\"\$${bak_f}_file$dest_f\""
		[ "$cp_src" ] && [ "$cp_dest" ] || { echolog -err "cp_conf: $FAIL set \$cp_src or \$cp_dest"; return 1; }
		[ -f "$cp_src" ] || continue
		[ -f "$cp_dest" ] && compare_files "$cp_src" "$cp_dest" && continue
		printf %s "$cp_act the $bak_f file... "
		cp "$cp_src" "$cp_dest" || { echolog -err "$cp_act the $bak_f file failed."; return 1; }
		OK
	done
}

#### VARIABLES

getconfig families
getconfig iplists

bk_dir="$datadir/backup"
config_file="$conf_file"
config_file_bak="$bk_dir/${p_name}.conf.bak"
status_file_bak="$bk_dir/status.bak"

checkvars _fw_backend datadir

. "$_lib-$_fw_backend.sh" || die

#### MAIN

mk_lock
set +f
case "$action" in
	create-backup)
		trap 'rm_bk_tmp; die' INT TERM HUP QUIT
		tmp_file="/tmp/${p_name}_backup.tmp"
		set_archive_type
		mkdir "$bk_dir" 2>/dev/null
		create_backup
		rm "$tmp_file" 2>/dev/null
		setconfig "bk_ext=${bk_ext:-bak}" &&
		cp_conf backup || bk_failed
		printf '%s\n\n' "Successfully created backup of $p_name config, ip sets and firewall rules." ;;
	restore)
		trap 'rm_rstr_tmp; die' INT TERM HUP QUIT
		printf '%s\n' "Preparing to restore $p_name from backup..."
		[ "$restore_conf" ] && bk_conf_file="$config_file_bak" || bk_conf_file="$config_file"
		[ ! -s "$bk_conf_file" ] && rstr_failed "File '$bk_conf_file' is empty or doesn't exist."
		getconfig iplists iplists "$bk_conf_file" &&
		getconfig bk_ext bk_ext "$bk_conf_file" || rstr_failed
		set_extract_cmd "$bk_ext"
		restorebackup
		printf '%s\n\n' "Successfully completed action 'restore'."
esac

die 0
