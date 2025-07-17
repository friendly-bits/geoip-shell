#!/bin/sh
# shellcheck disable=SC1090,SC2154

# geoip-shell-lib-lookup

# Copyright: antonk (antonk.d3v@gmail.com)
# github.com/friendly-bits


lookup() {
	finalize_lookup() {
		rm -rf "$dumped_ipsets_file"
		die "$@"
	}

	dump_ipsets() {
		for ipset in $1; do
			case "$ipset" in *[A-Z][A-Z]_${2}_*|*allow_in_${2}|*allow_out_${2}|*allow_${2}*|block_${2}*)
				print_ipset_elements "$ipset" "$1"
			esac
		done > "$3" || { echolog -err "Failed to get ipset elements for ipsets '$1'."; return 1; }
	}

	lookup_ips() {
		if [ -n "$1" ]; then
			for ip in $1; do
				case "$3" in
					4) case "$ip" in *:*) continue; esac ;;
					6) case "$ip" in *.*) continue; esac
				esac
				printf '%s\n' "$ip"
			done | grepcidr -f "$4"
		elif [ -n "$2" ]; then
			eval "regex=\"\${ipv${3}_regex}\""
			sed "s/$blanks/\n/g" < "$2" | grep -E "$regex" | grepcidr -f "$4"
		fi
	}

	# checks
	checkutil grepcidr || die "grepcidr not found. Install it using your distribution's package manager."
	[ -z "$1" ] && [ -z "$2" ] && die "Specify file with '-F <file>' or input IP addresses with '-I <\"IPs\">'."
	[ -n "$1" ] && [ -n "$2" ] && die "Use either '-F <file>' or '-I <\"IPs\">' but not both."
	[ -z "$2" ] || [ -s "$2" ] || die "File '$2' is not found or empty."

	lookup_families=
	if [ -n "$1" ]; then
		for ip in $1; do
			case "$ip" in
				*:*) add2list lookup_families 6 ;;
				*.*) add2list lookup_families 4 ;;
				*) echolog -nolog -err "Invalid ip: '$ip'${_nl}"
			esac
		done
	elif [ -n "$2" ]; then
		for f in 4 6; do
			eval "regex=\"\${ipv${3}_regex}\""
			grep -E "$regex" "$2" && add2list lookup_families "$f"
		done
	fi

	# variables
	dumped_ipsets_file=/tmp/geoip-shell-lookup.tmp
	ips_found=

	# get ipset list
	ipsets="$(get_ipsets | grep -v '_dhcp_')"
	[ -n "$ipsets" ] || die "No active IP sets found"

	# lookup
	if [ -z "$verb_mode" ]; then
		printf '%s\n\n' "Matching IP's in all loaded IP sets:"
		for f in $lookup_families; do
			dump_ipsets "$ipsets" "$f" "$dumped_ipsets_file" || finalize_lookup 1
			lookup_ips "$1" "$2" "$f" "$dumped_ipsets_file" && ips_found=1
		done
		[ -z "$ips_found" ] && { printf '%s\n' "${red}None${n_c}"; finalize_lookup 2; }
	else
		printf '%s\n\n' "Matching IP's:"
		for f in $lookup_families; do
			for ipset in $ipsets; do
				case "$ipset" in
					*[A-Z][A-Z]_${f}_*|*allow_in_${f}|*allow_out_${f}|*allow_${f}*|block_${f}*) ;;
					*) continue
				esac
				dump_ipsets "$ipset" "$f" "$dumped_ipsets_file" || finalize_lookup 1
				ips="$(lookup_ips "$1" "$2" "$f" "$dumped_ipsets_file")" || continue
				printf '%s\n%s\n\n' "IP set '$ipset':" "$ips"
				ips_found=1
			done
		done
		[ -z "$ips_found" ] && { printf '%s\n' "${red}No matching IP's found in all loaded IP sets.${n_c}"; finalize_lookup 2; }
	fi

	finalize_lookup 0
}

: