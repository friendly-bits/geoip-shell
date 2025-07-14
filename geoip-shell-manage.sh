#!/bin/sh
# shellcheck disable=SC2154,SC2086,SC1090,SC2034

# geoip-shell-manage.sh

# Copyright: antonk (antonk.d3v@gmail.com)
# github.com/friendly-bits

#### Initial setup
p_name="geoip-shell"
export inbound_geomode nolog=1 manmode=1

. "/usr/bin/${p_name}-geoinit.sh" &&
script_dir="$install_dir" &&
. "$_lib-setup.sh" &&
. "$_lib-uninstall.sh" || exit 1

san_args "$@"
newifs "$delim"
set -- $_args; oldifs

#### USAGE

# vars for usage()
ccodes_syn="<\"country_codes\">"
mode_syn="<whitelist|blacklist|disable>"

usage() {

cat <<EOF

Usage: ${blue}$me <action> [options]${n_c}

Provides interface to configure geoblocking.

${purple}Actions${n_c}:
  ${blue}configure${n_c}  :  change $p_name config
  ${blue}status${n_c}     :  check on the current status of geoblocking
  ${blue}reset${n_c}      :  reset geoip config and firewall geoip rules
  ${blue}restore${n_c}    :  re-apply geoblocking rules from the config
  ${blue}showconfig${n_c} :  print the contents of the config file
  ${blue}on|off${n_c}     :  enable or disable the geoblocking chain (via a rule in the base geoip chain)
  ${blue}stop${n_c}       :  kill any running geoip-shell processes, remove geoip-shell firewall rules and unload IP sets

${purple}'configure' action${n_c}:
  General syntax: ${blue}configure [options] [-D $direction_syn <options>]${n_c}
  Example: '$p_name configure inbound <options>' configures inbound traffic geoblocking.

  To configure separately inbound and outbound geoblocking in one command, use the direction keyword twice. Example:
    '$p_name configure -D inbound <options> -D outbound <options>'
  If direction (inbound|outbound) is not specified, defaults to configuring inboud traffic geoblocking. Example:
    '$p_name configure <options>'

${purple}Options for 'configure -D $direction_syn'${n_c}
  (affects geoblocking in the specified direction, or inbound if direction not specified):

  ${blue}-m $mode_syn${n_c} : Geoblocking mode: whitelist, blacklist or disable.
${sp8}'disable' removes all previous config options for specified direction and disables geoblocking for it.

  ${blue}-c $ccodes_syn${n_c} : 2-letter country codes to include in whitelist/blacklist.
${sp8}If passing multiple country codes, use double quotes.

  ${blue}-p <[tcp|udp]:[allow|block]:[all|<ports>]>${n_c} :
${sp8}For given protocol (tcp/udp), use 'block' to geoblock traffic on specific ports or on all ports.
${sp8}or use 'allow' to geoblock all traffic except on specific ports.
${sp8}To specify ports for both tcp and udp in one command, use the '-p' option twice.

${purple}General options for the 'configure' action${n_c} (affects geoblocking in both directions):

  ${blue}-f <ipv4|ipv6|"ipv4 ipv6">${n_c} : IP families (defaults to 'ipv4 ipv6'). Use double quotes for multiple families.

  ${blue}-u $srcs_syn${n_c} : Use this IP list source for download. Supported sources: ripe, ipdeny, maxmind.

  ${blue}-i <"[ifaces]"|auto|all>${n_c} :
${sp8}Changes which network interface(s) geoblocking firewall rules will be applied to.
${sp8}'all' will apply geoblocking to all network interfaces.
${sp8}'auto' will automatically detect WAN interfaces (this may cause problems if the machine has no direct WAN connection).
${sp8}Generally, if the machine has dedicated WAN interfaces, specify them, otherwise pick 'all'.

  ${blue}-l <"[lan_ips]"|auto|none>${n_c} :
${sp8}Specifies LAN IPs or subnets to exclude from geoblocking (both ipv4 and ipv6).
${sp8}Only compatible with whitelist mode.
${sp8}Generally, in whitelist mode, if the machine has no dedicated WAN interfaces,
${sp8}specify LAN IPs or subnets to avoid blocking them. Otherwise you probably don't need this.
${sp8}'auto' will automatically detect LAN subnets during the initial setup and at every update of the IP lists.
${sp8}'none' removes previously set LAN IPs and disables the automatic detection.
${sp8}*Don't use 'auto' if the machine has a dedicated WAN interface*

  ${blue}-t <"[trusted_ips]"|none>${n_c} :
${sp8}Specifies trusted IPs or subnets to exclude from geoblocking (both ipv4 and ipv6).
${sp8}This option is independent from the above LAN IPs option.
${sp8}Works both in whitelist and blacklist mode.
${sp8}'none' removes previously set trusted IPs

  ${blue}[-A|-B] <"[path_to_file]"|remove>${n_c} :
${sp8}Specifies local file containing a list of IPs or subnets to import into geoip-shell (one IP family per file).
${sp8}Use '-A' for allowlist, '-B' for blocklist.
${sp8}Rules for local IP lists will be applied regardless of whether geoblocking mode is whitelist or blacklist, and regardless of direction.
${sp8}'remove' removes existing local allowlists or blocklists.

  ${blue}-U <auto|pause|none|"[ip_addresses]">${n_c} :
${sp8}Policy for allowing automatic IP list updates when outbound geoblocking is enabled.
${sp8}Use 'auto' to detect IP addresses automatically once and always allow outbound connection to detected addresses.
${sp8}Or use 'pause' to always temporarily pause outbound geoblocking before fetching IP list updates.
${sp8}Or specify IP addresses for IP lists source (ripe, ipdeny or maxmind) to allow - for multiple addresses, use double quotes.
${sp8}Or use 'none' to remove previously assigned server IP addresses and disable this feature.

  ${blue}-r <[user_country_code]|none>${n_c} :
${sp8}Specify user's country code. Used to prevent accidental lockout of a remote machine.
${sp8}'none' disables this feature.

  ${blue}-o <true|false>${n_c} :
${sp8}No backup. If set to 'true', $p_name will not create a backup of IP lists and firewall rules state after applying changes,
${sp8}and will automatically re-fetch IP lists after each reboot.
${sp8}Default is 'true' for OpenWrt, 'false' for all other systems.

  ${blue}-a <"path">${n_c} :
${sp8}Set custom path to directory where backups and the status file will be stored.
${sp8}Default is '/tmp/$p_name-data' for OpenWrt, '/var/lib/$p_name' for all other systems.

  ${blue}-L <"path">${n_c} :
${sp8}Set custom path to directory where local IP lists will be stored.
${sp8}Default is '/etc/$p_name' for OpenWrt, '/var/lib/$p_name' for all other systems.

  ${blue}-s <"[expression]"|disable>${n_c} :
${sp8}Schedule expression for the periodic cron job implementing automatic update of the IP lists, must be inside double quotes.
${sp8}Example expression: "15 4 * * *" (at 4:15 [am] every day)
${sp8}'disable' will disable automatic updates of the IP lists.

  ${blue}-w <ipt|nft>${n_c} :
${sp8}Specify firewall backend to use with $p_name. 'ipt' for iptables, 'nft' for nftables.
${sp8}Default is nftables if present in the system.

  ${blue}-O <memory|performance>${n_c} :
${sp8}Optimization policy for nftables sets.
${sp8}By default optimizes for memory if the machine has less than 2GiB of RAM, otherwise for performance.
${sp8}Doesn't work with iptables.

  ${blue}-N <true|false>${n_c} :
${sp8}No Block: Skip creating the rule which redirects traffic to the geoblocking chain.
${sp8}Everything will be installed and configured but geoblocking will not be enabled. Default is false.

  ${blue}-n <true|false>${n_c} :
${sp8}No Persistence: Skip creating the persistence cron job or init script.
${sp8}$p_name will likely not work after reboot. Default is false.

  ${blue}-P <true|false>${n_c} : Force cron-based persistence even when the system may not support it. Default is false.

  ${blue}-K <true|false>${n_c} : Keep and re-use the complete downloaded MaxMind database until it's changed upstream.

${purple}Other options${n_c}:

  -v : Verbose status output
  -z : $nointeract_usage Will fail if required options are not specified or invalid.
  -d : Debug
  -V : Version
  -h : This help

EOF
}


#### PARSE ARGUMENTS

set_opt() {
	var_name="$1"
	[ "$opt" != p ] && {
		eval "oldval=\"\$${1}\""
		[ -n "$oldval" ] && {
			fordirection=
			case "$opt" in m|c) fordirection=" for direction '$direction'"; esac
			die "Option '-$opt' can not be used twice${fordirection}."
		}
	}
	case "$opt" in
		m|c|p) set_directional_opt "$var_name" ;;
		*) eval "$var_name"='$OPTARG'; return 0
	esac
}

set_directional_opt() {
	[ ! "$1" ] && die "set_direction_opt: arg is unset"
	d_var_name="$1"
	[ "$action" != configure ] && { usage; die "Option '-$opt' must be used with the 'configure' action."; }
	case "$direction" in
		inbound|outbound)
			case "$opt" in
				m|c) eval "${direction}_${d_var_name}"='$OPTARG' ;;
				p) eval "${direction}_ports_arg=\"\${${direction}_ports_arg}$OPTARG$_nl\""
			esac ;;
		*) die "Internal error: unexpected direction '$direction'."
	esac
	req_direc_opt=
}

# check for valid action
tolower action "$1"
case "$action" in
	configure) direction=inbound; shift ;;
	status|restore|reset|on|off|stop|showconfig) shift ;;
	*) action="$1"; unknownact
esac

# process the rest of the args
req_direc_opt=
while getopts ":D:m:c:f:s:i:l:t:p:r:u:A:B:U:K:a:L:o:w:O:n:N:P:zvdVh" opt; do
	case $opt in
		D) tolower OPTARG
			case "$OPTARG" in inbound|outbound) ;; *)
				usage; die "Invalid geoblocking direction '$OPTARG'. Use '-D inbound' or '-D outbound'."
			esac
			[ "$action" != configure ] && { usage; die "Action is '$action', but specifying geoblocking direction is only valid for action 'configure'."; }
			[ "$req_direc_opt" ] && { usage; die "Provide valid options for the '$direction' direction."; }
			direction="$OPTARG"
			req_direc_opt=1 ;;
		m) set_opt geomode_arg ;;
		c) set_opt ccodes_arg ;;
		p) set_opt ports_arg ;;

		f) set_opt families_arg ;;
		s) set_opt schedule_arg ;;
		i) set_opt ifaces_arg ;;
		l) set_opt lan_ips_arg ;;
		t) set_opt trusted_arg ;;
		r) set_opt user_ccode_arg ;;
		u) set_opt geosource_arg ;;
		A) set_opt local_allow_arg ;;
		B) set_opt local_block_arg ;;
		U) set_opt source_ips_arg ;;
		K) set_opt keep_mm_db_arg ;;
		a) set_opt datadir_arg ;;
		L) set_opt local_iplists_dir_arg ;;
		w) set_opt _fw_backend_arg ;;
		O) set_opt nft_perf_arg ;;

		o) set_opt nobackup_arg ;;
		n) set_opt no_persist_arg ;;
		N) set_opt noblock_arg ;;
		P) set_opt force_cron_persist_arg ;;

		z) nointeract_arg=1 ;;
		v) verb_status="-v" ;;
		d) debugmode_arg=1 ;;
		V) echo "$curr_ver"; exit 0 ;;
		h) usage; exit 0 ;;
		*) unknownopt
	esac
done
shift $((OPTIND-1))

[ "$req_direc_opt" ] && { usage; die "Provide valid options for direction '$direction'."; }

setdebug
debugentermsg

extra_args "$@"

is_root_ok


#### FUNCTIONS

# 1 - old dir
# 2 - new dir
# 3 - description
dir_mv() {
	prev_dir_mv="$1" new_dir_mv="$2" dir_cont_desc="$3"
	[ -n "${prev_dir_mv}" ] || return 0

	rm -rf "$new_dir_mv"
	dir_mk "$new_dir_mv" || die
	[ -d "$prev_dir_mv" ] || return 0

	if ! is_dir_empty "$prev_dir_mv"; then
		printf %s "Moving $dir_cont_desc to the new path... "
		set +f
		for mv_file in "$prev_dir_mv"/*; do
			if [ ! -d "$mv_file" ]; then
				mv -- "$mv_file" "$new_dir_mv/" || {
					mv "$new_dir_mv"/* "$prev_dir_mv/"
					set -f
					rm -rf "$new_dir_mv"
					die "$FAIL move the $dir_cont_desc."
				}
			fi
		done
		set -f
		OK
	fi

	# remove prev_dir_mv if it's empty
	rm_dir_if_empty "$prev_dir_mv"
}

# restore iplists from the config file
# if that fails, restore from backup
restore_from_config() {
	restore_msg="Restoring $p_name from ${_prev}config... "
	restore_ok_msg="Successfully restored $p_name from ${_prev}config."
	[ "$conf_act" = reset ] && {
		restore_msg="Applying ${_prev}config... "
		restore_ok_msg="Successfully applied ${_prev}config."
	}
	printf '\n%s\n' "$restore_msg"

	rm_iplists_rules || return 1
	rm -f "$status_file"

	# compile run args
	run_args=
	for d in inbound outbound; do
		eval "[ -n \"\${${d}_iplists}\" ] && run_args=\"\${run_args}\${${d}_iplists} \""
	done

	if [ -n "$run_args" ]; then
		# call the -run script
		eval "call_script -l \"$run_command\" add -l \"$run_args\" -o" && {
			printf '%s\n' "$restore_ok_msg"
			return 0
		}
	else
		echo "No IP lists registered - skipping firewall rules creation."
		return 0
	fi

	# Handle failure
	[ "$first_setup" ] && die

	[ ! "$prev_config_try" ] && [ "$prev_config" ] && {
		prev_config_try=1
		export main_config="$prev_config"

		if nodie=1 export_conf=1 get_config_vars && _prev="previous " &&
			[ ! "$_fw_backend_change" ] ||
				{ [ "$_fw_backend_change" ] && [ "$_fw_backend" ] && . "${_lib}-${_fw_backend}.sh"; }; then
					restore_from_config && { set_all_config; return 0; }
		else
			echolog -err "$FAIL load the previous config."
		fi
	}

	# recover from backup
	[ -f "$datadir/backup/$p_name.conf.bak" ] && call_script -l "$i_script-backup.sh" restore && {
		unset main_config
		get_config_vars
		check_lists_coherence && return 0
	}

	die "$FAIL restore $p_name state. If it's a bug then please report it."
}

# tries to prevent the user from locking themselves out
check_for_lockout() {
	# if we don't have user's country code, don't check for lockout
	[ "$user_ccode" = none ] && return 0

	u_ccode="${_nl}Your country code '$user_ccode'"
	lockout_exp=

	for direction in inbound outbound; do
		eval "iplists=\"\$${direction}_iplists\"
			geomode=\"\$${direction}_geomode\"
			geomode_change=\"\$${direction}_geomode_change\"
			lists_change=\"\$${direction}_lists_change\""
		if [ "$first_setup" ] || [ "$geomode_change" ] || [ "$lists_change" ] || [ "$user_ccode_change" ]; then
			ccode_included=
			inlist="in the planned $direction geoblocking $geomode"

			for family in $families; do
				is_included "${user_ccode}_${family}" "$iplists" && ccode_included=1
			done
			case "$geomode" in
				whitelist) [ ! "$ccode_included" ] && { lockout_exp=1; echolog -warn "$u_ccode is not included $inlist."; } ;;
				blacklist) [ "$ccode_included" ] && { lockout_exp=1; echolog -warn "$u_ccode is included $inlist."; }
			esac
		fi
	done

	[ ! "$lockout_exp" ] || [ "$nointeract" ] && return 0

	printf '\n%s\n%s\n' "Make sure you do not lock yourself out." "Proceed?"
	pick_opt "y|n"
	case "$REPLY" in
		y) printf '\n%s\n' "Proceeding..." ;;
		n)
			inbound_geomode="$inbound_geomode_prev"
			outbound_geomode="$outbound_geomode_prev"
			inbound_iplists="$inbound_iplists_prev"
			outbound_iplists="$outbound_iplists_prev"
			[ ! "$first_setup" ] && report_lists
			echo
			echolog "Aborted action '$action'."
			die 130
	esac
	:
}

set_first_setup() {
	[ "$action" != configure ] && echolog "Changing action to 'configure'."
	rm_setupdone
	export first_setup=1
	action=configure reset_req=1
}


#### showconfig
[ "$action" = showconfig ] && { printf '\n%s\n\n' "Config in $conf_file:"; cat "$conf_file"; die 0; }


#### VARIABLES

unset conf_act rm_conf

[ "$action" != stop ] && { [ "$first_setup" ] || [ ! -f "$conf_dir/setupdone" ]; } && {
	export first_setup=1
	[ "$action" != configure ] && {
		echolog "${_nl}Setup has not been completed."
		set_first_setup
	}

	[ ! "$nointeract_arg" ] && [ -s "$conf_file" ] && {
		q="[K]eep previous"
		keep_opt=k
		for _par in $ALL_CONF_VARS; do
			eval "arg_val=\"\$${_par}_arg\""
			[ "$arg_val" ] && {
				nodie=1 getconfig prev_val "$_par" "$conf_file" 2>/dev/null
				[ "$arg_val" != "$prev_val" ] && { q="[M]erge previous and new"; keep_opt=m; break; }
			}
		done

		printf '\n%s\n' "Existing config file found. $q config or [f]orget the old config? [$keep_opt|f] or [a] to abort setup."
		pick_opt "$keep_opt|f|a"
		case "$REPLY" in
			a) die 130 ;;
			f) rm_conf=1
		esac
	}
}

[ -s "$conf_file" ] && [ ! "$rm_conf" ] && {
	tmp_conf_file="/tmp/${p_name}_upd.conf"
	main_conf_path="$conf_file"

	# update config vars on first setup
	[ "$first_setup" ] && {
		sed 's/^tcp_ports=/inbound_tcp_ports=/;s/^udp_ports=/inbound_udp_ports=/;s/^geomode=/inbound_geomode=/;
				s/^iplists=/inbound_iplists=/' "$conf_file" > "$tmp_conf_file" && conf_file="$tmp_conf_file" ||
					{ FAIL; rm_conf=1; }
	}

	# load config
	nodie=1 export_conf=1 get_config_vars || rm_conf=1
	conf_file="$main_conf_path"
	rm -f "$tmp_conf_file"
}

[ ! -s "$conf_file" ] || [ "$rm_conf" ] && {
	rm -f "$conf_file"
	rm_data
	for _conf_var in $ALL_CONF_VARS; do
		is_alphanum "$_conf_var" || die "Internal error."
		eval "$_conf_var="
	done
	rm_setupdone
	export first_setup=1
}

[ "$_fw_backend" ] && { . "$_lib-$_fw_backend.sh" || die; } || {
	[ "$action" != configure ] && echolog "Firewall backend is not set."
	set_first_setup
}

[ -z "$inbound_geomode$outbound_geomode" ] && {
	[ "$action" != configure ] && echolog "${_nl}Geoblocking mode is not set for both inbound and outbound connections."
	set_first_setup
}

# check for valid geomode
for direction in inbound outbound; do
	eval "dir_geomode=\"\$${direction}_geomode\""
	case "$dir_geomode" in
		whitelist|blacklist|disable) ;;
		*)
			case "$dir_geomode" in
				'') [ "$action" != configure ] && echolog "Geoblocking mode for direction '$direction' is not set." ;;
				*) echolog -err "Unexpected $direction geoblocking mode '$dir_geomode'."
			esac
			unset "${direction}_geomode"
			set_first_setup ;;
	esac
done

for dir in inbound outbound; do
	san_str "${dir}_ccodes_arg" || die
	toupper "${dir}_ccodes_arg"
done

run_command="$i_script-run.sh"


## Check args for sanity

erract="action '$action'"
incompat="$erract is incompatible with option"

[ "$action" != configure ] && {
	for i_opt in "inbound_ccodes c" "outbound_ccodes c" "inbound_geomode m" "outbound_geomode m" \
			"inbound_ports p" "outbound_ports p" "trusted t" "lan_ips l" "ifaces i" "keep_mm_db K" \
			"geosource u" "source_ips U" "datadir a" "local_iplists_dir L" "nobackup o" "schedule s" \
			"families f" "user_ccode r" "nft_perf O" "nointeract z" "local_allow A" "local_block B"; do
		eval "[ -n \"\$${i_opt% *}_arg\" ]" && die "$incompat '-${i_opt#* }'."
	done
}


#### MAIN

[ "$action" = status ] && { . "$_lib-status.sh"; die $?; }

[ "$action" != stop ] && mk_lock
trap 'die' INT TERM HUP QUIT


case "$action" in
	on|off|stop)
		case "$action" in
			on) [ ! "$inbound_iplists$outbound_iplists" ] && die "No IP lists registered. Refusing to enable geoblocking."
				setconfig "noblock=false" ;;
			off) setconfig "noblock=true" ;;
			stop)
				kill_geo_pids
				mk_lock -f
				rm_iplists_rules
				die
		esac
		call_script "$i_script-apply.sh" $action
		die $? ;;
	reset)
		rm_iplists_rules
		rm_all_data
		[ -f "$conf_file" ] && { printf '%s\n' "Deleting the config file '$conf_file'..."; rm -f "$conf_file"; }
		rm_setupdone
		die 0 ;;
	restore) restore_from_config; die $?
esac


# From here on the action is 'configure'
prev_config="$main_config"

[ ! -s "$conf_file" ] && {
	touch "$conf_file" && chmod 600 "$conf_file" && chown root:root "$conf_file" || {
		rm -f "$conf_file"
		die "$FAIL create the config file."
	}
	[ "$_fw_backend" ] && rm_iplists_rules
}

debugprint "first_setup: '$first_setup'"

for var_name in datadir local_iplists_dir noblock nobackup schedule no_persist geosource ifaces families _fw_backend nft_perf \
	user_ccode lan_ips_ipv4 lan_ips_ipv6 trusted_ipv4 trusted_ipv6 source_ips_ipv4 source_ips_ipv6 source_ips_policy; do
	eval "${var_name}_prev=\"\$$var_name\""
done

export nointeract="${nointeract_arg:-$nointeract}"

# sets _fw_backend nft_perf nobackup noblock no_persist force_cron_persist datadir local_iplists_dir schedule families
#   geosource trusted user_ccode keep_mm_db
# imports local IP lists if specified
get_general_prefs || die

for opt_ch in datadir local_iplists_dir noblock nobackup schedule no_persist geosource families \
		_fw_backend nft_perf user_ccode source_ips_policy; do
	unset "${opt_ch}_change"
	eval "[ \"\$${opt_ch}\" != \"\$${opt_ch}_prev\" ] && ${opt_ch}_change=1"
done

checkvars _fw_backend datadir

unset ccodes_arg_unset iplists_unset geomode_set ports_change geomode_change_g
[ ! "$inbound_ccodes_arg$outbound_ccodes_arg" ] && ccodes_arg_unset=1
[ ! "$inbound_iplists$outbound_iplists" ] && iplists_unset=1

# determine if interactive geomode dialog is needed
for direction in inbound outbound; do
	[ -n "$geomode" ] && geomode_set=1
	eval "geomode_arg=\"\$${direction}_geomode_arg\"
			geomode=\"\$${direction}_geomode\""

	[ "$geomode" ] && geomode_set=1

	[ "$geomode_arg" ] && {
		tolower geomode_arg
		case "$geomode_arg" in whitelist|blacklist|disable)
			geomode_set=1
			eval "${direction}_geomode_arg=\"$geomode_arg\""
		esac
	}
done

# set *_ccodes *_ports *_iplists *_geomode
for direction in inbound outbound; do
	unset ccodes process_args geomode_change
	contradicts1="contradicts $direction geoblocking mode 'disable'."
	contradicts2="To enable geoblocking for direction $direction: '$p_name configure -D $direction -m <whitelist|blacklist>'"

	for _par in geomode iplists tcp_ports udp_ports; do
		eval "${_par}=\"\${${direction}_${_par}}\" ${_par}_prev=\"\${${direction}_${_par}}\" \
			${direction}_${_par}_prev=\"\${${direction}_${_par}}\""
	done

	for _par in ccodes_arg ports_arg geomode_arg; do
		eval "${_par}=\"\$${direction}_${_par}\""
	done

	[ -n "$ccodes_arg" ] || [ -n "$ports_arg" ] && process_args=1

	# geoblocking mode
	[ "$geomode_arg" ] && {
		case "$geomode_arg" in
			whitelist|blacklist|disable) geomode="$geomode_arg" ;;
			'') ;;
			*)
				echolog -err "Invalid geoblocking mode '$geomode_arg'."
				[ "$nointeract" ] && die
				pick_geomode
		esac
	}

	[ ! "$geomode_set" ] && {
		if [ "$nointeract" ]; then
			[ "$direction" = outbound ] && die "Specify geoblocking mode with -m $mode_syn"
			geomode=disable
		elif [ "$direction" = inbound ]; then
			pick_geomode
		elif [ "$direction" = outbound ]; then
			echolog "${_nl}${yellow}NOTE${n_c}: You can set up *outbound* geoblocking later by running 'geoip-shell configure -D outbound -m <whitelist|blacklist>'."
		fi
	}

	: "${geomode:=disable}"

	if [ "$geomode" = disable ]; then
		[ "$ports_arg" ] && die "Option '-p' $contradicts1" "$contradicts2"
		[ "$ccodes_arg" ] && die "Option '-c' $contradicts1" "$contradicts2"
		process_args=
		unset iplists "${direction}_iplists"
		eval "${direction}_tcp_ports=skip ${direction}_udp_ports=skip ${direction}_geomode=disable"
	else
		process_args=1
	fi

	[ "$geomode" != "$geomode_prev" ] && { geomode_change=1; geomode_change_g=1; }

	eval "${direction}_geomode"='$geomode' "${direction}_geomode_change"='$geomode_change'

	[ "$direction" = outbound ] && ! is_whitelist_present && {
		[ "$lan_ips_arg" ] && die "Option '-l' can only be used in whitelist geoblocking mode."
		if [ -n "$lan_ips_ipv4$lan_ips_ipv6" ]; then
			echolog -warn "Inbound geoblocking mode is '$inbound_geomode', outbound geoblocking mode is '$outbound_geomode'. Removing lan IPs from config."
			unset lan_ips_ipv4 lan_ips_ipv6
		fi
	}

	[ ! "$process_args" ] && continue

	# ports
	[ "$ports_arg" ] && { setports "${ports_arg%"$_nl"}" || die; }
	for opt_ch in tcp_ports udp_ports; do
		eval "[ \"\$${direction}_${opt_ch}\" != \"\$${direction}_${opt_ch}_prev\" ] && ${direction}_ports_change=1" &&
			ports_change=1
	done

	# country codes
	if [ -n "$ccodes_arg" ]; then
		norm_ccodes='' bad_ccodes=''
		toupper ccodes_arg
		for ccode in $ccodes_arg; do
			normalize_ccode norm_ccode "$ccode"
			case $? in
				1) die "Internal error while validating country codes." ;;
				3) bad_ccodes="$bad_ccodes$ccode "
			esac
			norm_ccodes="${norm_ccodes}${norm_ccode} "
		done
		[ "$bad_ccodes" ] && die "Invalid 2-letters country codes: '${bad_ccodes% }'."
		ccodes_arg="${norm_ccodes% }"
	fi

	if { [ "$ccodes_arg_unset" ] && [ "$iplists_unset" ]; } || [ "$ccodes_arg" ] || [ "$geomode_change" ]; then
		if [ "$nointeract" ]; then
			[ "$direction" = outbound ] && {
				san_str all_ccodes_arg "$inbound_ccodes_arg $outbound_ccodes_arg" || die
				[ ! "$all_ccodes_arg" ] && die "Specify country codes with '-c $ccodes_syn'."
			}
			[ "$ccodes_arg" ] && pick_ccodes
		else
			pick_ccodes
		fi
	fi

	[ "$families_change" ] && [ ! "$ccodes" ] &&
		for list_id in $iplists; do
			add2list ccodes "${list_id%_*}"
		done

	# generate a list of requested iplists
	lists_req=
	for ccode in $ccodes; do
		for f in $families; do
			add2list lists_req "${ccode}_$f"
		done
	done

	separate_excl_iplists lists_req "$lists_req" || die

	eval "${direction}_lists_req"='$lists_req' \
		"${direction}_ccodes"='$ccodes'
done

san_str all_ccodes_arg "$inbound_ccodes_arg $outbound_ccodes_arg" || die

[ "$excl_list_ids" ] && report_excluded_lists "$excl_list_ids"

[ "$all_ccodes_arg" ] && [ ! "$inbound_lists_req$outbound_lists_req" ] &&
	die "No applicable IP list IDs could be generated for country codes '$all_ccodes_arg'."

# ifaces and lan subnets
unset lan_picked ifaces_picked ifaces_change

for direction in inbound outbound; do
	eval "geomode=\"\$${direction}_geomode\" geomode_change=\"\$${direction}_geomode_change\""
	[ "$geomode" = disable ] && continue
	if [ ! "$ifaces" ] && [ ! "$ifaces_arg" ]; then
		[ "$nointeract" ] && die "Specify interfaces with -i <\"ifaces\"|auto|all>."
		printf '\n%s\n%s\n%s\n%s\n' "${blue}Does this machine have dedicated WAN network interface(s)?$n_c [y|n] or [a] to abort." \
			"For example, a router or a virtual private server may have it." \
			"A machine connected to a LAN behind a router is unlikely to have it." \
			"It is important to answer this question correctly."
		pick_opt "y|n|a"
		case "$REPLY" in
			a) die 130 ;;
			y) pick_ifaces ;;
			n) ifaces=all; is_whitelist_present && [ ! "$lan_picked" ] && { warn_lockout; pick_lan_ips; }
		esac
		ifaces_change=1
	fi

	if [ "$ifaces_arg" ] && [ ! "$ifaces_picked" ]; then
		ifaces=
		case "$ifaces_arg" in
			all) ifaces=all
				is_whitelist_present && [ ! "$lan_picked" ] &&
					{ [ "$first_setup" ] || [ "$geomode_change" ] || [ "$ifaces_change" ]; } &&
						{ warn_lockout; pick_lan_ips; } ;;
			auto) ifaces_arg=''; pick_ifaces -a ;;
			*) pick_ifaces
		esac
	fi

	[ ! "$ifaces" ] && ifaces=all

	get_difference "$ifaces" "$ifaces_prev" || ifaces_change=1

	if [ ! "$lan_picked" ] && [ ! "$lan_ips_ipv4$lan_ips_ipv6" ] && is_whitelist_present && [ "$geomode_change" ] &&
		[ "$ifaces" = all ]; then
		warn_lockout; pick_lan_ips
	fi
done

[ "$lan_ips_arg" ] &&  [ ! "$lan_picked" ] && pick_lan_ips

[ "$geosource_change" ] && unset source_ips_ipv4 source_ips_ipv6

# source IPs
if [ "$source_ips_arg" ] || {
		[ "$outbound_geomode" != disable ] && [ ! "$source_ips_ipv4$source_ips_ipv6" ] && [ "$source_ips_policy" != pause ] &&
		{
			[ ! "$source_ips_policy" ] ||
			[ "$geosource_change" ] ||
			{ [ "$outbound_geomode_change" ] && [ "$outbound_geomode_prev" = disable ]; }
		}
	}
then
	pick_source_ips
fi

for opt_ch in lan_ips_ipv4 lan_ips_ipv6 trusted_ipv4 trusted_ipv6 source_ips_ipv4 source_ips_ipv6; do
	eval "[ \"\$${opt_ch}\" != \"\$${opt_ch}_prev\" ]" && eval "${opt_ch%_ipv*}_change=1"
done

[ "$source_ips_policy_change" ] && [ "$source_ips_policy" = true ] && source_ips_change=1

unset all_iplists all_iplists_prev all_add_iplists
for direction in inbound outbound; do
	eval "lists_req=\"\$${direction}_lists_req\" iplists=\"\$${direction}_iplists\" iplists_prev=\"\$${direction}_iplists_prev\""
	: "${lists_req:="$iplists"}"
	iplists="$lists_req"

	! get_difference "$iplists_prev" "$iplists" && {
		lists_change=1
		eval "${direction}_lists_change=1"
	}
	eval "${direction}_iplists"='$iplists'

	add2list all_iplists_prev "$iplists_prev"
	add2list all_iplists "$iplists"
done

subtract_a_from_b "$all_iplists_prev" "$all_iplists" all_add_iplists

debugprint "all_add_iplists: '$all_add_iplists'"

unset run_restore_req run_add_req reset_req backup_req apply_req cron_req coherence_req

[ "$no_persist_change" ] || [ "$schedule_change" ] && cron_req=1

[ "$user_ccode_change" ] && backup_req=0

[ "$nobackup_change" ] && [ "$nobackup" = false ] && backup_req=1

[ "$ports_change" ] || [ "$ifaces_change" ] || [ "$geomode_change_g" ] || [ "$source_ips_policy_change" ] ||
	[ "$lan_ips_change" ] || [ "$trusted_change" ] || [ "$source_ips_change" ] || [ "$noblock_change" ] ||
	[ "$lists_change" ] && apply_req=1

[ "$nft_perf_change" ] && run_restore_req=1

[ "$all_add_iplists" ] && run_add_req=1

[ "$first_setup" ] || [ "$_fw_backend_change" ] || [ "$geosource_change" ] && reset_req=1

check_for_lockout

[ "$nobackup_change" ] && {
	[ -d "$datadir_prev/backup" ] && {
		printf %s "Removing old backup... "
		rm -rf "$datadir_prev/backup" || die "$FAIL remove old backup."
		OK
	}
}

if [ "$datadir_change" ]; then
	if [ -n "$datadir_prev" ] && [ -d "$datadir_prev" ]; then
		dir_mv "$datadir_prev" "$datadir" data
		dir_mv "$datadir_prev/backup" "$datadir/backup" backup
		rm -rf "$datadir_prev/backup"
		rm_dir_if_empty "$datadir_prev" || die
	fi
	status_file="$datadir/status"
fi

export datadir status_file

[ "$local_iplists_dir_change" ] && dir_mv "$local_iplists_dir_prev" "$local_iplists_dir" "local IP lists"

[ "$run_restore_req" ] &&
	{ [ "$nobackup_prev" = true ] || [ ! -s "$datadir/backup/$p_name.conf.bak" ] || [ ! -s "$status_file" ]; } &&
		reset_req=1

[ "$apply_req" ] && conf_act=apply
[ "$run_restore_req" ] && conf_act=run_restore
[ "$run_add_req" ] && conf_act=run_add
[ "$reset_req" ] && conf_act=reset

[ -z "$conf_act" ] && { check_lists_coherence -nr || conf_act=run_restore; }

debugprint "config action: '$conf_act'"

if [ "$_fw_backend_change" ]; then
	if [ "$_fw_backend_prev" ]; then
		(
			# use previous backend to remove existing rules
			export _fw_backend="$_fw_backend_prev"
			. "$_lib-$_fw_backend.sh" || exit 1
			rm_iplists_rules
			rm_data
			:
		) || die "$FAIL remove firewall rules for the backend '$_fw_backend_prev'."
	fi
	# source library for the new backend
	. "$_lib-$_fw_backend.sh" || die
else
	case "$conf_act" in
		backup|run_restore) ;;
		*)
			# create backup if it doesn't exist yet
			if [ "$nobackup" != true ] && [ -s "$status_file" ] && [ ! -s "$datadir/backup/status.bak" ]; then
				inbound_iplists="$inbound_iplists_prev" outbound_iplists="$outbound_iplists_prev" \
					call_script -l "$i_script-backup.sh" create-backup || rm_data
			fi
	esac
fi

set_all_config

case "$conf_act" in
	run_add|run_restore|reset)
		backup_req=
		cron_req=1 ;;
	apply)
		backup_req=1
		cron_req=1
		coherence_req=1 ;;
	*)
esac

dir_mk "$datadir" || die

case "$conf_act" in
	reset)
		restore_from_config
		rv_conf=$? ;;
	run_add)
		[ "$all_add_iplists" ] || die "conf_act is 'run_add' but \$all_add_iplists is empty string"
		get_counters
		call_script -l "$i_script-run.sh" add -l "$all_add_iplists" -o
		rv_conf=$? ;;
	run_restore)
		get_counters
		call_script -l "$i_script-run.sh" restore -f
		rv_conf=$? ;;
	apply)
		get_counters
		call_script "$i_script-apply.sh" restore
		rv_conf=$?
		main_config=
		nodie=1 export_conf=1 get_config_vars || rv_conf=1
		;;
	'') rv_conf=0 ;;
esac

if [ "$rv_conf" = 0 ]; then
	# add staging local lists
	for family in ipv4 ipv6; do
		for local_type in allow block; do
			filename="local_${local_type}_${family}"
			if [ -s "$staging_local_dir/$filename.ip" ] || [ -s "$staging_local_dir/$filename.net" ]; then
				set +f
				rm -f "$local_iplists_dir/$filename".*
				mv "$staging_local_dir/$filename".* "$local_iplists_dir/"
				set -f
			else
				continue
			fi
		done
	done
	rm -rf "$staging_local_dir"

	[ "$coherence_req" ] && [ "$conf_act" != reset ] && {
		check_lists_coherence || {
			rm -rf "$staging_local_dir"
			restore_from_config || die
		}

	}
else
	rm -rf "$staging_local_dir"
	backup_req=1
fi

case "$rv_conf" in
	0) ;;
	254)
		echolog "Restoring previous config."
		main_config="$prev_config"
		nodie=1 export_conf=1 get_config_vars && check_lists_coherence ||
			{
				_prev="previous "
				prev_config_try=1
				restore_from_config
				die $?
			}
		set_all_config
		backup_req=
		rv_conf=0 ;;
	*) restore_from_config
esac || die

[ "$rv_conf" = 0 ] && {
	bk_conf_only=
	[ "$backup_req" = 0 ] && bk_conf_only='-s'
	[ "$backup_req" ] && [ "$nobackup" != true ] && [ "$inbound_iplists$outbound_iplists" ] &&
		call_script -l "$i_script-backup.sh" create-backup "$bk_conf_only"

	[ "$first_setup" ] && touch "$conf_dir/setupdone"
	if [ "$cron_req" ]; then
		call_script "$i_script-cronsetup.sh" || echolog -err "$FAIL update cron jobs."
		[ "$_OWRTFW" ] && {
			case "$no_persist" in
				true) disable_owrt_persist ;;
				false)
					if [ -z "$inbound_iplists$outbound_iplists" ]; then
						[ ! -f "$conf_dir/no_persist" ] && touch "$conf_dir/no_persist"
						echolog "Countries list in the config file is empty! No point in creating firewall include."
					else
						rm -f "$conf_dir/no_persist"
						check_owrt_init && check_owrt_include || {
							rm_lock
							enable_owrt_persist
							rv_conf=$?
							[ -f "$lock_file" ] && {
								echo "Waiting for background processes to complete..."
								for i in $(seq 1 30); do
									[ ! -f "$lock_file" ] && break
									sleep 1
								done
								[ $i = 30 ] && echolog -warn "Lock file '$lock_file' is still in place. Please check system log."
							}
						}
					fi
			esac
		}
	fi

	[ "$first_setup" ] && [ "$rv_conf" = 0 ] &&
		printf '\n%s\n' "Successfully configured $p_name for firewall backend: ${blue}${_fw_backend}ables${n_c}."

	report_lists
	statustip
}

die $rv_conf
