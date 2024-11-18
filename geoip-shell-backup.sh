#!/bin/sh
# shellcheck disable=SC2015,SC2034,SC2154,SC2086,SC1090,SC2120

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

Usage: $me <action> [-n] [-s] [-d] [-V] [-h]

Creates a backup of the current firewall state and current ipsets or restores them from backup.

Actions:
  create-backup|restore  : create a backup of, or restore $p_name config, ipsets and firewall rules

Options:
  -n  : Do not restore config and status files
  -s  : Only restore or create backup of config and status files
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
restore_conf=1 only_conf_status=
while getopts ":nsdVh" opt; do
	case $opt in
		n) restore_conf= ;;
		s) only_conf_status=1 ;;
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

bk_failed() {
	[ "$1" ] && echolog -err "$1"
	rm_bk_tmp
	die "$FAIL back up $p_name ipsets."
}

rm_bk_tmp() {
	set +f
	rm -rf "$bk_dir_new"
	rm -f "$tmp_file" "$iplist_dir/"*.iplist
}

rstr_failed() {
	rm_rstr_tmp
	export main_config=
	[ "$1" ] && echolog -err "$1"
	[ "$2" = reset ] && {
		echolog -err "*** Geoblocking is not working. Removing geoblocking firewall rules. ***"
		rm_all_georules
	}
	die
}

rm_rstr_tmp() {
	set +f
	rm -f "$tmp_file" "$iplist_dir/"*.iplist
}

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
	unset src_f src_d dest_f dest_d
	case "$1" in
		restore) src_f=_bak; src_d="$bk_dir/"; cp_act=Restoring ;;
		backup) dest_f=_bak; dest_d="$bk_dir_new/"; cp_act="Creating backup of" ;;
		*) echolog -err "cp_conf: bad argument '$1'"; return 1
	esac

	for bak_f in status config; do
		eval "cp_src=\"$src_d\$${bak_f}_file$src_f\" cp_dest=\"$dest_d\$${bak_f}_file$dest_f\""
		[ "$cp_src" ] && [ "$cp_dest" ] || { echolog -err "cp_conf: $FAIL set \$cp_src or \$cp_dest"; return 1; }
		[ -f "$cp_src" ] || continue
		[ -f "$cp_dest" ] && compare_files "$cp_src" "$cp_dest" && {
			debugprint "$cp_src is identical to $cp_dest"
			continue
		}
		debugprint "Copying '$cp_src' to '$cp_dest'"
		printf %s "$cp_act the $bak_f file... "
		cp "$cp_src" "$cp_dest" || { echolog -err "$cp_act the $bak_f file failed."; return 1; }
		OK
	done
}

#### VARIABLES

getconfig families
[ ! "$inbound_iplists" ] && getconfig inbound_iplists
[ ! "$outbound_iplists" ] && getconfig outbound_iplists

bk_dir="$datadir/backup"
bk_dir_new="${bk_dir}.new"
config_file="$conf_file"
config_file_bak="${p_name}.conf.bak"
status_file="$datadir/status"
status_file_bak="status.bak"

checkvars _fw_backend datadir

. "$_lib-$_fw_backend.sh" || die

#### MAIN

mk_lock
set +f
case "$action" in
	create-backup)
		trap 'trap - INT TERM HUP QUIT; rm_bk_tmp; die' INT TERM HUP QUIT
		tmp_file="/tmp/${p_name}_backup.tmp"
		[ "$only_conf_status" ] && {
			bk_dir_new="$bk_dir"
			mkdir -p "$bk_dir" && chmod -R 600 "$bk_dir" && chown -R root:root "$bk_dir" &&
			cp_conf backup || die "$FAIL create backup of the config and status files."
			die 0
		}
		set_archive_type
		mkdir -p "$bk_dir_new" && chmod -R 600 "$bk_dir_new" && chown -R root:root "$bk_dir_new"
		san_str iplists "$inbound_iplists $outbound_iplists" || die
		create_backup
		rm -f "$tmp_file"
		setconfig "bk_ext=${bk_ext:-bak}" &&
		cp_conf backup || bk_failed
		rm -rf "$bk_dir"
		mv "$bk_dir_new" "$bk_dir" || bk_failed
		chmod -R 600 "$bk_dir" && chown -R root:root "$bk_dir" ||
			echolog -err "$FAIL set permissions for the backup directory '$bk_dir'."

		printf '%s\n\n' "Successfully created backup of $p_name state." ;;
	restore)
		trap 'trap - INT TERM HUP QUIT; rm_rstr_tmp; die' INT TERM HUP QUIT
		if [ "$restore_conf" ]; then
			bk_conf_file="$bk_dir/$config_file_bak"
			and_config=" and config"
		else
			bk_conf_file="$config_file"
			and_config=
		fi
		[ "$only_conf_status" ] && {
			cp_conf restore || die "$FAIL restore the config and status files."
			die 0
		}
		echolog "${_nl}Preparing to restore $p_name ip lists$and_config from backup..."
		[ ! -s "$bk_conf_file" ] && rstr_failed "Config file '$bk_conf_file' is empty or doesn't exist."
		getconfig inbound_iplists inbound_iplists "$bk_conf_file" &&
		getconfig outbound_iplists outbound_iplists "$bk_conf_file" &&
		getconfig bk_ext bk_ext "$bk_conf_file" || rstr_failed "$FAIL get backup config."
		san_str iplists "$inbound_iplists $outbound_iplists" || die

		if [ "$iplists" ]; then
			get_counters
			set_extract_cmd "$bk_ext"
			extract_iplists
		else
			echolog "No ip lists registered - skipping iplist extraction."
		fi

		### Remove geoblocking iptables rules and ipsets
		rm_all_georules || rstr_failed "$FAIL remove firewall rules and ipsets."

		[ "$restore_conf" ] && { cp_conf restore || rstr_failed; }

		export main_config=

		[ "$_fw_backend" = ipt ] && { restore_ipsets || rstr_failed "$FAIL restore $p_name ipsets from backup." reset; }
		call_script "$i_script-apply.sh" restore
		apply_rv=$?

		rm_rstr_tmp
		[ "$apply_rv" != 0 ] && rstr_failed "$FAIL restore $p_name ip lists$and_config from backup." "reset"

		[ "$restore_conf" ] && echolog "Successfully completed action 'restore'."
esac

die 0
