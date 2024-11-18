#!/bin/sh
# shellcheck disable=SC2154,SC1090

# geoip-shell-lib-uninstall.sh

# library used to uninstall or reset geoip-shell

# Copyright: antonk (antonk.d3v@gmail.com)
# github.com/friendly-bits


# kills any running geoip-shell scripts and downloads
kill_geo_pids() {
	get_ps_pid() {
		_pid="${1%% *}"
		case "$_pid" in
			*[!0-9]*)
				debugprint "get_ps_pid: invalid pid '$_pid'"
				return 1 ;;
		esac
		:
	}

	kill_ps() {
		debugprint "killing pid '$1' matching '$2'"
		pgrep -fa "$1" | awk '{print $1 " " $2 " " $3}' >&2
		kill "$1" 2>/dev/null
		_killed=1
	}

	get_parents_pids() {
		parent_pids="${$}|"
		last_pid="${$}"
		i_gpp=0
		while [ $i_gpp -le 24 ]; do
			i_gpp=$((i_gpp+1))
			SPPID="$(
				skipped='' prev_str=''
				tr ' ' '\n' 2>/dev/null < "/proc/$last_pid/stat" | \
				while IFS='' read -r str; do
					case "$prev_str" in
						*')'*) ;;
						*) prev_str="$str"; continue
					esac
					[ ! "$skipped" ] && { skipped=1; continue; }
					case "$str" in
						*[!0-9]*) continue ;;
						*) printf %s "$str"; break
					esac
				done
			)"
			[ ! "$SPPID" ] && break
			last_pid="$SPPID"
			parent_pids="${parent_pids}${SPPID}|"
		done
		printf %s "${parent_pids%|}"
	}

	all_parent_pids="$(get_parents_pids)"

	printf '\n%s\n' "Killing any running $p_name processes..."

	[ "$debugmode" ] && debugprint "parent pids: '$all_parent_pids'"

	i_kgp=0
	newifs "$default_IFS" kgp
	while :; do
		i_kgp=$((i_kgp+1))
		_killed=

		_geo_ps="$(
			pgrep -fa "$p_name" | \
			grep -Ev "(^${all_parent_pids}|(/usr/bin/)*$p_name(-manage.sh)* stop)[[:blank:]]|pgrep)" | \
			grep -E "(^[[:blank:]]*[0-9][0-9]*${blanks}(sudo )*${p_name}|/usr/bin/${p_name}([^[:blank:]]*sh)*)([[:blank:]]|$)"
		)"

		[ "$debugmode" ] && debugprint "_geo_ps: '$(printf %s "$_geo_ps" | awk '{print $1 " " $2 " " $3 " " $4}')'"

		_dl_ps="$(
			pgrep -fa "($ripe_url_stats|$ripe_url_api|$ipdeny_ipv4_url|$ipdeny_ipv6_url)" | \
			grep -v pgrep | grep -E '[[:blank:]](curl|wget|uclient-fetch)([[:blank:]]|$)'
		)"

		[ "$debugmode" ] && debugprint "_dl_ps: '$(printf %s "$_dl_ps" | awk '{print $1 " " $2 " " $3 " " $4}')'"

		for g in "" manage run backup apply fetch cronsetup; do
			kgp_script="${p_name}-${g}.sh"
			[ ! "$g" ] && kgp_script="$p_name"

			IFS="$_nl"
			for entry in $_geo_ps; do
				IFS="$default_IFS"
				get_ps_pid "$entry" || continue

				case "$entry" in "$kgp_script"|*" /usr/bin/$kgp_script "*|*" /usr/bin/$kgp_script"|"/usr/bin/$kgp_script "*)
					kill_ps "$_pid" "$kgp_script"
					continue 2
				esac
			done
		done

		IFS="$_nl"
		for entry in $_dl_ps; do
			IFS="$default_IFS"
			get_ps_pid "$entry" || continue
			for g in curl uclient-fetch wget; do
				case "$entry" in *"$g"*)
					kill_ps "$_pid" "$g"
					continue 2
				esac
			done
		done

		if [ ! "$_killed" ] || [ $i_kgp -gt 30 ]; then
			oldifs kgp
			return 0
		fi
		sleep 1
	done
	oldifs kgp
}

rm_iplists_rules() {
	case "$iplist_dir" in
		*"$p_name"*) rm_geodir "$iplist_dir" iplist ;;
		*)
			# remove individual iplist files if iplist_dir is shared with non-geoip-shell files
			[ "$iplist_dir" ] && [ -d "$iplist_dir" ] && {
				echo "Removing $p_name ip lists..."
				set +f
				rm -f "${iplist_dir:?}"/*.iplist
				set -f
			}
	esac

	### Remove geoip firewall rules
	[ "$_fw_backend" ] && rm_all_georules || {
		[ "$in_uninstall" ] && echolog -err "$FAIL remove $p_name firewall rules. Please restart the machine after uninstallation."
	}

	:
}

rm_cron_jobs() {
	case "$(crontab -u root -l 2>/dev/null)" in *"${p_name}-run.sh"*)
		echo "Removing cron jobs..."
		crontab -u root -l 2>/dev/null | grep -v "${p_name}-run.sh" | crontab -u root -
	esac
	:
}

# 1 - dir path
# 2 - dir description
rm_geodir() {
	[ "$1" ] && [ -d "$1" ] && {
		printf '%s\n' "Deleting the $2 directory '$1'..."
		rm -rf "$1"
	}
}

rm_data() {
	rm_geodir "$datadir"/backup backup
	rm -f "$datadir"/status
	{ find "$datadir" | head -n2 | grep -v "^$datadir\$"; } 1>/dev/null 2>/dev/null || rm_geodir "$datadir" data
	:
}

rm_symlink() {
	rm -f "${install_dir}/${p_name}"
}

rm_config() {
	rm_geodir "$conf_dir" config
	:
}

rm_setupdone() {
	rm -f "$conf_dir/setupdone"
}


[ ! "$_fw_backend" ] && [ "$root_ok" ] && {
	if [ "$_OWRTFW" ]; then
		[ "$_OWRTFW" = 4 ] && _fw_backend=nft || _fw_backend=ipt
	elif [ -f "$_lib-check-compat.sh" ]; then
		. "$_lib-check-compat.sh"
		if check_fw_backend nft; then
			_fw_backend=nft
		elif check_fw_backend ipt; then
			_fw_backend=ipt
		fi
	fi 2>/dev/null
}

: