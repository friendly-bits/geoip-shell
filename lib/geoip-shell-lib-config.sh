#!/bin/sh
# shellcheck disable=SC2016,SC2154,SC2015,SC2086

# geoip-shell-lib-config.sh

# geoip-shell library for config management

# Copyright: antonk (antonk.d3v@gmail.com)
# github.com/friendly-bits

GS_CONFIG_OWNER=

CONF_FILE_TMP="${GEORUN_DIR:?}/tmpconfig"

unload_main_config() {
	for _conf_pair in $CONF_KEYS_MAP; do
		unset "${_conf_pair##*=}"
	done
	unset GS_CONFIG_SET
}

discard_config_changes() {
	unload_main_config
	rm -f "$CONF_FILE_TMP"
	unset GS_CONFIG_OWNER
}

# 3 (optional): space-separated list of [var_name]=[key] to set (otherwise assigns each key to corresponding var name)
set_config_vars() {
	unset scv_ok scv_fail

	scv_src_pr="$1" scv_lines="$2" scv_req_pairs="$3"

	[ "$scv_lines" ] || { bad_args set_config_vars "$@"; return 1; }
	newifs "$_nl" scv
	for scv_line in $scv_lines; do
		[ -n "$scv_line" ] || continue
		oldifs scv
		scv_key="${scv_line%%=*}"

		if [ -z "$scv_req_pairs" ]; then
			scv_var="$scv_key"
		else
			case "$scv_req_pairs" in
				"${scv_key}="*)
					scv_var="${scv_req_pairs##"${scv_key}="}" ;;
				*" ${scv_key}="*)
					scv_var="${scv_req_pairs##*" ${scv_key}="}" ;;
				*) false
			esac &&
			scv_var="${scv_var%% *}" ||
			{ is_included "$scv_key" "$scv_req_pairs" " " && scv_var="$scv_key"; } ||
			continue
		fi

		[ -n "$scv_var" ] &&
		is_alphanum "$scv_var" &&
		if [ "$EXPORT_CONF" ]; then
			export "${scv_var}=${scv_line#*=}"
		else
			eval "${scv_var}"='${scv_line#*=}'
		fi || { echolog -err "set_config_vars: Invalid line '$scv_line' in $scv_src_pr."; scv_fail=1; break; }
		scv_ok=1
	done
	oldifs scv

	[ -n "$scv_ok" ] && [ -z "$scv_fail" ]
}

# Env vars:
# EXPORT_CONF
#
# gets all config from file $1 or $CONF_FILE if unsecified
# 1: type
# 2: path to config/status file or empty for main cfg file
# 3 (optional): list of [key]=[var_name] to set (otherwise assigns each key to mapped var name)
load_config() {
	unset lcf_lines lcf_f lcf_type lcf_src lcf_src_pr

	lcf_type="$1"
	lcf_src="$2"
	lcf_req_pairs="$3"

	[ -z "$lcf_req_pairs" ] && [ "$lcf_type" = "main" ] && lcf_req_pairs="$CONF_KEYS_MAP"

	lcf_f="${lcf_src:-"$CONF_FILE"}"
	lcf_src_pr="file '$lcf_f'"

	parse_config lcf_lines "$lcf_f" "$lcf_type" &&
	set_config_vars "$lcf_src_pr" "$lcf_lines" "$lcf_req_pairs" ||
	{
		echolog -err "$FAIL parse $lcf_src_pr."
		[ ! "$nodie" ] && die
		return 1
	}

	:
}

# Load main config
# If parent doesn't own the config, set curr script as config owner
load_main_config() {
	[ -n "$GS_CONFIG_SET" ] && [ "$1" != '-f' ] && return 0
	EXPORT_CONF=1 load_config main || return 1

	[ -z "$GS_CONFIG_SET" ] && GS_CONFIG_OWNER=1 # identifies the script which owns the exported config vars
	export GS_CONFIG_SET=1
}

ser_cfg() {
	ser_out_var="$1"
	shift
	ser_opts=
	for ser_opt in "$@"; do
		[ -n "$ser_opt" ] || continue
		ser_opts="${ser_opts}${ser_opt}${delim}"
	done
	eval "$ser_out_var"='$ser_opts'
}

# Env vars:
# PCF_IGNORE_MISSING_FILE
# PCF_IGNORE_MISSING_KEYS
# PCF_FORCE_RELOAD
#
# 1: var name for new config output
# 2: conf file path
# 3: type
# extra args (optional): new key=value pairs to override old config
parse_config() {
	pcf_fail() { [ -n "$1" ] && echolog -err "parse_config: $1"; eval "${pcf_new_conf_var:-_}=''"; }

	pcf_new_conf_var="$1" pcf_path="$2" pcf_type="$3"
	unset pcf_is_main pcf_migr_opts_map pcf_regex pcf_valid_keys pcf_depr_keys pcf_cfg1 pcf_cfg2

	# cfg1 = config from file
	# cfg2 = config from args

	[ "$pcf_path" = "$CONF_FILE" ] && {
		pcf_is_main=1
		pcf_migr_opts_map="$MIGR_KEYS_MAP"
		pcf_depr_keys="$DEPR_KEYS"
	}

	[ $# -ge 3 ] &&
	case "$*" in *"$_nl"*|*"$delim"*) false ;; *) :; esac &&
	[ -n "$pcf_new_conf_var" ] && [ -n "$pcf_path" ] && [ -n "$pcf_type" ] &&
	case "$pcf_type" in
		main)
			pcf_valid_keys="$CONF_KEYS_MAP"
			[ -n "$pcf_is_main" ] && [ -s "$CONF_FILE_TMP" ] && {
				pcf_path="$CONF_FILE_TMP"
			}
			: ;;
		exclusions) pcf_valid_keys="exclude_iplists_country exclude_iplists_asn" ;;
		cca2) pcf_valid_keys="$VALID_REGISTRIES" ;;
		main_status) pcf_valid_keys="last_update" pcf_regex="prev_date_[a-zA-Z0-9_]*|prev_ips_cnt_[a-zA-Z0-9_]*" ;;
		fetch_res) pcf_valid_keys="fetched_lists failed_lists" ;;
		counters) pcf_regex="[a-zA-Z0-9_]*" ;;
		*) false ;;
	esac || { bad_args parse_config "$@"; return 1; }

	[ "$pcf_type" = "main" ] && pcf_regex="$MAIN_CONF_REGEX" ||
		for key_exp in $pcf_valid_keys; do
			key="${key_exp%%=*}"
			pcf_regex="${pcf_regex}${pcf_regex:+|}${key}"
		done

	[ -n "$pcf_regex" ] || { bad_args parse_config "$@"; return 1; }
	pcf_regex="^(${pcf_regex})$"

	pcf_conf=
	pcf_file_found=

	shift 3

	ser_cfg pcf_cfg2 "$@"

	[ -s "$pcf_path" ] && {
		pcf_file_found=1
		pcf_cfg1="$(cat "$pcf_path" | tr '\n' "$delim")"
	}

	[ -n "$pcf_file_found" ] || [ -n "$PCF_IGNORE_MISSING_FILE" ] || {
		pcf_fail "Config/status file '$pcf_path' is missing!"
		return 1
	}

	pcf_warn_file="${GEOTEMP_DIR:-"/tmp"}/pcf_warn"
	mkdir -p "${pcf_warn_file%/*}"
	rm -f "$pcf_warn_file"

	pcf_conf="$(
		$awk_cmd \
				-v cfg1="$pcf_cfg1" \
				-v cfg2="$pcf_cfg2" \
				-v is_main="$pcf_is_main" \
				-v val_keys="$pcf_valid_keys" \
				-v regex="$pcf_regex" \
				-v migr_opts="$pcf_migr_opts_map" \
				-v depr_keys="$pcf_depr_keys" \
				-v ignore_missing="$PCF_IGNORE_MISSING_KEYS" \
				-v delim="$delim" \
				-v yellow="$yellow" -v n_c="$n_c" \
			'

			function WARN(msg) {print yellow msg n_c > "/dev/stderr"}
			function san_spaces(line,san_delim) {
				if (!san_delim) san_delim=" "
				sub(/^[ 	]+/, "", line); sub(/[ 	]+$/, "", line); gsub(/[ 	]+/,san_delim,line); return line
			}

			BEGIN{
				rv=0
				rv_dup=0
				rv_missing=0

				# migrated, deprecated opts
				if (is_main) {
					split(migr_opts,migr_tmp," ")
					for (el in migr_tmp) {
						line=migr_tmp[el]
						n=split(line,migr_pair,"=")
						if (n == 2) {
							old_k=migr_pair[1]
							new_k=migr_pair[2]
							if (!old_k || !new_k) continue
							migr[old_k]=new_k
						}
					}

					u=split(depr_keys,depr_tmp," ")
					for (el in depr_tmp) { key=depr_tmp[el]; depr[key] }
				}

				# req_keys
				val_keys=san_spaces(val_keys)
				n=split(val_keys,t_arr," ")
				for (i=1; i<=n; i++) {
					key_exp=t_arr[i]
					if (!key_exp) continue
					split(key_exp,t_key,"=")

					key=t_key[1]
					req_keys[key]
					req_keys_ind[i]=key
				}

				configs_arr[1]=cfg1
				configs_arr[2]=cfg2
				for (i=1; i<=2; i++) {
					if (!configs_arr[i]) continue
					split(configs_arr[i],cfg_tmp,delim)
					for (el in cfg_tmp) {
						line=san_spaces(cfg_tmp[el])
						if ( !line || index(line,"#") == 1 ) continue
						n=split(line,pair,"=")
						key=pair[1]
						val=pair[2]
						if (n == 2 && key ~ /^[a-zA-Z0-9_]+$/ && val !~ /.*[$()"`'\''].*/) {}
							else {WARN("Failed to parse line \"" line "\" in cfg" i); exit 1}

						if (is_main && key in depr) continue
						if (is_main && key in migr) key=migr[key]

						key_pr=" key \"" key "\""
						if (seen_keys[i"-"key]) {WARN("Duplicate" key_pr "in cfg" i); rv_dup=73}
						if (key ~ regex) {
							seen_keys[i"-"key]=1
							seen_keys[key]=1
							res[key]=val
						}
						else WARN("Ignoring unknown" key_pr)
					}
				}

				if (!ignore_missing) {
					for (key in req_keys)
						{if (seen_keys[key] != 1) {
							WARN("Missing key \"" key "\"")
							if (!is_main) exit 1
							rv_missing=98
							res[key]=""
						}
					}
				}

				# Print in consistent order
				ind=1
				while (req_keys_ind[ind]) {
					key=req_keys_ind[ind]
					if (key in res) {} else {ind++; continue}
					print key "=" res[key]
					printed[key]
					ind++
				}
				for (key in res) { if (key in printed) continue; print key "=" res[key]}
				exit rv_missing + rv_dup
			}
		' 2>"$pcf_warn_file"
	)"

	pcf_rv=$?

	unset pcf_w_msg pcf_changed pcf_dup pcf_missing pcf_err
	case "$pcf_rv" in
		0) ;;
		73) pcf_dup=1 ;;
		98) pcf_missing=1 ;;
		171) pcf_dup=1 pcf_missing=1 ;;
		1) pcf_err=1 ;;
		*) echolog -err "parse_config: unexpected awk return code '$pcf_rv'"; pcf_err=1 ;;
	esac

	[ -s "$pcf_warn_file" ] && pcf_w_msg="$(cat "$pcf_warn_file" 2>/dev/null)"
	rm -f "$pcf_warn_file"

	[ "$pcf_w_msg" ] && { [ ! "$pcf_is_main" ] || [ "$pcf_w_msg" != "$PCF_WARNED" ]; } && {
		echolog -warn "Config parser for file '$pcf_path':${_nl}${pcf_w_msg}"

		[ -n "$pcf_missing" ] &&
			echolog "${yellow}Missing config entries will be recreated with empty values at next config file update.${n_c}"

		[ -n "$pcf_dup" ] &&
			echolog "${yellow}Duplicate config entries will be removed at next config file update.${n_c}"
		printf '\n'

		[ "$pcf_is_main" ] && export PCF_WARNED="$pcf_w_msg"
	}

	[ -n "$pcf_err" ] && {
		pcf_fail "$FAIL parse config."
		return 1
	}

	eval "$pcf_new_conf_var"='$pcf_conf'

	:
}

set_main_config() { setconfig main "" "$@"; }

# 1: type
# 2: file path
# Accepts key=value pairs and writes them to (or replaces in) the config/status file
setconfig() {
	sc_failed() { echolog -err "setconfig failed${1:+": $1"}"; [ ! "$nodie" ] && die; }

	newconfig=
	sc_type="$1" sc_path="$2"
	shift 2

	sc_main_conf_path="${inst_root_gs}${CONF_FILE}"
	[ "$sc_type" = main ] && : "${sc_path:=${sc_main_conf_path}}"

	[ "$sc_path" ] || { sc_failed "'\$sc_path' variable is not set."; die; }

	sc_is_main=
	[ "$sc_path" = "${sc_main_conf_path}" ] && sc_is_main=1

	# Use tmp file when modifying config loaded by a parent
	sc_load_path="$sc_path"
	sc_save_path="$sc_path"

	[ "$sc_is_main" ] && {
		sc_save_path="$CONF_FILE_TMP"
		[ -f "$CONF_FILE_TMP" ] && sc_load_path="$CONF_FILE_TMP"
	}

	PCF_IGNORE_MISSING_FILE=1 PCF_IGNORE_MISSING_KEYS=1 parse_config newconfig "$sc_load_path" "$sc_type" "$@" ||
		{ sc_failed "$FAIL process config in file '$sc_load_path'."; return 1; }

	if [ ! -f "$sc_save_path" ] || ! compare_file2str "$sc_save_path" "$newconfig"; then
		debugprint "Updating config/status at '$sc_save_path'."
		printf '%s\n' "$newconfig" > "$sc_save_path" || { sc_failed "$FAIL write to '$sc_save_path'"; return 1; }

		[ "$sc_is_main" ] && [ "$sc_save_path" = "$sc_main_conf_path" ] && OK >&2

		[ "$ROOT_OK" = 1 ] && {
			chmod 600 "$sc_save_path" && chown root:root "$sc_save_path" ||
				echolog -warn "$FAIL update permissions for file '$sc_save_path'."
		}
	fi

	:
}

# Writes all values in main config vars to CONF_FILE_TMP
set_all_config() {
	for sac_var in $CONF_KEYS_MAP; do
		sac_key="${sac_var%%=*}"
		sac_var="${sac_var#*=}"
		eval "sac_val=\"\${$sac_var}\""
		sac_entries="${sac_entries}${sac_key}=${sac_val}${_nl}"
	done
	newifs "$_nl" sac
	set -- ${sac_entries%"$_nl"}
	oldifs sac
	setconfig main "" "$@"
}

# wrapper for load_config() intended for status files
# 1: type
# 2: file path
getstatus() {
	[ -n "$1" ] && [ -n "$2" ] || {
		bad_args getstatus "$@"
		[ ! "$nodie" ] && die
		return 1
	}
	PCF_IGNORE_MISSING_KEYS=1 nodie=1 load_config "$1" "$2"
}

# wrapper for setconfig()
# 1: path to file
# args are passed as is to setconfig
setstatus() {
	[ "$1" ] || { bad_args setstatus "$@"; die; }
	[ -d "${1%/*}" ] || mkdir -p "${1%/*}" || return 1
	# 	[ "$ROOT_OK" = 1 ] && chmod -R 600 "${1%/*}"
	# [ -f "$1" ] || touch "$1" &&
	# 	[ "$ROOT_OK" = 1 ] && chmod 600 "$1"
	setconfig "$@" && return 0
	rm -f "$1"
	return 1
}

set_main_conf_opts() {
	# Map in the format <key[=var_name]>
	# When var_name is omitted, var_name is same as config key
	CONF_KEYS_MAP="
		inbound_geomode
		inbound_iplists
		inbound_tcp_ports
		inbound_udp_ports
		inbound_icmp
		outbound_geomode
		outbound_iplists
		outbound_tcp_ports
		outbound_udp_ports
		outbound_icmp
		lan_ips_ipv4
		lan_ips_ipv6
		autodetect_lan
		trusted_ipv4
		trusted_ipv6
		source_ips_ipv4
		source_ips_ipv6
		source_ips_policy
		ip_families=families
		geosource
		firewall_backend=_fw_backend
		ifaces
		upd_schedule
		max_fetch_attempts
		reboot_sleep
		no_block
		no_persist
		no_backup
		force_cron_persist
		nft_sets_policy=nft_perf
		keep_fetched_db
		user_ccode
		mm_license_type
		mm_acc_id
		mm_license_key
		ipinfo_license_type
		ipinfo_token
		datadir
		local_iplists_dir
		custom_script
		bk_ext
	"

	# Config migration
	# list of options to migrate in the format <old_key=new_key>
	MIGR_KEYS_MAP="
		_fw_backend=firewall_backend
		families=ip_families
		autodetect=autodetect_lan
		keep_mm_db=keep_fetched_db
		schedule=upd_schedule
		noblock=no_block
		nobackup=no_backup
		nft_perf=nft_sets_policy
		max_attempts=max_fetch_attempts
	"

	DEPR_KEYS="
		http
	"

	for mco_cat in CONF_KEYS_MAP MIGR_KEYS_MAP DEPR_KEYS; do
		IFS="$default_IFS"
		eval "mco_opts=\"\${$mco_cat}\""
		set -- $mco_opts
		IFS=" "
		export "$mco_cat=$*"
	done

	IFS="$default_IFS"

	export MAIN_CONF_REGEX=
	for so_exp in $CONF_KEYS_MAP; do
		so_key="${so_exp%%=*}"
		MAIN_CONF_REGEX="${MAIN_CONF_REGEX}${MAIN_CONF_REGEX:+|}${so_key}"
	done
}

[ -n "$CONF_KEYS_MAP" ] || set_main_conf_opts

:
