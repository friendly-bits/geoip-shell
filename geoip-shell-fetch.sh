#!/bin/sh
# shellcheck disable=SC2154,SC1090,SC2034,SC2086,SC2015

# geoip-shell-fetch.sh

# Copyright: antonk (antonk.d3v@gmail.com)
# github.com/friendly-bits

#### Initial setup
p_name="geoip-shell"
script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)

geoinit="${p_name}-geoinit.sh"
for geoinit_path in "$script_dir/$geoinit" "/usr/bin/$geoinit"; do
	[ -f "$geoinit_path" ] && break
done

. "$geoinit_path" &&
. "$_lib-arrays.sh" || exit 1

san_args "$@"
newifs "$delim"
set -- $_args; oldifs


#### USAGE

usage() {
cat <<EOF

Usage: $me -l <"list_ids"> -p <path> [-o <output_file>] [-s <status_file>] [-u <"source">] [-f] [-d] [-V] [-h]

1) Fetches ip lists for given country codes from RIPE API or from ipdeny
	(supports any combination of ipv4 and ipv6 lists)

2) Parses, validates the downloaded lists, and saves each one to a separate file.

Options:
  -l $list_ids_usage
  -p <path>        : Path to directory where downloaded and compiled subnet lists will be stored.
  -o <output_file> : Path to output file where fetched list will be stored.
${sp16}${sp8}With this option, specify exactly 1 country code.
${sp16}${sp8}(use either '-p' or '-o' but not both)
  -s <status_file> : Path to a status file to register fetch results in.
  -u $sources_usage
 
  -r : Raw mode (outputs newline-delimited lists rather than nftables-ready ones)
  -f : Force using fetched lists even if list timestamp didn't change compared to existing list
  -d : Debug
  -V : Version
  -h : This help

EOF
}


#### Parse args

while getopts ":l:p:o:s:u:rfdVh" opt; do
	case $opt in
		l) lists_arg=$OPTARG ;;
		p) iplist_dir_f=$OPTARG ;;
		s) status_file=$OPTARG ;;
		o) output_file=$OPTARG ;;
		u) source_arg=$OPTARG ;;

		r) raw_mode=1 ;;
		f) force_update=1 ;;
		d) debugmode_arg=1 ;;
		V) echo "$curr_ver"; exit 0 ;;
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
	[ -z "$1" ] && { unset "$2"; return 1; }
	mon_temp="${1#????}"
	eval "$2=\"${1%????}-${mon_temp%??}-${1#??????}\""
}

reg_server_date() {
	case "$1" in
		[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9] )
			set_a_arr_el server_dates_arr "$2=$1"
			debugprint "Got date from $3 for '$2': '$1'."
			;;
		*) debugprint "$FAIL get date from $3 for '$2'."
			:
	esac
}

# get list time based on the file date on the server
get_src_dates_ipdeny() {
	tmp_file_path="/tmp/${p_name}_ipdeny"

	_res=
	for list_id in $valid_lists; do
		f="${list_id#*_}"; case "$_res" in *"$f"*) ;; *) _res="$_res$f "; esac
	done
	families="${_res% }"

	for family in $families; do
		case "$family" in
			ipv4) server_url="$ipdeny_ipv4_url" ;;
			ipv6) server_url="$ipdeny_ipv6_url"
		esac
		debugprint "getting listing from url '$server_url'..."

		server_html_file="${tmp_file_path}_dl_page_${family}.tmp"
		server_plaintext_file="${tmp_file_path}_plaintext_${family}.tmp"
		# debugprint "timestamp fetch command: '$fetch_cmd \"${server_url}\" > \"$server_html_file\""
		$fetch_cmd_q "${http}://$server_url" > "$server_html_file"

		debugprint "Processing $family listing on the IPDENY server..."

		# 1st part of awk strips HTML tags, 2nd part trims extra spaces
		[ -f "$server_html_file" ] && awk '{gsub("<[^>]*>", "")} {$1=$1};1' "$server_html_file" > "$server_plaintext_file" ||
			echolog "failed to fetch server dates from the IPDENY server."
		rm -f "$server_html_file"
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

	for family in $families; do rm -f "${tmp_file_path}_plaintext_${family}.tmp"; done
}

# get list time based on the filename on the server
get_src_dates_ripe() {
	server_html_file="/tmp/geoip-shell_server_dl_page.tmp"

	for registry in $registries; do
		tolower reg_lc "$registry"
		server_url="$ripe_url_stats/$reg_lc"

		debugprint "getting listing from url '$server_url'..."
		[ ! "$server_url" ] && { echolog -err "get_src_dates_ripe(): $server_url variable should not be empty!"; return 1; }

		# debugprint "timestamp fetch command: '$fetch_cmd_q \"${server_url}\" > \"$server_html_file\""
		$fetch_cmd_q "${http}://$server_url" > "$server_html_file"

		debugprint "Processing the listing..."
		# gets a listing and filters it by something like '-xxxxxxxx.md5' where x's are numbers,
		# then cuts out everything but the numbers, sorts and gets the latest one
		# based on a heuristic but it's a standard format and unlikely to change
		server_date="$(grep -oE '\-[0-9]{8}\.md5' < "$server_html_file" | cut -b 2-9 | sort -V | tail -n1)"

		rm -f "$server_html_file"
		get_a_arr_val fetch_lists_arr "$registry" list_ids
		for list_id in $list_ids; do
			reg_server_date "$server_date" "$list_id" "RIPE"
		done
	done
}

parse_ripe_json() {
	in_list="$1" out_list="$2" family="$3"
	sed -n -e /"$family"/\{/]/q\;:1 -e n\;/]/q\;p\;b1 -e \} "$in_list" | cut -d\" -f2 > "$out_list"
	[ -s "$out_list" ]; return $?
}

# populates $registries, "fetch_lists_arr" array)
group_lists_by_registry() {
	valid_lists=
	# group lists by registry
	for registry in $all_registries; do
		list_ids=
		for list_id in $san_lists; do
			ccode="${list_id%_*}"
			get_a_arr_val registry_ccodes_arr "$registry" ccodes
			case "$ccodes" in *" ${ccode} "*)
				add2list registries "$registry"
				add2list list_ids "$list_id"
				add2list valid_lists "$list_id"
			esac
		done
		set_a_arr_el fetch_lists_arr "$registry=$list_ids"
	done

	subtract_a_from_b "$valid_lists" "$san_lists" invalid_lists
	[ "$invalid_lists" ] && {
		for invalid_list in $invalid_lists; do
			add2list invalid_ccodes "${invalid_list%_*}"
		done
		die "Invalid country codes: '$invalid_ccodes'."
	}
	[ ! "$valid_lists" ] && die "No applicable ip list id's found in '$lists_arg'."
	failed_lists="$valid_lists"
}

# checks vars set in the status file
# and populates variables $prev_list_reg, $prev_date_raw, $prev_date_compat, $prev_s_cnt
check_prev_list() {
	list_id="$1"
	unset prev_list_reg prev_date_raw prev_date_compat prev_s_cnt

	eval "prev_s_cnt=\"\$prev_ips_cnt_${list_id}\""
	case "$prev_s_cnt" in
		''|0) prev_s_cnt=''
			debugprint "Previous subnets count for '$list_id' is 0."
			;;
		*)
			eval "prev_date_compat=\"\$prev_date_${list_id}\""
			if [ "$prev_date_compat" ]; then
				prev_list_reg=true
				p="$prev_date_compat"
				mon_temp="${p#?????}"
				prev_date_raw="${p%??????}${mon_temp%???}${p#????????}"
			else
				debugprint "Note: status file '$status_file' has no information for list '$purple$list_id$n_c'."
				prev_s_cnt=
			fi
	esac
}

# checks whether any of the ip lists need update
# and populates $up_to_date_lists, $ccodes_need_update accordingly
check_updates() {
	time_now="$(date +%s)"

	printf '\n%s\n' "Checking for ip list updates on the $dl_src_cap server..."
	echo

	case "$dl_src" in
		ipdeny) get_src_dates_ipdeny ;;
		ripe) get_src_dates_ripe ;;
		*) die "Unknown source: '$dl_src'."
	esac

	unset up_to_date_lists ccodes_need_update families no_date_lists
	for list_id in $valid_lists; do
		get_a_arr_val server_dates_arr "$list_id" date_src_raw
		date_raw_to_compat "$date_src_raw" date_src_compat

		if [ ! "$date_src_compat" ]; then
			add2list no_date_lists "$list_id"
			date_src_raw="$(date +%Y%m%d)"; force_update=1
			date_raw_to_compat "$date_src_raw" date_src_compat
		fi

		time_source="$(date -d "$date_src_compat" +%s)"

		time_diff=$(( time_now - time_source ))

		# warn the user if the date on the server is older than now by more than a week
		if [ "$time_diff" -gt 604800 ]; then
			msg1="Newest ip list for list '$list_id' on the $dl_src_cap server is dated '$date_src_compat' which is more than 7 days old."
			msg2="Either your clock is incorrect, or '$dl_src_cap' is not updating the list for '$list_id'."
			msg3="If it's the latter, please notify the developer."
			echolog -warn "$msg1" "$msg2" "$msg3"
		fi

		check_prev_list "$list_id"

		if [ "$prev_list_reg" ] && [ "$date_src_raw" -le "$prev_date_raw" ] && [ ! "$force_update" ] && [ ! "$manmode" ]; then
			add2list up_to_date_lists "$list_id"
		else
			add2list ccodes_need_update "${list_id%_*}"
			add2list families "${list_id##*_}"
		fi
	done

	[ "$no_date_lists" ] &&
		echolog -warn "$FAIL get the timestamp from the server for ip lists: '$no_date_lists'. Will try to fetch anyway."
	[ "$up_to_date_lists" ] &&
		echolog "Ip lists '${purple}$up_to_date_lists${n_c}' are already ${green}up-to-date${n_c} with the $dl_src_cap server."
	:
}

rm_tmp_f() {
	rm -f "$fetched_list" "$parsed_list" "$valid_list"
}

list_failed() {
	rm_tmp_f
	[ "$1" ] && echolog -err "$1"
}

process_ccode() {

	curr_ccode="$1"; tolower curr_ccode_lc "$curr_ccode"
	unset prev_list_reg list_path fetched_list
	set +f; rm -f "/tmp/${p_name}_"*.tmp; set -f

	for family in $families; do
		list_id="${curr_ccode}_${family}"
		case "$exclude_iplists" in *"$list_id"*)
			continue
		esac
		case "$dl_src" in
			ripe) dl_url="${ripe_url_api}v4_format=prefix&resource=${curr_ccode}" ;;
			ipdeny)
				case "$family" in
					"ipv4" ) dl_url="${ipdeny_ipv4_url}/${curr_ccode_lc}-aggregated.zone" ;;
					*) dl_url="${ipdeny_ipv6_url}/${curr_ccode_lc}-aggregated.zone"
				esac ;;
			*) die "Unsupported source: '$dl_src'."
		esac

		# set list_path to $output_file if it is set, or to $iplist_dir_f/$list_id otherwise
		list_path="${output_file:-$iplist_dir_f/$list_id.iplist}"

		# temp files
		parsed_list="/tmp/${p_name}_parsed-${list_id}.tmp"
		fetched_list="/tmp/${p_name}_fetched-$curr_ccode.tmp"

		valid_s_cnt=0
		failed_s_cnt=0

		# checks the status file and populates $prev_list_reg, $prev_date_raw
		check_prev_list "$list_id"

		if [ ! -s "$fetched_list" ]; then
			case "$dl_src" in
				ripe ) printf '%s\n' "Fetching ip list for country '${purple}$curr_ccode${n_c}' from $dl_src_cap..." ;;
				ipdeny ) printf '%s\n' "Fetching ip list for '${purple}$list_id${n_c}' from $dl_src_cap..."
			esac

			debugprint "fetch command: $fetch_cmd \"${http}://$dl_url\" > \"$fetched_list\""
			$fetch_cmd "${http}://$dl_url" > "$fetched_list" || {
				rv=$?
				echolog -err "${fetch_cmd%% *} returned error code $rv for command '$fetch_cmd \"${http}://$dl_url\"'."
				[ $rv = 8 ] && checkutil uci && echolog "$owrt_ssl_needed"
				list_failed "$FAIL fetch the ip list for '$list_id' from the $dl_src_cap server."; continue;
			}
			printf '%s\n\n' "Fetch successful."
		fi

		case "$dl_src" in
			ripe)
				printf %s "Parsing ip list for '${purple}$list_id${n_c}'... "
				parse_ripe_json "$fetched_list" "$parsed_list" "$family" ||
					{ list_failed "$FAIL parse the ip list for '$list_id'."; continue; }
				OK ;;
			ipdeny) mv "$fetched_list" "$parsed_list"
		esac

		printf %s "Validating '$purple$list_id$n_c'... "
		# Validates the parsed list, populates the $valid_s_cnt, failed_s_cnt variables
		validate_list "$list_id"
		rm -f "$parsed_list"

		[ "$failed_s_cnt" = 0 ] && OK || { FAIL; continue; }

		printf '%s\n\n' "Validated subnets for '$purple$list_id$n_c': $valid_s_cnt."
		check_subnets_cnt_drop "$list_id" || { list_failed; continue; }

		debugprint "Updating $list_path... "
		{ [ "$raw_mode" ] && cat "$valid_list" || {
				printf %s "elements={ "
				tr '\n' ',' < "$valid_list"
				printf '%s\n' "}"
			}
		} > "$list_path" || { list_failed "$FAIL overwrite the file '$list_path'"; continue; }

		touch -d "$date_src_compat" "$list_path"
		add2list fetched_lists "$list_id"
		set_a_arr_el subnets_cnt_arr "$list_id=$valid_s_cnt"
		set_a_arr_el list_date_arr "$list_id=$date_src_compat"

		rm -f "$valid_list"
	done

	rm -f "$fetched_list"
	:
}

validate_list() {
	list_id="$1"
	# todo: change to mktemp?
	valid_list="/tmp/validated-${list_id}.tmp"
	family="${list_id#*_}"

	case "$family" in ipv4) subnet_regex="$subnet_regex_ipv4" ;; *) subnet_regex="$subnet_regex_ipv6"; esac
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
		echolog -err "$WARN validated 0 subnets for list '$purple$list_id$n_c'. Perhaps the country code is incorrect?" >&2
		return 1
	fi

	# Check if subnets count decreased dramatically compared to the old list
	if [ "$prev_list_reg" ]; then
		# compare fetched subnets count to old subnets count, get result in %
		s_percents="$((valid_s_cnt * 100 / prev_s_cnt))"
		case $((s_percents < 90)) in
			1) echolog -err "$WARN validated subnets count '$valid_s_cnt' in the fetched list '$purple$list_id$n_c'" \
				"is ${s_percents}% of '$prev_s_cnt' subnets in the existing list dated '$prev_date_compat'." \
				"Not updating the list."
				return 1 ;;
			*) debugprint "Validated $family subnets count for list '$purple$list_id$n_c' is ${s_percents}% of the count in the old list."
		esac
	fi
}


#### Set output file/s

# check that either $iplist_dir_f or $output_file is set
[ ! "$iplist_dir_f" ] && [ ! "$output_file" ] &&
	die "Specify iplist directory with '-p <path-to-dir>' or output file with '-o <output_file>'."
# ... but not both
[ "$iplist_dir_f" ] && [ "$output_file" ] && die "Use either '-p <path-to-dir>' or '-o <output_file>' but not both."

fast_el_cnt "$lists_arg" " " lists_arg_cnt

# if $output_file is set, make sure that no more than 1 list is specified
[ "$output_file" ] && [ "$lists_arg_cnt" -gt 1 ] &&
	die "To fetch multiple lists, use '-p <path-to-dir>' instead of '-o <output_file>'."

[ "$iplist_dir_f" ] && [ ! -d "$iplist_dir_f" ] && die "Directory '$iplist_dir_f' doesn't exist!"
iplist_dir_f="${iplist_dir_f%/}"


#### Load cca2.list
all_registries="ARIN RIPENCC APNIC AFRINIC LACNIC"
newifs "$_nl" cca
cca2_f="cca2.list"
for cca2_path in "$script_dir/$cca2_f" "$conf_dir/$cca2_f"; do
	[ -f "$cca2_path" ] && break
done

[ -f "$cca2_path" ] && cca2_list="$(cat "$cca2_path")" || die "$FAIL load the cca2 list."
set -- $cca2_list
for i in 1 2 3 4 5; do
	eval "c=\"\${$i}\""
	set_a_arr_el registry_ccodes_arr "$c"
done
oldifs cca

#### Check for valid DL source
valid_sources="ripe ipdeny"
default_source="ripe"
tolower source_arg
dl_src="${source_arg:-"$default_source"}"
toupper dl_src_cap "$dl_src"
checkvars dl_src
set -- $dl_src
[ "$2" ] && die "Specify only one download source."
# debugprint "valid_sources: '$valid_sources', dl_src: '$dl_src'"
subtract_a_from_b "$valid_sources" "$dl_src" invalid_source
case "$invalid_source" in *?*) die "Invalid source: '$invalid_source'"; esac

#### Choose best available DL utility, set options
ucl_f_cmd="uclient-fetch"
curl_cmd="curl -L -f"

[ "$script_dir" = "$install_dir" ] && [ "$root_ok" ] && getconfig http
unset secure_util fetch_cmd owrt_ssl
[ -s /usr/lib/libustream-ssl.so ] || [ -s /lib/libustream-ssl.so ] &&
	[ -s /etc/ssl/certs/ca-certificates.crt ] && [ -s /etc/ssl/cert.pem ] && checkutil uci && owrt_ssl=1
for util in curl wget uclient-fetch; do
	checkutil "$util" || continue
	case "$util" in
		curl)
			secure_util="curl"
			curl --help curl 2>/dev/null | grep -q '\-\-fail-early' && curl_cmd="$curl_cmd --fail-early"
			con_check_cmd="$curl_cmd --retry 2 --connect-timeout 10 -s -S --head"
			curl_cmd="$curl_cmd --retry 5 --connect-timeout 16"
			fetch_cmd="$curl_cmd --progress-bar"
			fetch_cmd_q="$curl_cmd -s -S"
			break ;;
		wget)
			if ! wget --version | grep -m1 "GNU Wget"; then
				wget_cmd="wget -q"
				unset wget_tries wget_tries_con_check wget_show_progress
				[ "$owrt_ssl" ] && secure_util="wget"
			else
				wget_show_progress=" --show-progress"
				wget_cmd="wget -q --max-redirect=10"
				secure_util="wget"
				wget_tries=" --tries=5"
				wget_tries_con_check=" --tries=2"
			fi 1>/dev/null 2>/dev/null

			con_check_cmd="$wget_cmd$wget_tries_con_check --timeout=10 --spider"
			wget_cmd="$wget_cmd$wget_tries --timeout=16"
			fetch_cmd="$wget_cmd$wget_show_progress -O -"
			fetch_cmd_q="$wget_cmd -O -"
			[ "$secure_util" ] && break ;;
		uclient-fetch)
			fetch_cmd="$ucl_f_cmd -T 16 -O -"
			fetch_cmd_q="$ucl_f_cmd -T 16 -q -O -"
			con_check_cmd="$ucl_f_cmd -T 10 -q -s"
			[ "$owrt_ssl" ] && { secure_util="uclient-fetch"; break; }
	esac
done

[ "$daemon_mode" ] && fetch_cmd="$fetch_cmd_q"

[ -z "$fetch_cmd" ] && die "Compatible download utilites (curl/wget/uclient-fetch) unavailable."

owrt_ssl_needed="Please install the package 'ca-bundle' and one of the packages: libustream-mbedtls, libustream-openssl, libustream-wolfssl."

if [ -z "$secure_util" ]; then
	[ "$dl_src" = ipdeny ] && {
		echolog -err "SSL support is required to use the IPDENY source but no utility with SSL support is available."
		checkutil uci && echolog "$owrt_ssl_needed"
		die
	}

	if [ -z "$http" ]; then
		if [ "$nointeract" ]; then
			REPLY=y
		else
			[ ! "$manmode" ] && die "no fetch utility with SSL support available."
			printf '\n%s\n' "Can not find download utility with SSL support. Enable insecure downloads?"
			pick_opt "y|n"
		fi
		case "$REPLY" in
			n) die "No fetch utility available." ;;
			y) http="http"; [ "$script_dir" = "$install_dir" ] && setconfig http
		esac
	fi
elif [ -n "$secure_util" ]; then http="https"
fi
: "${http:=https}"


#### VARIABLES

unset lists exclude_iplists excl_list_ids failed_lists fetched_lists
[ -f "$excl_file" ] && nodie=1 getconfig exclude_iplists exclude_iplists "$excl_file"

for list_id in $lists_arg; do
	case "$list_id" in
		*_*) toupper cc_up "${list_id%%_*}"; tolower fml_lo "_${list_id#*_}" ;;
		*) die "invalid list id '$list_id'."
	esac
	list_id="$cc_up$fml_lo"
	case "$exclude_iplists" in *"$list_id"*)
		add2list excl_list_ids "$list_id"
		continue
	esac
	add2list lists "$list_id"
done
san_lists="$lists"

[ "$excl_list_ids" ] && report_excluded_lists "$excl_list_ids"


#### Checks


# groups lists by registry
# populates $registries, fetch_lists_arr
group_lists_by_registry

[ ! "$registries" ] && die "$FAIL determine relevant regions."

case "$dl_src" in
	ripe) dl_srv="${ripe_url_api%%/*}"
		con_check_url="${ripe_url_api}v4_format=prefix&resource=nl" ;;
	ipdeny) dl_srv="${ipdeny_ipv4_url%%/*}"
		con_check_url="${ipdeny_ipv4_url}"
esac

# check internet connectivity
[ "$dl_src" = ipdeny ] && printf '\n%s' "Note: IPDENY server may be unresponsive at round hours."
printf '\n%s' "Checking connectivity... "
$con_check_cmd "${http}://$con_check_url" 1>/dev/null 2>/dev/null || {
	rv=$?
	echolog -err "${con_check_cmd%% *} returned error code $rv for command '$con_check_cmd \"${http}://$con_check_url\"'."
	[ $rv = 8 ] && checkutil uci && echolog "$owrt_ssl_needed"
	die "Connection attempt to the $dl_src_cap server failed."
}
OK

for f in "$status_file" "$output_file"; do
	[ "$f" ] && [ ! -f "$f" ] && { touch "$f" || die "$FAIL create file '$f'."; }
done


#### Main

for list_id in $valid_lists; do
	unset "prev_ips_cnt_${list_id}"
done

# read info about previous fetch from the status file
if [ "$status_file" ] && [ -s "$status_file" ]; then
	getstatus "$status_file"
else
	debugprint "Status file '$status_file' either doesn't exist or is empty."
	:
fi

trap 'rm_tmp_f; rm -f "$server_html_file"
	for family in $families; do
		rm -f "${tmp_file_path}_plaintext_${family}.tmp" "${tmp_file_path}_dl_page_${family}.tmp"
	done; exit' INT TERM HUP QUIT

check_updates

# processes the lists associated with the specific registry
for ccode in $ccodes_need_update; do
	process_ccode "$ccode"
done


### Report fetch results via status file
if [ "$status_file" ]; then
	ips_cnt_str=
	# convert array contents to formatted multi-line string for writing to the status file
	get_a_arr_keys subnets_cnt_arr list_ids
	for list_id in $list_ids; do
		get_a_arr_val subnets_cnt_arr "$list_id" subnets_cnt
		ips_cnt_str="${ips_cnt_str}prev_ips_cnt_${list_id}=$subnets_cnt$_nl"
	done

	list_dates_str=
	get_a_arr_keys list_date_arr list_ids
	for list_id in $list_ids; do
		get_a_arr_val list_date_arr "$list_id" prev_date
		list_dates_str="${list_dates_str}prev_date_${list_id}=$prev_date$_nl"
	done

	subtract_a_from_b "$fetched_lists $up_to_date_lists" "$failed_lists" failed_lists
	setstatus "$status_file" "fetched_lists=$fetched_lists" "up_to_date_lists=$up_to_date_lists" \
		"failed_lists=$failed_lists" "$ips_cnt_str" "$list_dates_str" ||
			die "$FAIL write to the status file '$status_file'."
fi

:
