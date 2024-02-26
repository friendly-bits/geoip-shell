#!/bin/sh
# shellcheck disable=SC2317,SC2086,SC1090,SC2154,SC2155,SC2034

# geoip-shell-install.sh

# Copyright: friendly bits
# github.com/friendly-bits

# Installer for geoip blocking suite of shell scripts

# Creates system folder structure for scripts, config and data.
# Copies all scripts included in the suite to /usr/sbin.
# Calls the *manage script to set up geoip-shell and then call the -fetch and -apply scripts.
# If an error occurs during installation, calls the uninstall script to revert any changes made to the system.
# Accepts a custom cron schedule expression as an argument.

#### Initial setup
p_name="geoip-shell"
script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)

export nolog=1 manmode=1 in_install=1

. "$script_dir/${p_name}-common.sh" || exit 1
. "$script_dir/ip-regex.sh"

check_root

san_args "$@"
newifs "$delim"
set -- $_args; oldifs


#### USAGE

usage() {
cat <<EOF

Usage: $me -c <"country_codes"> -m <whitelist|blacklist> [-s <"sch_expression"|disable>] [ -f <"families"> ]
            [-u <ripe|ipdeny>] [-t <host|router>] [-p <portoptions>] [-a] [-e] [-o] [-n] [-k] [-d] [-h]

Installer for geoip blocking suite of shell scripts.
Must be run as root.

Core Options:
  -c <"country_codes">               : 2-letter country codes to fetch and apply the iplists for.
                                         (if passing multiple country codes, use double quotes)
  -m <whitelist|blacklist>           : geoip blocking mode: whitelist or blacklist
                                         (to change the mode after installation, run the *install script again)
  -s <"expression"|disable>          : schedule expression for the periodic cron job implementing auto-updates of the ip lists,
                                         must be inside double quotes
                                         default is "15 4 * * *" (4:15 am every day)
                                       "disable" will disable automatic updates of the ip lists
  -f <ipv4|ipv6|"ipv4 ipv6">         : families (defaults to 'ipv4 ipv6'). if specifying multiple families, use double quotes.
  -u <ripe|ipdeny>                   : Use this ip list source for download. Supported sources: ripe, ipdeny. Defaults to ripe.
  -i <wan|all>                       : Specifies whether geoip firewall rules will be applied to specific WAN network interface(s)
                                           or to all network interfaces.
                                           If the machine has a dedicated WAN interface, pick 'wan', otherwise pick 'all'.
                                           If not specified, asks during installation.
  -p <[tcp:udp]:[allow|block]:ports> : For given protocol (tcp/udp), use "block" to only geoblock incoming traffic on specific ports,
                                          or use "allow" to geoblock all incoming traffic except on specific ports.
                                          Multiple '-p' options are allowed to specify both tcp and udp in one command.
                                          Only works with the 'apply' action.
                                          For examples, refer to NOTES.md.

Extra Options:
  -a  : Autodetect LAN subnets or WAN interfaces (depending on if geoip is applied to wan interfaces or to all interfaces).
            If not specified, asks during installation.
  -e  : Optimize ip sets for performance (by default, optimizes for low memory consumption)
  -o  : No backup. Will not create a backup of previous firewall state after applying changes.
  -n  : No persistence. Geoip blocking may not work after reboot.
  -k  : No Block: Skip creating the rule which redirects traffic to the geoip blocking chain
             (everything will be installed and configured but geoip blocking will not be enabled)
  -d  : Debug
  -h  : This help

EOF
}

#### PARSE ARGUMENTS

while getopts ":c:m:s:f:u:i:r:p:aeonkdh" opt; do
	case $opt in
		c) ccodes=$OPTARG ;;
		m) list_type=$OPTARG ;;
		s) cron_schedule_args=$OPTARG ;;
		f) families_arg=$OPTARG ;;
		u) source_arg=$OPTARG ;;
		i) iface_type=$OPTARG ;;

		r) ports_arg=$OPTARG ;;
		a) autodetect=1 ;;
		e) perf_opt=performance ;;
		p) ports_arg="$ports_arg$OPTARG$_nl" ;;
		o) nobackup=1 ;;
		n) no_persist=1 ;;
		k) noblock=1 ;;
		d) export debugmode=1 ;;
		h) usage; exit 0 ;;
		*) unknownopt
	esac
done
shift $((OPTIND-1))
extra_args "$@"

echo

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
	for scriptfile in $1; do
		destination="${2:-"$install_dir/${scriptfile##*/}"}"
		rv=0
		{
			if [ "$_OWRTFW" ]; then
				# strip comments
				grep -v "^[[:space:]]*#[^\!]" "$script_dir/$scriptfile" > "$destination"
			else
				cp "$script_dir/$scriptfile" "$destination"
			fi
		} || install_failed "$FAIL copy file '$scriptfile' to '$destination'."
		chown root:root "${destination}" &&
		chmod 555 "$destination" || install_failed "$FAIL set permissions for file '${destination}${scriptfile}'."
	done
}

install_failed() {
	printf '%s\n\n%s\n%s\n' "$*" "Installation failed." "Uninstalling ${p_name}..." >&2
	call_script "$script_dir/${p_name}-uninstall.sh"
	exit 1
}

# format: '-r proto:A-B; proto:C-D,E,F-G; proto:H'
get_ports() {

	invalid_line() { usage; die "Invalid value for '-r': '$sourceline'."; }
	check_edge_chars() {
		[ "${1%"${1#?}"}" = "$2" ] && invalid_line
		[ "${1#"${1%?}"}" = "$2" ] && invalid_line
	}
	sourceline="$1"
	trimsp line "$sourceline"
	check_edge_chars "$line" ";"
	IFS=";"
	for opt in $line; do
		case "$opt" in *:*) ;; *) invalid_line; esac
		proto="${opt%%:}"
		ports="${opt#:}"
		case "$ports" in *:*) invalid_line; esac
		trimsp ports
		trimsp proto
		case $proto in
			udp|tcp) ;;
			*) die "Unsupported protocol '$proto'."
		esac
		check_edge_chars "$ports" ","
		IFS=","
		for chunk in $ports; do
			trimsp chunk
			check_edge_chars "$chunk" "-"
			case "${chunks%%-}" in *-*) invalid_line; esac
			fragments=''
			IFS="-"
			for fragment in $chunk; do
				trimsp fragment
				case "$fragment" in *[!0-9]*) invalid_line; esac
				fragments="${fragments}{fragment}-}"
			done
			fragments="${fragments%-}"
		done
	done

}

# checks country code by asking the user, then validates against known-good list
get_country() {
	user_ccode=""

	printf '\n%s\n%s\n%s\n' "Please enter your country code." \
		"It will be used to check if your geoip settings may lock you out of your remote machine and warn you if so." \
		"If you want to skip this check, press Enter." >&2
	while true; do
		printf '%s\n' "Country code (2 letters)/Enter to skip: " >&2
		read -r REPLY
		case "$REPLY" in
			'') printf '%s\n\n' "Skipping..." >&2; return 0 ;;
			*) REPLY="$(toupper "$REPLY")"
				validate_ccode "$REPLY" "$script_dir/cca2.list"; rv=$?
				case "$rv" in
					0)  user_ccode="$REPLY"; break ;;
					1)  die "Internal error while trying to validate country codes." ;;
					2)  printf '\n%s\n%s\n\n' "'$REPLY' is not a valid 2-letter country code." \
						"Try again or press Enter to skip this check." >&2
				esac
		esac
	done

	printf %s "$user_ccode"
	:
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

pick_iface() {
	all_ifaces="$(sed -n '/^[[:space:]]*[^[:space:]]*:/s/^[[:space:]]*//;s/:.*//p' < /proc/net/dev | grep -vx 'lo')"
	[ ! "$all_ifaces" ] && die "$FAIL detect network interfaces."
	san_str all_ifaces

	# detect OpenWrt wan interfaces
	wan_ifaces=''
	[ "$_OWRTFW" ] && wan_ifaces="$(fw$_OWRTFW zone wan)"

	# fallback and non-OpenWRT
	[ ! "$wan_ifaces" ] && wan_ifaces="$({ ip r get 1; ip -6 r get 1::; } 2>/dev/null |
		sed 's/.*[[:space:]]dev[[:space:]][[:space:]]*//;s/[[:space:]].*//' | grep -vx 'lo')"
	san_str wan_ifaces
	get_intersection "$wan_ifaces" "$all_ifaces" wan_ifaces ' '

	printf '\n%s\n' "Firewall rules will be applied to the WAN network interfaces of your machine."
	[ "$wan_ifaces" ] && {
		printf '\n%s\n%s\n\n' "All network interfaces: $all_ifaces" \
			"Autodetected WAN interfaces: $wan_ifaces"
		[ "$autodetect" ] && { c_wan_ifaces="$wan_ifaces"; return; }
		printf '%s\n' "(c)onfirm, c(h)ange, or (a)bort installation? "
		pick_opt "c|h|a"
		case "$REPLY" in
			c|C) c_wan_ifaces="$wan_ifaces"; return ;;
			a|A) exit 0
		esac
	}
	while true; do
		printf '\n%s\n%s\n' "All network interfaces: $all_ifaces" \
			"Type in WAN network interface names (whitespace separated), or Enter to abort installation."
		read -r REPLY
		[ -z "$REPLY" ] && exit 0
		subtract_a_from_b "$all_ifaces" "$REPLY" bad_ifaces ' '
		[ -z "$bad_ifaces" ] && break
		printf '\n%s\n' "$ERR Network interfaces '$bad_ifaces' do not exist in this system."
	done
	san_str c_wan_ifaces "$REPLY"
}

pick_subnets() {
	[ ! "$autodetect" ] &&
		printf '\n\n%s\n' "${yellow}*NOTE*${n_c}: In whitelist mode, traffic from your LAN subnets will be blocked, unless you whitelist them."
	for family in $families; do
		printf '\n%s\n' "Detecting local $family subnets..."
		s="$(sh "$script_dir/detect-local-subnets-AIO.sh" -s -f "$family")" || printf '%s\n' "$FAIL autodetect $family local subnets."
		san_str s

		[ -n "$s" ] && {
			printf '\n%s\n' "Autodetected $family LAN subnets: '$s'."
			[ "$autodetect" ] && { eval "c_lan_subnets_$family=\"$s\""; continue; }
			printf '%s\n%s\n' "(c)onfirm, c(h)ange, (s)kip or (a)bort installation?" \
				"Verify that correct LAN subnets have been detected in order to avoid problems."
			pick_opt "c|h|s|a"
			case "$REPLY" in
				c|C) eval "c_lan_subnets_$family=\"$s\""; continue ;;
				s|S) continue ;;
				a|A) exit 0
			esac
		}
		autodetect_off=1
		while true; do
			printf '\n%s\n' "Type in $family LAN subnets (whitespace separated), or Enter to abort installation."
			read -r REPLY
			[ -z "$REPLY" ] && exit 0
			bad_subnet=''
			for subnet in $REPLY; do
				validate_subnet "$subnet" || { bad_subnet=1; break; }
			done
			[ ! "$bad_subnet" ] && break
		done
		eval "c_lan_subnets_$family=\"$REPLY\""
	done
	[ "$autodetect" ] || [ "$autodetect_off" ] && return
	printf '\n%s\n' "(A)uto-detect local subnets when autoupdating and at launch or keep this config (c)onstant?"
	pick_opt "a|c"
	autodetect=''
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


#### Variables

# detect the init system
detect_sys

[ "$_OWRTFW" ] && {
	datadir="$conf_dir/data"
	init_script_tpl="OpenWrt/${p_name}-init.tpl"
	fw_include_tpl="OpenWrt/${p_name}-fw-include.tpl"
	mk_fw_inc_script_tpl="OpenWrt/${p_name}-mk-fw-include.tpl"
	owrt_common_script="OpenWrt/${p_name}-owrt-common.sh"
} || datadir="/var/lib/${p_name}"

export datadir
iplist_dir="${datadir}/ip_lists"

default_schedule="15 4 * * *"

ipt_libs='' ipt_script=
[ "$_fw_backend" = ipt ] && { ipt_libs="apply-ipt backup-ipt"; ipt_script="ipt"; }
script_files=
for f in fetch apply manage cronsetup run uninstall backup common nft "$ipt_script"; do
	[ "$f" ] && script_files="$script_files${p_name}-$f.sh "
done
script_files="$script_files validate-cron-schedule.sh detect-local-subnets-AIO.sh ip-regex.sh \
	detect-local-subnets-AIO.sh posix-arrays-a-mini.sh $owrt_common_script"

lib_files=
for f in apply-nft backup-nft $ipt_libs; do
	lib_files="${lib_files}lib/${p_name}-$f.sh "
done

source_default="ripe"
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
	* ) printf '%s\n' "$me: $ERR invalid family '$families_arg'." >&2; exit 1
esac

ccodes="$(toupper "$ccodes")"

cron_schedule="${cron_schedule_args:-$default_schedule}"
sleeptime="30"

export list_type="$(tolower "$list_type")"


#### CHECKS

# Check for valid country codes
[ ! "$ccodes" ] && { usage; die "Specify country codes with '-c <\"country_codes\">'!"; }
rv=0
for ccode in $ccodes; do
	validate_ccode "$ccode" "$script_dir/cca2.list" || { bad_ccodes="$bad_ccodes$ccode "; rv=1; }
done
[ "$rv" != 0 ] && die "$ERR Invalid 2-letter country codes: '${bad_ccodes% }'."

case "$list_type" in
	whitelist|blacklist) ;;
	'') usage; die "Specify firewall mode with '-m whitelist' or '-m blacklist'!" ;;
	*) die "$ERR Unrecognized mode '$list_type'! Use either 'whitelist' or 'blacklist'!"
esac

[ ! "$families" ] && die "$ERR \$families variable should not be empty!"

check_files "$script_files cca2.list $init_script_tpl $fw_include_tpl $mk_fw_inc_script_tpl" || die "$ERR missing files: $missing_files."

check_cron_compat

# validate cron schedule from args
[ "$cron_schedule_args" ] && [ "$cron_schedule" != "disable" ] && {
	sh "$script_dir/validate-cron-schedule.sh" -x "$cron_schedule_args" || die "$FAIL validate cron schedule '$cron_schedule'."
}

#### MAIN

user_ccode="$(get_country)"

case "$iface_type" in
	'') ;;
	all) REPLY=n ;;
	wan) REPLY=y ;;
	*) usage; die "Invalid string for the '-i' option: '$iface_type'."
esac

[ -z "$iface_type" ] && {
	printf '\n%s\n%s\n%s\n%s\n' "Does this machine have dedicated WAN interface(s)? (y|n)" \
		"For example, a router or a virtual private server may have it." \
		"A machine connected to a LAN behind a router is unlikely to have it." \
		"It is important to asnwer this question correctly."
	pick_opt "y|n"
}
case "$REPLY" in
	y|Y) pick_iface ;;
	n|N) [ "$list_type" = "whitelist" ] && pick_subnets
esac

## run the *uninstall script to reset associated cron jobs, firewall rules and ipsets
call_script "$script_dir/${p_name}-uninstall.sh" || die "Pre-install cleanup failed."

## Copy scripts to $install_dir
printf %s "Copying scripts to $install_dir... "
copyscripts "$script_files" && copyscripts "$lib_files"
OK
echo

## Create a symlink from ${p_name}-manage.sh to ${p_name}
rm "${install_dir}/${p_name}" 2>/dev/null
ln -s "${install_dir}/${p_name}-manage.sh" "${install_dir}/${p_name}" ||
	install_failed "$FAIL create symlink from ${p_name}-manage.sh to ${p_name}."

# Create the directory for config and, if required, parent directories
mkdir -p "$conf_dir"

# write config
printf %s "Setting config... "

makepath
setconfig "nodie=1" "UserCcode=$user_ccode" "Lists=" "ListType=$list_type" "tcp=skip" "udp=skip" \
	"Source=$source" "Families=$families" "CronSchedule=$cron_schedule"  \
	"LanIfaces=$c_lan_ifaces" "Autodetect=$autodetect" "PerfOpt=$perf_opt" \
	"LanSubnets_ipv4=$c_lan_subnets_ipv4" "LanSubnets_ipv6=$c_lan_subnets_ipv6" "WAN_ifaces=$c_wan_ifaces" \
	"RebootSleep=$sleeptime" "NoBackup=$nobackup" "NoPersistence=$no_persist" "NoBlock=$noblock" "HTTP=" || install_failed
[ "$ports_arg" ] && { setports "${ports_arg%"$_nl"}" || install_failed; }
printf '%s\n' "datadir=$datadir PATH=\"$PATH\" initsys=$initsys default_schedule=\"$default_schedule\"" >> \
	"$install_dir/${p_name}-common.sh" || install_failed "$FAIL set variables in the -common script"
OK

# Create the directory for downloaded lists and, if required, parent directories
mkdir -p "$iplist_dir"

# copy cca2.list
cp "$script_dir/cca2.list" "$install_dir" || install_failed "$FAIL copy 'cca2.list' to '$install_dir'."

# only allow root to read the $datadir and files inside it
rv=0
chmod -R 600 "$datadir" || rv=1
chown -R root:root "$datadir" || rv=1
[ "$rv" != 0 ] && install_failed "$FAIL set permissions for '$datadir'."

### Add iplist(s) for $ccodes to managed iplists, then fetch and apply the iplist(s)
call_script "$install_dir/${p_name}-manage.sh" add -f -c "$ccodes" || install_failed "$FAIL create and apply the iplist."

WARN_F="$WARN Installed without"

if [ "$schedule" != "disable" ] || [ ! "$no_cr_persist" ]; then
	### Set up cron jobs
	call_script "$install_dir/${p_name}-cronsetup.sh" || install_failed "$FAIL set up cron jobs."
else
	printf '%s\n\n' "$WARN_F ${cr_p2}autoupdate functionality."
fi

# OpenWrt-specific stuff
[ "$_OWRTFW" ] && {
	init_script="/etc/init.d/${p_name}-init"
	fw_include_script="$install_dir/${p_name}-fw-include.sh"
	mk_fw_inc_script="$install_dir/${p_name}-mk-fw-include.sh"

	echo "_OWRT_install=1" >> "$install_dir/${p_name}-common.sh"
	if [ "$schedule" = "disable" ]; then
		printf '%s\n\n' "$WARN_F persistence functionality."
	else
		printf %s "Adding the init script... "
		eval "printf '%s\n' \"$(cat "$init_script_tpl")\" > \"$init_script\"" || install_failed "$FAIL create the init script."
		OK

		printf %s "Preparing the firewall include... "
		eval "printf '%s\n' \"$(cat "$fw_include_tpl")\" > \"$fw_include_script\"" &&
		{
			printf '%s\n%s\n%s\n%s\n' "#!/bin/sh" "p_name=$p_name" \
				"install_dir=\"$install_dir\"" "fw_include_path=\"$fw_include_script\""
			grep -v "^[[:space:]]*#[^\!]" "$mk_fw_inc_script_tpl"
		} > "$mk_fw_inc_script" ||
			install_failed "$FAIL prepare the firewall include."
		chmod +x "$init_script" "$fw_include_script" "$mk_fw_inc_script" || install_failed "$FAIL set permissions."
		OK

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

exit 0
