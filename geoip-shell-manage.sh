#!/bin/sh
# shellcheck disable=SC2154,SC2086,SC1090,SC2034

# geoip-shell-manage.sh

# Copyright: antonk (antonk.d3v@gmail.com)
# github.com/friendly-bits

#### Initial setup
p_name="geoip-shell"
GS_ID=manage
: "${manmode:=1}"
export inbound_geomode nolog=1 manmode

script_dir="$INSTALL_DIR"
. "/usr/bin/${p_name}-geoinit.sh" || exit 1

san_args "$@"
newifs "$delim"
set -- $_args
oldifs

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
  ${blue}lookup${n_c}     :  look up given IP addresses in IP sets loaded by geoip-shell
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

  ${blue}-c $ccodes_syn${n_c} : 2-letter country codes and/or region codes to include in whitelist/blacklist.
${sp8}Supported region codes: RIPE, ARIN, APNIC, AFRINIC, LACNIC
${sp8}If passing multiple values, use double quotes.

  ${blue}-p <[tcp|udp]:[allow|block]:[all|<ports>]>${n_c} :
${sp8}For given protocol (tcp/udp), use 'block' to geoblock traffic on specific ports or on all ports.
${sp8}or use 'allow' to geoblock all traffic except on specific ports.
  ${blue}-p <icmp:[allow|block]>${n_c} :
${sp8}For *icmp*, use 'block' to geoblock all traffic, or use 'allow' to allow all icmp traffic through geoblocking filter.
${sp8}To specify rules for multiple protocols in one command, use the '-p' option multiple times.

${purple}General options for the 'configure' action${n_c} (affects geoblocking in both directions):

  ${blue}-f <ipv4|ipv6|"ipv4 ipv6">${n_c} :
${sp8}IP families (defaults to 'ipv4 ipv6'). Use double quotes for multiple families.

  ${blue}-u <ripe|ipdeny|maxmind|ipinfo>${n_c} :
${sp8}Specify IP list source.

  ${blue}-i <"[ifaces]"|auto|all>${n_c} :
${sp8}Changes which network interface(s) geoblocking firewall rules will be applied to.
${sp8}'all' will apply geoblocking to all network interfaces.
${sp8}'auto' will automatically detect WAN interfaces (this may cause problems if the machine has no direct WAN connection).
${sp8}Generally, if the machine has dedicated WAN interfaces, specify them, otherwise pick 'all'.

  ${blue}-l <"[lan_ips]"|auto|none>${n_c} :
${sp8}Specifies LAN IPs or IP ranges to exclude from geoblocking (both ipv4 and ipv6).
${sp8}Only compatible with whitelist mode.
${sp8}Generally, in whitelist mode, if the machine has no dedicated WAN interfaces,
${sp8}specify LAN IPs or IP ranges to avoid blocking them. Otherwise you probably don't need this.
${sp8}'auto' will automatically detect LAN IP ranges during the initial setup and at every update of the IP lists.
${sp8}'none' removes previously set LAN IPs and disables the automatic detection.
${sp8}*Don't use 'auto' if the machine has a dedicated WAN interface*

  ${blue}-t <"[trusted_ips]"|none>${n_c} :
${sp8}Specifies trusted IPs or IP ranges to exclude from geoblocking (both ipv4 and ipv6).
${sp8}This option is independent from the above LAN IPs option.
${sp8}Works both in whitelist and blacklist mode.
${sp8}'none' removes previously set trusted IPs

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
${sp8}Default is '$GEORUN_DIR/data' for OpenWrt, '/var/lib/$p_name' for all other systems.

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

  ${blue}-S <"path">${n_c} :
${sp8}Set path to custom script called on success or failure when $p_name is running automatically, or 'none' to disable.
${sp8}See README for specifics.

  ${blue}-P <true|false>${n_c} : Force cron-based persistence even when the system may not support it. Default is false.

  ${blue}-K <true|false>${n_c} : Keep and re-use the complete downloaded MaxMind/IPinfo database until it's changed upstream.

${purple}Options for the 'import' action${n_c}:
  ${blue}[-A|-B] <"[path_to_file]"|remove>${n_c} :
${sp8}Specifies local file containing a list of IP addresses or IP ranges to import into geoip-shell (one IP family per file).
${sp8}Use '-A' to import into local allowlist, '-B' to import into local blocklist.
${sp8}Rules for local IP lists will be applied regardless of whether geoblocking mode is whitelist or blacklist, and regardless of direction.
${sp8}'remove' removes any previously imported local IP lists of specified type (-A for allowlist, -B for blocklist).

${purple}Options for the 'lookup' action${n_c}:
  ${blue}-I <"ip_addresses">${n_c} : Look up specified IP addresses in loaded IP sets
  ${blue}-F <path>${n_c} : Read IP addresses from file and look them up in loaded IP sets
  ${blue}-v${n_c} : Verbose mode: print which of the loaded IP sets each matching IP address belongs to

${purple}Other options${n_c}:

  -v : Verbose status output
  -z : $nointeract_usage Will fail if required options are not specified or invalid.
  -d : Debug
  -V : Version
  -h : This help

EOF
}


#### PARSE ARGUMENTS

configure_opts_req=
configure_opts="m|c|p|f|s|i|l|t|r|u|U|K|a|L|w|O|o|n|N|P|S"
lookup_opts="I|F"
status_opts="v"
import_opts="A|B"


die_m() { rm -rf "$GEOTEMP_DIR"; rm -rf "${STAGING_LOCAL_DIR:-???}"; die "$@"; }

set_opt() {
	sop_var="$1"

	# Check opt sanity
	eval "action_opts=\"\${${action}_opts}\""
	is_included "$opt" "$action_opts" "|" || die "action '$action' is incompatible with option '-$opt'."

	[ "$opt" != p ] && {
		eval "oldval=\"\$${sop_var}\""
		[ -n "$oldval" ] && {
			fordirection=
			case "$opt" in m|c) fordirection=" for direction '$direction'"; esac
			die "Option '-$opt' can not be used twice${fordirection}."
		}
	}

	[ "$action" = configure ] && configure_opts_req=1

	# set vars
	case "$opt" in
		m|c|p) set_directional_opt "$sop_var" ;;
		*) eval "$sop_var"='$OPTARG'; return 0
	esac
}

set_directional_opt() {
	[ "$1" ] || bad_args set_direction_opt "$@"
	sdo_var="$1"
	[ "$action" != configure ] && { usage; die "Option '-$opt' must be used with the 'configure' action."; }
	case "$direction" in
		inbound|outbound)
			case "$opt" in
				m|c) eval "${direction}_${sdo_var}"='$OPTARG' ;;
				p) eval "${direction}_proto_arg=\"\${${direction}_proto_arg}\$OPTARG\$_nl\""
			esac ;;
		*) die "Internal error: unexpected direction '$direction'."
	esac
	req_direc_opt=
}

# check for valid action
tolower action "$1"
case "$action" in
	configure) direction=inbound; shift ;;
	status|restore|reset|on|off|stop|showconfig|lookup|import) shift ;;
	*) action="$1"; unknownact
esac

# process the rest of the args
req_direc_opt=
while getopts ":D:m:c:f:s:i:l:t:p:r:u:A:B:U:K:a:L:o:w:O:n:N:P:S:I:F:zvdVh" opt; do
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
		p) set_opt proto_arg ;;

		f) set_opt families_arg ;;
		s) set_opt upd_schedule_arg ;;
		i) set_opt ifaces_arg ;;
		l) set_opt lan_ips_arg ;;
		t) set_opt trusted_arg ;;
		r) set_opt user_ccode_arg ;;
		u) set_opt geosource_arg ;;
		A) set_opt local_allow_arg ;;
		B) set_opt local_block_arg ;;
		U) set_opt source_ips_arg ;;
		K) set_opt keep_fetched_db_arg ;;
		a) set_opt datadir_arg ;;
		L) set_opt local_iplists_dir_arg ;;
		w) set_opt _fw_backend_arg ;;
		O) set_opt nft_perf_arg ;;

		o) set_opt no_backup_arg ;;
		n) set_opt no_persist_arg ;;
		N) set_opt no_block_arg ;;
		P) set_opt force_cron_persist_arg ;;
		S) set_opt custom_script_arg ;;

		I) set_opt lookup_addr_arg ;;
		F) set_opt lookup_addr_file_arg ;;

		z) nointeract_arg=1 ;;
		v) verb_mode="-v" ;;
		d) debugmode_arg=1 ;;
		V) echo "$curr_ver"; die 0 ;;
		h) usage; die 0 ;;
		*) unknownopt
	esac
done
shift $((OPTIND-1))

[ "$req_direc_opt" ] && { usage; die "Provide valid options for direction '$direction'."; }

setdebug
debugentermsg

extra_args "$@"

is_root_ok

source_lib setup || die


#### FUNCTIONS

# 1 - old dir
# 2 - new dir
# 3 - description
dir_mv() {
	prev_dir_mv="$1" new_dir_mv="$2" dir_cont_desc="$3"
	[ -n "$prev_dir_mv" ] || return 0
	[ -n "$new_dir_mv" ] || return 1

	rm -rf "$new_dir_mv"
	dir_mk "$new_dir_mv" || die_m
	[ -d "$prev_dir_mv" ] || return 0

	if ! is_dir_empty "$prev_dir_mv"; then
		printf %s "Moving $dir_cont_desc to the new path... "
		set +f
		for mv_file in "$prev_dir_mv"/*; do
			case "$mv_file" in *"/*") continue; esac
			if [ ! -d "$mv_file" ]; then
				mv -- "$mv_file" "$new_dir_mv/" || {
					mv "$new_dir_mv"/* "$prev_dir_mv/"
					set -f
					rm -rf "$new_dir_mv"
					die_m "$FAIL move the $dir_cont_desc."
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
	_prev="${1}${1:+ }"
	restore_msg="Restoring $p_name from ${_prev}config... "
	restore_ok_msg="Successfully restored $p_name from ${_prev}config."
	[ "$conf_act" = reset ] && {
		restore_msg="Applying ${_prev}config... "
		restore_ok_msg="Successfully applied ${_prev}config."
	}
	printf '\n%s\n' "$restore_msg"

	rm_iplists_rules || return 1
	rm -f "$status_file"

	if [ -n "$_prev" ]; then
		[ -s "$CONF_FILE" ] || { echolog "Previous config not found."; return 1; }
		if discard_config_changes &&
			nodie=1 load_main_config &&
			[ ! "$_fw_backend_change" ] ||
				{ [ "$_fw_backend_change" ] && [ "$_fw_backend" ] && source_lib "$_fw_backend"; }; then
			:
		else
			echolog -err "$FAIL restore previous config."
			return 1
		fi
	fi

	# compile run args
	run_args=
	for d in inbound outbound; do
		eval "[ -n \"\${${d}_iplists}\" ] && run_args=\"\${run_args}\${${d}_iplists} \""
	done

	if [ -n "$run_args" ]; then
		# call the -run script
		call_script -l "$i_script-run.sh" add -l "$run_args" && {
			printf '%s\n' "$restore_ok_msg"
			return 0
		}
	else
		echo "No IP lists registered - skipping firewall rules creation."
		return 0
	fi

	# Handle failure
	[ "$first_setup" ] && die_m

	if [ -n "$_prev" ]; then
		return 1
	else
		restore_from_config previous && return 0
	fi

	# recover from backup
	[ -f "$datadir/backup/$p_name.conf.bak" ] && call_script -l "$i_script-backup.sh" restore && {
		discard_config_changes
		load_main_config
		check_lists_coherence && return 0
	}

	die_m "$FAIL restore $p_name state. If it's a bug then please report it."
}

# tries to prevent the user from locking themselves out
check_for_lockout() {
	# if we don't have user's country code, don't check for lockout
	[ "$user_ccode" = none ] && return 0

	u_ccode="${_nl}Your country code '$user_ccode'"
	lockout_exp=

	for direction in inbound outbound; do
		eval "dfl_iplists=\"\$${direction}_iplists\"
			dfl_geomode=\"\$${direction}_geomode\"
			dfl_geomode_change=\"\$${direction}_geomode_change\"
			dfl_lists_change=\"\$${direction}_lists_change\""
		if [ "$first_setup" ] || [ "$dfl_geomode_change" ] || [ "$dfl_lists_change" ] || [ "$user_ccode_change" ]; then
			ccode_included=
			inlist="in the planned $direction geoblocking $dfl_geomode"

			for family in $families; do
				is_included "${user_ccode}_${family}" "$dfl_iplists" && ccode_included=1
			done
			case "$dfl_geomode" in
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
			discard_config_changes
			load_main_config
			die_m 130
	esac
	:
}

set_first_setup() {
	rm_setupdone
	[ "$action" = configure ] || die_m 0 "Please run '$p_name configure'."
	export first_setup=1
	reset_req=1
}

report_lists() {
	unset iplists_incoherent local_lists_rl
	for direction in inbound outbound; do
		eval "geomode=\"\$${direction}_geomode\""
		[ "$geomode" = disable ] && continue
		get_active_iplists verified_lists "$direction"
		nl2sp verified_lists
		for list_id in $verified_lists; do
			case "$list_id" in *local_*)
				add2list local_lists_rl "$list_id"
			esac
		done
		subtract_a_from_b "$local_lists_rl" "$verified_lists" ccode_lists
		verified_lists_sp="$local_lists_rl"
		[ "$ccode_lists" ] && verified_lists_sp="$verified_lists_sp $ccode_lists"
		report_lists=
		for list_id in $verified_lists_sp; do
			case "$list_id" in
				allow_in_*|allow_out_*|allow_*|dhcp_*) continue ;;
				*) report_lists="$report_lists$list_id "
			esac
		done
		if [ -n "$report_lists" ]; then
			report_lists="'${blue}${report_lists% }${n_c}'"
		else
			report_lists="${red}None${n_c}"
		fi
		printf '\n%s\n' "Final IP lists in $direction $geomode: $report_lists."
	done
}


export nointeract="${nointeract_arg:-$nointeract}"

#### Make lock if needed
case "$action" in
	showconfig)
		printf '\n%s\n\n' "Config in $CONF_FILE:"; cat "$CONF_FILE"; die 0 ;;
	lookup|on|off|reset|restore|import|configure)
		mk_lock || die
		trap 'die_m' INT TERM HUP QUIT
esac

export GS_CONFIG_OWNER="$GS_ID" # manage always owns the config

in_configure=
[ "$action" = configure ] && in_configure=1


#### Handle first setup and/or missing config

dir_mk -n "$GEOTEMP_DIR" || die

conf_file_found=
[ -s "$CONF_FILE" ] && conf_file_found=1
rm_conf=

[ "$action" != stop ] && { [ "$first_setup" ] || [ ! -f "$CONF_DIR/setupdone" ]; } && {
	export first_setup=1
	[ "$action" = configure ] || echolog "${_nl}Setup has not been completed."

	set_first_setup

	[ ! "$nointeract" ] && [ -n "$conf_file_found" ] && {
		q="[K]eep previous"
		keep_opt=k
		[ -n "$configure_opts_req" ] &&
			{ q="[M]erge previous and new"; keep_opt=m; }

		printf '\n%s\n' "Existing config file found. $q config or [f]orget the old config? [$keep_opt|f] or [a] to abort setup."
		pick_opt "$keep_opt|f|a"
		case "$REPLY" in
			a) die 130 ;;
			f) rm_conf=1
		esac
	}
}

#### Load config
[ "$conf_file_found" ] && [ ! "$rm_conf" ] &&
	nodie=1 load_main_config || {
		rm -f "$CONF_FILE"
		rm_data
		discard_config_changes
		set_first_setup
	}

export datadir status_file="$datadir/status"

for opt_spec in \
	"_fw_backend${delim}firewall backend" \
	"inbound_geomode outbound_geomode${delim}geoblocking mode" \
	"geosource${delim}IP list source" \
	"ifaces${delim}network interfaces"
do
	alt_check_opts="${opt_spec%"${delim}"*}"
	for alt_check_opt in $alt_check_opts; do
		eval "check_val=\"\${$alt_check_opt}\""
		[ -n "$check_val" ] && continue 2
	done
	check_desc="${opt_spec##*"${delim}"}"
	[ "$action" != configure ] && echolog "Config options '$alt_check_opts' not set. Can not determine $check_desc."
	set_first_setup
	break
done

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
			eval "${direction}_geomode="
			set_first_setup ;;
	esac
done


#### MAIN

[ "$action" = configure ] && {
	do_configure
	set_all_config
}

source_lib "$_fw_backend" || die_m

# actions which do not require lock
case "$action" in
	status)
		source_lib status && report_status
		die $? ;;
	stop)
		kill_geo_pids
		mk_lock -f
		rm_iplists_rules
		die_m 0 ;;
	lookup)
		source_lib lookup &&
		lookup "$lookup_addr_arg" "$lookup_addr_file_arg"
		die_m $? ;;
	on|off)
		case "$action" in
			on) [ ! "$inbound_iplists$outbound_iplists" ] && die_m "No IP lists registered. Refusing to enable geoblocking."
				set_main_config "no_block=false" ;;
			off) set_main_config "no_block=true" ;;
		esac
		call_script "$i_script-apply.sh" $action
		die_m $? ;;
	reset)
		[ -n "${nointeract}" ] || {
			printf '\n%s\n' "Warning: this will reset $p_name config and remove $p_name IP lists and firewall rules. Continue? (y|n)"
			pick_opt "y|n"
			[ "$REPLY" = y ] || die_m 0
		}
		rm_iplists_rules
		rm_all_data
		[ -f "$CONF_FILE" ] && { printf '%s\n' "Deleting the config file '$CONF_FILE'..."; rm -f "$CONF_FILE"; }
		rm_setupdone
		die_m 0 ;;
	restore) restore_from_config; die_m $? ;;
	import) import_local_iplists ;;
esac


unset run_restore_req run_add_req reset_req backup_req apply_req cron_req coherence_req

[ "$no_persist_change" ] || [ "$upd_schedule_change" ] && cron_req=1

[ "$user_ccode_change" ] && backup_req=0

[ "$no_backup_change" ] && [ "$no_backup" = false ] && backup_req=1

[ "$proto_change" ] || [ "$ifaces_change" ] || [ "$geomode_change_g" ] || [ "$source_ips_policy_change" ] ||
	[ "$lan_ips_change" ] || [ "$trusted_change" ] || [ "$source_ips_change" ] || [ "$no_block_change" ] ||
	[ "$final_lists_change" ] && apply_req=1

[ "$nft_perf_change" ] && run_restore_req=1

[ "$all_add_iplists" ] && run_add_req=1

[ "$first_setup" ] || [ "$_fw_backend_change" ] || [ "$geosource_change" ] && reset_req=1

check_for_lockout

[ "$no_backup_change" ] && [ -n "$datadir_prev" ] && {
	[ -d "$datadir_prev/backup" ] && {
		printf %s "Removing old backup... "
		rm -rf "$datadir_prev/backup" || die_m "$FAIL remove old backup."
		OK
	}
}

if [ "$datadir_change" ]; then
	if [ -n "$datadir_prev" ] && [ -d "$datadir_prev" ]; then
		dir_mv "$datadir_prev" "$datadir" data
		dir_mv "$datadir_prev/backup" "$datadir/backup" backup
		rm -rf "$datadir_prev/backup"
		rm_dir_if_empty "$datadir_prev" || die_m
	fi
	export datadir status_file="$datadir/status"
fi

[ "$local_iplists_dir_change" ] && dir_mv "$local_iplists_dir_prev" "$local_iplists_dir" "local IP lists"

[ "$run_restore_req" ] &&
	{ [ "$no_backup_prev" = true ] || [ ! -s "$datadir/backup/$p_name.conf.bak" ] || [ ! -s "$status_file" ]; } &&
		reset_req=1

conf_act=
[ "$apply_req" ] && conf_act=apply
[ "$run_restore_req" ] && conf_act=run_restore
[ "$run_add_req" ] && conf_act=run_add
[ "$reset_req" ] && conf_act=reset

if [ "$_fw_backend_change" ]; then
	if [ "$_fw_backend_prev" ]; then
		(
			# use previous backend to remove existing rules
			export _fw_backend="$_fw_backend_prev"
			source_lib "$_fw_backend_prev" || exit 1
			rm_iplists_rules
			rm_data
			:
		) || die_m "$FAIL remove firewall rules for backend '$_fw_backend_prev'."
	fi
	source_lib "$_fw_backend" || die_m
fi

[ -n "$conf_act" ] || check_lists_coherence || conf_act=run_restore

debugprint "config action: '$conf_act'"

case "$conf_act" in run_add|reset|apply)
	# create backup if rules exist and no backup exists yet
	if [ "$no_backup" != true ] && [ -s "$status_file" ] && [ ! -s "$datadir/backup/status.bak" ] &&
		checkutil get_fwrules_iplists &&
		{
			nolog=1 get_fwrules_iplists inbound | grep . ||
			nolog=1 get_fwrules_iplists outbound | grep .
		} 1>/dev/null 2>/dev/null; then
		inbound_iplists="$inbound_iplists_prev" outbound_iplists="$outbound_iplists_prev" \
			call_script -l "$i_script-backup.sh" create-backup || rm_data
	fi
esac

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

dir_mk "$datadir" || die_m

case "$conf_act" in
	reset)
		restore_from_config
		rv_conf=$? ;;
	run_add)
		[ "$all_add_iplists" ] || die_m "conf_act is 'run_add' but \$all_add_iplists is empty string"
		get_counters
		call_script -l "$i_script-run.sh" add -l "$all_add_iplists"
		rv_conf=$? ;;
	run_restore)
		get_counters
		call_script -l "$i_script-run.sh" restore -f
		rv_conf=$? ;;
	apply)
		get_counters
		call_script "$i_script-apply.sh" restore
		rv_conf=$?
		;;
	'') rv_conf=0 ;;
esac

if [ "$rv_conf" = 0 ]; then
	# move staging local lists to permanent location
	if [ "$action" = import ]; then
		[ "$final_lists_change" ] && {
			for family in ipv4 ipv6; do
				for local_type in allow block; do
					filename="local_${local_type}_${family}"
					if [ -s "$STAGING_LOCAL_DIR/$filename.ip" ] || [ -s "$STAGING_LOCAL_DIR/$filename.net" ]; then
						set +f
						rm -f "$local_iplists_dir/$filename".*
						mv "$STAGING_LOCAL_DIR/$filename".* "$local_iplists_dir/"
						set -f
					else
						continue
					fi
				done
			done
		}
		rm -rf "${STAGING_LOCAL_DIR:-???}"
		[ -n "$src_local_files" ] && printf '%s\n\n' "${yellow}You can delete source files to free up space:${n_c}${_nl}${src_local_files}"
	fi

	[ "$coherence_req" ] && [ "$conf_act" != reset ] && {
		check_lists_coherence || restore_from_config || die_m
	}
else
	rm -rf "${STAGING_LOCAL_DIR:-???}"
	backup_req=1
fi

case "$rv_conf" in
	0) ;;
	254)
		[ -s "$CONF_FILE" ] || { echolog "Previous config not found - can not restore."; false; } &&
		{
			echolog "Restoring previous config."
			discard_config_changes
			nodie=1 load_main_config && check_lists_coherence
		} ||
			{
				restore_from_config previous
				die_m $?
			}
		backup_req=
		rv_conf=0 ;;
	*) restore_from_config
esac || die_m

[ "$rv_conf" = 0 ] && {
	bk_conf_only=
	[ "$backup_req" = 0 ] && bk_conf_only='-s'
	[ "$backup_req" ] && [ "$no_backup" != true ] && [ "$inbound_iplists$outbound_iplists" ] &&
		call_script -l "$i_script-backup.sh" create-backup "$bk_conf_only"

	[ "$first_setup" ] && touch "$CONF_DIR/setupdone"
	if [ "$cron_req" ]; then
		call_script "$i_script-cronsetup.sh" || echolog -err "$FAIL update cron jobs."
		[ "$_OWRTFW" ] && {
			case "$no_persist" in
				true) disable_owrt_persist ;;
				false)
					if [ -z "$inbound_iplists$outbound_iplists" ]; then
						[ ! -f "$CONF_DIR/no_persist" ] && touch "$CONF_DIR/no_persist"
						echolog "Countries list in the config file is empty! No point in creating firewall include."
					else
						rm -f "$CONF_DIR/no_persist"
						check_owrt_init && check_owrt_include || {
							rm_lock
							enable_owrt_persist
							rv_conf=$?
							[ -f "$LOCK_FILE" ] && {
								echo "Waiting for background processes to complete..."
								for i in $(seq 1 30); do
									[ ! -f "$LOCK_FILE" ] && break
									sleep 1
								done
								[ $i = 30 ] && echolog -warn "Lock file '$LOCK_FILE' is still in place. Please check system log."
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

die_m $rv_conf
