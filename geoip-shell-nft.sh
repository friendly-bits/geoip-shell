#!/bin/sh
# shellcheck disable=SC2154,SC2155,SC2034

# TODO: add verification of the backend

### General

get_nft_family() {
	nft_family="${family%ipv4}"; nft_family="ip${nft_family#ipv}"
}

### Tables and chains

is_geochain_on() {
	force_read_geotable=1
	get_matching_line "$(nft_get_chain "$base_geochain")" "*" "${geotag}_enable" "*"
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

nft_rm_all_georules() {
	printf %s "Removing firewall geoip rules... "
	nolog=1 nft_get_geotable 1>/dev/null 2>/dev/null || { echo "Table '$geotable' doesn't exist"; return 0; }
	nft delete table inet "$geotable" || { echolog -err "Error: Failed to delete table '$geotable'."; return 1; }
	echo "Ok."
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

### (ip)sets

get_ipset_id() {
	list_id="${1%_"$geotag"}"
	list_id="${list_id%_*}"
	family="${list_id#*_}"
	case "$family" in
		ipv4|ipv6) return 0 ;;
		*) echolog -err "Internal error: ip set name '$1' has unexpected format."
			family=''; list_id=''
			return 1
	esac
}

#### High-level functions

# checks current ipsets and firewall rules for geoip-shell
# returns a list of active ip lists
# 1 - var name for output
get_active_iplists() {
	case "$list_type" in
		whitelist) nft_verdict="accept" ;;
		blacklist) nft_verdict="drop" ;;
		*) die "get_active_iplists: Error: unexpected geoip mode '$list_type'."
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
check_lists_coherence() {
	debugprint "Verifying ip lists coherence..."

	# check for a valid list type
	case "$list_type" in whitelist|blacklist) ;; *) die "Error: Unexpected geoip mode '$list_type'!"; esac

	unset unexp_lists missing_lists
	getconfig "Lists" config_lists
	sp2nl "$config_lists" config_lists
	force_read_geotable=1
	get_active_iplists active_lists || {
		nl2sp "$ipset_lists" ips_l_str; nl2sp "$iprules_lists" ipr_l_str
		echolog -err "Warning: ip sets ($ips_l_str) differ from iprules lists ($ipr_l_str)."
		return 1
	}
	force_read_geotable=

	get_difference "$active_lists" "$config_lists" lists_difference
	case "$lists_difference" in
		'') debugprint "Successfully verified ip lists coherence."; return 0 ;;
		*) nl2sp "$active_lists" active_l_str; nl2sp "$config_lists" config_l_str
			echolog -err "Failed to verify ip lists coherence." "active lists: '$active_l_str'" "config lists: '$config_l_str'"
			subtract_a_from_b "$config_lists" "$active_lists" unexp_lists; nl2sp "$unexp_lists" unexp_lists
			subtract_a_from_b "$active_lists" "$config_lists" missing_lists; nl2sp "$unexp_lists" missing_lists
			return 1
	esac
}


geotag="${proj_name}"
export geochain="${geochain:-"$(toupper "$proj_name")"}"

geotable="$geotag"
base_geochain="GEOIP-BASE"
