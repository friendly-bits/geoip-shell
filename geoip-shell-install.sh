#!/bin/sh
# shellcheck disable=SC2317,SC2086,SC1090,SC2154,SC2155,SC2034

# geoip-shell-install.sh

# Installer for geoip blocking suite of shell scripts

# Creates system folder structure for scripts, config and data.
# Copies all scripts included in the suite to /usr/sbin.
# Calls the *manage script to set up geoip-shell and then call the -fetch and -apply scripts.
# If an error occurs during installation, calls the uninstall script to revert any changes made to the system.
# Accepts a custom cron schedule expression as an argument.

#### Initial setup
proj_name="geoip-shell"
script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)

export nolog="1" manualmode="1" in_install="1"
makepath=1

. "$script_dir/${proj_name}-common.sh" || exit 1
. "$script_dir/ip-regex.sh"


check_root

sanitize_args "$@"
newifs "$delim"
set -- $arguments; oldifs


#### USAGE

usage() {
cat <<EOF

Usage: $me -c <"country_codes"> -m <whitelist|blacklist> [-s <"sch_expression"|disable>] [ -f <"families"> ]
            [-p <ports_options>] [-u <ripe|ipdeny>] [-t <host|router>] [-a] [-o] [-n] [-k] [-d] [-h]

Installer for geoip blocking suite of shell scripts.
Must be run as root.

Core Options:
-c <"country_codes">          : 2-letter country codes to fetch and apply the iplists for.
                                  (if passing multiple country codes, use double quotes)
-m <whitelist|blacklist>      : geoip blocking mode: whitelist or blacklist
                                  (to change the mode after installation, run the *install script again)
-s <"expression"|disable>     : schedule expression for the periodic cron job implementing auto-updates of the ip lists,
                                  must be inside double quotes
                                  default is "15 4 * * *" (4:15 am every day)
                                "disable" will disable automatic updates of the ip lists
-f <ipv4|ipv6|"ipv4 ipv6">    : families (defaults to 'ipv4 ipv6'). if specifying multiple families, use double quotes.
-u <ripe|ipdeny>              : Use this ip list source for download. Supported sources: ripe, ipdeny. Defaults to ripe.
-i <wan|all>                  : Specifies whether firewall rules will be applied to specific WAN network interface(s)
                                    or to all network interfaces.
                                    If the machine has a dedicated WAN interface, pick 'wan', otherwise pick 'all'.
                                    If not specified, asks during installation.
-p <"[allow|block]:proto:ports"> : Only geoblock incoming traffic on specific ports,
                                     or geoblock all incoming traffic except on specific ports.
                                     Multiple '-p' options are allowed.
                                     For details, refer to NOTES.md.

Extra Options:
-a  : Autodetect LAN subnets or WAN interfaces (depending on if geoip is applied to wan interfaces or to all interfaces).
          If not specified, asks during installation.
-o  : No backup. Will not create a backup of previous firewall state after applying changes.
-n  : No persistence. Geoip blocking may not work after reboot.
-k  : No Block: Skip creating the rule which redirects traffic to the geoip blocking chain
           (everything will be installed and configured but geoip blocking will not be enabled)
-d  : Debug
-h  : This help

EOF
}

#### PARSE ARGUMENTS

while getopts ":c:m:s:f:u:i:p:aonkdh" opt; do
	case $opt in
		c) ccodes=$OPTARG ;;
		m) list_type=$OPTARG ;;
		s) cron_schedule_args=$OPTARG ;;
		f) families_arg=$OPTARG ;;
		u) source_arg=$OPTARG ;;
		i) iface_type=$OPTARG ;;

		a) autodetect=1 ;;
		p) ports_arg="$ports_arg$OPTARG$_nl" ;;
		o) nobackup=1 ;;
		n) no_persistence=1 ;;
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
	destination="${install_dir}/"

	for scriptfile in $1; do
		rv=0
		cp -p "$script_dir/$scriptfile" "$destination" || install_failed "Error copying file '$scriptfile' to '$destination'."
		chown root:root "$destination$scriptfile" || rv=1
		chmod 555 "${destination}${scriptfile}" || rv=1
		[ "$rv" != 0 ] && install_failed "Error: failed to set permissions for file '${destination}${scriptfile}'."
	done
}

install_failed() {
	echo "$*" >&2
	printf '\n%s\n' "Installation failed." >&2
	echo "Uninstalling ${proj_name}..." >&2
	call_script "$script_dir/${proj_name}-uninstall.sh"
	exit 1
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
	return 0
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

	return 0
}

pick_iface() {
	all_ifaces="$(sed -n '/^[[:space:]]*[^[:space:]]*:/s/^[[:space:]]*//;s/:.*//p' < /proc/net/dev | grep -vx 'lo')"
	[ ! "$all_ifaces" ] && die "Error: Failed to detect network interfaces."
	sanitize_str all_ifaces

	# detect wan interfaces
	wan_ifaces=''
	checkutil ubus && { # for OpenWRT
		if [ -x /sbin/fw4 ]; then
			wan_ifaces="$(fw4 zone wan)"
		elif [ -x /sbin/fw3 ]; then
			wan_ifaces="$(fw3 zone wan)"
		fi
	}
	# fallback and non-OpenWRT
	[ ! "$wan_ifaces" ] && wan_ifaces="$({ ip r get 1; ip -6 r get 1::; } 2>/dev/null |
		sed 's/.*[[:space:]]dev[[:space:]][[:space:]]*//;s/[[:space:]].*//' | grep -vx 'lo')"
	sanitize_str wan_ifaces
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
		printf '\n%s\n' "Error: Network interfaces '$bad_ifaces' do not exist in this system."
	done
	sanitize_str c_wan_ifaces "$REPLY"
}

pick_subnets() {
	[ ! "$autodetect" ] &&
		printf '\n\n%s\n' "${yellow}*NOTE*${n_c}: In whitelist mode, traffic from your LAN subnets will be blocked, unless you whitelist them."
	for family in $families; do
		printf '\n%s\n' "Detecting local $family subnets..."
		s="$(sh "$script_dir/detect-local-subnets-AIO.sh" -s -f "$family")" || echo "Failed to autodetect $family local subnets."
		sanitize_str s

		[ -n "$s" ] && {
			printf '\n%s\n' "Autodetected $family LAN subnets: '$s'."
			[ "$autodetect" ] && { eval "c_lan_subnets_$family=\"$s\""; continue; }
			printf '%s\n%s\n' "(c)onfirm, c(h)ange, (s)kip or (a)bort installation? " \
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

#### CONSTANTS

iplist_dir="${datadir}/ip_lists"
default_schedule="15 4 * * *"

for f in fetch apply manage cronsetup run common uninstall backup ipt; do
	script_files="$script_files${proj_name}-$f.sh "
done
script_files="$script_files validate-cron-schedule.sh check-ip-in-source.sh \
	detect-local-subnets-AIO.sh posix-arrays-a-mini.sh ip-regex.sh "

#### VARIABLES

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
	* ) echo "$me: Error: invalid family '$families_arg'." >&2; exit 1
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
[ "$rv" != 0 ] && die "Error: Invalid 2-letter country codes: '${bad_ccodes% }'."

case "$list_type" in
	whitelist|blacklist) ;;
	'') usage; die "Specify firewall mode with '-m whitelist' or '-m blacklist'!" ;;
	*) die "Error: Unrecognized mode '$list_type'! Use either 'whitelist' or 'blacklist'!"
esac

[ ! "$families" ] && die "Error: \$families variable should not be empty!"

check_files "$script_files cca2.list" || die "Error: missing files: $missing_files."

if [ "$cron_schedule" != "disable" ] || [ ! "$no_persistence" ]; then
	# check cron service
	check_cron || die "Error: cron seems to not be enabled." "Enable the cron service before using this script." \
			"Or run with options '-n' '-s disable' which will disable persistence and autoupdates."
	[ ! "$cron_reboot" ] && [ ! "$no_persistence" ] && die "Error: cron-based persistence doesn't work with Busybox cron." \
		"If you want to install without persistence support, run with option '-n'"
fi

# validate cron schedule from arguments
[ "$cron_schedule_args" ] && {
	sh "$script_dir/validate-cron-schedule.sh" -x "$cron_schedule_args" || die "Error validating cron schedule '$cron_schedule'."
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

## run the *uninstall script to reset associated cron jobs, iptables rules and ipsets
call_script "$script_dir/${proj_name}-uninstall.sh" -r || die "Pre-install cleanup failed."

# Create the directory for config and, if required, parent directories
mkdir -p "$conf_dir"

# write config
printf %s "Setting config... "

setconfig "UserCcode=$user_ccode" "Lists=" "ListType=$list_type" "PATH=$PATH" "tcp=skip" "udp=skip" \
	"Source=$source" "Families=$families" "FamiliesDefault=$families_default" "CronSchedule=$cron_schedule" \
	"DefaultSchedule=$default_schedule" "LanIfaces=$c_lan_ifaces" "Autodetect=$autodetect_opt" \
	"LanSubnets_ipv4=$c_lan_subnets_ipv4" "LanSubnets_ipv6=$c_lan_subnets_ipv6" "WAN_ifaces=$c_wan_ifaces" \
	"RebootSleep=$sleeptime" "NoBackup=$nobackup" "NoPersistence=$no_persistence" "NoBlock=$noblock" "BackupFile=" "HTTP="
[ "$ports_arg" ] && { setports "${ports_arg%"$_nl"}" || install_failed; }
printf '%s\n' "Ok."

# Create the directory for downloaded lists and, if required, parent directories
mkdir -p "$iplist_dir"

## Copy scripts to $install_dir
printf %s "Copying scripts to $install_dir... "
copyscripts "$script_files"
printf '%s\n\n'  "Ok."

## Create a symlink from ${proj_name}-manage.sh to ${proj_name}
rm "${install_dir}/${proj_name}" 2>/dev/null
ln -s "${install_dir}/${proj_name}-manage.sh" "${install_dir}/${proj_name}" ||
	install_failed "Failed to create symlink from ${proj_name}-manage.sh to ${proj_name}."

# copy cca2.list
cp "$script_dir/cca2.list" "$install_dir" || install_failed "Error copying file 'cca2.list' to '$install_dir'."

# only allow root to read the $datadir and files inside it
# '600' means only the owner can read or write to the files
rv=0
chmod -R 600 "$datadir" || rv=1
chown -R root:root "$datadir" || rv=1
[ "$rv" != 0 ] && install_failed "Error: Failed to set permissions for '$datadir'."

### Add iplist(s) for $ccodes to managed iplists, then fetch and apply the iplist(s)
call_script "$install_dir/${proj_name}-manage.sh" add -f -c "$ccodes" || install_failed "Failed to create and apply the iplist."

if [ ! "$no_persistence" ] || [ "$cron_schedule" != "disable" ]; then
	### Set up cron jobs
	call_script "$install_dir/${proj_name}-manage.sh" schedule -s "$cron_schedule" || install_failed "Failed to set up cron jobs."
else
	printf '%s\n\n' "Warning: Installed with no persistence and no autoupdate functionality."
fi

statustip
echo "Install done."

exit 0
