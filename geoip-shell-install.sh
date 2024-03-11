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

. "$script_dir/$p_name-common.sh" || exit 1
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
		m) list_type=$OPTARG ;;
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
		z) nointeract=1 ;;
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
	missing_files=""
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
	for f in $1; do
		dest="${2:-"$install_dir/${f##*/}"}"
		{
			if [ "$_OWRTFW" ]; then
				# strip comments
				san_script "$script_dir/$f" > "$dest"
			else
				# replace the shebang
				printf '%s\n' "#!${curr_shell:-/bin/sh}" > "$dest"
				tail -n +2 "$script_dir/$f" >> "$dest"
			fi
		} || install_failed "$FAIL copy file '$f' to '$dest'."
		chown root:root "${dest}" && chmod 555 "$dest" || install_failed "$FAIL set permissions for file '${dest}${f}'."
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

# checks country code by asking the user, then validates against known-good list
pick_user_ccode() {
	[ "$user_ccode_arg" = none ] || { [ "$nointeract" ] && [ ! "$user_ccode_arg" ]; } && { user_ccode=''; return 0; }

	[ ! "$user_ccode_arg" ] && printf '\n%s\n%s\n' "Please enter your country code." \
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
	[ ! "$ccodes_arg" ] && printf '\n%s\n' "Please enter country codes to include in geoip $list_type."
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

pick_list_type() {
	printf '%s\n' "Select geoip blocking mode: [w]hitelist or [b]lacklist, or [a] to abort the installation."
	pick_opt "w|b|a"
	case "$REPLY" in
		w|W) list_type=whitelist ;;
		b|B) list_type=blacklist ;;
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
	printf '\n%s\n' "Geoip firewall rules will be applied to specific network interfaces of this machine."
	[ ! "$ifaces_arg" ] && [ "$auto_ifaces" ] && {
		printf '\n%s\n%s\n\n' "All network interfaces: $all_ifaces" \
			"Autodetected WAN interfaces: $auto_ifaces"
		[ "$1" = "-a" ] && { conf_ifaces="$auto_ifaces"; return; }
		printf '%s\n' "[c]onfirm, c[h]ange, or [a]bort installation? "
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
		printf '\n\n%s\n' "${yellow}*NOTE*${n_c}: In whitelist mode, traffic from your LAN subnets will be blocked, unless you whitelist them."

	for family in $families; do
		printf '\n%s\n' "Detecting $family LAN subnets..."
		s="$(call_script "$p_script-detect-lan.sh" -s -f "$family")" ||
			printf '%s\n' "$FAIL autodetect $family LAN subnets." >&2
		nl2sp s

		[ -n "$s" ] && {
			printf '\n%s\n' "Autodetected $family LAN subnets: '$s'."
			[ "$autodetect" ] && { eval "c_lan_subnets_$family=\"$s\""; continue; }
			printf '\n%s\n%s\n\n' "[c]onfirm, c[h]ange, [s]kip or [a]bort installation?" \
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
	printf '\n%s\n' "[A]uto-detect LAN subnets when updating ip lists or keep this config [c]onstant?"
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
		procd) . "$script_dir/OpenWrt/${p_name}-owrt-common.sh" || exit 1
	esac
	:
}

makepath() {
	d="$install_dir"
	case "$PATH" in *:"$d":*|"$d"|*:"$d"|"$d":* );; *) PATH="$PATH:$d"; esac
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

[ "$_OWRTFW" ] && {
	datadir="$conf_dir/data"
	o_script="OpenWrt/${p_name}-owrt"
	owrt_init="$o_script-init.tpl"
	owrt_fw_include="$o_script-fw-include.tpl"
	owrt_mk_fw_inc="$o_script-mk-fw-include.tpl"
	owrt_common_script="$o_script-common.sh"
	default_schedule="15 4 * * 5"
	source_default="ipdeny"
} || { datadir="/var/lib/${p_name}" default_schedule="15 4 * * *" source_default="ripe"; }

export datadir
iplist_dir="${datadir}/ip_lists"

detect_lan="${p_name}-detect-lan.sh"

ipt_libs=
[ "$_fw_backend" = ipt ] && ipt_libs="lib-ipt lib-apply-ipt lib-backup-ipt lib-status-ipt"
script_files=
for f in fetch apply manage cronsetup run uninstall backup common; do
	[ "$f" ] && script_files="$script_files${p_name}-$f.sh "
done
script_files="$script_files $owrt_common_script"

lib_files=
for f in lib-arrays lib-nft lib-apply-nft lib-backup-nft lib-status-nft lib-ip-regex $ipt_libs; do
	lib_files="${lib_files}lib/${p_name}-$f.sh "
done

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

export list_type="$(tolower "$list_type")"

lan_picked=


#### CHECKS

[ ! "$families" ] && die "\$families variable should not be empty!"

[ "$lan_subnets_arg" ] && [ "$list_type" = blacklist ] && die "option '-l' is incompatible with mode 'blacklist'"

check_files "$script_files $lib_files cca2.list $detect_lan $owrt_init $owrt_fw_include $owrt_mk_fw_inc" ||
	die "missing files: $missing_files."

check_cron_compat

# validate cron schedule from args
[ "$schedule_arg" ] && [ "$schedule" != "disable" ] && {
	call_script "$p_script-cronsetup.sh" -x "$schedule_arg" || die "$FAIL validate cron schedule '$schedule'."
}

#### MAIN

case "$list_type" in
	whitelist|blacklist) ;;
	'') [ "$nointeract" ] && die "Specify geoip blocking mode with -m <whitelist|blacklist>"; pick_list_type ;;
	*) die "Unrecognized mode '$list_type'! Use either 'whitelist' or 'blacklist'!"
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
	printf '\n%s\n%s\n%s\n\n%s\n' "Does this machine have dedicated WAN network interface(s)? [y|n] or [a] to abort the installation." \
		"For example, a router or a virtual private server may have it." \
		"A machine connected to a LAN behind a router is unlikely to have it." \
		"It is important to asnwer this question correctly."
	pick_opt "y|n|a"
	case "$REPLY" in
		a|A) exit 0 ;;
		y|Y) pick_ifaces ;;
		n|N) [ "$list_type" = whitelist ] && pick_lan_subnets
	esac
else
	case "$ifaces_arg" in
		all) [ "$list_type" = whitelist ] && pick_lan_subnets ;;
		auto) ifaces_arg=''; pick_ifaces -a ;;
		*) pick_ifaces
	esac
fi

[ "$lan_subnets_arg" ] && [ "$lan_subnets_arg" != none ] && [ ! "$lan_picked" ] && pick_lan_subnets

# don't copy the detect-lan script, unless autodetect is enabled
[ "$autodetect" ] || detect_lan=

## run the *uninstall script to reset associated cron jobs, firewall rules and ipsets
call_script "$p_script-uninstall.sh" || die "Pre-install cleanup failed."

## Copy scripts to $install_dir
printf %s "Copying scripts to $install_dir... "
copyscripts "$script_files $detect_lan $lib_files"
OK

lib_dir="$install_dir"

## Create a symlink from ${p_name}-manage.sh to ${p_name}
rm "$i_script" 2>/dev/null
ln -s "$i_script-manage.sh" "$i_script" || install_failed "$FAIL create symlink from ${p_name}-manage.sh to $p_name."

# Create the directory for config
mkdir -p "$conf_dir"

# write config
printf %s "Setting config... "

makepath
nodie=1
setconfig "UserCcode=$user_ccode" "Lists=" "ListType=$list_type" "tcp=skip" "udp=skip" \
	"Source=$source" "Families=$families" "CronSchedule=$schedule" "MaxAttempts=$max_attempts" \
	"Ifaces=$conf_ifaces" "Autodetect=$autodetect" "PerfOpt=$perf_opt" \
	"LanSubnets_ipv4=$c_lan_subnets_ipv4" "LanSubnets_ipv6=$c_lan_subnets_ipv6" \
	"TSubnets_ipv4=$t_subnets_ipv4" "TSubnets_ipv6=$t_subnets_ipv6" \
	"RebootSleep=$sleeptime" "NoBackup=$nobackup" "NoPersistence=$no_persist" "NoBlock=$noblock" "HTTP=" || install_failed

# add $install_dir to $PATH
add2list PATH "$install_dir" ':'

# set some variables in the -setvars script
cat <<- EOF > "${conf_dir}/${p_name}-setvars.sh" || install_failed "$FAIL set variables in the -setvars script"
	#!${curr_shell:-/bin/sh}
	export datadir="$datadir" lib_dir="$lib_dir" PATH="$PATH"
	export _lib="\$lib_dir/$p_name-lib" initsys="$initsys" default_schedule="$default_schedule" use_shell="$curr_shell"
EOF
OK

[ "$ports_arg" ] && { setports "${ports_arg%"$_nl"}" || install_failed; }

# Create the directory for downloaded lists
mkdir -p "$iplist_dir"

# copy cca2.list
cp "$script_dir/cca2.list" "$install_dir" || install_failed "$FAIL copy 'cca2.list' to '$install_dir'."

# only allow root to read the $datadir and files inside it
rv=0
chmod -R 600 "$datadir" "$conf_dir" || rv=1
chown -R root:root "$datadir" "$conf_dir" || rv=1
[ "$rv" != 0 ] && install_failed "$FAIL set permissions for '$datadir'."

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

	echo "_OWRT_install=1" >> "$i_script-common.sh"
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
				"install_dir=\"$install_dir\"" "fw_include_path=\"$fw_include\""
			san_script "$owrt_mk_fw_inc"
		} > "$mk_fw_inc" || install_failed "$FAIL prepare the firewall include."
		chmod +x "$init_script" "$fw_include" "$mk_fw_inc" || install_failed "$FAIL set permissions."

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
