#!/bin/sh
# shellcheck disable=SC2317,SC2154,SC1090,SC2086,SC2034

# geoip-shell-fetch.sh

#### Initial setup
proj_name="geoip-shell"
script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)

. "$script_dir/${proj_name}-common.sh" || exit 1
. "$script_dir/posix-arrays-a-mini.sh" || exit 1
. "$script_dir/ip-regex.sh"

sanitize_args "$@"
newifs "$delim"
set -- $arguments; oldifs


#### USAGE

usage() {
    cat <<EOF

Usage: $me -l <"list_ids"> -p <path> [-o <output_file>] [-s <status_file>] [-u <"source">] [-f] [-d] [-h]

    1) Fetches ip subnets for given country codes from RIPE API or from ipdeny
        (RIPE seems to store lists for all countries)
        (supports any combination of ipv4 and ipv6 lists)

    2) Parses, validates the downloaded lists, and saves each one to a separate file.

Options:
    -l <"list_id's">  : List id's in the format '<ccode>_<family>'. If passing multiple list id's, use double quotes.
    -p <path>         : Path to directory where downloaded and compiled subnet lists will be stored.
    -o <output_file>  : Path to output file where fetched list will be stored.
                           With this option, specify exactly 1 country code.
                           (use either '-p' or '-o' but not both)
    -s <status_file>  : Path to a status file to register fetch results in.
    -u <"source">     : Source for the download. Currently supports 'ripe' and 'ipdeny'.
 
    -r                : Raw mode (outputs newline-delimited list)
    -f                : force using fetched lists even if list timestamp didn't change compared to existing list
    -d                : Debug
    -h                : This help

EOF
}


#### Parse arguments

while getopts ":l:p:o:s:u:rfdh" opt; do
	case $opt in
		l) lists_arg=$OPTARG ;;
		p) iplist_dir=$OPTARG ;;
		s) status_file=$OPTARG ;;
		o) output_file=$OPTARG ;;
		u) source_arg=$OPTARG ;;

		r) raw_mode=1 ;;
		f) force_update=1 ;;
		d) debugmode_args=1 ;;
		h) usage; exit 0 ;;
		*) unknownopt
	esac
done
shift $((OPTIND-1))
extra_args "$@"

setdebug

debugentermsg


#### FUNCTIONS

# converts yyyymmdd to yyyy-mm-dd
# 1 - raw date
# 2 - var name for output
date_raw_to_compat() {
	[ -z "$1" ] && return 1
	mon_temp="${1#????}"
	eval "$2=\"${1%????}-${mon_temp%??}-${1#??????}\""
}

reg_server_date() {
	case "$1" in
		[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9] )
			set_a_arr_el server_dates_arr "$2=$1"
			debugprint "Got date from $3 for '$2': '$1'."
			;;
		*) debugprint "Failed to get date from $3 for '$2'."
	esac
}

# get list time based on the file date on the server
get_source_list_dates_ipdeny() {
	tmp_file_path="/tmp/${proj_name}_ipdeny"

	_res=''
	for list_id in $valid_lists; do
		f="${list_id#*_}"; case "$_res" in *"$f"*) ;; *) _res="$_res$f$_nl"; esac
	done
	families="${_res%_nl}"


	for family in $families; do
		case "$family" in
			ipv4) server_url="$ipdeny_ipv4_url" ;;
			ipv6) server_url="$ipdeny_ipv6_url"
		esac
		debugprint "getting listing from url '$server_url'..."

		server_html_file="${tmp_file_path}_dl_page_${family}.tmp"
		server_plaintext_file="${tmp_file_path}_plaintext_${family}.tmp"
		# debugprint "timestamp fetch command: '$fetch_cmd \"${server_url}\" > \"$server_html_file\""
		$fetch_cmd_q "$server_url" > "$server_html_file"

		debugprint "Processing $family listing on the IPDENY server..."

		# 1st part of awk strips HTML tags, 2nd part trims extra spaces
		[ -f "$server_html_file" ] && awk '{gsub("<[^>]*>", "")} {$1=$1};1' "$server_html_file" > "$server_plaintext_file" ||
			echolog "Error: failed to fetch server dates from the IPDENY server."
		rm "$server_html_file" 2>/dev/null
	done

	for list_id in $valid_lists; do
		curr_ccode="${list_id%%_*}"
		family="${list_id#*_}"
		server_plaintext_file="${tmp_file_path}_plaintext_${family}.tmp"
		# picks the line for the correct entry, then picks the 2nd field which is the date
		# matches that to date in format 'dd-Mon-20yy', then converts to 'yyyymmdd'
		[ -f "$server_plaintext_file" ] && server_date="$(
			awk -v c="$curr_ccode" '($1==tolower(c)"-aggregated.zone" && $2 ~ /^[0-3][0-9]-...-20[1-9][0-9]$/) {split($2,d,"-");
				$1 = sprintf("%04d%02d%02d", d[3],index("  JanFebMarAprMayJunJulAugSepOctNovDec",d[2])/3,d[1]); print $1}' \
				"$server_plaintext_file"
		)"

		reg_server_date "$server_date" "$list_id" "IPDENY"
	done

	for family in $families; do rm "${tmp_file_path}_plaintext_${family}.tmp" 2>/dev/null; done
}

# get list time based on the filename on the server
get_source_list_dates_ripe() {
	server_html_file="/tmp/geoip-shell_server_dl_page.tmp"

	for registry in $registries; do
		server_url="$ripe_url_stats"/"$(tolower "$registry")"

		debugprint "getting listing from url '$server_url'..."
		[ ! "$server_url" ] && { echolog -err "get_source_list_dates_ripe(): $server_url variable should not be empty!"; return 1; }

		# debugprint "timestamp fetch command: '$fetch_cmd_q \"${server_url}\" > \"$server_html_file\""
		$fetch_cmd_q "$server_url" > "$server_html_file"

		debugprint "Processing the listing..."
		# gets a listing and filters it by something like '-xxxxxxxx.md5' where x's are numbers,
		# then cuts out everything but the numbers, sorts and gets the latest one
		# based on a heuristic but it's a standard format and unlikely to change
		server_date="$(grep -oE '\-[0-9]{8}\.md5' < "$server_html_file" | cut -b 2-9 | sort -V | tail -n1)"

		rm "$server_html_file" 2>/dev/null
		get_a_arr_val fetch_lists_arr "$registry" list_ids
		for list_id in $list_ids; do
			reg_server_date "$server_date" "$list_id" "RIPE"
		done
	done
}

parse_ripe_json() {
	in_list="$1" out_list="$2" family="$3"
	sed -n -e /"$family"/\{:1 -e n\;/]/q\;p\;b1 -e \} "$in_list" | cut -d\" -f2 > "$out_list"
	[ -s "$out_list" ]; return $?
}

# populates $registries, "fetch_lists_arr" array)
group_lists_by_registry() {
	valid_lists=''
	# group lists by registry
	for registry in $all_registries; do
		list_ids=''
		for list_id in $lists_arg; do
			ccode="${list_id%_*}"
			get_a_arr_val registry_ccodes_arr "$registry" ccodes
			case "$ccodes" in *" ${ccode} "* )
				registries="$registries$registry "
				list_ids="$list_ids$list_id "
				valid_lists="$valid_lists$list_id$_nl"
			esac
		done
		sanitize_str list_ids
		set_a_arr_el fetch_lists_arr "$registry=${list_ids% }"
	done
	sanitize_str registries

	subtract_a_from_b "$valid_lists" "$lists_arg" invalid_lists
	[ "$invalid_lists" ] && {
		for invalid_list in $invalid_lists; do
			invalid_ccodes="$invalid_ccodes${invalid_list%_*} "
		done
		sanitize_str invalid_ccodes
		die "Invalid country codes: '$invalid_ccodes'."
	}
}

# checks the status faile
# and populates variables $prev_list_reg, $prev_date_raw, $prev_date_compat, $prev_s_cnt
check_prev_list() {
	unset_prev_vars() { unset prev_list_reg prev_date_raw prev_date_compat prev_s_cnt; }

	list_id="$1"
	unset_prev_vars

	# if $status_file is set and physically exists, get LastFailedSubnetsCnt_${list_id} from the status file
	if [ "$status_file" ] && [ -s "$status_file" ]; then
		getstatus "$status_file" "PrevSubnetsCnt_${list_id}" prev_s_cnt
		case "$prev_s_cnt" in
			''|0)
				debugprint "Previous subnets count for '$list_id' is 0."
				unset_prev_vars
				;;
			*)
				prev_list_reg="true"
				getstatus "$status_file" "PrevDate_${list_id}" "prev_date_compat"; rv=$?
				case "$rv" in
					1) die "Failed to read the status file." ;;
					2) debugprint "Note: status file '$status_file' has no information for list '$purple$list_id$n_c'."
						unset_prev_vars
				esac
				[ "$prev_date_compat" ] && {
					p="$prev_date_compat"
					mon_temp="${p#?????}"
					prev_date_raw="${p%??????}${mon_temp%???}${p#????????}"
				}
		esac
	else
		debugprint "Status file '$status_file' either doesn't exist or is empty."
		unset_prev_vars
	fi
}

# checks whether any of the ip lists need update
# and populates $up_to_date_lists, lists_need_update accordingly
check_updates() {
	unset lists_need_update up_to_date_lists

	time_now="$(date +%s)"

	printf '\n%s\n\n' "Checking for ip list updates on the $dl_src_cap server..."

	case "$dl_src" in
		ipdeny ) get_source_list_dates_ipdeny ;;
		ripe ) get_source_list_dates_ripe ;;
		* ) die "Unknown source: '$dl_src'."
	esac

	ccodes=''; families=''
	for list_id in $valid_lists; do
		get_a_arr_val server_dates_arr "$list_id" date_src_raw
		date_raw_to_compat "$date_src_raw" date_src_compat

		if [ ! "$date_src_compat" ]; then
			echolog -err "Warning: failed to get the timestamp from the server for list '$list_id'. Will try to fetch anyway."
			date_src_raw="$(date +%Y%m%d)"; force_update=1
			date_raw_to_compat "$date_src_raw" date_src_compat
		fi

		time_source="$(date -d "$date_src_compat" +%s)"

		time_diff=$(( time_now - time_source ))

		# warn the user if the date on the server is older than now by more than a week
		if [ "$time_diff" -gt 604800 ]; then
			msg1="Warning: newest ip list for list '$list_id' on the $dl_src_cap server is dated '$date_src_compat' which is more than 7 days old."
			msg2="Either your clock is incorrect, or '$dl_src_cap' is not updating the list for '$list_id'."
			msg3="If it's the latter, please notify the developer."
			echolog -err "$msg1" "$msg2" "$msg3"
		fi

		# debugprint "checking $list_id"
		check_prev_list "$list_id"

		if [ "$prev_list_reg" ] && [ "$date_src_raw" -le "$prev_date_raw" ] && [ ! "$force_update" ] && [ ! "$manualmode" ]; then
			up_to_date_lists="$up_to_date_lists$list_id "
		else
			ccode="${list_id%_*}"; case "$ccodes" in *"$ccode"*) ;; *) ccodes="$ccodes$ccode "; esac
			family="${list_id#*_}"; case "$families" in *"$family"*) ;; *) families="$families$family "; esac
		fi
	done

	ccodes_need_update="${ccodes% }"
	families="${families% }"

	if [ "$up_to_date_lists" ]; then
		echolog "Ip lists '${purple}${up_to_date_lists% }${n_c}' are already ${green}up-to-date${n_c} with the $dl_src_cap server."
	fi

	return 0
}

list_failed() {
	rm "$fetched_list" "$parsed_list" "$valid_list" 2>/dev/null
	failed_lists="$failed_lists$list_id "
	[ "$1" ] && echolog -err "$1"
}

process_ccode() {

	curr_ccode="$1"; curr_ccode_lc="$(tolower "$curr_ccode")"
	unset prev_list_reg list_path fetched_list
	set +f; rm -f "/tmp/${proj_name}_"*.tmp; set -f

	for family in $families; do
		list_id="${curr_ccode}_${family}"
		case "$dl_src" in
			ripe ) dl_url="${ripe_url_api}v4_format=prefix&resource=${curr_ccode}" ;;
			ipdeny )
				case "$family" in
					"ipv4" ) dl_url="${ipdeny_ipv4_url}/${curr_ccode_lc}-aggregated.zone" ;;
					* ) dl_url="${ipdeny_ipv6_url}/${curr_ccode_lc}-aggregated.zone"
				esac ;;
			* ) die "Unsupported source: '$dl_src'."
		esac

		# set list_path to $output_file if it is set, or to $iplist_dir/$list_id otherwise
		list_path="${output_file:-$iplist_dir/$list_id.iplist}"

		# temp files
		parsed_list="/tmp/${proj_name}_parsed-${list_id}.tmp"
		fetched_list="/tmp/${proj_name}_fetched-$curr_ccode.tmp"

		valid_s_cnt=0
		failed_s_cnt=0

		# checks the status file and populates $prev_list_reg, $prev_date_raw
		check_prev_list "$list_id"

		if [ ! -s "$fetched_list" ]; then
			case "$dl_src" in
				ripe ) printf '%s\n' "Fetching ip list for country '${purple}$curr_ccode${n_c}' from $dl_src_cap..." ;;
				ipdeny ) printf '%s\n' "Fetching ip list for '${purple}$list_id${n_c}' from $dl_src_cap..."
			esac

			debugprint "fetch command: $fetch_cmd \"$dl_url\" > \"$fetched_list\""
			$fetch_cmd "$dl_url" > "$fetched_list" ||
				{ list_failed "Failed to fetch the ip list for '$list_id' from the $dl_src_cap server."; continue; }
			printf '%s\n\n' "Fetch successful."
		fi

		case "$dl_src" in
			ripe)
				printf %s "Parsing ip list for '${purple}$list_id${n_c}'... "
				parse_ripe_json "$fetched_list" "$parsed_list" "$family" ||
					{ list_failed "Failed to parse the ip list for '$list_id'."; continue; }
				echo "Ok." ;;
			ipdeny) mv "$fetched_list" "$parsed_list"
		esac

		printf %s "Validating '$purple$list_id$n_c'... "
		# Validates the parsed list, populates the $valid_s_cnt, failed_s_cnt variables
		validate_list "$list_id"
		rm "$parsed_list" 2>/dev/null

		[ "$failed_s_cnt" = 0 ] && echo "Ok." || { echo "Failed."; continue; }

		printf '%s\n\n' "Validated subnets for '$purple$list_id$n_c': $valid_s_cnt."
		check_subnets_cnt_drop "$list_id" || { list_failed; continue; }

		debugprint "Updating $list_path... "
		{ [ "$raw_mode" ] && cat "$valid_list" || {
				printf %s "elements={ "
				tr '\n' ',' < "$valid_list"
				printf '%s\n' "}"
			}
		} > "$list_path" || { list_failed "Failed to overwrite the file '$list_path'"; continue; }

		touch -d "$date_src_compat" "$list_path"
		fetched_lists="$fetched_lists$list_id "
		set_a_arr_el subnets_cnt_arr "$list_id=$valid_s_cnt"
		set_a_arr_el list_date_arr "$list_id=$date_src_compat"

		rm "$valid_list" 2>/dev/null
	done

	rm "$fetched_list" 2>/dev/null
	return 0
}

validate_list() {
	list_id="$1"
	# todo: change to mktemp?
	valid_list="/tmp/validated-${list_id}.tmp"
	family="${list_id#*_}"

	case "$family" in "ipv4" ) subnet_regex="$subnet_regex_ipv4" ;; *) subnet_regex="$subnet_regex_ipv6"; esac
	grep -E "^$subnet_regex$" "$parsed_list" > "$valid_list"

	parsed_s_cnt=$(wc -w < "$parsed_list")
	valid_s_cnt=$(wc -w < "$valid_list")
	failed_s_cnt=$(( parsed_s_cnt - valid_s_cnt ))

	if [ "$failed_s_cnt" != 0 ]; then
		failed_s="$(grep -Ev  "$subnet_regex" "$parsed_list")"

		list_failed "${_nl}NOTE: out of $parsed_s_cnt subnets for ip list '${purple}$list_id${n_c}, $failed_s_cnt subnets ${red}failed validation${n_c}'."
		if [ $failed_s_cnt -gt 10 ]; then
				echo "First 10 failed subnets:"
				printf '%s\n' "$failed_s" | head -n10
				printf '\n'
		else
			printf '%s\n%s\n\n' "Following subnets failed validation:" "$failed_s"
		fi
	fi
}

# compares current validated subnets count to previous one
check_subnets_cnt_drop() {
	list_id="$1"
	if [ "$valid_s_cnt" = 0 ]; then
		echolog -err "Warning: validated 0 subnets for list '$purple$list_id$n_c'. Perhaps the country code is incorrect?" >&2
		return 1
	fi

	# Check if subnets count decreased dramatically compared to the old list
	if [ "$prev_list_reg" ]; then
		# compare fetched subnets count to old subnets count, get result in %
		s_percents="$((valid_s_cnt * 100 / prev_s_cnt))"
		case $((s_percents < 90)) in
			1) echolog -err "Warning: validated subnets count '$valid_s_cnt' in the fetched list '$purple$list_id$n_c'" \
				"is ${s_percents}% of '$prev_s_cnt' subnets in the existing list dated '$prev_date_compat'." \
				"Not updating the list."
				return 1 ;;
			*) debugprint "Validated $family subnets count for list '$purple$list_id$n_c' is ${s_percents}% of the count in the old list."
		esac
	fi
}


#### CONSTANTS

all_registries="ARIN RIPENCC APNIC AFRINIC LACNIC"

newifs "$_nl" cca
cca2_file="$script_dir/cca2.list"
[ -f "$cca2_file" ] && cca2_list="$(cat "$cca2_file")" || die "Failed to load the cca2 list."
set -- $cca2_list
for i in 1 2 3 4 5; do
	eval "c=\"\${$i}\""
	set_a_arr_el registry_ccodes_arr "$c"
done
oldifs cca

ucl_f_cmd="uclient-fetch -T 16"
curl_cmd="curl -L --retry 5 -f --fail-early --connect-timeout 7"

[ "$script_dir" = "$install_dir" ] && getconfig HTTP http
secure_util=''; fetch_cmd=''
for util in curl wget uclient-fetch; do
	checkutil "$util" || continue
	case "$util" in
		curl)
			secure_util="curl"
			curl_cmd="curl -L --retry 5 -f --fail-early --connect-timeout 7"
			fetch_cmd="$curl_cmd --progress-bar"
			fetch_cmd_q="$curl_cmd -s"
			break
			;;
		wget)
			if checkutil ubus && checkutil uci; then
				wget_cmd="wget -q --timeout=16"
				[ -s "/usr/lib/libustream-ssl.so" ] && { secure_util="wget"; break; }
			else
				wget_cmd="wget -q --max-redirect=10 --tries=5 --timeout=16"
				secure_util="wget"
				fetch_cmd="$wget_cmd --show-progress -O -"
				fetch_cmd_q="$wget_cmd -O -"
				break
			fi
			;;
		uclient-fetch)
			[ -s "/usr/lib/libustream-ssl.so" ] && secure_util="uclient-fetch"
			fetch_cmd="$ucl_f_cmd -O -"
			fetch_cmd_q="$ucl_f_cmd -q -O -"
	esac
done

[ -z "$fetch_cmd" ] && die "Error: Compatible download utilites unavailable."

if [ -z "$secure_util" ] && [ -z "$http" ]; then
	[ ! "$manualmode" ] && die "Error: no fetch utility with SSL support available."
	printf '\n%s\n' "Can not find download utility with SSL support. Enable insecure downloads?"
	pick_opt "y|n"
	case "$REPLY" in
		n|N) die "No fetch utility available." ;;
		y|Y) http="http"; [ "$script_dir" = "$install_dir" ] && setconfig "HTTP=http"
	esac
fi
: "${http:=https}"

valid_sources="ripe${_nl}ipdeny"
default_source="ripe"

ripe_url_stats="${http}://ftp.ripe.net/pub/stats"
ripe_url_api="${http}://stat.ripe.net/data/country-resource-list/data.json?"
ipdeny_ipv4_url="${http}://www.ipdeny.com/ipblocks/data/aggregated"
ipdeny_ipv6_url="${http}://www.ipdeny.com/ipv6/ipaddresses/aggregated"


#### VARIABLES

lists_arg=$(
	for list_id in $lists_arg; do
		case "$list_id" in
			*_* ) toupper "${list_id%%_*}"; tolower "_${list_id#*_}"; printf '\n' ;;
			*) die "Error: invalid list id '$list_id'."
		esac
	done
)

source_arg="$(tolower "$source_arg")"
dl_src="${source_arg:-"$default_source"}"
dl_src_cap="$(toupper "$dl_src")"

unset failed_lists fetched_lists


#### Checks

set -- $dl_src
case "$2" in *?*) usage; die "Specify only one download source."; esac

[ ! "$dl_src" ] && die "Internal error: '\$dl_src' variable should not be empty!"

# debugprint "valid_sources: '$valid_sources', dl_src: '$dl_src'"
subtract_a_from_b "$valid_sources" "$dl_src" invalid_source
case "$invalid_source" in *?*) usage; die "Invalid source: '$invalid_source'"; esac

# check that either $iplist_dir or $output_file is set
[ ! "$iplist_dir" ] && [ ! "$output_file" ] &&
	{ usage; die "Specify iplist directory with '-p <path-to-dir>' or output file with '-o <output_file>'."; }
# ... but not both
[ "$iplist_dir" ] && [ "$output_file" ] &&
	{ usage; die "Use either '-p <path-to-dir>' or '-o <output_file>' but not both."; }

case "$lists_arg" in '') usage; die "Specify country code/s!"; esac
fast_el_cnt "$lists_arg" "$_nl" lists_arg_cnt


# if $output_file is set, make sure that no more than 1 list is specified
[ "$output_file" ] && [ "$lists_arg_cnt" -gt 1 ] &&
		{ usage; die "To fetch multiple lists, use '-p <path-to-dir>' instead of '-o <output_file>'."; }

[ "$iplist_dir" ] && [ ! -d "$iplist_dir" ] &&
	die "Error: Directory '$iplist_dir' doesn't exist!" || iplist_dir="${iplist_dir%/}"

for f in "$status_file" "$output_file"; do
	[ "$f" ] && [ ! -f "$f" ] && { touch "$f" || die "Error: failed to create file '$f'."; }
done


#### Main

# groups lists by registry
# populates $registries, fetch_lists_arr
group_lists_by_registry

[ ! "$registries" ] && die "Error: failed to determine relevant regions."

# debugprint "registries: '$registries'"

check_updates

# processes the lists associated with the specific registry
for ccode in $ccodes_need_update; do
	process_ccode "$ccode"
done


### Report fetch results via status file
if [ "$status_file" ]; then
	subnets_cnt_str=''
	# convert array contents to formatted multi-line string for writing to the status file
	get_a_arr_keys subnets_cnt_arr list_ids
	for list_id in $list_ids; do
		get_a_arr_val subnets_cnt_arr "$list_id" subnets_cnt
		subnets_cnt_str="${subnets_cnt_str}PrevSubnetsCnt_${list_id}=$subnets_cnt$_nl"
	done

	list_dates_str=''
	get_a_arr_keys list_date_arr list_ids
	for list_id in $list_ids; do
		get_a_arr_val list_date_arr "$list_id" prevdate
		list_dates_str="${list_dates_str}PrevDate_${list_id}=$prevdate$_nl"
	done

	setstatus "$status_file" "FetchedLists=${fetched_lists% }" "up_to_date_lists=${up_to_date_lists% }" \
				"FailedLists=${failed_lists% }" "$subnets_cnt_str" "$list_dates_str" ||
		die "Error: Failed to write to the status file '$status_file'."
fi

exit 0
