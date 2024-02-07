#!/bin/sh
# shellcheck disable=SC2015,SC2317,SC2034,SC2154,SC2086,SC1090

# geoip-shell-backup.sh


#### Initial setup
proj_name="geoip-shell"
script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)

. "$script_dir/${proj_name}-common.sh" || exit 1
. "$script_dir/geoip-shell-nft.sh" || exit 1

check_root

sanitize_args "$@"
newifs "$delim"
set -- $arguments; oldifs


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

# process the rest of the arguments
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


#### FUNCTIONS

# resets firewall rules, destroys geoip ipsets and then initiates restore from file
restorebackup() {
	printf '%s\n' "Preparing to restore firewall state from backup..."

	getconfig Lists lists "$conf_file_bak"
	getconfig BackupExt bk_ext "$conf_file_bak"

	set_extract_cmd "$bk_ext"

	printf %s "Restoring files from backup... "
	for list_id in $lists; do
		bk_file="$bk_dir/$list_id.$bk_ext"
		iplist_file="$iplist_dir/${list_id}.iplist.new"

		[ ! -s "$bk_file" ] && restore_failed "Error: '$bk_file' is empty or doesn't exist."

		# extract elements and write to $iplist_file
		$extract_cmd "$bk_file" > "$iplist_file" || restore_failed "Failed to extract backup file '$bk_file'."
		[ ! -s "$iplist_file" ] && restore_failed "Failed to extract ip list for $list_id."
		# count lines in the iplist file
		line_cnt=$(wc -l < "$iplist_file")
		debugprint "\nLines count in $list_id backup: $line_cnt"
	done

	cp "$status_file_bak" "$status_file" || restore_failed "Failed to restore the status file."
	cp "$conf_file_bak" "$conf_file" || restore_failed "Failed to restore the config file."

	echo "Ok."

	# remove geoip rules
	nft_rm_all_georules || restore_failed "Error removing firewall rules."

	for f in "${iplist_dir}"/*.new; do
		mv -- "$f" "${f%.new}" || restore_failed "Failed to overwrite file '$f'"
	done

	export force_read_geotable=1
	call_script "$script_dir/${proj_name}-apply.sh" add -l "$lists"; apply_rv=$?
	rm "$iplist_dir/"*.iplist 2>/dev/null
	[ "$apply_rv" != 0 ] && restore_failed "Failed to restore the firewall state from backup." "reset"

	rm "$temp_file" 2>/dev/null
	return 0
}

restore_failed() {
	rm "$temp_file" 2>/dev/null
	rm "$iplist_dir/"*.iplist.new 2>/dev/null
	printf '%s\n' "$1" >&2
	[ "$2" = reset ] && {
		echolog -err "*** Geoip blocking is not working. Removing geoip firewall rules and cron jobs. ***"
		call_script "$script_dir/${proj_name}-uninstall.sh" -c
	}
	exit 1
}

backup_failed() {
	rm -f "$temp_file" "$bk_dir/"*.new 2>/dev/null
	die "Failed to back up the firewall state."
}

# Saves current firewall state to a backup file
create_backup() {
	set_archive_type

	getconfig Lists lists "$conf_file"
	temp_file="/tmp/geoip-shell_backup.tmp"
	mkdir "$bk_dir" 2>/dev/null

	# save the current firewall state
	printf %s "Creating backup of the firewall state... "
	for list_id in $lists; do
		bk_file="${bk_dir}/${list_id}.${archive_ext:-bak}"
		iplist_file="$iplist_dir/${list_id}.iplist"
		getstatus "$status_file" "PrevDate_${list_id}" list_date || backup_failed
		ipset="${list_id}_${list_date}_${geotag}"

		rm "$temp_file" 2>/dev/null
		# extract elements and write to $temp_file
		nft list set inet "$geotable" "$ipset" |
			sed -n -e /"elements[[:space:]]*=[[:space:]]*{"/\{ -e p\;:1 -e n\; -e p\; -e /\}/q\;b1 -e \} > "$temp_file"
		[ ! -s "$temp_file" ] && backup_failed

		[ "$debugmode" ] && backup_len="$(wc -l < "$temp_file")"
		debugprint "\n$list_id backup length: $backup_len"

		$compr_cmd < "$temp_file" > "${bk_file}.new"; rv=$?
		[ "$rv" != 0 ] || [ ! -s "${bk_file}.new" ] && backup_failed
	done
	echo "Ok."

	rm "$temp_file" 2>/dev/null

	for f in "${bk_dir}"/*.new; do
		mv -- "$f" "${f%.new}" || backup_failed
	done

	cp "$status_file" "$status_file_bak" || backup_failed
	setconfig "BackupExt=${archive_ext:-bak}"
	cp "$conf_file" "$conf_file_bak"  || backup_failed
}

# detects archive type (if any) of file passed in 1st argument by its extension
# and sets the $extract_cmd variable accordingly
set_extract_cmd() {
	set_extr_cmd() { checkutil "$1" && extract_cmd="$1 -cd" ||
		die "Error: backup archive type is '$1' but the $1 utility is not found."; }

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

for entry in "Datadir datadir" "Families families" "Lists config_lists"; do
	getconfig "${entry% *}" "${entry#* }"
done

conf_file_bak="$datadir/${proj_name}.conf.bak"
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
		printf '\n%s\n' "Successfully created backup of config, ip sets and firewall rules."
		;;
	restore)
		restorebackup
		echolog "Successfully restored the firewall state from backup."
		printf '\n%s\n\n' "View geoip-blocking status with '${blue}${proj_name} status${n_c}' (may require 'sudo')."
		;;
	*) unknownact
esac

exit 0
