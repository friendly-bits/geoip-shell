#!/bin/sh
# shellcheck disable=SC2154,SC2086,SC1090

# geoip-shell-detect-lan.sh

# Copyright: antonk (antonk.d3v@gmail.com)
# github.com/friendly-bits

# Detects local area ipv4 and ipv6 subnets
# Only use on a machine which has no dedicated WAN interfaces (physical or logical)
# otherwise WAN subnet may be wrongly detected as LAN subnet

# outputs aggregated subnets
# to output only aggregated subnets (and no other text), run with the '-s' argument
# to only check a specific family (inet or inet6), run with the '-f <family>' argument

# This is a customized version of detect-local-subnets-AIO.sh script found here:
# github.com/friendly-bits/subnet-tools

#### Initial setup

p_name="geoip-shell"
script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)

geoinit="${p_name}-geoinit.sh"
for geoinit_path in "$script_dir/$geoinit" "/usr/bin/$geoinit"; do
	[ -f "$geoinit_path" ] && break
done
. "$geoinit_path" || exit 1

## Simple args parsing
for arg in "$@"; do
	case "$arg" in
		-s ) subnets_only=1 ;;
		-f ) families_arg=check ;;
		* ) case "$families_arg" in check) families_arg="$arg"; esac
	esac
done
[ "$families_arg" = check ] && die "Specify family with '-f'."


setdebug

debugentermsg

## Functions

# 1 - mask bits
# 2 - ip length in bytes
generate_mask() {
	maskbits="$1"
	ip_len_bytes="$2"

	bytes_done='' i='' sum=0 cur=128

	octets=$((maskbits / 8))
	frac=$((maskbits % 8))
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
		printf "%02x" "$sum" || { printf '%s\n' "generate_mask: Error: failed to convert byte '$sum' to hex." >&2; return 1; }
		bytes_done="${bytes_done}1"

		while :; do
			case ${#bytes_done} in "$ip_len_bytes") break; esac
			case "$((${#bytes_done}%chunk_len_bytes))" in 0) printf ' 0x'; esac
			printf %s "00"
			bytes_done="${bytes_done}1"
		done
	}
}

# 1 - ip
# 2 - family
ip_to_hex() {
	ip="$1"; family="$2"
	case "$family" in
		inet ) chunk_delim='.'; hex_flag='' ;;
		inet6 )
			chunk_delim=':'; hex_flag='0x'
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
	IFS="$chunk_delim"
	for chunk in $ip; do
		printf " 0x%0${chunk_len_chars}x" "$hex_flag$chunk"
	done
}

# 1 - input hex chunks
# 2 - family
# 3 - var name for output
hex_to_ip() {
	family="$2"; out_var="$3"
	ip="$(IFS=' ' printf "%$_fmt_id$_fmt_delim" $1)" || { echo "hex_to_ip: Error: failed to convert hex to ip." >&2; return 1; }

	case "$family" in inet6 )
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

# 1- family
get_local_subnets() {

	family="$1"
	unset res_subnets res_ips

	case "$family" in
		inet) ip_len_bits=32; chunk_len_bits=8; _fmt_id='d'; _fmt_delim='.' ;;
		inet6) ip_len_bits=128; chunk_len_bits=16; _fmt_id='x'; _fmt_delim=':' ;;
		*) printf '%s\n' "get_local_subnets: invalid family '$family'." >&2; return 1
	esac

	ip_len_bytes=$((ip_len_bits/8))
	chunk_len_bytes=$((chunk_len_bits/8))
	chunk_len_chars=$((chunk_len_bytes*2))

	subnets_hex="$(
		if [ "$family" = inet ]; then
			ifaces="dummy_123|$(
				ip -f inet route show table local scope link |
				sed -n '/[ 	]lo[ 	]/d;/[ 	]dev[ 	]/{s/.*[ 	]dev[ 	][ 	]*//;s/[ 	].*//;p}' | tr '\n' '|')"
			ip -o -f inet addr show | grep -E "${ifaces%|}" | grep -oE "$subnet_regex_ipv4"
		else
			ip -o -f inet6 addr show |
				grep -oE 'inet6[ 	]+(fd[0-9a-f]{0,2}:|fe80:)[0-9a-f:/]+' | grep -oE "$subnet_regex_ipv6\$"
		fi |

		while read -r subnet; do
			printf %s "${subnet#*/}/"
			ip_to_hex "${subnet%%/*}" "$family"
			printf '\n'
		done | sort -n
	)"

	[ -z "$subnets_hex" ] &&
		{ printf '%s\n' "get_local_subnets(): Failed to detect local subnets for family $family." >&2; return 1; }

	subnets_hex="$subnets_hex$_nl"
	while :; do
		case "$subnets_hex" in ''|"$_nl") break; esac

		## trim the 1st (largest) subnet on the list to its mask bits

		# get the first subnet from the list
		IFS_OLD="$IFS"; IFS="$_nl"
		set -- $subnets_hex
		subnet1_hex="$1"

		# remove current subnet from the list
		shift 1
		subnets_hex="$*$_nl"
		IFS="$IFS_OLD"

		# debugprint "processing subnet: $subnet1_hex"

		# get mask bits
		maskbits="${subnet1_hex%/*}"
		# chop off mask bits
		ip_hex="${subnet1_hex#*/}"

		# generate mask if it's not been generated yet
		eval "mask=\"\$mask_${family}_${maskbits}\""
		case "$mask" in '')
			mask="$(generate_mask "$maskbits" "$ip_len_bytes")" || return 1
			eval "mask_${family}_${maskbits}=\"$mask\""
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
		hex_to_ip "$ip1_hex" "$family" "res_ip"

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
		IFS="$IFS_OLD"
	done

	validate_ip "${res_ips%"$_nl"}" "$family" ||
		{ echo "get_local_subnets: Error: failed to validate one or more of output addresses." >&2; return 1; }

	[ ! "$subnets_only" ] && printf '%s\n' "Local $family subnets (aggregated):"
	case "$res_subnets" in
		'') [ ! "$subnets_only" ] && echo "None found." ;;
		*) printf %s "$res_subnets"
	esac
	[ ! "$subnets_only" ] && echo

	:
}


## Main

families=
tolower families_arg
for f in $families_arg; do
	case "$f" in
		inet|ipv4) add2list families inet ;;
		inet6|ipv6) add2list families inet6 ;;
		*) die "Invalid family '$f'."
	esac
done
: "${families:="inet inet6"}"

rv_gl=0
for family in $families; do
	get_local_subnets "$family" || rv_gl=1
done

exit $rv_gl
