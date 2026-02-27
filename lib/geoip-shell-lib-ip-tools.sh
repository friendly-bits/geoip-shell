#!/bin/sh
# shellcheck disable=SC2154,SC2086,SC2004

# geoip-shell-lib-ip-tools.sh

# Copyright: antonk (antonk.d3v@gmail.com)
# github.com/friendly-bits

# Library for detecting LAN ipv4 and ipv6 subnets and for subnets aggregation


# Only use get_lan_subnets() and detect_lan_subnets() on a machine which has no dedicated WAN interfaces (physical or logical)
# otherwise WAN subnet may be wrongly detected as LAN subnet

# detect_lan_subnets() and get_lan_subnets() require variables $subnet_regex_[ipv4|ipv6] to be set

# Usage for lan subnets detection (no aggregation):
# call detect_lan_subnets (requires family as 1st argument - ipv4|inet|ipv6|inet6)

# Usage for lan subnets detection + aggregation:
# call get_lan_subnets (requires family as 1st argument - ipv4|inet|ipv6|inet6)

# Usage for subnets/IPs aggregation:
# pipe input subnets (newline-separated) into aggregate_subnets (requires family as 1st argument - ipv4|inet|ipv6|inet6)


## Functions

# 1 - ipv4 address (delimited with '.') or ipv6 address (delimited with ':')
# 2 - family (ipv4|inet|ipv6|inet6)
# 3 - mask bits (integer)
# 4 - var name for output
ip_to_int() {
	ip_itoint="$1"
	family_itoint="$2"
	ip2int_maskbits="$3"
	out_var_itoint="$4"

	# ipv4
	case "$family_itoint" in ipv4|inet)
		# number of bits to trim
		bits_trim=$((32-ip2int_maskbits))

		# convert IP to int and trim to mask bits
		newifs "." itoint
		set -- $ip_itoint

		IFS=" "
		for octet in "$1" "$2" "$3" "$4"; do
			case "$octet" in
				[0-9]|[1-9][0-9]|1[0-9][0-9]|2[0-4][0-9]|25[0-5]) ;;
				*)
					echolog -err "ip_to_int: invalid octet '$octet'"
					oldifs itoint
					return 1
			esac
		done

		oldifs itoint
		ip2int_conv_exp="(($1<<24) + ($2<<16) + ($3<<8) + $4)>>$bits_trim<<$bits_trim"
		eval "$out_var_itoint=$(( $ip2int_conv_exp ))"
		return 0
	esac


	# ipv6

	# expand ipv6 and convert to int
	# process enough chunks to cover $maskbits bits

	newifs ":" itoint
	set -- $ip_itoint
	oldifs itoint

	bits_processed=0
	chunks_done=0

	missing_chunks=$((8-$#))
	ip_itoint=
	for chunk in "$@"; do
		# print 0's in place of missing chunks
		case "${chunk}" in '')
			missing_chunks=$((missing_chunks+1))
			while :; do
				case $missing_chunks in 0) break; esac

				bits_processed=$(( bits_processed + 16 ))
				chunks_done=$((chunks_done+1))
				ip_itoint="${ip_itoint}0 "

				case $(( ip2int_maskbits - bits_processed )) in 0|-*) break 2; esac

				missing_chunks=$((missing_chunks-1))
			done
			continue ;;
		esac

		case "$chunk" in
			????|???|??|?) ;;
			*)
				echolog -err "ip_to_int: invalid chunk '$chunk'"
				return 1
		esac

		case "$chunk" in
			*[!a-f0-9]*)
				echolog -err "ip_to_int: invalid chunk '$chunk'"
				return 1
		esac

		bits_processed=$(( bits_processed + 16 ))
		chunks_done=$((chunks_done+1))

		case $(( ip2int_maskbits - bits_processed )) in
			0)
				ip_itoint="${ip_itoint}$(( 0x${chunk} )) "
				break ;;
			-*)
				bits_trim=$(( bits_processed - ip2int_maskbits ))
				ip_itoint="${ip_itoint}$(( 0x${chunk}>>bits_trim<<bits_trim )) "
				break ;;
			*)
				ip_itoint="${ip_itoint}$(( 0x${chunk} )) "
		esac
	done

	# replace remaining chunks with 0's
	while :; do
		case $(( 8 - chunks_done )) in 0) break; esac
		ip_itoint="${ip_itoint}0 "
		chunks_done=$(( chunks_done + 1 ))
	done


	eval "$out_var_itoint=\"\$ip_itoint\""

	:
}

# Converts input integer(s) into IP address with optional mask bits
# For ipv6, input should be 8 whitespace-separated integer numbers
# 1 - input IP address represented as integer(s)
# 2 - family (ipv4|inet|ipv6|inet6)
# 3 - optional: mask bits (integer). if specified, appends /[maskbits] to output
int_to_ip() {
	case "$3" in
		'') maskbits_iti='' ;;
		*) maskbits_iti="/$3"
	esac

	case "$2" in
		ipv4|inet)
			printf '%s\n' "$(( ($1>>24)&255 )).$(( ($1>>16)&255 )).$(( ($1>>8)&255 )).$(($1 & 255))${maskbits_iti}" ;;
		ipv6|inet6)
			# convert into 16-bit hex chunks delimited with ':'
			set -- $1
			printf ':%x' $* |

			# convert to ipv6 and compress
			{
				hex_to_ipv6 || exit 1
				printf '%s\n' "${maskbits_iti}"
			}
	esac || return 1
	:
}

# input via STDIN: 16-bit hex chunks with ':' preceding each
# output via STDOUT (without newline)
hex_to_ipv6() {
	IFS='' read -r ip_hti
	# compress 0's across neighbor chunks
	IFS=' '
	for zeroes in ":0:0:0:0:0:0:0:0" ":0:0:0:0:0:0:0" ":0:0:0:0:0:0" ":0:0:0:0:0" ":0:0:0:0" ":0:0:0" ":0:0"; do
		case "$ip_hti" in *$zeroes*)
			ip_hti="${ip_hti%%"$zeroes"*}::${ip_hti#*"$zeroes"}"
			break
		esac
	done

	# replace ::: with ::
	case "$ip_hti" in *:::*) ip_hti="${ip_hti%%:::*}::${ip_hti#*:::}"; esac

	# debugprint "hex_to_ip: preliminary commpressed IP: '$ip_hti'"

	# trim leading colon if it's not a double colon
	case "$ip_hti" in
        :[!:]*) ip_hti="${ip_hti#:}"
	esac

	printf %s "${ip_hti}"
}


# input via STDIN: newline-separated subnets or IPs
# output via STDOUT: newline-separated subnets
# 1 - family (ipv4|ipv6|inet|inet6)
aggregate_subnets() {
	inv_maskbits() {
		printf '%s\n' "aggregate_subnets: invalid mask bits '$1'" >&2
	}

	family_ags="$1"
	case "$1" in
		ipv4|inet) ip_len_bits=32 ;;
		ipv6|inet6) ip_len_bits=128 ;;
		*) echolog -err "aggregate_subnets: invalid family '$1'."; return 1
	esac

	processed_maskbits=' '
	nonempty_ags=

	# print with maskbits prepended
	awk -F/ "\$0{ if (\$2) {mb=\$2} else {mb=\"$ip_len_bits\"}; print mb \"/\" \$1}" |

	# sort by mask bits, add magic string in final line
	{
		sort -n
		printf '%s\n' EOF_AGS
	} |

	# process subnets
	while IFS="$_nl" read -r subnet1; do
		case "$subnet1" in
			'') continue ;;
			EOF_AGS)
				[ "$nonempty_ags" ] && exit 0
				exit 1
		esac

		# get mask bits
		maskbits="${subnet1%/*}"
		case "$maskbits" in *[!0-9]*)
			inv_maskbits "$maskbits"
			exit 1
		esac

		case "$maskbits" in ?|??|???) ;; *)
			inv_maskbits "$maskbits"
			exit 1
		esac

		case $((ip_len_bits-maskbits)) in -*)
			inv_maskbits "$maskbits"
			exit 1
		esac

		# chop off mask bits
		ip1_ags="${subnet1#*/}"

		# convert IP to int and trim to mask bits
		ip_to_int "$ip1_ags" "$family_ags" "$maskbits" ip1_int || exit 1

		# don't print if trimmed IP int is included in ${res_ips_by_mb_${maskbits}}
		IFS=' '
		bits_processed=0
		ip1_trim=
		set -- $ip1_int
		chunk=
		for mb in $processed_maskbits; do
			chunks_done_last=0
			eval "mb_ips=\"\${res_ips_by_mb_${mb}}\""

			case "$family_ags" in
				ipv4|inet)
					bits_trim=$((32-mb))
					ip1_trim=$(( ip1_int>>bits_trim<<bits_trim )) ;;
				ipv6|inet6)
					# process $mb bits
					for chunk in "$@"; do
						case $(( mb - (bits_processed+16) )) in
							0)
								bits_processed=$(( bits_processed + 16 ))
								chunks_done_last=$(( chunks_done_last + 1 ))
								ip1_trim="${ip1_trim}${chunk}"
								chunk=
								break ;;
							-*)
								bits_trim=$(( bits_processed + 16 - mb ))
								chunk=$(( chunk>>bits_trim<<bits_trim ))
								break ;;
							*)
								bits_processed=$(( bits_processed + 16 ))
								chunks_done_last=$(( chunks_done_last + 1 ))
								ip1_trim="${ip1_trim}${chunk} "
						esac
					done
			esac

			shift $chunks_done_last
			case "$mb_ips" in *"${_nl}${ip1_trim}${chunk} "*) continue 2; esac
		done

		# add current IP to ${res_ips_by_mb_${maskbits}
		eval "res_ips_by_mb_${maskbits}=\"\${res_ips_by_mb_${maskbits}}${_nl}${ip1_int} \""

		# add current maskbits to $processed_maskbits
		case "$processed_maskbits" in *" $maskbits "*) ;; *)
			processed_maskbits="${processed_maskbits}${maskbits} "
		esac

		# convert back to IP and print out
		int_to_ip "$ip1_int" "$family_ags" "$maskbits" || {
			echolog -err "$FAIL convert '$ip1_int' to IP."
			exit 1
		}
		nonempty_ags=1
	done &&
	return 0

	cat 1>/dev/null
	return 1
}

# Outputs newline-separated subnets
# 1 - family (ipv4|inet|ipv6|inet6)
detect_lan_subnets() {
	case "$1" in
		ipv4|inet)
			case "$subnet_regex_ipv4" in '') echolog -err "detect_lan_subnets: regex is not set"; return 1; esac
			ifaces="dummy_123|$(
				ip -f inet route show table local scope link |
				sed -n '/[ 	]lo[ 	]/d;/[ 	]dev[ 	]/{s/.*[ 	]dev[ 	][ 	]*//;s/[ 	].*//;p}' | tr '\n' '|')"
			ip -o -f inet addr show | grep -E "${ifaces%|}" | grep -oE "$subnet_regex_ipv4" ;;
		ipv6|inet6)
			case "$subnet_regex_ipv6" in '') echolog -err "detect_lan_subnets: regex is not set"; return 1; esac
			ip -o -f inet6 addr show |
				grep -oE 'inet6[ 	]+(fd[0-9a-f]{0,2}:|fe80:)[0-9a-f:/]+' | grep -oE "$subnet_regex_ipv6\$" ;;
		*) echolog -err "detect_lan_subnets: invalid family '$1'."; return 1
	esac
}

# 1 - family (ipv4|ipv6|inet|inet6)
get_lan_subnets() {
	# debugprint "Starting get_lan_subnets"
	detect_lan_subnets "$1" |
	aggregate_subnets "$1" || { echolog -err "$FAIL detect $1 LAN IP ranges."; return 1; }
}

:
