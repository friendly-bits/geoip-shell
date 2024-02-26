#!/bin/sh
# shellcheck disable=SC2154,SC2086,SC2317,SC2018,SC2019

# detect-local-subnets-AIO.sh

# Copyright: friendly bits
# github.com/friendly-bits

# Unix shell script which uses standard utilities to detect local area ipv4 and ipv6 subnets, regardless of the device it's running on (router or host)
# Some heuristics are employed which are likely to work on Linux but for other Unixes, testing is recommended

# by default, outputs all found local ip addresses, and aggregated subnets
# to output only aggregated subnets (and no other text), run with the '-s' argument
# to only check a specific family (inet or inet6), run with the '-f <family>' argument
# running with the '-n' argument disables validation which speeds up the processing significantly, but the results are not as safe
# '-d' argument is for debug


#### Initial setup

export LC_ALL=C
me=$(basename "$0")
set -f

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)

# shellcheck source=ip-regex.sh
. "$script_dir/ip-regex.sh"

## Simple args parsing
debugmode=''
for arg in "$@"; do
	case "$arg" in
		-s ) subnets_only=1 ;;
		-n ) novalidation=1 ;;
		-d ) debugmode=1 ;;
		-f ) families_arg=check ;;
		* ) case "$families_arg" in check) families_arg="$arg"; esac
	esac
done
case "$families_arg" in check) echo "Specify family with '-f'." >&2; exit 1; esac


## Functions

debugprint() {
	[ "$debugmode" ] && printf '%s\n' "$1" >&2
}

checkutil() {
	command -v "$1" 1>/dev/null
}

# 1 - mask bits
# 2 - ip length in bytes
generate_mask() {
	maskbits="$1"
	ip_len_bytes="$2"

	bytes_done='' i='' sum=0 cur=128

	octets=$((maskbits / 8))
	frac=$((maskbits % 8))
	while true; do
		case ${#bytes_done} in "$octets") break; esac
		case $((${#bytes_done}%chunk_len_bytes==0)) in 1) printf ' 0x'; esac
		printf %s "ff"
		bytes_done="${bytes_done}1"
	done

	case "${#bytes_done}" in "$ip_len_bytes") ;; *)
		while true; do
			case ${#i} in "$frac") break; esac
			sum=$((sum + cur))
			cur=$((cur / 2))
			i="${i}1"
		done
		case "$((${#bytes_done}%chunk_len_bytes))" in 0) printf ' 0x'; esac
		printf "%02x" "$sum" || { printf '%s\n' "generate_mask: Error: failed to convert byte '$sum' to hex." >&2; return 1; }
		bytes_done="${bytes_done}1"

		while true; do
			case ${#bytes_done} in "$ip_len_bytes") break; esac
			case "$((${#bytes_done}%chunk_len_bytes))" in 0) printf ' 0x'; esac
			printf %s "00"
			bytes_done="${bytes_done}1"
		done
	esac
}

# 1 - ip's
# 2 - regex
validate_ip() {
	addr="$1"; ip_regex="$2"
	[ ! "$addr" ] && { echo "validate_ip: Error: received an empty ip address." >&2; return 1; }

	# using the 'ip route get' command to put the address through kernel's validation
	# it normally returns 0 if the ip address is correct and it has a route, 1 if the address is invalid
	# 2 if validation successful but for some reason it can't check the route
	for address in $addr; do
		ip route get "$address" 1>/dev/null 2>/dev/null
		case $? in 0|2) ;; *)
			{ printf '%s\n' "validate_ip: Error: ip address'$address' failed kernel validation." >&2; return 1; }
		esac
	done

	## regex validation
	printf '%s\n' "$addr" | grep -vE "^$ip_regex$" > /dev/null
	[ $? != 1 ] && { printf '%s\n' "validate_ip: Error: one or more addresses failed regex validation: '$addr'." >&2; return 1; }
	:
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
				while true; do
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
			::*) ;;
			:*) ip="${ip#:}"
		esac
	esac
	eval "$out_var"='${ip%$_fmt_delim}'
}

# 1- family
get_local_subnets() {

	family="$1"; res_subnets=''; res_ips=''

	case "$family" in
		inet ) ip_len_bits=32; chunk_len_bits=8; ip_regex="$ipv4_regex"; _fmt_id='d'; _fmt_delim='.' ;;
		inet6 ) ip_len_bits=128; chunk_len_bits=16; ip_regex="$ipv6_regex"; _fmt_id='x'; _fmt_delim=':' ;;
		* ) printf '%s\n' "get_local_subnets: invalid family '$family'." >&2; return 1
	esac

	ip_len_bytes=$((ip_len_bits/8))
	chunk_len_bytes=$((chunk_len_bits/8))
	chunk_len_chars=$((chunk_len_bytes*2))

	subnets_hex="$(
		if [ "$family" = inet ]; then
			ip -f inet route show table local scope link |
			grep -v "[[:space:]]lo[[:space:]]" | grep -oE "dev[[:space:]]+[^[:space:]]+" | sed 's/^dev[[:space:]]*//g' | sort -u |
			while read -r iface; do
				ip -o -f inet addr show "$iface" | grep -oE "$subnet_regex_ipv4"
			done
		else
			ip -o -f inet6 addr show | grep -oE "inet6[[:space:]]+(fd[0-9a-f]{0,2}:|fe80:)(([[:alnum:]:/])+)" | grep -oE "$subnet_regex_ipv6$"
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
	while true; do
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
		[ ! "$mask" ] && {
			mask="$(generate_mask "$maskbits" "$ip_len_bytes")" || return 1
			eval "mask_${family}_${maskbits}=\"$mask\""
		}

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
			[ "$bits_done" != "$maskbits" ] && {
				set -- $mask
				chunks_done="${chunks_done}1"
				eval "mask_chunk=\"\${${#chunks_done}}\""

				printf " 0x%0${chunk_len_chars}x" $(( ip_chunk & mask_chunk ))
				bits_done=$((bits_done + chunk_len_bits))
			}

			# repeat 00 for every missing byte
			while [ "$bits_done" != "$ip_len_bits" ]; do
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
#			debugprint "comparing to subnet: '$subnet2_hex'"
			# chop off mask bits
			ip2_hex="${subnet2_hex#*/}"

			bytes_diff=0; bits_done=0; chunks_done=''

			# compare ~ $maskbits bits of ip1 and ip2
			IFS=' '
			for ip1_chunk in $ip1_hex; do
				[ $((bits_done + chunk_len_bits < maskbits)) = 0 ] && break
				bits_done=$((bits_done + chunk_len_bits))
				chunks_done="${chunks_done}1"

				set -- $ip2_hex
				eval "ip2_chunk=\"\${${#chunks_done}}\""

#				debugprint "comparing chunks '$ip1_chunk' - '$ip2_chunk'"

				bytes_diff=$((ip1_chunk - ip2_chunk))
				# if there is any difference, no need to calculate further
				[ "$bytes_diff" != 0 ] && break
			done

			# if needed, calculate the next ip2 chunk and compare to ip1 chunk
			[ "$bits_done" = "$maskbits" ] || [ "$bytes_diff" != 0 ] && continue

#			debugprint "calculating last chunk..."
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

	case "$novalidation" in '') validate_ip "${res_ips%"$_nl"}" "$ip_regex" ||
		{ echo "get_local_subnets: Error: failed to validate one or more of output addresses." >&2; return 1; }; esac

	[ ! "$subnets_only" ] && printf '%s\n' "Local $family subnets (aggregated):"
	case "$res_subnets" in
		'') [ ! "$subnets_only" ] && echo "None found." ;;
		*) printf %s "$res_subnets"
	esac
	[ ! "$subnets_only" ] && echo

	:
}


## Constants
_nl='
'

## Checks

[ "$novalidation" ] || {
	# check dependencies
	! checkutil tr || ! checkutil grep || ! checkutil ip &&
		{ echo "$me: Error: missing dependencies, can not proceed" >&2; exit 1; }
}

## Main

families=
[ -n "$families_arg" ] && for word in $(printf '%s' "$families_arg" | tr 'A-Z' 'a-z'); do
	case "$word" in
		inet|ipv4) families="${families}inet " ;;
		inet6|ipv6) families="${families}inet6 " ;;
		*) printf '%s\n' "$me: Error: invalid family '$word'." >&2; exit 1
	esac
done
: "${families:="inet inet6"}"

rv_global=0
for family in $families; do
	get_local_subnets "$family"; rv_global=$((rv_global + $?))
done

exit $rv_global
