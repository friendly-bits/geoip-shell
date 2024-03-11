#!/bin/sh
# shellcheck disable=SC2154,SC2155,SC2034

# library for interacting with nftables

# Copyright: friendly bits
# github.com/friendly-bits

### General

get_nft_family() {
	nft_family="${family%ipv4}"; nft_family="ip${nft_family#ipv}"
}


### Tables and chains

is_geochain_on() {
	old_force="$force_read_geotable"
	force_read_geotable=1
	get_matching_line "$(nft_get_chain "$base_geochain")" "*" "${geotag}_enable" "*"; rv=$?
	force_read_geotable="$old_force"
	return $rv
}

nft_get_geotable() {
	[ -z "$force_read_geotable" ] && [ -n "$_geotable_cont" ] &&  { printf '%s\n' "$_geotable_cont"; return 0; }

	export _geotable_cont="$(nft -ta list ruleset inet | sed -n -e /"^table inet $geotable"/\{:1 -e n\;/^\}/q\;p\;b1 -e \})"
	[ -z "$_geotable_cont" ] && return 1 || { printf '%s\n' "$_geotable_cont"; return 0; }
}

# 1 - chain name
nft_get_chain() {
	_chain_cont="$(nft_get_geotable | sed -n -e /"chain $1 {"/\{:1 -e n\;/"^[[:space:]]*}"/q\;p\;b1 -e \})"
	[ -z "$_chain_cont" ] && return 1 || { printf '%s\n' "$_chain_cont"; return 0; }
}

rm_all_georules() {
	printf %s "Removing firewall geoip rules... "
	nolog=1 nft_get_geotable 1>/dev/null 2>/dev/null ||  return 0
	nft delete table inet "$geotable" || { echolog -err "$FAIL delete table '$geotable'."; return 1; }
	OK
}


### Rules

# 1 - chain name
# 2 - current chain contents
# 3... tags list
mk_nft_rm_cmd() {
	chain="$1"; _chain_cont="$2"; shift 2
	[ ! "$chain" ] || [ ! "$*" ] && return 1
	for tag in "$@"; do
		printf '%s\n' "$_chain_cont" | sed -n "/$tag/"'s/^.* # handle/'"delete rule inet $geotable $chain handle"'/p' || return 1
	done
}

# parses an nft array/list and outputs it in human-readable format
get_nft_list() {
	n=0; _res=
	[ "$1" = '!=' ] && { _res='!='; shift; n=$((n+1)); }
	case "$1" in
		'{')
			while true; do
				shift; n=$((n+1))
				[ "$1" = '}' ] && break
				_res="$_res$1"
			done ;;
		*) _res="$_res$1"
	esac
}

### (ip)sets

get_ipset_id() {
	list_id="${1%_"$geotag"}"
	list_id="${list_id%_*}"
	family="${list_id#*_}"
	case "$family" in
		ipv4|ipv6) return 0 ;;
		*) echolog -err "ip set name '$1' has unexpected format."
			family=''; list_id=''
			return 1
	esac
}

# 1 - set name
nft_cnt_elements() {
	nft list set inet "$geotable" "$1" |
		sed -n -e /"elements[[:space:]]*=/{s/elements[[:space:]]*=[[:space:]]*{//;:1" -e "/}/{s/}//"\; -e p\; -e q\; -e \}\; -e p\; -e n\;b1 -e \} | wc -w
}


#### High-level functions

# checks current ipsets and firewall rules for geoip-shell
# returns a list of active ip lists
# 1 - var name for output
get_active_iplists() {
	case "$list_type" in
		whitelist) nft_verdict="accept" ;;
		blacklist) nft_verdict="drop" ;;
		*) die "get_active_iplists: unexpected geoip mode '$list_type'."
	esac

	ipset_lists="$(nft -t list sets inet | sed -n "/$geotag/{s/.*set[[:space:]]*//;s/_.........._${geotag}.*//p}")"
	iprules_lists="$(nft_get_geotable |
		sed -n "/saddr[[:space:]]*@.*${geotag}.*$nft_verdict/{s/.*@//;s/_.........._${geotag}.*//p}")"

	debugprint "ipset_lists: '$ipset_lists', iprules_lists: '$iprules_lists'"

	get_difference "$ipset_lists" "$iprules_lists" lists_difference
	get_intersection "$ipset_lists" "$iprules_lists" "$1"

	case "$lists_difference" in '') iplists_incoherent=''; return 0 ;; *) iplists_incoherent="true"; return 1; esac
}

# checks whether current ipsets and firewall rules match the config

geotable="$geotag"
base_geochain="GEOIP-BASE"
