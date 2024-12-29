#!/bin/sh
# shellcheck disable=SC2154,SC2034,SC2086

# common functions and variables for OpenWrt-related geoip-shell scripts

# Copyright: antonk (antonk.d3v@gmail.com)
# github.com/friendly-bits


checkutil () { command -v "$1" 1>/dev/null; }

detect_fw_backend() {
	case "$_OWRTFW" in
		3) printf ipt ;;
		4) printf nft ;;
		*) echolog -err "Invalid OpenWrt firewall version '$_OWRTFW'."; return 1
	esac
	:
}

enable_owrt_persist() {
	[ "$no_persist" = true ] && {
		printf '%s\n\n' "Installed without persistence functionality."
		return 1
	}

	rm -f "$conf_dir/no_persist"
	! check_owrt_init && {
		[ -s "$init_script" ] || {
			echolog -err "The init script '$init_script' is missing. Please reinstall $p_name."
			return 1
		}
		printf %s "Enabling the init script... "
		$init_script enable
		check_owrt_init || { FAIL; echolog -err "$FAIL enable '$init_script'."; return 1; }
		OK
	}
	/bin/sh "$install_dir/${p_name}-mk-fw-include.sh"
}

disable_owrt_persist() {
	[ ! -f "$conf_dir/no_persist" ] && touch "$conf_dir/no_persist"
	[ ! -s "$init_script" ] ||
	{
		printf %s "Disabling the init script... "
		$init_script disable && ! check_owrt_init ||
			{ echolog -err "$FAIL disable the init script '$init_script'."; return 1; }
		OK
	} &&
	{
		rm_owrt_fw_include
		reload_owrt_fw
	}
	:
}

check_owrt_init() {
	set +f
	for f in /etc/rc.d/S*"${p_name}-init"; do
		[ -s "$f" ] && { set -f; return 0; }
	done
	set -f
	return 1
}

# checks value in uci for firewall.geoip_shell.$1
# 1 - option
# 2 - value
check_uci_ent() { [ "$(uci -q get firewall."$p_name_c.$1")" = "$2" ]; }

# checks the firewall include for geoip-shell in uci
check_owrt_include() {
	check_uci_ent enabled 1 || return 1
	[ "$_OWRTFW" = 4 ] && return 0
	check_uci_ent reload 1
}

rm_owrt_fw_include() {
	uci -q get firewall."$p_name_c" 1>/dev/null || return 0
	printf %s "Removing the firewall include... "
	uci -q delete firewall."$p_name_c" 1>/dev/null && OK || FAIL

	echo "Committing fw$_OWRTFW changes..."
	uci commit firewall
	:
}

rm_owrt_init() {
	[ ! -s "$init_script" ] && return 0
	echo "Deleting the init script..."
	$init_script disable 2>/dev/null && rm -f "$init_script"
}

restart_owrt_fw() {
	echo "Restarting firewall$_OWRTFW..."
	fw$_OWRTFW -q restart
	:
}

reload_owrt_fw() {
	echo "Reloading firewall$_OWRTFW..."
	fw$_OWRTFW -q reload
	:
}

# returns 0 if crontab is readable and cron or crond process is running, 1 otherwise
# sets $cron_reboot if above conditions are satisfied and cron is not implemented via the busybox binary
check_cron() {
	[ "$cron_rv" = 0 ] && return 0
	export cron_rv=1

	# check reading crontab
	try_read_crontab || {
		cron_rv=2
		return 2
	}

	cron_path="/usr/sbin/crond"
	pgrep -x "$cron_path" 1>/dev/null && cron_rv=0
	return "$cron_rv"
}

# checks if the cron service is running and if it supports features required by the config
# if cron service is not running, implements dialog with the user and optional automatic correction
check_cron_compat() {
	[ "$schedule" = disable ] && return 0
	cr_p2="automatic ip list updates"
	i=0
	while [ $i -le 1 ]; do
		i=$((i+1))
		# check if cron is running
		check_cron && {
			[ $i = 2 ] && OK
			break
		}
		[ $i = 2 ] && { FAIL; die; }
		case $cron_rv in
			1)
				cron_err_msg_1="cron is not running"
				cron_err_msg_2="The cron service needs to be enabled and started in order for ${cr_p2} to work"
				autosolution_msg="enable and start the cron service" ;;
			2)
				cron_err_msg_1="initial crontab file does not exist for user root"
				cron_err_msg_2="The initial crontab file must exist so geoip-shell can create cron jobs for ${cr_p2}"
				autosolution_msg="create the initial crontab file" ;;
		esac
		echo
		echolog -err "$cron_err_msg_1." "$cron_err_msg_2." \
			"If you want to use $p_name without ${cr_p2}," \
			"configure $p_name with option '-s disable'."
		[ "$nointeract" ] && {
			echolog "Please run '$p_name configure' in order to have $p_name enable the cron service for you."
			die
		}

		printf '\n%s\n' "Would you like $p_name to $autosolution_msg? [y|n]."
		pick_opt "y|n"
		[ "$REPLY" = n ] && die

		# if reading crontab fails, try to create an empty crontab
		try_read_crontab || {
			printf '\n%s' "Attempting to create a new crontab file for root... "
			printf '' | crontab -u root - || { FAIL; die "command \"printf '' | crontab -u root -\" returned error code $?."; }
			try_read_crontab || { FAIL; die "Issued crontab file creation command, still can not read crontab."; }
			OK
			if check_cron; then
				break
			else
				i=0
				continue
			fi
		}

		# try to enable and start cron service
		printf '\n%s' "Attempting to enable and start cron... "
		{
			for f in crond cron; do
				cron_svc_path="/etc/init.d/$f"
				[ -f "$cron_svc_path" ] && break
			done && {
				$cron_svc_path enable
				$cron_svc_path start
				sleep 1
			}
		} 1>/dev/null
	done
	:
}


me="${0##*/}"
p_name_c="${p_name%%-*}_${p_name#*-}"
_OWRTFW=
init_script="/etc/init.d/${p_name}-init"
conf_dir="/etc/$p_name"

# check for OpenWrt firewall version
checkutil uci && checkutil procd && for i in 3 4; do
	[ -x /sbin/fw$i ] && export _OWRTFW="$i"
done

[ -z "$_OWRTFW" ] && {
	logger -s -t "$me" -p user.warn "Warning: Detected procd init but no OpenWrt firewall."
	return 0
}
curr_sh_g="/bin/sh"
:
