#!/bin/sh
# shellcheck disable=SC2317,SC2154,SC2086,SC2034,SC1090

# geoip-shell-uninstall

# uninstalls or resets the geoip-shell suite


#### Initial setup
proj_name="geoip-shell"
script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)

. "$script_dir/${proj_name}-common.sh" || exit 1
. "$script_dir/geoip-shell-nft.sh" || exit 1

nolog=1

check_root

sanitize_args "$@"
newifs "$delim"
set -- $arguments; oldifs

#### USAGE

usage() {
    cat <<EOF

Usage: $me [-r] [-h]

1) Removes geoip firewall rules
2) Removes geoip cron jobs
3) Deletes scripts' data folder /var/lib/geoip-shell
4) Deletes the scripts from /usr/local/bin
5) Deletes the config folder /etc/geoip-shell

Options:
-l  : Reset ip lists and remove firewall geoip rules, don't uninstall
-c  : Reset ip lists and remove firewall geoip rules and cron jobs, don't uninstall
-r  : Remove cron jobs, geoip config and firewall geoip rules, don't uninstall
-h  : This help

EOF
}

#### PARSE ARGUMENTS

while getopts ":rlch" opt; do
	case $opt in
		l) resetonly_lists="-l" ;;
		c) reset_only_lists_cron=1 ;;
		r) resetonly="-r" ;;
		h) usage; exit 0;;
		*) unknownopt
	esac
done
shift $((OPTIND-1))

extra_args "$@"

echo

debugentermsg


### VARIABLES
install_dir="/usr/local/bin"

[ "$script_dir" != "$install_dir" ] && [ -f "$install_dir/${proj_name}-uninstall.sh" ] && [ ! "$norecur" ] && {
	export norecur=1 # prevents infinite loop
	call_script "$install_dir/${proj_name}-uninstall.sh" "$resetonly" "$resetonly_lists" && exit 0
}

getconfig "Datadir" "datadir" "" -nodie
datadir="${datadir:-/var/lib/${proj_name}}"
iplist_dir="${datadir}/ip_lists"
conf_dir="${conf_dir:-/etc/${proj_name}}"
status_file="${datadir}/ip_lists/status"

#### CHECKS

#### MAIN

printf '%s\n' "Cleaning up..."

### Delete geoip firewall rules
nft_rm_all_georules >/dev/null || die 1

[ -f "$conf_file" ] && setconfig "Lists="
set +f; rm "$iplist_dir"/* 2>/dev/null

[ "$resetonly_lists" ] && exit 0

### Remove geoip cron jobs
crontab -u root -l 2>/dev/null |  grep -v "${proj_name}-run.sh" | crontab -u root -

[ "$resetonly_lists_cron" ] && exit 0

# Delete the config file
rm "$conf_file" 2>/dev/null

[ "$resetonly" ] && exit 0

rm -rf "$datadir"

rm "${install_dir}/${proj_name}"

for script_name in fetch apply manage cronsetup run common uninstall backup nft; do
	rm "$install_dir/${proj_name}-${script_name}.sh" 2>/dev/null
done
for script_name in validate-cron-schedule check-ip-in-source detect-local-subnets-AIO posix-arrays-a-mini ip-regex; do
	rm "$install_dir/${script_name}.sh" 2>/dev/null
done

rm -rf "$conf_dir" 2>/dev/null

printf '%s\n\n' "Uninstall complete."

exit 0
