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

Usage: $me -l <"list_ids"> -p <path> [-o <output_file>] [-s <path>] [-u <"source">] [-f] [-d] [-V] [-h]

1) Fetches IP lists for given country codes from RIPE API, or from ipdeny, or from MaxMind
	(supports any combination of ipv4 and ipv6 lists)

2) Parses, validates the downloaded lists, and saves each one to a separate file.

Options:
  -l <"list_ids">  : $list_ids_usage
  -p <path>        : Path to directory where downloaded and compiled subnet lists will be stored.
  -o <output_file> : Path to output file where fetched list will be stored.
${sp16}${sp8}With this option, specify exactly 1 country code.
${sp16}${sp8}(use either '-p' or '-o' but not both)
  -s <path>        : Path to a file to register fetch results in.
  -u $srcs_syn : Use this IP list source for download. Supported sources: ripe, ipdeny, maxmind.
 
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
		s) fetch_res_file=$OPTARG ;;
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
		[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9])
			set_a_arr_el server_dates_arr "$2=$1"
			debugprint "Got date from $3 for '$2': '$1'."
			;;
		*)
			debugprint "$FAIL get date from $3 for '$2'."
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
		# debugprint "timestamp fetch command: '$fetch_cmd_date \"${http}://${server_url}\" > \"$server_html_file\""
		$fetch_cmd_date "${http}://$server_url" > "$server_html_file"

		debugprint "Processing $family listing on the IPDENY server..."

		# 1st part of awk strips HTML tags, 2nd part trims extra spaces
		[ -f "$server_html_file" ] && $awk_cmd '{gsub("<[^>]*>", "")} {$1=$1};1' "$server_html_file" > "$server_plaintext_file" ||
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
			$awk_cmd -v c="$curr_ccode" '($1==tolower(c)"-aggregated.zone" && $2 ~ /^[0-3][0-9]-...-20[1-9][0-9]$/) {split($2,d,"-");
				date=sprintf("%04d%02d%02d", d[3],index("  JanFebMarAprMayJunJulAugSepOctNovDec",d[2])/3,d[1]); print date}' \
				"$server_plaintext_file"
		)"

		reg_server_date "$server_date" "$list_id" IPDENY
	done

	for family in $families; do rm -f "${tmp_file_path}_plaintext_${family}.tmp"; done
}

# get list time based on the filename on the server
get_src_dates_ripe() {
	server_html_file="/tmp/geoip-shell_server_dl_page.tmp"

	[ ! "$ripe_url_stats" ] && { echolog -err "get_src_dates_ripe(): \$ripe_url_stats variable should not be empty!"; return 1; }

	for registry in $registries; do
		tolower reg_lc "$registry"
		server_url="$ripe_url_stats/$reg_lc"

		debugprint "getting listing from url '$server_url'..."

		# debugprint "timestamp fetch command: '$fetch_cmd_date \"${http}://${server_url}\" > \"$server_html_file\""
		$fetch_cmd_date "${http}://$server_url" > "$server_html_file"

		debugprint "Processing the listing..."
		# gets a listing and filters it by something like '-xxxxxxxx.md5' where x's are numbers,
		# then cuts out everything but the numbers, sorts and gets the latest one
		# based on a heuristic but it's a standard format and unlikely to change
		server_date="$(grep -oE '\-[0-9]{8}\.md5' < "$server_html_file" | cut -b 2-9 | sort -V | tail -n1)"

		rm -f "$server_html_file"
		get_a_arr_val fetch_lists_arr "$registry" list_ids
		for list_id in $list_ids; do
			reg_server_date "$server_date" "$list_id" RIPE
		done
	done
}

# get list time based on the filename on the server
get_src_dates_maxmind() {
	server_url="https://${maxmind_url}/${mm_db_name}-Country-CSV/download?suffix=zip"

	debugprint "getting date from url '$server_url'..."

	case "$fetch_cmd" in
		curl*) fetch_cmd_date="$fetch_cmd_date --head" ;;
		wget*) fetch_cmd_date="$fetch_cmd_date -S --method HEAD"
	esac

	debugprint "timestamp fetch command: $fetch_cmd_date \"${server_url}\""

	MM_DB_DATE="$(
		$fetch_cmd_date "$server_url" 2>&1 |
		sed -n "/[Ll]ast-[Mm]odified:.*,/{
			s/\r//g;
			s/.*[Ll]ast-[Mm]odified${blank}*:${blank}*//;
			s/^[A-Z][a-z][a-z],${blanks}//;
			s/${blanks}GMT${blank}*//;
			s/${blanks}[0-9][0-9]:[0-9][0-9]:[0-9][0-9]$//;
			p;q;}" |
			# matches input to date in format 'dd Mon 20yy', then converts to 'yyyymmdd'
			awk '
				BEGIN{rv=1}
				$0 ~ /^[0-3][0-9] ... 20[1-9][0-9]$/ {
					split($0,d," ");
					date=sprintf("%04d%02d%02d",d[3],index("  JanFebMarAprMayJunJulAugSepOctNovDec",d[2])/3,d[1])
					print date
					rv=0
					exit
				}
				END{exit rv}
			'
	)" || return 1

	for list_id in $valid_lists; do
		reg_server_date "$MM_DB_DATE" "$list_id" MAXMIND
	done
	:
}

parse_ripe_json() {
	in_file="$1" out_file="$2" family_parse="$3"
	sed -n -e /"$family_parse"/\{/]/q\;:1 -e n\;/]/q\;p\;b1 -e \} "$in_file" | cut -d\" -f2 > "$out_file" &&
		[ -s "$out_file" ] &&
			return 0
	return 1
}

preparse_maxmind_csv() {
	in_file="$1" out_file="$2" ccodes_parse="$3" family_parse="$4" mm_db_name_parse="$5"
	mm_countries_tmp_file=/tmp/maxmind_countries.csv
	san_str ccodes_parse_regex "$ccodes_parse" " " "|"

	unzip -p "$in_file" "*/${mm_db_name_parse}-Country-Locations-en.csv" > "$mm_countries_tmp_file" || {
		rm -f "$mm_countries_tmp_file"
		return 1
	}

	unzip -p "$in_file"  "*/${mm_db_name_parse}-Country-Blocks-IPv${family_parse#ipv}.csv" |
		$awk_cmd -F ',' "
			NR==FNR { if (\$5~/^($ccodes_parse_regex)$/) {ccodes[\$1]=\$5}; next}
			\$2 in ccodes {print ccodes[\$2], \$1}
		" "$mm_countries_tmp_file" - | gzip > "$out_file" &&
			[ -s "$out_file" ] && {
				rm -f "$mm_countries_tmp_file"
				return 0
			}
	rm -f "$mm_countries_tmp_file"
	return 1
}

parse_maxmind_db() {
	in_file="$1" out_file="$2" ccode_parse="$3"

	gunzip -fc "$in_file" |
		sed -n "/^$ccode_parse/{s/^$ccode_parse${blanks}//;p;}" > "$out_file" &&
		[ -s "$out_file" ] &&
			return 0
	return 1
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
	[ ! "$valid_lists" ] && die "No applicable IP list IDs found in '$lists_arg'."
	failed_lists="$valid_lists"
}

# checks vars retrieved from the status file
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

# checks whether any of the IP lists need update
# and populates $up_to_date_lists, $ccodes_need_update accordingly
check_updates() {
	time_now="$(date +%s)"

	printf '\n%s\n' "Checking for IP list updates on the $dl_src_cap server..."

	case "$dl_src" in
		ipdeny) get_src_dates_ipdeny ;;
		ripe) get_src_dates_ripe ;;
		maxmind) get_src_dates_maxmind ;;
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
			msg1="Newest IP list for '$list_id' on the $dl_src_cap server is dated '$date_src_compat' which is more than 7 days old."
			msg2="Either your clock is incorrect, or $dl_src_cap is not updating the list for '$list_id'."
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
		echolog -warn "$FAIL get the timestamp from the server for IP lists: '$no_date_lists'. Will try to fetch anyway."
	[ "$up_to_date_lists" ] &&
		echolog "IP lists '${purple}$up_to_date_lists${n_c}' are already ${green}up-to-date${n_c} with the $dl_src_cap server."
	:
}

rm_tmp_f() {
	rm -f "$fetched_file" "$parsed_list" "$valid_list"
}

rm_mm_tmp_f() {
	set +f
	rm -f "/tmp/${p_name}_preparsed"*.tmp
	set -f
}

list_failed() {
	rm_tmp_f
	[ "$1" ] && echolog -err "$1"
}

# 1 - fetch cmd
# 2 - url
# 3 - output file
fetch_file() {
	[ $# = 3 ] || { echolog -err "fetch_file: invalid arguments."; return 1; }

	debugprint "fetch command: $1 \"$2\" > \"$3\""
	$1 "$2" > "$3" || {
		fetch_rv=$?
		echolog -err "${fetch_cmd%% *} returned error code $fetch_rv for command:" "$1 \"$2\""
		return 1
	}
	[ -s "$3" ] || return 1

	printf '%s\n' "Fetch successful."
	:
}

fetch_maxmind() {
	fetched_db_mm="/tmp/${p_name}_fetched-mm-db_${MM_DB_DATE}.zip"
	dl_url="${maxmind_url}/${mm_db_name}-Country-CSV/download?suffix=zip"

	if [ "$keep_mm_db" = true ] && [ -s "$fetched_db_mm" ]; then
		printf '%s\n' "Using previously fetched database from MaxMind..."
	else
		rm -f "/tmp/${p_name}_fetched-mm-db"*
		printf '%s\n' "Fetching the database from MaxMind..."

		fetch_file "$fetch_cmd" "${http}://$dl_url" "$fetched_db_mm" || {
			list_failed "$FAIL fetch the database from Maxmind"
			rm -f "$fetched_db_mm"
			return 1
		}
	fi

	printf '\n%s' "Pre-parsing the database... "
	for family in $families; do
		preparsed_db_mm="/tmp/${p_name}_preparsed-${family}.gz.tmp"
		preparse_maxmind_csv "$fetched_db_mm" "$preparsed_db_mm" "$ccodes_need_update" "$family" "$mm_db_name" || {
			FAIL
			rm -f "$fetched_db_mm"
			rm_mm_tmp_f
			echolog -err "$FAIL pre-parse the database from MaxMind."
			return 1
		}
	done
	OK

	[ "$keep_mm_db" = true ] || rm -f "$fetched_db_mm"

	for family in $families; do
		preparsed_db_mm="/tmp/${p_name}_preparsed-${family}.gz.tmp"
		for ccode in $ccodes_need_update; do
			list_id="${ccode}_${family}"
			case "$exclude_iplists" in *"$list_id"*) continue; esac
			parsed_list_mm="/tmp/${p_name}_fetched-${list_id}.tmp"
			printf %s "Parsing the IP list for '${purple}$list_id${n_c}'... "

			parse_maxmind_db "$preparsed_db_mm" "$parsed_list_mm" "$ccode" || {
				rm_mm_tmp_f
				echolog -err "$FAIL parse the IP list for '$list_id'."
				return 1
			}
			OK
		done
		rm -f "$preparsed_db_mm"
	done
	echo

	:
}

process_ccode() {
	curr_ccode="$1"
	tolower curr_ccode_lc "$curr_ccode"
	unset list_path fetched_file

	for family in $families; do
		list_id="${curr_ccode}_${family}"
		case "$exclude_iplists" in *"$list_id"*) continue; esac

		rm_fetched_list_id=
		case "$dl_src" in
			ripe)
				fetched_file="/tmp/${p_name}_fetched-$curr_ccode.tmp"
				dl_url="${ripe_url_api}v4_format=prefix&resource=${curr_ccode}" ;;
			maxmind)
				fetched_file="/tmp/${p_name}_fetched-$list_id.tmp"
				rm_fetched_list_id=1
				dl_url="" ;;
			ipdeny)
				fetched_file="/tmp/${p_name}_fetched-$list_id.tmp"
				rm_fetched_list_id=1
				case "$family" in
					ipv4) dl_url="${ipdeny_ipv4_url}/${curr_ccode_lc}-aggregated.zone" ;;
					*) dl_url="${ipdeny_ipv6_url}/${curr_ccode_lc}-aggregated.zone"
				esac ;;
			*) die "Unsupported source: '$dl_src'."
		esac

		# set list_path to $output_file if it is set, or to $iplist_dir_f/$list_id otherwise
		list_path="${output_file:-$iplist_dir_f/$list_id.iplist}"

		parsed_list="/tmp/${p_name}_parsed-${list_id}.tmp"

		valid_s_cnt=0
		failed_s_cnt=0

		if [ ! -s "$fetched_file" ]; then
			case "$dl_src" in
				ripe) fetch_subj="IP list for country '${purple}$curr_ccode${n_c}'" ;;
				maxmind) list_failed "Fetched file '$fetched_file' for list ID '$list_id' not found"; return 1 ;;
				ipdeny) fetch_subj="IP list for '${purple}$list_id${n_c}'"
			esac
			printf '\n%s\n' "Fetching the $fetch_subj from $dl_src_cap..."

			fetch_file "$fetch_cmd" "${http}://$dl_url" "$fetched_file" || {
				list_failed "$FAIL fetch the $fetch_subj from $dl_src_cap."
				return 1
			}
		fi

		[ -s "$fetched_file" ] || { list_failed "$FAIL fetch the $fetch_subj from $dl_src_cap."; continue; }

		case "$dl_src" in
			ripe)
				printf %s "Parsing the IP list for '${purple}$list_id${n_c}'... "
				parse_ripe_json "$fetched_file" "$parsed_list" "$family" ||
					{ list_failed "$FAIL parse the IP list for '$list_id'."; continue; }
				OK ;;
			maxmind|ipdeny) mv "$fetched_file" "$parsed_list"
		esac

		# Validate the parsed list, populate the $valid_s_cnt, $failed_s_cnt
		printf %s "Validating '$purple$list_id$n_c'... "
		valid_list="/tmp/validated-${list_id}.tmp"

		case "$family" in
			ipv4) subnet_regex="$subnet_regex_ipv4" ;;
			*) subnet_regex="$subnet_regex_ipv6"
		esac
		grep -E "^$subnet_regex$" "$parsed_list" > "$valid_list"

		parsed_s_cnt=$(wc -w < "$parsed_list")
		valid_s_cnt=$(wc -w < "$valid_list")
		failed_s_cnt=$(( parsed_s_cnt - valid_s_cnt ))

		if [ "$failed_s_cnt" != 0 ]; then
			failed_s="$(grep -Ev  "$subnet_regex" "$parsed_list")"

			list_failed "${_nl}out of $parsed_s_cnt subnets for IP list '${purple}$list_id${n_c}, $failed_s_cnt subnets ${red}failed validation${n_c}'."
			if [ $failed_s_cnt -gt 10 ]; then
					echo "First 10 failed subnets:"
					printf '%s\n' "$failed_s" | head -n10
					printf '\n'
			else
				printf '%s\n%s\n\n' "Following subnets failed validation:" "$failed_s"
			fi
			rm -f "$parsed_list"
			continue
		else
			rm -f "$parsed_list"
			OK
		fi

		printf '%s\n' "Validated subnets for '$purple$list_id$n_c': $valid_s_cnt."
		check_subnets_cnt_drop "$list_id" || { list_failed; continue; }

		debugprint "Updating $list_path... "
		if [ "$raw_mode" ]; then
			cat "$valid_list"
		else
			printf %s "elements={ "
			tr '\n' ',' < "$valid_list"
			printf '%s\n' "}"
		fi > "$list_path" || { list_failed "$FAIL write to file '$list_path'"; continue; }

		touch -d "$date_src_compat" "$list_path"
		add2list fetched_lists "$list_id"
		set_a_arr_el subnets_cnt_arr "$list_id=$valid_s_cnt"
		set_a_arr_el list_date_arr "$list_id=$date_src_compat"

		rm -f "$valid_list"
		[ "$rm_fetched_list_id" ] && rm -f "$fetched_file"
	done

	rm -f "$fetched_file"
	:
}

# compares current validated subnets count to previous one
check_subnets_cnt_drop() {
	list_id="$1"

	if [ "$valid_s_cnt" = 0 ]; then
		echolog -warn "validated 0 subnets for list '$purple$list_id$n_c'. Perhaps the country code is incorrect?${_nl}"
		return 1
	fi

	# Check if subnets count decreased dramatically compared to the old list
	check_prev_list "$list_id"
	if [ "$prev_s_cnt" ] && [ "$prev_s_cnt" != 0 ]; then
		# compare fetched subnets count to old subnets count, get result in %
		s_percents="$((valid_s_cnt * 100 / prev_s_cnt))"
		if [ $s_percents -lt 60 ]; then
			echolog -warn "validated subnets count '$valid_s_cnt' in the fetched list '$purple$list_id$n_c'" \
			"is ${s_percents}% of '$prev_s_cnt' subnets in the existing list dated '$prev_date_compat'." \
			"Not updating the list."
			return 1
		else
			debugprint "Validated $family subnets count for list '$purple$list_id$n_c' is ${s_percents}% of the count in the old list."
			:
		fi
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
cca2_f=cca2.list
for cca2_path in "$script_dir/$cca2_f" "$conf_dir/$cca2_f"; do
	[ -f "$cca2_path" ] && break
done

[ -f "$cca2_path" ] && cca2_list="$(cat "$cca2_path")" || die "$FAIL load the cca2 list."
newifs "$_nl" cca
set -- $cca2_list
oldifs cca
for c in "$@"; do
	case "$c" in
		'') continue ;;
		*[!\ \	]*) ;;
		*) continue
	esac
	case "$c" in
		*[!\ =A-Za-z\	]*|*=*=*) die "Unexpected data in cca2.list" ;;
		*=*)
	esac
	case "${c%%=*}" in
		*[!a-zA-Z]*) die "Unexpected data in cca2.list"
	esac
	set_a_arr_el registry_ccodes_arr "$c"
done

#### Check for valid DL source
default_source=ripe
is_alphanum "$source_arg" && tolower source_arg && subtract_a_from_b "$valid_sources" "$source_arg" ||
	die "Invalid source: '$source_arg'"
dl_src="${source_arg:-"$default_source"}"
checkvars dl_src
toupper dl_src_cap "$dl_src"

#### Choose best available DL utility, set options
ucl_cmd="uclient-fetch -O -"
curl_cmd="curl -f"
wget_cmd="wget -O -"

[ "$script_dir" = "$install_dir" ] && [ "$root_ok" ] && getconfig http
unset fetch_cmd ssl_ok wget_no_ssl

if [ -s /etc/ssl/certs/ca-certificates.crt ]; then
	case "$initsys" in
		procd|busybox)
			if [ -s /etc/ssl/cert.pem ] && {
				[ -s /usr/bin/ssl_client ] ||
				{ [ -s /usr/lib/libustream-ssl.so ] || [ -s /lib/libustream-ssl.so ] && checkutil uci; }
			}
			then
				ssl_ok=1
			fi ;;
		*) ssl_ok=1
	esac
fi

case "$dl_src" in
	ipdeny|maxmind) main_conn_timeout=16 ;;
	ripe) main_conn_timeout=22 # ripe api may be slow at processing initial request for a non-ripe region
esac

for util in curl wget uclient-fetch; do
	checkutil "$util" || continue
	maxmind_str=
	case "$util" in
		curl)
			curl --help curl 2>/dev/null | grep '\--fail-early' 1>/dev/null && curl_cmd="$curl_cmd --fail-early"
			[ "$dl_src" = maxmind ] && maxmind_str=" -u $mm_acc_id:$mm_license_key"
			con_check_cmd="$curl_cmd -o /dev/null --write-out '%{http_code}' --retry 2 --connect-timeout 7 -s --head"
			fetch_cmd="$curl_cmd$maxmind_str -L -f --retry 3"
			fetch_cmd_date="$fetch_cmd --connect-timeout 16 -s -S"
			fetch_cmd="$fetch_cmd --connect-timeout $main_conn_timeout"
			fetch_cmd_q="$fetch_cmd -s -S"
			fetch_cmd="$fetch_cmd --progress-bar"
			con_check_ok_ptrn="(301|302|403)"
			break ;;
		wget)
			if ! wget --version 2>/dev/null | grep -m1 "GNU Wget" 1>/dev/null; then
				unset wget_tries wget_tries_con_check wget_show_progress wget_max_redirect wget_con_check_max_redirect wget_server_response
				[ "$dl_src" = maxmind ] &&
					die "Can not fetch from MaxMind with this version of wget. Please install curl or GNU wget."
				con_check_ok_ptrn="HTTP error (301|302|403)"
			else
				wget_server_response=" --server-response"
				wget_show_progress=" --show-progress"
				wget_max_redirect=" --max-redirect=10"
				wget_con_check_max_redirect=" --max-redirect=0"
				wget_tries=" --tries=3"
				wget_tries_con_check=" --tries=2"
				con_check_ok_ptrn="HTTP/.* (302 Moved Temporarily|403 Forbidden|301 Moved Permanently)"
			fi

			[ "$dl_src" = maxmind ] && maxmind_str=" --user=${mm_acc_id} --password=${mm_license_key}"
			con_check_cmd="${wget_cmd}${wget_server_response}${wget_con_check_max_redirect}${wget_tries_con_check} --timeout=7 --spider"
			fetch_cmd="${wget_cmd}${wget_max_redirect}${wget_tries}${maxmind_str} -q"
			fetch_cmd_date="${fetch_cmd} --timeout=16"
			fetch_cmd="${fetch_cmd} --timeout=${main_conn_timeout}"
			fetch_cmd_q="${fetch_cmd}"
			fetch_cmd="${fetch_cmd}${wget_show_progress}"
			wget --version 2>/dev/null | grep 'wget-nossl' 1>/dev/null && { wget_no_ssl=1; continue; }
			break ;;
		uclient-fetch)
			[ "$dl_src" = maxmind ] &&
				die "Can not fetch from MaxMind with uclient-fetch. Please install curl or GNU wget."
			con_check_cmd="$ucl_cmd -T 7 -s"
			fetch_cmd_date="$ucl_cmd -T 16 -q"
			fetch_cmd_q="$ucl_cmd -T $main_conn_timeout -q"
			fetch_cmd="$ucl_cmd -T $main_conn_timeout"
			con_check_ok_ptrn="HTTP error (301|302|403)"
			break
	esac
done

case "${fetch_cmd}" in wget)
	[ "$wget_no_ssl" ] && ssl_ok=
esac

[ "$daemon_mode" ] && fetch_cmd="$fetch_cmd_q"

[ -z "$fetch_cmd" ] && die "Compatible download utilites (curl/wget/uclient-fetch) unavailable."

if [ -z "$ssl_ok" ]; then
	case "$dl_src" in ipdeny|maxmind)
		echolog -err "SSL support is required to use the ${dl_src_cap} source but no utility with SSL support is available."
		checkutil uci && echolog "Please install the package 'ca-bundle' and one of the packages: libustream-mbedtls, libustream-openssl, libustream-wolfssl."
		die
	esac

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
			y) http=http; [ "$script_dir" = "$install_dir" ] && setconfig http
		esac
	fi
fi
: "${http:=https}"

debugprint "http: '$http', ssl_ok: '$ssl_ok'"


#### VARIABLES

separate_excl_iplists san_lists "$lists_arg" || die

unset failed_lists fetched_lists


#### Checks


# groups lists by registry
# populates $registries, fetch_lists_arr
group_lists_by_registry

[ "$registries" ] || die "$FAIL determine relevant regions."

# check connectivity
case "$dl_src" in
	ripe) con_check_url="${ripe_url_api%%/*}" ;;
	ipdeny) con_check_url="${ipdeny_ipv4_url%%/*}" ;;
	maxmind)
		checkvars maxmind_url mm_license_type mm_acc_id mm_license_key
		con_check_url="${maxmind_url%%/*}"

		case "$mm_license_type" in
			free) mm_db_name=GeoLite2 ;;
			paid) mm_db_name=GeoIP2 ;;
			*) die "unexpected MaxMind license type '$mm_license_type'"
		esac
esac

debugprint "conn check command: '$con_check_cmd \"${http}://$con_check_url\"'"
[ "$dl_src" = ipdeny ] && printf '\n%s' "Note: IPDENY server may be unresponsive at round hours."

printf '\n%s' "Checking connectivity... "
con_check_file=/tmp/geoip-shell-conn-check
$con_check_cmd "${http}://$con_check_url" 1>"$con_check_file" 2>&1 || {
	rv=$?
	if ! grep -E "${con_check_ok_ptrn}" "$con_check_file" 1>/dev/null; then
		rm -f "$con_check_file"
		echolog -err "${_nl}${con_check_cmd%% *} returned error code $rv for command:" "$con_check_cmd \"${http}://$con_check_url\""
		die "Connection attempt to the $dl_src_cap server failed."
	fi
}
OK
rm -f "$con_check_file"

for f in "$status_file" "$fetch_res_file" "$output_file"; do
	[ "$f" ] && [ ! -f "$f" ] && { touch "$f" || die "$FAIL create file '$f'."; }
done


#### Main

# read info about previous fetch from the status file
if [ "$status_file" ] && [ -s "$status_file" ]; then
	getstatus "$status_file"
else
	debugprint "Status file '$status_file' is empty or doesn't exist."
	:
fi

trap 'rm_tmp_f; rm_mm_tmp_f; [ "$keep_mm_db" = true ] || rm -f "$fetched_db_mm" \
	set +f;	rm -f "$server_html_file" "/tmp/${p_name}_ipdeny_plaintext_"*.tmp "/tmp/${p_name}_ipdeny_dl_page_"*.tmp; set -f; \
	trap - INT TERM HUP QUIT; exit' INT TERM HUP QUIT

check_updates

# process list IDs
set +f; rm -f "/tmp/${p_name}_"*.tmp; set -f
if [ "$dl_src" = maxmind ] && [ "$ccodes_need_update" ]; then
	fetch_maxmind || die
fi

for ccode in $ccodes_need_update; do
	process_ccode "$ccode"
done


### Report fetch results via fetch_res_file
if [ "$fetch_res_file" ]; then
	subtract_a_from_b "$fetched_lists $up_to_date_lists" "$failed_lists" failed_lists
	setstatus "$fetch_res_file" "fetched_lists=$fetched_lists" "up_to_date_lists=$up_to_date_lists" \
		"failed_lists=$failed_lists" || die "$FAIL write to file '$fetch_res_file'."
fi

if [ "$status_file" ]; then
	list_dates_str=
	get_a_arr_keys list_date_arr list_ids
	for list_id in $list_ids; do
		get_a_arr_val list_date_arr "$list_id" prev_date
		list_dates_str="${list_dates_str}prev_date_${list_id}=$prev_date$_nl"
	done

	ips_cnt_str=
	# convert array contents to formatted multi-line string for writing to the status file
	get_a_arr_keys subnets_cnt_arr list_ids
	for list_id in $list_ids; do
		get_a_arr_val subnets_cnt_arr "$list_id" subnets_cnt
		ips_cnt_str="${ips_cnt_str}prev_ips_cnt_${list_id}=$subnets_cnt$_nl"
	done

	[ "$ips_cnt_str" ] || [ "$list_dates_str" ] && {
		setstatus "$status_file" "$list_dates_str" "$ips_cnt_str" || die "$FAIL write to file '$status_file'."
		[ "$root_ok" ] && [ "$datadir" ] &&
			case "$status_file" in "$datadir"*)
				chmod 600 "$status_file" && chown -R root:root "$status_file"
			esac
	}
fi

:
