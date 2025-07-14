#!/bin/sh
# shellcheck disable=SC2006,SC2154,SC2010

# geoip-shell-lib-non-owrt.sh

# checks for supported shell and presence of some other required utilities

# Copyright: antonk (antonk.d3v@gmail.com)
# github.com/friendly-bits

# check for common deps
check_common_deps() {
	for dep in grep tr cut sort wc awk sed logger pgrep pidof; do
		hash "$dep" 2>/dev/null || { echo "Error: missing dependency: '$dep'"; exit 1; }
	done
}

check_shell() {
	if [ -n "$curr_sh_g" ]; then return 0; fi
	fast_sh="dash|ash|yash|ksh93|ksh|busybox sh|busybox"
	slow_sh="mksh|lksh|bash"
	compat_sh="${fast_sh}|${slow_sh}"
	incompat_sh="zsh|csh|posh"

	# not assuming a compatible shell at this point
	_g_test=`echo 0112 | grep -oE '1{2}'` # backticks on purpose
	if [ "$_g_test" != 11 ]; then echo "Error: grep doesn't support the required options." >&2; exit 1; fi

	# check for proc
	if [ ! -d "/proc" ]; then echo "Error: /proc not found."; exit 1; fi

	# check for supported shell
	if command -v readlink 1>/dev/null; then
		curr_sh_g=`readlink /proc/$$/exe`
	fi
	if [ -z "$curr_sh_g" ]; then
		curr_sh_g=`ls -l /proc/$$/exe | grep -oE '/[^[:space:]]+$'`
	fi

	ok_sh=`printf %s "$curr_sh_g" | grep -E "/($compat_sh)"`
	if [ -z "$curr_sh_g" ]; then
		echo "Warning: failed to identify current shell. $p_name may not work correctly. Please notify the developer." >&2
	elif [ -z "$ok_sh" ]; then
		bad_sh=`echo "$curr_sh_g" | grep -E "$incompat_sh"`
		if [ -n "$bad_sh" ]; then
			echo "Error: incompatible shell $curr_sh_g." >&2
			while [ "$n" -le 6 ]; do
				___sh="${compat_sh%%"|"*}"
				compat_sh="${compat_sh#*"|"}"
				if command -v "$___sh" 1>/dev/null; then
					case "$___sh" in *busybox*) ___sh="busybox sh"; esac
					echo "This system has a compatible shell '$___sh', you can use it with $p_name: '$___sh ${p_name}-install.sh'."
					break
				fi
				if [ -z "$compat_sh" ]; then break; fi
			done
			exit 1
		else
			echo "Warning: whether $p_name works with your shell $blue$curr_sh_g$n_c is currently unknown. Please test and notify the developer." >&2
		fi
	fi
	case "$curr_sh_g" in *busybox*) curr_sh_g="/bin/busybox sh"; esac
	export curr_sh_g
}

# returns 0 if crontab is readable and cron or crond process is running, 1 otherwise
# sets $cron_reboot if above conditions are satisfied and cron is not implemented via the busybox binary
check_cron() {
	check_cron_path() {
		cron_rl_path="$(ls -l "$1" 2>/dev/null)" || {
			debugprint "Path '$1' not found"
			return 1
		}
		debugprint "check_cron: Found real path: '/${cron_rl_path#*/}'."
		# check for busybox cron
		case "$cron_rl_path" in
			*busybox*)
				debugprint "Detected Busybox cron."
				;;
			*)
				debugprint "Detected non-Busybox cron."
				cron_reboot=1
		esac
		[ "$force_cron_persist" = true ] && {
			debugprint "\$force_cron_persist is true."
			cron_reboot=1
		}
		cron_rv=0
		:
	}

	try_pidof() {
		pidof "$1" 1>/dev/null && cron_path="$(command -v "$1")"
	}

	try_pgrep() {
		cron_path="$(pgrep -af "/$1" | awk "BEGIN{rv=1} \$2 ~ /\/${1}\$/ {print \$2; rv=0; exit} END{exit rv}")"
	}

	debugprint "check_cron: \$no_persist is '$no_persist'. \$cron_rv is '$cron_rv'."
	[ "$cron_rv" = 0 ] && return 0

	unset cron_reboot cron_path
	export cron_reboot cron_rv=1

	# check for crontab command
	checkutil crontab || {
		debugprint "check_cron: crontab command not found."
		cron_rv=3
		return 3
	}

	# check reading crontab
	try_read_crontab || {
		debugprint "check_cron: $FAIL read crontab."
		cron_rv=2
		return 2
	}

	# check for cron or crond in running processes
	for try_cmd in try_pidof try_pgrep; do
		try_cmd_n="${try_cmd#try_}"
		debugprint "check_cron: Trying with '${try_cmd_n}'..."
		for cron_cmd in crond fcron cron; do
			debugprint "Checking '$cron_cmd'"
			if $try_cmd "$cron_cmd"; then
				debugprint "${try_cmd_n} found '$cron_cmd', path: '$cron_path'"
				check_cron_path "$cron_path"
				case $? in
					0) break 2 ;;
					1) continue
				esac
			else
				debugprint "${try_cmd_n} didn't find '$cron_cmd'"
				continue
			fi
		done
	done

	debugprint "check_cron: returning '$cron_rv'"
	return "$cron_rv"
}

# checks if the cron service is running and if it supports features required by the config
# if cron service is not running, implements dialog with the user and optional automatic correction
check_cron_compat() {
	[ "$schedule" = disable ] && [ "$no_persist" = true ] && return 0
	cr_p2="persistence and " cr_p3="automatic IP list updates"
	i=0
	while [ $i -le 1 ]; do
		i=$((i+1))
		# check if cron is running
		check_cron && {
			[ $i = 2 ] && {
				OK
				printf '%s\n%s\n%s' "Please restart the device after completing setup." \
					"Then run '$p_name configure' and $p_name will check the cron service again." \
					"Press Enter to continue "
				read -r dummy
			}
			break
		}
		[ $i = 2 ] && { FAIL; die; }
		case $cron_rv in
			1)
				cron_err_msg_1="cron is not running"
				cron_err_msg_2="The cron service needs to be enabled and started in order for ${cr_p2}${cr_p3} to work"
				autosolution_msg="enable and start the cron service" ;;
			2)
				cron_err_msg_1="initial crontab file does not exist for user root"
				cron_err_msg_2="The initial crontab file must exist so geoip-shell can create cron jobs for ${cr_p2}${cr_p3}"
				autosolution_msg="create the initial crontab file" ;;
			3)
				cron_err_msg_1="'crontab' utility not found. This usually means that cron is not installed."
				cron_err_msg_2="cron is required for ${cr_p2}${cr_p3}"
		esac
		echo
		echolog -err "$cron_err_msg_1." "$cron_err_msg_2." \
			"If you want to use $p_name without ${cr_p2}${cr_p3}," \
			"configure $p_name with options '-n true' '-s disable'."
		[ "$nointeract" ] && {
			echolog "Please run '$p_name configure' without the option '-z' in order to have $p_name enable the cron service for you."
			die
		}
		[ "$cron_rv" = 3 ] && { echolog "Please install cron, then run '$p_name configure'."; die; }

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
		debugprint "check_cron_compat: initsys is '$initsys'"
		for cron_cmd in crond cron cronie fcron dcron; do
			debugprint "check_cron_compat: trying '$cron_cmd'"
			case "$initsys" in
				systemd) systemctl status $cron_cmd; [ $? = 4 ] && continue
						systemctl is-enabled "$cron_cmd" || systemctl enable "$cron_cmd"
						systemctl start "$cron_cmd" ;;
				sysvinit) checkutil update-rc.d && {
							update-rc.d $cron_cmd enable
							service $cron_cmd start; }
						checkutil chkconfig && {
							chkconfig $cron_cmd on
							service $cron_cmd start; } ;;
				upstart) rm -f "/etc/init/$cron_cmd.override" ;;
				openrc) rc-update add $cron_cmd default || continue
			esac

			[ -f "/etc/init.d/$cron_cmd" ] && {
				/etc/init.d/$cron_cmd enable
				/etc/init.d/$cron_cmd start
			}
			unisleep
			check_cron && break
		done 2>&1 |
		if [ -n "$debugmode" ]; then cat 1>&2; else cat 1>/dev/null; fi
	done

	[ ! "$cron_reboot" ] && [ "$no_persist" != true ] && {
		echolog -err "Detected Busybox cron service. cron-based persistence may not work with Busybox cron on this device." \
		"If you want to use $p_name without persistence support, run '$p_name configure -n true'." \
		"If you want to force cron-based persistence support, run '$p_name configure -n false -P true'." \
		"Reboot after installation and run 'geoip-shell status' to verify that persistence is working."
		return 1
	}
	:
}

:
