#!/bin/sh
# shellcheck disable=SC2015,SC2317,SC2034,SC2154,SC2086,SC1090

# geoip-shell-backup-ipt.sh

. "$_lib-ipt.sh" || die


#### FUNCTIONS

# resets iptables policies and rules, destroys associated ipsets and then initiates restore from file
restorebackup() {
	# outputs the iptables portion of the backup file for $family
	get_iptables_bk() {
		sed -n -e /"\[${p_name}_IPTABLES_$family\]"/\{:1 -e n\;/\\["${p_name}_IP"/q\;p\;b1 -e \} < "$tmp_file"
	}
	# outputs the ipset portion of the backup file
	get_ipset_bk() { sed -n "/create ${p_name}/,\$p" < "$tmp_file"; }

	printf '%s\n' "Restoring firewall state from backup... "

	[ -z "$bk_file" ] && die "Can not restore the firewall state: no backup found."
	[ ! -f "$bk_file" ] && die "Can not find the backup file '$bk_file'."

	# extract the backup archive into tmp_file
	tmp_file="/tmp/${p_name}_backup.tmp"
	$extract_cmd "$bk_file" > "$tmp_file" || rstr_failed "$FAIL extract backup file '$bk_file'."
	[ ! -s "$tmp_file" ] && rstr_failed "$ERR backup file '$bk_file' is empty or backup extraction failed."

	printf '%s\n\n' "Successfully read backup file: '$bk_file'."

	printf %s "Checking the iptables portion of the backup file... "

	# count lines in the iptables portion of the backup file
	for family in $families; do
		line_cnt=$(get_iptables_bk | wc -l)
		debugprint "Firewall $family lines number in backup: $line_cnt"
		[ "$line_cnt" -lt 2 ] && rstr_failed "$ERR firewall $family backup appears to be empty or non-existing."
	done
	OK

	printf %s "Checking the ipset portion of the backup file... "
	# count lines in the ipset portion of the backup file
	line_cnt=$(get_ipset_bk | grep -c "add ${p_name}")
	debugprint "ipset lines number in backup: $line_cnt"
	[ "$line_cnt" = 0 ] && rstr_failed "$ERR ipset backup appears to be empty or non-existing."
	OK; echo

	### Remove geoip iptables rules and ipsets
	rm_all_georules || rstr_failed "$FAIL remove firewall rules and ipsets."

	echo

	# ipset needs to be restored before iptables
	for restoretgt in ipset iptables; do
		printf %s "Restoring $restoretgt state... "
		case "$restoretgt" in
			ipset) get_ipset_bk | ipset restore; rv=$? ;;
			iptables)
				rv=0
				for family in $families; do
					set_ipt_cmds
					get_iptables_bk | $ipt_restore_cmd; rv=$((rv+$?))
				done ;;
		esac

		case "$rv" in
			0) OK ;;
			*) FAIL >&2
			rstr_failed "$FAIL restore $restoretgt state from backup." "reset"
		esac
	done

	rm "$tmp_file" 2>/dev/null

	cp "$status_file_bak" "$status_file" || rstr_failed "$FAIL restore the status file."
	cp "$conf_file_bak" "$conf_file" || rstr_failed "$FAIL restore the config file."

	# save backup file full path to the config file
	setconfig "BackupFile=$bk_file" || rstr_failed

	:
}

rstr_failed() {
	rm "$tmp_file" 2>/dev/null
	echolog -err "$1"
	[ "$2" = reset ] && {
		echolog -err "*** Geoip blocking is not working. Removing geoip firewall rules and the associated cron jobs. ***"
		call_script "$script_dir/${p_name}-uninstall.sh" -c
	}
	die
}

bk_failed() {
	rm "$tmp_file" "${bk_file}.new" 2>/dev/null
	die "$1"
}

# Saves current firewall state to a backup file
create_backup() {
	printf %s "Creating backup of current $p_name state... "

	bk_len=0
	for family in $families; do
		set_ipt_cmds
		printf '%s\n' "[${p_name}_IPTABLES_$family]" >> "$tmp_file" &&
		printf '%s\n' "*$ipt_table" >> "$tmp_file" &&
		$ipt_save_cmd | grep -i "$geotag" >> "$tmp_file" &&
		printf '%s\n' "COMMIT" >> "$tmp_file" || bk_failed "$FAIL back up $p_name state."
	done
	OK

	bk_len="$(wc -l < "$tmp_file")"
	printf '%s\n' "[${p_name}_IPSET]" >> "$tmp_file"

	for ipset in $(ipset list -n | grep $geotag); do
		printf %s "Creating backup of ipset '$ipset'... "

		# append current ipset content to tmp_file
		ipset save "$ipset" >> "$tmp_file"; rv=$?

		bk_len_old=$(( bk_len + 1 ))
		bk_len="$(wc -l < "$tmp_file")"
		[ "$rv" != 0 ] || [ "$bk_len" -le "$bk_len_old" ] && bk_failed "$FAIL back up ipset '$ipset'."
		OK
	done

	printf %s "Compressing backup... "
	$compr_cmd < "$tmp_file" > "${bk_file}.new" &&  [ -s "${bk_file}.new" ] ||
		bk_failed "$FAIL compress firewall backup to file '${bk_file}.new'."

	mv "${bk_file}.new" "$bk_file" || bk_failed "$FAIL overwrite file '$bk_file'."
	:
}
