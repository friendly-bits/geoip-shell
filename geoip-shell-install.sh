#!/bin/sh
# shellcheck disable=SC2317,SC2086,SC1090,SC2154,SC2155,SC2034

# geoip-shell-install.sh

# Copyright: friendly bits
# github.com/friendly-bits

# Installer for geoip blocking suite of shell scripts

# Creates system folder structure for scripts, config and data.
# Copies the required scripts to /usr/sbin.
# Calls the *manage script to set up geoip-shell and then call the -run script.
# If an error occurs during installation, calls the uninstall script to revert any changes made to the system.

#### Initial setup
p_name="geoip-shell"
script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)

export manmode=1 in_install=1

. "$script_dir/$p_name-geoinit.sh" || exit 1
. "$_lib-ip-regex.sh"
export nolog=1

san_args "$@"
newifs "$delim"
set -- $_args; oldifs


#### USAGE

usage() {
cat <<EOF

Usage: $me [-c <"country_codes">] [-m <whitelist|blacklist>] [-s <"expression"|disable>] [ -f <"families"> ] [-u <ripe|ipdeny>]
           [-i <"ifaces"|auto|all>] [-l <"lan_subnets"|auto|none>] [-b <"trusted_subnets"] [-p <port_options>]
           [-a] [-e] [-o] [-n] [-k] [-z] [-d] [-h]

Installer for the $p_name suite.
Asks the user about each required option, except those specified.

Core Options:

  -m <whitelist|blacklist> : Geoip blocking mode: whitelist or blacklist.

  -c <"country_codes"> : 2-letter country codes to include in the whitelist|blacklist.

  -f <ipv4|ipv6|"ipv4 ipv6"> : Families (defaults to 'ipv4 ipv6'). Use double quotes for multiple families.

  -u <ripe|ipdeny> : Use this ip list source for download. Supported sources: ripe, ipdeny.

  -s <"expression"|disable> :
        Schedule expression for the periodic cron job implementing automatic update of the ip lists.
        Must be inside double quotes.
        'disable' will disable automatic updates of the ip lists.

  -i <"[ifaces]"|auto|all> :
        Specifies whether geoip firewall rules will be applied to specific network interface(s)
        or to all network interfaces.
        Generally, if the machine has dedicated WAN interfaces, specify them, otherwise pick 'all'.
        'auto' will autodetect WAN interfaces (this will cause problems if the machine has no direct WAN connection)

  -l <"[lan_subnets]"|auto|none> :
        Specifies LAN subnets to exclude from geoip blocking (both ipv4 and ipv6).
        Has no effect in blacklist mode.
        Generally, in whitelist mode, if the machine has no dedicated WAN interfaces,
        specify LAN subnets to avoid blocking them. Otherwise you probably don't need this.
        'auto' will autodetect LAN subnets during installation and every update of the ip lists.
        *Don't use 'auto' if the machine has a dedicated WAN interface*

  -t <"[trusted_subnets]"> :
        Specifies trusted subnets to exclude from geoip blocking (both ipv4 and ipv6).
        This option works independently from the above LAN subnets option.
        Works in both whitelist and blacklist mode.

  -p <tcp|udp>:<allow|block>:<all|[ports]> :
        For given protocol (tcp/udp), use "block" to only geoblock incoming traffic on specific ports,
        or use "allow" to geoblock all incoming traffic except on specific ports.
        Specifying 'all' does what one would expect.
        Multiple '-p' options are allowed to specify both tcp and udp in one command.
        Only works with the 'apply' action.

  -r <[user_country_code]|none> :
        Specify user's country code. Used to prevent accidental lockout of a remote machine.
        "none" disables this feature.

Extra Options:
  -e : Optimize nftables ip sets for performance (by default, optimizes for low memory consumption). Has no effect with iptables.
  -o : No backup. Will not create a backup of previous firewall state after applying changes.
  -n : No persistence. Geoip blocking may not work after reboot.
  -k : No Block: Skip creating the rule which redirects traffic to the geoip blocking chain.
         (everything will be installed and configured but geoip blocking will not be enabled)
  -z : Non-interactive installation. Will not ask any questions. Will fail if required options are not specified or invalid.
  -d : Debug
  -h : This help

EOF
}

#### PARSE ARGUMENTS

while getopts ":c:m:s:f:u:i:l:r:p:t:eonkdhz" opt; do
	case $opt in
		c) ccodes_arg=$OPTARG ;;
		m) geomode=$OPTARG ;;
		s) schedule_arg=$OPTARG ;;
		f) families_arg=$OPTARG ;;
		u) source_arg=$OPTARG ;;
		i) ifaces_arg=$OPTARG ;;
		l) lan_subnets_arg=$OPTARG ;;
		t) t_subnets_arg=$OPTARG ;;
		p) ports_arg="$ports_arg$OPTARG$_nl" ;;
		r) user_ccode_arg=$OPTARG ;;

		e) perf_opt=performance ;;
		o) nobackup=1 ;;
		n) no_persist=1 ;;
		k) noblock=1 ;;
		d) export debugmode=1 ;;
		z) export nointeract=1 ;;
		h) usage; exit 0 ;;
		*) unknownopt
	esac
done
shift $((OPTIND-1))
extra_args "$@"

check_root
debugentermsg


#### FUNCTIONS

check_files() {
	missing_files=
	err=0
	for dep_file in $1; do
		if [ ! -s "$script_dir/$dep_file" ]; then
			missing_files="${missing_files}'$dep_file', "
			err=$((err+1))
		fi
	done
	missing_files="${missing_files%, }"
	return "$err"
}

copyscripts() {
	[ "$1" = '-n' ] && { _mod=444; shift; } || _mod=555
	for f in $1; do
		dest="$install_dir/${f##*/}"
		[ "$2" ] && dest="$2/${f##*/}"
		{
			if [ "$_OWRTFW" ]; then
				# strip comments
				san_script "$script_dir/$f" > "$dest"
			else
				# replace the shebang
				printf '%s\n' "#!${curr_sh:-/bin/sh}" > "$dest"
				tail -n +2 "$script_dir/$f" >> "$dest"
			fi
		} || install_failed "$FAIL copy file '$f' to '$dest'."
		chown root:root "${dest}" && chmod "$_mod" "$dest" || install_failed "$FAIL set permissions for file '${dest}${f}'."
	done
}

install_failed() {
	printf '%s\n\n%s\n%s\n' "$*" "Installation failed." "Uninstalling ${p_name}..." >&2
	call_script "$p_script-uninstall.sh"
	exit 1
}

validate_subnet() {
	case "$1" in */*) ;; *) printf '%s\n' "Invalid subnet '$1': missing '/[maskbits]'." >&2; return 1; esac
	maskbits="${1#*/}"
	case "$maskbits" in ''|*[!0-9]*) printf '%s\n' "Invalid mask bits '$maskbits' in subnet '$1'." >&2; return 1; esac
	ip="${1%%/*}"
	case "$family" in
		ipv4 ) ip_len_bits=32; ip_regex="$ipv4_regex" ;;
		ipv6 ) ip_len_bits=128; ip_regex="$ipv6_regex" ;;
	esac

	case $(( (maskbits<8) | (maskbits>ip_len_bits)  )) in 1)
		printf '%s\n' "Invalid $family mask bits '$maskbits'." >&2; return 1
	esac

	ip route get "$ip" 1>/dev/null 2>/dev/null
	case $? in 0|2) ;; *) { printf '%s\n' "ip address '$ip' failed kernel validation." >&2; return 1; }; esac
	printf '%s\n' "$ip" | grep -vE "^$ip_regex$" > /dev/null
	[ $? != 1 ] && { printf '%s\n' "$family address '$ip' failed regex validation." >&2; return 1; }
	:
}

pick_shell() {
	unset sh_msg s_shs_avail f_shs_avail
	curr_sh_b="${curr_sh##*"/"}"
	is_included "$curr_sh_b" "${simple_sh}|busybox sh" "|" && return 0
	newifs "|" psh
	for ___sh in $simple_sh; do
		checkutil "$___sh" && add2list s_shs_avail "$___sh"
	done
	oldifs psh
	[ -z "$s_shs_avail" ] && [ -n "$ok_sh" ] && return 0
	newifs "|" psh
	for ___sh in $fancy_sh; do
		checkutil "$___sh" && add2list f_shs_avail "$___sh"
	done
	oldifs psh
	[ -z "$f_shs_avail" ] && return 0
	is_included "$curr_sh_b" "$fancy_sh" "|" && sh_msg="Your fancy shell '$curr_sh_b' is supported by $p_name" ||
		sh_msg="I'm running under an unsupported/uknown shell '$curr_sh_b'"
	if [ -n "$s_shs_avail" ]; then
		recomm_sh="${s_shs_avail%% *}"
		rec_sh_type="simple"
	elif [ -n "$f_shs_avail" ]; then
		recomm_sh="${f_shs_avail%% *}"
		rec_sh_type="supported"
	fi
	printf '\n%s\n%s\n' "$blue$sh_msg but a $rec_sh_type shell '$recomm_sh' is available in this system, using it instead is recommended.$n_c" "Would you like to use '$recomm_sh' with $p_name? [y|n] or [a] to abort installation."
	pick_opt "y|n|a"
	case "$REPLY" in
		a|A) exit 0 ;;
		y|Y) curr_sh="$(command -v "$recomm_sh")" ;;
		n|N) if [ -n "$bad_sh" ]; then exit 1; fi
	esac
}

# checks country code by asking the user, then validates against known-good list
pick_user_ccode() {
	[ "$user_ccode_arg" = none ] || { [ "$nointeract" ] && [ ! "$user_ccode_arg" ]; } && { user_ccode=''; return 0; }

	[ ! "$user_ccode_arg" ] && printf '\n%s\n%s\n' "${blue}Please enter your country code.$n_c" \
		"It will be used to check if your geoip settings may block your own country and warn you if so."
	REPLY="$user_ccode_arg"
	while true; do
		[ ! "$REPLY" ] && {
			printf %s "Country code (2 letters)/Enter to skip: "
			read -r REPLY
		}
		case "$REPLY" in
			'') printf '%s\n\n' "Skipped."; return 0 ;;
			*) REPLY="$(toupper "$REPLY")"
				validate_ccode "$REPLY" "$script_dir/cca2.list"; rv=$?
				case "$rv" in
					0)  user_ccode="$REPLY"; break ;;
					1)  die "Internal error while trying to validate country codes." ;;
					2)  printf '\n%s\n' "'$REPLY' is not a valid 2-letter country code."
						[ "$nointeract" ] && exit 1
						printf '%s\n\n' "Try again or press Enter to skip this check."
						REPLY=
				esac
		esac
	done
}

# asks the user to entry country codes, then validates against known-good list
pick_ccodes() {
	[ "$nointeract" ] && [ ! "$ccodes_arg" ] && die "Specify country codes with '-c <\"country_codes\">'."
	[ ! "$ccodes_arg" ] && printf '\n%s\n' "${blue}Please enter country codes to include in geoip $geomode.$n_c"
	REPLY="$ccodes_arg"
	while true; do
		unset bad_ccodes ok_ccodes
		[ ! "$REPLY" ] && {
			printf %s "Country codes (2 letters) or [a] to abort the installation: "
			read -r REPLY
		}
		REPLY="$(toupper "$REPLY")"
		trimsp REPLY
		case "$REPLY" in
			a|A) exit 0 ;;
			*)
				newifs ' ;,' pcc
				for ccode in $REPLY; do
					[ "$ccode" ] && {
						validate_ccode "$ccode" "$script_dir/cca2.list" && ok_ccodes="$ok_ccodes$ccode " ||
							bad_ccodes="$bad_ccodes$ccode "
					}
				done
				oldifs pcc
				[ "$bad_ccodes" ] && {
					printf '%s\n' "Invalid 2-letter country codes: '${bad_ccodes% }'."
					[ "$nointeract" ] && exit 1
					REPLY=
					continue
				}
				[ ! "$ok_ccodes" ] && {
					printf '%s\n' "No country codes detected in '$REPLY'."
					[ "$nointeract" ] && exit 1
					REPLY=
					continue
				}
				ccodes="${ok_ccodes% }"; break
		esac
	done
}

pick_geomode() {
	printf '\n%s\n' "${blue}Select geoip blocking mode:$n_c [w]hitelist or [b]lacklist, or [a] to abort the installation."
	pick_opt "w|b|a"
	case "$REPLY" in
		w|W) geomode=whitelist ;;
		b|B) geomode=blacklist ;;
		a|A) exit 0
	esac
}

pick_ifaces() {
	all_ifaces="$(detect_ifaces)" || die "$FAIL detect network interfaces."

	[ ! "$ifaces_arg" ] && {
		# detect OpenWrt wan interfaces
		auto_ifaces=
		[ "$_OWRTFW" ] && auto_ifaces="$(fw$_OWRTFW zone wan)"

		# fallback and non-OpenWRT
		[ ! "$auto_ifaces" ] && auto_ifaces="$({ ip r get 1; ip -6 r get 1::; } 2>/dev/null |
			sed 's/.*[[:space:]]dev[[:space:]][[:space:]]*//;s/[[:space:]].*//' | grep -vx 'lo')"
		san_str auto_ifaces
		get_intersection "$auto_ifaces" "$all_ifaces" auto_ifaces
		nl2sp auto_ifaces
	}

	nl2sp all_ifaces
	printf '\n%s\n' "${yellow}*NOTE*: ${blue}Geoip firewall rules will be applied to specific network interfaces of this machine.$n_c"
	[ ! "$ifaces_arg" ] && [ "$auto_ifaces" ] && {
		printf '%s\n%s\n' "All found network interfaces: $all_ifaces" \
			"Autodetected WAN interfaces: $blue$auto_ifaces$n_c"
		[ "$1" = "-a" ] && { conf_ifaces="$auto_ifaces"; return; }
		printf '%s\n' "[c]onfirm, c[h]ange, or [a]bort installation?"
		pick_opt "c|h|a"
		case "$REPLY" in
			c|C) conf_ifaces="$auto_ifaces"; return ;;
			a|A) exit 0
		esac
	}

	REPLY="$ifaces_arg"
	while true; do
		u_ifaces=
		printf '\n%s\n' "All found network interfaces: $all_ifaces"
		[ ! "$REPLY" ] && {
			printf '%s\n' "Type in WAN network interface names, or [a] to abort installation."
			read -r REPLY
			case "$REPLY" in a|A) exit 0; esac
		}
		san_str -s u_ifaces "$REPLY"
		[ -z "$u_ifaces" ] && {
			printf '%s\n' "No interface names detected in '$REPLY'." >&2
			[ "$nointeract" ] && die
			REPLY=
			continue
		}
		subtract_a_from_b "$all_ifaces" "$u_ifaces" bad_ifaces ' '
		[ -z "$bad_ifaces" ] && break
		echolog -err "Network interfaces '$bad_ifaces' do not exist in this system."
		echo
		[ "$nointeract" ] && die
		REPLY=
	done
	conf_ifaces="$u_ifaces"
	printf '%s\n' "Selected interfaces: '$conf_ifaces'."
}

pick_lan_subnets() {
	lan_picked=1 autodetect=
	case "$lan_subnets_arg" in
		none) return 0 ;;
		auto) lan_subnets_arg=''; autodetect=1 ;;
	esac

	[ "$lan_subnets_arg" ] && {
		unset bad_subnet lan_subnets
		san_str lan_subnets_arg "$lan_subnets_arg" ' ' "$_nl"
		for family in $families; do
			eval "lan_subnets_$family="
			eval "ip_regex=\"\$subnet_regex_$family\""
			subnets="$(printf '%s\n' "$lan_subnets_arg" | grep -E "^$ip_regex$")"
			san_str subnets
			[ ! "$subnets" ] && continue
			for subnet in $subnets; do
				validate_subnet "$subnet" || bad_subnet=1
			done
			[ "$bad_subnet" ] && break
			nl2sp "c_lan_subnets_$family" "$subnets"
			lan_subnets="$lan_subnets$subnets$_nl"
		done
		subtract_a_from_b "$lan_subnets" "$lan_subnets_arg" bad_subnets
		[ "${lan_subnets% }" ] && [ ! "$bad_subnet" ] && [ ! "$bad_subnets" ] && return 0
		[ "$bad_subnets" ] &&
			echolog -err "'$bad_subnets' are not valid subnets for families '$families'."
		[ ! "$bad_subnet" ] && [ ! "${lan_subnets% }" ] &&
			echolog -err "No valid subnets detected in '$lan_subnets_arg' compatible with families '$families'."
	}

	[ "$nointeract" ] && [ ! "$autodetect" ] && die "Specify lan subnets with '-l <\"lan_subnets\"|auto|none>'."

	[ ! "$nointeract" ] &&
		printf '\n\n%s\n' "${yellow}*NOTE*: ${blue}In whitelist mode, traffic from your LAN subnets will be blocked, unless you whitelist them.$n_c"

	for family in $families; do
		printf '\n%s\n' "Detecting $family LAN subnets..."
		s="$(call_script "$p_script-detect-lan.sh" -s -f "$family")" ||
			printf '%s\n' "$FAIL autodetect $family LAN subnets." >&2
		nl2sp s

		[ -n "$s" ] && {
			printf '%s\n' "Autodetected $family LAN subnets: '$blue$s$n_c'."
			[ "$autodetect" ] && { eval "c_lan_subnets_$family=\"$s\""; continue; }
			printf '%s\n%s\n' "[c]onfirm, c[h]ange, [s]kip or [a]bort installation?" \
				"Verify that correct LAN subnets have been detected in order to avoid problems."
			pick_opt "c|h|s|a"
			case "$REPLY" in
				c|C) eval "c_lan_subnets_$family=\"$s\""; continue ;;
				s|S) continue ;;
				h|H) autodetect_off=1 ;;
				a|A) exit 0
			esac
		}

		REPLY=
		while true; do
			unset u_subnets bad_subnet
			[ ! "$nointeract" ] && [ ! "$REPLY" ] && {
				printf '\n%s\n' "Type in $family LAN subnets, [s] to skip or [a] to abort installation."
				read -r REPLY
				case "$REPLY" in
					s|S) break ;;
					a|A) exit 0
				esac
			}
			san_str -s u_subnets "$REPLY"
			[ -z "$u_subnets" ] && {
				printf '%s\n' "No $family subnets detected in '$REPLY'." >&2
				REPLY=
				continue
			}
			for subnet in $u_subnets; do
				validate_subnet "$subnet" || bad_subnet=1
			done
			[ ! "$bad_subnet" ] && break
			REPLY=
		done
		eval "c_lan_subnets_$family=\"$u_subnets\""
	done

	[ "$autodetect" ] || [ "$autodetect_off" ] && return
	printf '\n%s\n' "${blue}[A]uto-detect LAN subnets when updating ip lists or keep this config [c]onstant?$n_c"
	pick_opt "a|c"
	case "$REPLY" in a|A) autodetect="1"; esac
}

detect_sys() {
	# init process is pid 1
	_pid1="$(ls -l /proc/1/exe)"
	for initsys in systemd procd initctl busybox upstart unknown; do
		case "$_pid1" in *"$initsys"* ) break; esac
	done
	[ "$initsys" = unknown ] && case "$_pid1" in *"/sbin/init"* )
		for initsys in systemd upstart unknown; do
			case "$_pid1" in *"$initsys"* ) break; esac
		done
	esac
	case "$initsys" in
		unknown) return 1 ;;
		procd) . "$script_dir/OpenWrt/${p_name}-lib-owrt-common.sh" || exit 1; curr_sh="/bin/sh"
	esac
	:
}

# removes comments
# 1 - (optional) input filename, otherwise reads from STDIN
san_script() {
	p="^[[:space:]]*#[^\!].*$"
	if [ "$1" ]; then grep -vx "$p" "$1"; else grep -vx "$p"; fi
}


#### Detect the init system
detect_sys

#### Variables

export conf_dir="/etc/$p_name"
[ "$_OWRTFW" ] && {
	datadir="$conf_dir/data"
	o_script="OpenWrt/${p_name}-owrt"
	owrt_init="$o_script-init.tpl"
	owrt_fw_include="$o_script-fw-include.tpl"
	owrt_mk_fw_inc="$o_script-mk-fw-include.tpl"
	owrt_comm="OpenWrt/${p_name}-lib-owrt-common.sh"
	default_schedule="15 4 * * 5"
	source_default="ipdeny"
} || {
	datadir="/var/lib/${p_name}" default_schedule="15 4 * * *" source_default="ripe" check_compat="check-compat"
	init_check_compat=". \"\${_lib}-check-compat.sh\" || exit 1"
}

detect_lan="${p_name}-detect-lan.sh"

script_files=
for f in fetch apply manage cronsetup run uninstall backup; do
	[ "$f" ] && script_files="$script_files${p_name}-$f.sh "
done

unset lib_files ipt_libs
[ "$_fw_backend" = ipt ] && ipt_libs="ipt apply-ipt backup-ipt status-ipt"
for f in common arrays nft apply-nft backup-nft status-nft ip-regex $check_compat $ipt_libs; do
	lib_files="${lib_files}lib/${p_name}-lib-$f.sh "
done
lib_files="$lib_files $owrt_comm"

source_arg="$(tolower "$source_arg")"
case "$source_arg" in ''|ripe|ipdeny) ;; *) usage; die "Unsupported source: '$source_arg'."; esac
source="${source_arg:-$source_default}"

families_default="ipv4 ipv6"
[ "$families_arg" ] && families_arg="$(tolower "$families_arg")"
case "$families_arg" in
	inet|inet6|'inet inet6'|'inet6 inet' ) families="$families_arg" ;;
	''|'ipv4 ipv6'|'ipv6 ipv4' ) families="$families_default" ;;
	ipv4 ) families="ipv4" ;;
	ipv6 ) families="ipv6" ;;
	* ) echolog -err "invalid family '$families_arg'."; exit 1
esac

ccodes="$(toupper "$ccodes")"

schedule="${schedule_arg:-$default_schedule}"
sleeptime=30 max_attempts=30

export geomode="$(tolower "$geomode")"

lan_picked=


#### CHECKS

[ ! "$families" ] && die "\$families variable should not be empty!"

[ "$lan_subnets_arg" ] && [ "$geomode" = blacklist ] && die "option '-l' is incompatible with mode 'blacklist'"

check_files "$script_files $lib_files cca2.list $detect_lan $owrt_init $owrt_fw_include $owrt_mk_fw_inc" ||
	die "missing files: $missing_files."

check_cron_compat

# validate cron schedule from args
[ "$schedule_arg" ] && [ "$schedule" != "disable" ] && {
	call_script "$p_script-cronsetup.sh" -x "$schedule_arg" || die "$FAIL validate cron schedule '$schedule'."
}


#### MAIN

[ ! "$_OWRTFW" ] && [ ! "$nointeract" ] && pick_shell

case "$geomode" in
	whitelist|blacklist) ;;
	'') [ "$nointeract" ] && die "Specify geoip blocking mode with -m <whitelist|blacklist>"; pick_geomode ;;
	*) die "Unrecognized mode '$geomode'! Use either 'whitelist' or 'blacklist'!"
esac

# process trusted subnets if specified
[ "$t_subnets_arg" ] && {
	t_subnets=
	san_str t_subnets_arg "$t_subnets_arg" ' ' "$_nl"
	for family in $families; do
		eval "t_subnets_$family="
		eval "ip_regex=\"\$subnet_regex_$family\""
		subnets="$(printf '%s\n' "$t_subnets_arg" | grep -E "^$ip_regex$")"
		[ ! "$subnets" ] && continue
		for subnet in $subnets; do
			validate_subnet "$subnet" || die
		done
		t_subnets="$t_subnets$subnets$_nl"
		san_str subnets
		nl2sp "t_subnets_$family" "$subnets"
	done
	subtract_a_from_b "$t_subnets" "$t_subnets_arg" bad_subnets
	nl2sp bad_subnets
	[ "$bad_subnets" ] && die "'$bad_subnets' are not valid subnets for families '$families'."
	[ -z "${t_subnets% }" ] && die "No valid subnets detected in '$t_subnets_arg' compatible with families '$families'."
}

pick_ccodes

pick_user_ccode

if [ -z "$ifaces_arg" ]; then
	[ "$nointeract" ] && die "Specify interfaces with -i <\"ifaces\"|auto|all>."
	printf '\n%s\n%s\n%s\n%s\n' "${blue}Does this machine have dedicated WAN network interface(s)?$n_c [y|n] or [a] to abort the installation." \
		"For example, a router or a virtual private server may have it." \
		"A machine connected to a LAN behind a router is unlikely to have it." \
		"It is important to answer this question correctly."
	pick_opt "y|n|a"
	case "$REPLY" in
		a|A) exit 0 ;;
		y|Y) pick_ifaces ;;
		n|N) [ "$geomode" = whitelist ] && pick_lan_subnets
	esac
else
	case "$ifaces_arg" in
		all) [ "$geomode" = whitelist ] && pick_lan_subnets ;;
		auto) ifaces_arg=''; pick_ifaces -a ;;
		*) pick_ifaces
	esac
fi

export datadir lib_dir="/usr/lib"
export _lib="$lib_dir/$p_name-lib" conf_file="$conf_dir/$p_name.conf" use_shell="$curr_sh"

[ "$lan_subnets_arg" ] && [ "$lan_subnets_arg" != none ] && [ ! "$lan_picked" ] && pick_lan_subnets

# don't copy the detect-lan script, unless autodetect is enabled
[ "$autodetect" ] || detect_lan=

## run the *uninstall script to reset associated cron jobs, firewall rules and ipsets
call_script "$p_script-uninstall.sh" || die "Pre-install cleanup failed."

## Copy scripts to $install_dir
printf %s "Copying scripts to $install_dir... "
copyscripts "$script_files $detect_lan"
OK

printf %s "Copying library scripts to $lib_dir... "
copyscripts -n "$lib_files" "$lib_dir"
OK

## Create a symlink from ${p_name}-manage.sh to ${p_name}
rm "$i_script" 2>/dev/null
ln -s "$i_script-manage.sh" "$i_script" || install_failed "$FAIL create symlink from ${p_name}-manage.sh to $p_name."

# Create the directory for config
mkdir -p "$conf_dir"

# write config
printf %s "Setting config... "

# add $install_dir to $PATH
add2list PATH "$install_dir" ':'

# set some variables in the -init script
cat <<- EOF > "$conf_dir/${p_name}-consts" || install_failed "$FAIL set essential variables."
	export conf_dir="$conf_dir" datadir="$datadir" PATH="$PATH" initsys="$initsys" default_schedule="$default_schedule"
	export conf_file="$conf_file" status_file="$datadir/status" use_shell="$curr_sh"
EOF

. "$conf_dir/${p_name}-consts"

# create the -init script
cat <<- EOF > "${i_script}-geoinit.sh" || install_failed "$FAIL create the -geoinit script"
	export lib_dir="$lib_dir"
	export _lib="\$lib_dir/\${p_name}-lib"
	$init_check_compat
	. "\${_lib}-common.sh" || exit 1
	if [ -z "\$root_ok" ] && [ "\$(id -u)" = 0 ]; then
		_no_l="\$nolog"
		. "$conf_dir/\${p_name}-consts" || exit 1
		{ nolog=1 check_deps nft 2>/dev/null && export _fw_backend=nft; } ||
		{ check_deps iptables ip6tables iptables-save ip6tables-save iptables-restore ip6tables-restore ipset && export _fw_backend=ipt
		} || die "neither nftables nor iptables+ipset found."
		export root_ok=1
		r_no_l
	fi
EOF

nodie=1
setconfig "UserCcode=$user_ccode" "Lists=" "Geomode=$geomode" "tcp=skip" "udp=skip" \
	"Source=$source" "Families=$families" "CronSchedule=$schedule" "MaxAttempts=$max_attempts" \
	"Ifaces=$conf_ifaces" "Autodetect=$autodetect" "PerfOpt=$perf_opt" \
	"LanSubnets_ipv4=$c_lan_subnets_ipv4" "LanSubnets_ipv6=$c_lan_subnets_ipv6" \
	"TSubnets_ipv4=$t_subnets_ipv4" "TSubnets_ipv6=$t_subnets_ipv6" \
	"RebootSleep=$sleeptime" "NoBackup=$nobackup" "NoPersistence=$no_persist" "NoBlock=$noblock" "HTTP=" || install_failed
OK

[ "$ports_arg" ] && { setports "${ports_arg%"$_nl"}" || install_failed; }

# copy cca2.list
cp "$script_dir/cca2.list" "$conf_dir/" || install_failed "$FAIL copy 'cca2.list' to '$conf_dir'."

# only allow root to read the $datadir and $conf_dir and files inside it
mkdir -p "$datadir" &&
chmod -R 600 "$datadir" "$conf_dir" &&
chown -R root:root "$datadir" "$conf_dir" ||
install_failed "$FAIL to create '$datadir'."

### Add iplist(s) for $ccodes to managed iplists, then fetch and apply the iplist(s)
call_script "$i_script-manage.sh" add -f -c "$ccodes" || install_failed "$FAIL create and apply the iplist."

WARN_F="$WARN Installed without"

if [ "$schedule" != disable ] || [ ! "$no_cr_persist" ]; then
	### Set up cron jobs
	call_script "$i_script-cronsetup.sh" || install_failed "$FAIL set up cron jobs."
else
	printf '%s\n\n' "$WARN_F ${cr_p2}autoupdate functionality."
fi

# OpenWrt-specific stuff
[ "$_OWRTFW" ] && {
	init_script="/etc/init.d/${p_name}-init"
	fw_include="$i_script-fw-include.sh"
	mk_fw_inc="$i_script-mk-fw-include.sh"

	echo "export _OWRT_install=1" >> "$conf_dir/${p_name}-consts"
	if [ "$no_persist" ]; then
		printf '%s\n\n' "$WARN_F persistence functionality."
	else
		echo "Adding the init script... "
		eval "printf '%s\n' \"$(cat "$owrt_init")\"" | san_script > "$init_script" ||
			install_failed "$FAIL create the init script."

		echo "Preparing the firewall include... "
		eval "printf '%s\n' \"$(cat "$owrt_fw_include")\"" | san_script > "$fw_include" &&
		{
			printf '%s\n%s\n%s\n%s\n' "#!/bin/sh" "p_name=$p_name" \
				"install_dir=\"$install_dir\"" "fw_include_path=\"$fw_include\" _lib=\"$_lib\""
			san_script "$owrt_mk_fw_inc"
		} > "$mk_fw_inc" || install_failed "$FAIL prepare the firewall include."
		chmod +x "$init_script" && chmod 555 "$fw_include" "$mk_fw_inc" || install_failed "$FAIL set permissions."

		printf %s "Enabling and starting the init script... "
		$init_script enable && $init_script start || install_failed "$FAIL enable or start the init script."
		sleep 1
		check_owrt_init || install_failed "$FAIL enable '$init_script'."
		check_owrt_include || install_failed "$FAIL add firewall include."
		OK
	fi
}

statustip
echo "Install done."
