#!/bin/sh

export \
	DEF_SRC_COUNTRY="ripe" \
	DEF_SRC_ASN="ipinfo_app" \
	\
	maxmind_wget_opts=


#### Get cmd's and opts for best available DL utility
get_fetch_util() {
	gfu_src="$6" gfu_src_cap="$7"
	gfu_main_timeout=16
	case "$gfu_src" in
		ipdeny|maxmind|ipinfo|ipinfo_app) gfu_main_timeout=16 ;;
		ripe) gfu_main_timeout=22 # ripe api may be slow at processing initial request for a non-ripe region
	esac

	wget_con_check_ptrn="HTTP/.* (302 Moved Temporarily|403 Forbidden|301 Moved Permanently)"
	ucl_con_check_ptrn="HTTP error (301|302|403)"
	curl_con_check_ptrn="(301|302|403)"

	ucl_cmd="uclient-fetch -O -"
	curl_cmd="curl -f --retry 2"
	wget_cmd="wget -O -"

	unset gfu_cmd_main gfu_cmd_date gfu_cmd_q gfu_cmd_con_check gfu_con_check_ptrn

	for util in curl wget uclient-fetch; do
		checkutil "$util" || continue
		unset ssl_util
		util_path="$(readlink -f "$(command -v "$util")")"
		[ "${util_path##*/}" = "uclient-fetch" ] && util="uclient-fetch"

		# source-specific fetch opts
		unset extra_opts extra_opts_wget extra_opts_curl
		case "$gfu_src" in
			maxmind)
				forced_utils="wget curl"
				extra_opts_wget=" --user=${mm_acc_id} --password=${mm_license_key}"
				extra_opts_curl=" -u $mm_acc_id:$mm_license_key" ;;
		esac
		[ -n "$forced_utils" ] && {
			san_str forced_utils_pr "$forced_utils" " " " or "
			is_included "$util" "$forced_utils" || die "Can not fetch from $gfu_src_cap with $util. Please install $forced_utils_pr."
		}
		eval "extra_opts=\"\${extra_opts_${util}}\""
		eval "$1=\"\${gs_opts_${3}}\""

		# cmds and opts
		if [ "$util" = "uclient-fetch" ]; then
			gfu_cmd_con_check="$ucl_cmd -T 7 -s"
			gfu_cmd_date="$ucl_cmd -T 16 -q"
			gfu_cmd_q="$ucl_cmd -T $gfu_main_timeout -q"
			gfu_cmd_main="$ucl_cmd -T $gfu_main_timeout"
			gfu_con_check_ptrn="$ucl_con_check_ptrn"
			{ [ -s /usr/bin/ssl_client ] || [ -s /usr/lib/libustream-ssl.so ] || [ -s /lib/libustream-ssl.so ]; } &&
				ssl_util=1
		else
			case "$util" in
				curl)
					curl --help curl 2>/dev/null | grep '\--fail-early' 1>/dev/null &&
						curl_cmd="${curl_cmd} --fail-early"
					gfu_cmd_con_check="${curl_cmd} -o /dev/null --write-out '%{http_code}' --connect-timeout 7 -s --head"
					gfu_cmd_main="${curl_cmd}${extra_opts} -L -f --connect-timeout ${gfu_main_timeout}"
					gfu_cmd_date="${curl_cmd}${extra_opts} -L -f --connect-timeout 16 -s -S"
					gfu_cmd_q="${gfu_cmd_main} -s -S"
					gfu_cmd_main="${gfu_cmd_main} --progress-bar"
					gfu_con_check_ptrn="${curl_con_check_ptrn}"
					curl --version 2>/dev/null | grep -E "Protocols:.*${blank}https(${blank}|$)" 1>/dev/null &&
						ssl_util=1 ;;
				wget)
					unset wget_tries wget_show_progress wget_max_redirect wget_con_check_max_redirect wget_server_response

					wget_ver="$(wget --version 2>/dev/null | head -n6)"
					case "$wget_ver" in
						*"GNU Wget"*)
							wget_server_response=" --server-response"
							wget_show_progress=" --show-progress"
							wget_max_redirect=" --max-redirect=10"
							wget_con_check_max_redirect=" --max-redirect=0"
							wget_tries=" --tries=2"
							gfu_con_check_ptrn="$wget_con_check_ptrn" ;;
						*)
							echolog -warn "Unknown wget version is installed. Fetching with it may or may not work. Install curl or GNU wget to remove this warning."
							gfu_con_check_ptrn="(${ucl_con_check_ptrn}|${wget_con_check_ptrn})"
					esac

					gfu_cmd_con_check="${wget_cmd}${wget_server_response}${wget_con_check_max_redirect}${wget_tries} --timeout=7 --spider"
					gfu_cmd_main="${wget_cmd}${wget_max_redirect}${wget_tries}${extra_opts} -q"
					gfu_cmd_date="${gfu_cmd_main} --timeout=16"
					gfu_cmd_main="${gfu_cmd_main} --timeout=${gfu_main_timeout}"
					gfu_cmd_q="${gfu_cmd_main}"
					gfu_cmd_main="${gfu_cmd_main}${wget_show_progress}"
					case "$wget_ver" in *"+https"*)
						ssl_util=1
					esac ;;
			esac
		fi

		[ -n "$ssl_util" ] && break
	done

	[ -n "$gfu_cmd_main" ] || die "Compatible download utilites (curl/wget/uclient-fetch) unavailable."

	if [ -z "$ssl_util" ] ||
		{
			[ -n "$_OWRTFW" ] && ! { [ -s /etc/ssl/certs/ca-certificates.crt ] && [ -s /etc/ssl/cert.pem ]; }
		}; then
		echolog -warn "SSL support is required for download but SSL support was not detected. Fetch may fail."
		[ -n "$_OWRTFW" ] && echolog "Please install the package 'ca-bundle' and one of the packages: libustream-mbedtls, libustream-openssl, libustream-wolfssl."
	fi

	eval "$1"='$gfu_cmd_main' "$2"='$gfu_cmd_q' "$3"='$gfu_cmd_date' "$4"='$gfu_cmd_con_check' "$5"='$gfu_con_check_ptrn'
}