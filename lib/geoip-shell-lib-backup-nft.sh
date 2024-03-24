#!/bin/sh
# shellcheck disable=SC2154,SC1090

# geoip-shell-backup-nft.sh

# nftables-specific library for the -backup script

. "$_lib-nft.sh" || die


#### FUNCTIONS

# resets firewall rules, destroys geoip ipsets and then initiates restore from file
restorebackup() {
	printf %s "Restoring files from backup... "
	for list_id in $config_lists; do
		bk_file="$bk_dir/$list_id.$bk_ext"
		iplist_file="$iplist_dir/${list_id}.iplist"

		[ ! -s "$bk_file" ] && rstr_failed "'$bk_file' is empty or doesn't exist."

		# extract elements and write to $iplist_file
		$extract_cmd "$bk_file" > "$iplist_file" || rstr_failed "$FAIL extract backup file '$bk_file'."
		[ ! -s "$iplist_file" ] && rstr_failed "$FAIL extract ip list for $list_id."
		# count lines in the iplist file
		line_cnt=$(wc -l < "$iplist_file")
		debugprint "\nLines count in $list_id backup: $line_cnt"
	done

	cp "$status_file_bak" "$status_file" || rstr_failed "$FAIL restore the status file."
	cp "$conf_file_bak" "$conf_file" || rstr_failed "$FAIL restore the config file."

	OK

	# remove geoip rules
	rm_all_georules || rstr_failed "$FAIL remove firewall rules."

	call_script "${i_script}-apply.sh" add -l "$config_lists"; apply_rv=$?
	rm "$iplist_dir/"*.iplist 2>/dev/null
	[ "$apply_rv" != 0 ] && rstr_failed "$FAIL restore the firewall state from backup." "reset"
	:
}

rm_rstr_tmp() {
	rm "$iplist_dir/"*.iplist 2>/dev/null
}

rstr_failed() {
	rm_rstr_tmp
	[ "$1" ] && echolog -err "$1"
	[ "$2" = reset ] && {
		echolog -err "*** Geoip blocking is not working. Removing geoip firewall rules. ***"
		rm_all_georules
	}
	die
}

rm_bk_tmp() {
	rm -f "$tmp_file" "$bk_dir/"*.new 2>/dev/null
}

bk_failed() {
	rm_bk_tmp
	die "$FAIL back up $p_name ip sets."
}

# Saves current firewall state to a backup file
create_backup() {
	# back up current ip sets
	printf %s "Creating backup of $p_name ip sets... "
	getstatus "$status_file" || bk_failed
	for list_id in $config_lists; do
		bk_file="${bk_dir}/${list_id}.${bk_ext:-bak}"
		iplist_file="$iplist_dir/${list_id}.iplist"
		eval "list_date=\"\$prev_date_${list_id}\""
		[ -z "$list_date" ] && bk_failed
		ipset="${list_id}_${list_date}_${geotag}"

		rm "$tmp_file" 2>/dev/null
		# extract elements and write to $tmp_file
		nft list set inet "$geotable" "$ipset" |
			sed -n -e /"elements[[:space:]]*=[[:space:]]*{"/\{ -e p\;:1 -e n\; -e p\; -e /\}/q\;b1 -e \} > "$tmp_file"
		[ ! -s "$tmp_file" ] && bk_failed

		[ "$debugmode" ] && bk_len="$(wc -l < "$tmp_file")"
		debugprint "\n$list_id backup length: $bk_len"

		$compr_cmd < "$tmp_file" > "${bk_file}.new"; rv=$?
		[ "$rv" != 0 ] || [ ! -s "${bk_file}.new" ] && bk_failed
	done
	OK

	for f in "${bk_dir}"/*.new; do
		mv -- "$f" "${f%.new}" || bk_failed
	done
	:
}
