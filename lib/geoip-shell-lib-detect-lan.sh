#!/bin/sh
# shellcheck disable=SC2154,SC2086,SC1090

# geoip-shell-detect-lan.sh

# Copyright: antonk (antonk.d3v@gmail.com)
# github.com/friendly-bits

# Library for detecting LAN ipv4 and ipv6 subnets and for subnets aggregation


# Usage for lan subnets detection:
# 1 - get detected subnets from get_lan_subnets (outputs via $res_subnets)
# Only use get_lan_subnets() on a machine which has no dedicated WAN interfaces (physical or logical)
# otherwise WAN subnet may be wrongly detected as LAN subnet

# Usage for subnets aggregation:
# 1 - pipe input subnets (newline-separated) into ips2hex
# 2 - call aggregate_subnets with the resulting subnets hex


# This is a customized version of detect-local-subnets-AIO.sh script found here:
# github.com/friendly-bits/subnet-tools


## Functions

# output via $family_dl
convert_family() {
	case "$1" in
		ipv4|inet) family_dl=inet ;;
		ipv6|inet6) family_dl=inet6 ;;
		*) echolog -err "convert_family: invalid family '$1'"; return 1
	esac
}

# Output: assigned vars with naming $mask_${family_dl}_${maskbits}
# 1 - newline-separated subnets with maskbits prepended
# 2 - family (inet|inet6)
generate_masks() {
	family_dl="$2"

	maskbits_vars="$(
		IFS="$_nl"
		for s in $1; do
			# print mask bits
			printf '%s\n' "${s%/*}"
		done |
		while read -r b; do
			case "$b" in '') continue; esac
			case "$generated_masks" in "$b"|"$b "*|*" $b"|*" $b "*) continue; esac
			printf %s "mask_${family_dl}_${b}=\""
			bytes_done='' i='' sum=0 cur=128

			octets=$((b / 8))
			frac=$((b % 8))
			while :; do
				case ${#bytes_done} in "$octets") break; esac
				case $((${#bytes_done}%chunk_len_bytes==0)) in 1) printf ' 0x'; esac
				printf %s "ff"
				bytes_done="${bytes_done}1"
			done

			[ ${#bytes_done} != $ip_len_bytes ] && {
				while :; do
					case ${#i} in "$frac") break; esac
					sum=$((sum + cur))
					cur=$((cur / 2))
					i="${i}1"
				done
				case "$((${#bytes_done}%chunk_len_bytes))" in 0) printf ' 0x'; esac
				printf "%02x" "$sum" || { echolog -err "generate_masks: $FAIL convert byte '$sum' to hex."; exit 1; }
				bytes_done="${bytes_done}1"

				while :; do
					case ${#bytes_done} in "$ip_len_bytes") break; esac
					case "$((${#bytes_done}%chunk_len_bytes))" in 0) printf ' 0x'; esac
					printf %s "00"
					bytes_done="${bytes_done}1"
				done
			}
			printf '"\n'
			generated_masks="$generated_masks$b "
		done
		:
	)" || return 1
	[ "$maskbits_vars" ] || { echolog -err "generate_masks: no masks successfully generated."; return 1; }
	eval "$maskbits_vars" || { echolog -err "generate_masks: $FAIL to assign vars."; return 1; }
	:
}

# 1 - ip
# 2 - family (inet|inet6)
ip_to_hex() {
	ip="$1"; family_dl="$2"
	case "$family_dl" in inet6)
		# expand ::
		case "$ip" in *::*)
			zeroes=":0:0:0:0:0:0:0:0:0"
			ip_tmp="$ip"
			while :; do
				case "$ip_tmp" in *:*) ip_tmp="${ip_tmp#*:}";; *) break; esac
				zeroes="${zeroes#??}"
			done
			# replace '::'
			ip="${ip%::*}$zeroes${ip##*::}"
			# prepend 0 if we start with :
			case "$ip" in :*) ip="0${ip}"; esac
		esac
	esac
	IFS_OLD_ith="$IFS"
	IFS="$_fmt_delim"
	for chunk in $ip; do
		printf " 0x%0${chunk_len_chars}x" "$hex_flag$chunk" || { echolog -err "ip_to_hex: $FAIL convert chunk '$chunk'."; return 1; }
	done
	IFS="$IFS_OLD_ith"
}

# 1 - input hex chunks
# 2 - family (inet|inet6)
# 3 - var name for output
hex_to_ip() {
	family_dl="$2"; out_var="$3"
	ip="$(IFS=' ' printf "%$_fmt_id$_fmt_delim" $1)" || {
		unset "$out_var"
		echolog -err "hex_to_ip: $FAIL convert hex to ip."
		return 1
	}

	case "$family_dl" in inet6 )
		## compress ipv6

		case "$ip" in :* ) ;; *) ip=":$ip"; esac
		# compress 0's across neighbor chunks
		for zeroes in ":0:0:0:0:0:0:0:0" ":0:0:0:0:0:0:0" ":0:0:0:0:0:0" ":0:0:0:0:0" ":0:0:0:0" ":0:0:0" ":0:0"; do
			case "$ip" in *$zeroes* )
				ip="${ip%%"$zeroes"*}::${ip#*"$zeroes"}"
				break
			esac
		done

		# trim leading colon if it's not a double colon
		case "$ip" in
			::::*) ip="${ip#::}" ;;
			:::*) ip="${ip#:}" ;;
			::*) ;;
			:*) ip="${ip#:}"
		esac
	esac
	eval "$out_var"='${ip%$_fmt_delim}'
}

# input via stdin
# if maskbits not included, adds /128 for ipv6 or /32 for ipv4
# outputs sorted by maskbits subnets hex, with prepended maskbits/
# 1 - family (ipv4|ipv6|inet|inet6)
ips2hex() {
	# debugprint "Starting ips2hex"
	convert_family "$1"
	set_conv_vars "$family_dl" || return 1
	while read -r ip2h; do
		case "$ip2h" in
			'') continue ;;
			*/*) printf %s "${ip2h#*/}/" ;;
			*) printf %s "${ip_len_bits}/"
		esac
		ip_to_hex "${ip2h%%/*}" "$family_dl" || exit 1
		printf '\n'
	done | sort -n
}

# 1 - family (ipv4|ipv6|inet|inet6)
# 2 - sorted by maskbits subnets hex, with prepended maskbits/
# output via $res_subnets
aggregate_subnets() {
	# debugprint "Starting aggregate_subnets for family $1, input '$2'."
	convert_family "$1"
	subnets_hex="$2$_nl"
	set_conv_vars "$family_dl" || return 1
	unset res_subnets res_ips
	IFS_OLD_ags="$IFS"

	# generate masks
	generate_masks "$subnets_hex" "$family_dl" || return 1

	while :; do
		case "$subnets_hex" in ''|"$_nl") break; esac

		## trim the 1st (largest) subnet on the list to its mask bits

		# get the first subnet from the list
		IFS="$_nl"
		set -- $subnets_hex
		subnet1_hex="$1"

		# remove current subnet from the list
		shift 1
		subnets_hex="$*$_nl"
		IFS="$default_IFS"

		# debugprint "processing subnet: $subnet1_hex"

		# get mask bits
		maskbits="${subnet1_hex%/*}"
		# chop off mask bits
		ip_hex="${subnet1_hex#*/}"

		# load mask
		eval "mask=\"\$mask_${family_dl}_${maskbits}\""
		case "$mask" in '')
			echolog -err "aggregate_subnets: no registered mask for maskbits '$maskbits', family '$family_dl'"; return 1
		esac

		# calculate ip & mask
		ip1_hex="$(
			# copy ~ $maskbits bits
			IFS=' '; chunks_done=''; bits_done=0
			for ip_chunk in $ip_hex; do
				[ $((bits_done + chunk_len_bits < maskbits)) = 0 ] && break
				printf ' %s' "$ip_chunk"
				bits_done=$((bits_done + chunk_len_bits))
				chunks_done="${chunks_done}1"
			done
			# calculate the next chunk if needed
			[ $bits_done != $maskbits ] && {
				set -- $mask
				chunks_done="${chunks_done}1"
				eval "mask_chunk=\"\${${#chunks_done}}\""

				printf " 0x%0${chunk_len_chars}x" $(( ip_chunk & mask_chunk ))
				bits_done=$((bits_done + chunk_len_bits))
			}

			# repeat 00 for every missing byte
			while :; do
				case $((bits_done>=ip_len_bits)) in 1) break; esac
				[ $((bits_done%chunk_len_bits)) = 0 ] && printf ' 0x'
				printf %s "00"
				bits_done=$((bits_done + 8))
			done
		)"
		# debugprint "calculated '$ip_hex' & '$mask' = '$ip1_hex'"

		# format from hex number back to ip
		hex_to_ip "$ip1_hex" "$family_dl" res_ip || return 1

		# append mask bits and add current subnet to resulting list
		res_subnets="${res_subnets}${res_ip}/${maskbits}${_nl}"
		res_ips="${res_ips}${res_ip}${_nl}"

		IFS="$_nl"
		# iterate over all remaining subnets
		for subnet2_hex in $subnets_hex; do
			# chop off mask bits
			ip2_hex="${subnet2_hex#*/}"

			bytes_diff=0; bits_done=0; chunks_done=

			# compare ~ $maskbits bits of ip1 and ip2
			IFS=' '
			for ip1_chunk in $ip1_hex; do
				case $((bits_done + chunk_len_bits < maskbits)) in 0) break; esac
				bits_done=$((bits_done + chunk_len_bits))
				chunks_done="${chunks_done}1"

				set -- $ip2_hex
				eval "ip2_chunk=\"\${${#chunks_done}}\""

				bytes_diff=$((ip1_chunk - ip2_chunk))
				# if there is any difference, no need to calculate further
				case "$bytes_diff" in 0) ;; *) break; esac
			done

			# if needed, calculate the next ip2 chunk and compare to ip1 chunk
			[ "$bits_done" = "$maskbits" ] || [ "$bytes_diff" != 0 ] && continue

			chunks_done="${chunks_done}1"

			set -- $ip2_hex
			eval "ip2_chunk=\"\${${#chunks_done}}\""
			set -- $mask
			eval "mask_chunk=\"\${${#chunks_done}}\""

			bytes_diff=$((ip1_chunk - (ip2_chunk & mask_chunk) ))

			# if no differences found, subnet2 is encapsulated in subnet1 - remove subnet2 from the list
			[ "$bytes_diff" = 0 ] && subnets_hex="${subnets_hex%%"$subnet2_hex$_nl"*}${subnets_hex#*"$subnet2_hex$_nl"}"
		done
		IFS="$IFS_OLD_ags"
	done
	IFS="$IFS_OLD_ags"

	validate_ip "${res_ips%"$_nl"}" "$family_dl" ||
		{ echolog -err "get_lan_subnets: $FAIL validate one or more of output addresses."; return 1; }
	:
}

# sets $ip_len_bits, $ip_len_bytes, $chunk_len_bits, $chunk_len_bytes $_fmt_id, $_fmt_delim
# 1 - family (inet|inet6)
set_conv_vars() {
	case "$1" in
		inet) ip_len_bits=32 chunk_len_bits=8 _fmt_id='d' _fmt_delim='.' hex_flag='' ;;
		inet6) ip_len_bits=128 chunk_len_bits=16 _fmt_id='x' _fmt_delim=':' hex_flag='0x' ;;
		*) echolog -err "set_conv_vars: invalid family '$1'."; return 1
	esac

	ip_len_bytes=$((ip_len_bits/8))
	chunk_len_bytes=$((chunk_len_bits/8))
	chunk_len_chars=$((chunk_len_bytes*2))
	:
}

# Outpus newline-separated subnets in hex with maskbits prepended
# 1 - family (inet|inet6)
get_lan_subnets_hex() {
	set_conv_vars "$family_dl" || return 1
	if [ "$family_dl" = inet ]; then
		ifaces="dummy_123|$(
			ip -f inet route show table local scope link |
			sed -n '/[ 	]lo[ 	]/d;/[ 	]dev[ 	]/{s/.*[ 	]dev[ 	][ 	]*//;s/[ 	].*//;p}' | tr '\n' '|')"
		ip -o -f inet addr show | grep -E "${ifaces%|}" | grep -oE "$subnet_regex_ipv4"
	elif [ "$family_dl" = inet6 ]; then
		ip -o -f inet6 addr show |
			grep -oE 'inet6[ 	]+(fd[0-9a-f]{0,2}:|fe80:)[0-9a-f:/]+' | grep -oE "$subnet_regex_ipv6\$"
	fi |
	ips2hex "$family_dl"
}

# 1 - family (ipv4|ipv6|inet|inet6)
get_lan_subnets() {
	# debugprint "Starting get_lan_subnets"
	convert_family "$1"
	lan_subnets_hex="$(get_lan_subnets_hex "$family_dl")" && [ "$lan_subnets_hex" ] &&
	aggregate_subnets "$family_dl" "$lan_subnets_hex" && [ "$res_subnets" ] ||
		{ unset res_subnets; echolog -err "$FAIL detect $family_dl LAN subnets."; return 1; }
}

: