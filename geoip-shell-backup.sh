#!/bin/sh
# shellcheck disable=SC2015,SC2317,SC2034,SC2154,SC2086,SC1090

# geoip-shell-backup.sh


#### Initial setup
proj_name="geoip-shell"
script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)

. "$script_dir/${proj_name}-common.sh" || exit 1
. "$script_dir/${proj_name}-ipt.sh" || exit 1

check_root

sanitize_args "$@"
newifs "$delim"
set -- $arguments; oldifs


#### USAGE

usage() {
cat <<EOF

Usage: $me <action> [-d] [-h]

- Creates a backup of the current iptables states and current ipsets,
- or restores them from backup
- if restore from backup fails, calls the *reset script to deactivate geoip blocking

Actions:
    create-backup|restore  : create a backup of, or restore config, geoip-associated ipsets and iptables rules

Options:
    -d                     : Debug
    -h                     : This help

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

# resets iptables policies and rules, destroys associated ipsets and then initiates restore from file
restorebackup() {
	# outputs the iptables portion of the backup file for $family
	get_iptables_bk() {
		sed -n -e /"\[${proj_name}_IPTABLES_$family\]"/\{:1 -e n\;/\\["${proj_name}_IP"/q\;p\;b1 -e \} < "$temp_file"
	}
	# outputs the ipset portion of the backup file
	get_ipset_bk() { sed -n "/create ${proj_name}/,\$p" < "$temp_file"; }

	printf '%s\n' "Restoring firewall state from backup... "
	getconfig BackupFile bk_file "" -nodie; rv=$?
	if [ "$rv" = 1 ]; then
		restore_failed "Error reading the config file."
	elif [ "$rv" = 2 ] || [ -z "$bk_file" ]; then
		restore_failed "Can not restore the firewall state: no backup found."
	fi

	[ ! -f "$bk_file" ] && restore_failed "Can not find the backup file '$bk_file'."

	set_extract_cmd "$bk_file"

	# extract the backup archive into temp_file
	temp_file="/tmp/geoip-shell_backup.tmp"
	$extract_cmd "$bk_file" > "$temp_file" || restore_failed "Failed to extract backup file '$bk_file'."
	[ ! -s "$temp_file" ] && restore_failed "Error: backup file '$bk_file' is empty or backup extraction failed."

	printf '%s\n\n' "Successfully read backup file: '$bk_file'."

	printf %s "Checking the iptables portion of the backup file... "

	# count lines in the iptables portion of the backup file
	for family in $families; do
		line_cnt=$(get_iptables_bk | wc -l)
		debugprint "Firewall $family lines number in backup: $line_cnt"
		[ "$line_cnt" -lt 2 ] && restore_failed "Error: firewall $family backup appears to be empty or non-existing."
	done
	echo "Ok."

	printf %s "Checking the ipset portion of the backup file... "
	# count lines in the ipset portion of the backup file
	line_cnt=$(get_ipset_bk | grep -c "add ${proj_name}")
	debugprint "ipset lines number in backup: $line_cnt"
	[ "$line_cnt" = 0 ] && restore_failed "Error: ipset backup appears to be empty or non-existing."
	printf '%s\n\n' "Ok."

	### Remove geoip iptables rules and ipsets
	rm_all_ipt_rules || restore_failed "Error removing firewall rules and ipsets."

	echo

	# ipset needs to be restored before iptables
	for restoretarget in ipset iptables; do
		printf %s "Restoring $restoretarget state... "
		case "$restoretarget" in
			ipset) get_ipset_bk | ipset restore; rv=$? ;;
			iptables)
				rv=0
				for family in $families; do
					set_ipt_cmds
					get_iptables_bk | $ipt_restore_cmd; rv=$((rv+$?))
				done ;;
		esac

		case "$rv" in
			0) echo "Ok." ;;
			*) echo "Failed." >&2
			restore_failed "Failed to restore $restoretarget state from backup." "reset"
		esac
	done

	rm "$temp_file" 2>/dev/null
	return 0
}

restore_failed() {
	rm "$temp_file" 2>/dev/null
	echo "$1" >&2
	[ "$2" = reset ] && {
		echo "*** Geoip blocking is not working. Removing geoip firewall rules and the associated cron jobs. ***" >&2
		call_script "$script_dir/${proj_name}-uninstall.sh" -c
	}
	exit 1
}

# Saves current firewall state to a backup file
create_backup() {
	set_archive_type

	temp_file="/tmp/${proj_name}_backup.tmp"
	bk_file="$datadir/firewall_backup.${archive_ext:-bak}"
	backup_len=0

	printf %s "Creating backup of current iptables state... "

	rv=0
	for family in $families; do
		set_ipt_cmds
		printf '%s\n' "[${proj_name}_IPTABLES_$family]" >> "$temp_file"
		# save iptables state to temp_file
		printf '%s\n' "*$ipt_table" >> "$temp_file" || rv=1
		$ipt_save_cmd | grep -i "$geotag" >> "$temp_file" || rv=1
		printf '%s\n' "COMMIT" >> "$temp_file" || rv=1
		[ "$rv" != 0 ] && {
			rm "$temp_file" 2>/dev/null
			die "Failed to back up iptables state."
		}
	done
	echo "Ok."

	backup_len="$(wc -l < "$temp_file")"
	printf '%s\n' "[${proj_name}_IPSET]" >> "$temp_file"

	for ipset in $(ipset list -n | grep $geotag); do
		printf %s "Creating backup of ipset '$ipset'... "

		# append current ipset content to temp_file
		ipset save "$ipset" >> "$temp_file"; rv=$?

		backup_len_old=$(( backup_len + 1 ))
		backup_len="$(wc -l < "$temp_file")"
		[ "$rv" != 0 ] || [ "$backup_len" -le "$backup_len_old" ] && {
			rm "$temp_file" 2>/dev/null
			die "Failed to back up ipset '$ipset'."
		}
		echo "Ok."
	done

	printf %s "Compressing backup... "
	$compr_cmd < "$temp_file" > "${bk_file}.new"; rv=$?
	[ "$rv" != 0 ] || [ ! -s "${bk_file}.new" ] && {
			rm "$temp_file" "${bk_file}.new" 2>/dev/null
			die "Failed to compress firewall backup to file '${bk_file}.new' with utility '$compr_cmd'."
		}

	echo "Ok."
	rm "$temp_file" 2>/dev/null

	cp "$conf_file" "$conf_file_backup" || { rm "${bk_file}.new"; die "Error creating a backup copy of the config file."; }

	mv "${bk_file}.new" "$bk_file" || die "Failed to overwrite file '$bk_file'."

	# save backup file full path to the config file
	setconfig "BackupFile=$bk_file"
}

# detects archive type (if any) of file passed in 1st argument by its extension
# and sets the $extract_cmd variable accordingly
set_extract_cmd() {
	set_extr_cmd() { checkutil "$1" && extract_cmd="$1 -cd" ||
		die "Error: backup archive type is '$1' but the $1 utility is not found."; }

	debugprint "Backup file: '$1'"
	filename="$(basename "$1")"
	file_ext="${filename##*.}"
	case "$file_ext" in
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

conf_file_backup="$datadir/${proj_name}.conf.bak"

#### CHECKS

[ ! -f "$conf_file" ] && die "Config file '$conf_file' doesn't exist! Run the installation script again."


#### MAIN

case "$action" in
	create-backup)
		create_backup
		printf '\n%s\n%s\n' "Successfully created backup of config, ipsets and iptables rules." "Backup file: '$bk_file'"
		;;
	restore)
		restorebackup
		printf %s "Restoring the config file from backup... "
		cp "$conf_file_backup" "$conf_file" || die "Error."
		printf '%s\n\n'  "Ok."
		# save backup file full path to the config file
		setconfig "BackupFile=$bk_file"
		echolog "Successfully restored ipset and iptables state from backup."
		statustip
		;;
	*) unknownact
esac

exit 0
