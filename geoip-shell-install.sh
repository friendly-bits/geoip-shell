#!/bin/sh
# shellcheck disable=SC2086,SC1090,SC2154,SC2034

# geoip-shell-install.sh

# Copyright: friendly bits
# github.com/friendly-bits

# Installer for geoip blocking suite of shell scripts

# Creates system folder structure for scripts, config and data.
# Copies the required scripts to /usr/sbin.
# Calls the *manage script to set up geoip-shell and then call the -run script.
# If an error occurs during installation, calls the uninstall script to revert any changes made to the system.

#### Initial setup
p_name="geoip-shell"
curr_ver="0.4"
script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)

export manmode=1 in_install=1 nolog=1

. "$script_dir/$p_name-geoinit.sh" &&
. "$_lib-setup.sh" &&
. "$_lib-uninstall.sh" || exit 1

san_args "$@"
newifs "$delim"
set -- $_args; oldifs


#### USAGE

usage() {
cat <<EOF
v$curr_ver

Usage: $me [-m $mode_syn] [-c <"country_codes">] [-f $fam_syn ] [-u <ripe|ipdeny>] [-s $sch_syn] [-i $if_syn]
${sp8}[-l $lan_syn] [-t $tr_syn] [-p $ports_syn] [-r $user_ccode_syn] [-o <true|false>] [-a <"path">]
${sp8}[-e] [-n] [-k] [-z] [-d] [-h]

Installer for $p_name.
Asks the user about each required option, except those specified in arguments.

Core Options:

  -m $geomode_usage

  -c $ccodes_usage

  -f $families_usage

  -u $sources_usage

  -s $schedule_usage

  -i $ifaces_usage

  -l $lan_ips_usage

  -t $trusted_ips_usage

  -p $ports_usage

  -r $user_ccode_usage

  -o $nobackup_usage

  -a $datadir_usage

Extra Options:
  -e : Optimize nftables ip sets for performance (by default, optimizes for low memory consumption). Has no effect with iptables.
  -n : No persistence. Geoip blocking may not work after reboot.
  -k : No Block: Skip creating the rule which redirects traffic to the geoip blocking chain.
         (everything will be installed and configured but geoip blocking will not be enabled)
  -z : Non-interactive installation. Will not ask any questions. Will fail if required options are not specified or invalid.
  -d : Debug
  -h : This help

EOF
}

#### PARSE ARGUMENTS

while getopts ":c:m:s:f:u:i:l:t:p:r:a:o:enkdhz" opt; do
	case $opt in
		c) ccodes_arg=$OPTARG ;;
		m) geomode_arg=$OPTARG ;;
		s) schedule_arg=$OPTARG ;;
		f) families_arg=$OPTARG ;;
		u) geosource_arg=$OPTARG ;;
		i) ifaces_arg=$OPTARG ;;
		l) lan_ips_arg=$OPTARG ;;
		t) trusted_arg=$OPTARG ;;
		p) ports_arg="$ports_arg$OPTARG$_nl" ;;
		r) user_ccode_arg=$OPTARG ;;
		a) datadir_arg="$OPTARG" ;;
		o) nobackup_arg=$OPTARG ;;

		e) nft_perf=performance ;;
		n) no_persist=1 ;;
		k) noblock=1 ;;
		z) export nointeract=1 ;;
		d) export debugmode=1 ;;
		h) usage; exit 0 ;;
		*) unknownopt
	esac
done
shift $((OPTIND-1))
extra_args "$@"

# inst_root_gs is set by an external packaging script
[ ! "$inst_root_gs" ] && check_root
debugentermsg


#### FUNCTIONS

check_files() {
	missing_files=
	err=0
	for dep_file in $1; do
		[ ! "$dep_file" ] && continue
		if [ ! -s "$script_dir/$dep_file" ]; then
			missing_files="${missing_files}'$dep_file', "
			err=$((err+1))
		fi
	done
	missing_files="${missing_files%, }"
	return "$err"
}

copyscripts() {
	[ "$1" = '-n' ] && { _mod=444; shift; } || _mod=555
	for f in $1; do
		dest="$inst_root_gs$install_dir/${f##*/}"
		[ "$2" ] && dest="$inst_root_gs$2/${f##*/}"
		prep_script "$script_dir/$f" > "$dest" || install_failed "$FAIL copy file '$f' to '$dest'."
		[ ! "$inst_root_gs" ] && {
			chown root:root "${dest}" && chmod "$_mod" "$dest" || install_failed "$FAIL set permissions for file '${dest}${f}'."
		}
	done
}

install_failed() {
	printf '%s\n\n%s\n%s\n' "$*" "Installation failed." "Uninstalling ${p_name}..." >&2
	[ ! "$inst_root_gs" ] && call_script "$p_script-uninstall.sh"
	exit 1
}

pick_shell() {
	unset sh_msg f_shs_avail s_shs_avail
	curr_sh_g_b="${curr_sh_g##*"/"}"
	is_included "$curr_sh_g_b" "$fast_sh" "|" && return 0
	newifs "|" psh
	for ___sh in $fast_sh; do
		checkutil "$___sh" && add2list f_shs_avail "$___sh"
	done
	oldifs psh
	[ -z "$f_shs_avail" ] && [ -n "$ok_sh" ] && return 0
	newifs "|" psh
	for ___sh in $slow_sh; do
		checkutil "$___sh" && add2list s_shs_avail "$___sh"
	done
	oldifs psh
	[ -z "$s_shs_avail" ] && return 0
	is_included "$curr_sh_g_b" "$slow_sh" "|" &&
		sh_msg="${blue}Your shell '$curr_sh_g_b' is supported by $p_name" msg_nc="$n_c" ||
		sh_msg="I'm running under an unsupported/unknown shell '$curr_sh_g_b'"
	if [ -n "$f_shs_avail" ]; then
		recomm_sh="${f_shs_avail%% *}"
		rec_sh_type="faster"
	elif [ -n "$s_shs_avail" ]; then
		recomm_sh="${s_shs_avail%% *}"
		rec_sh_type="supported"
	fi
	[ "$recomm_sh" = busybox ] && recomm_sh="busybox sh"
	printf '\n%s\n%s\n' \
		"$sh_msg but a $rec_sh_type shell '$recomm_sh' is available in this system, using it instead is recommended.$msg_nc" \
		"Would you like to use '$recomm_sh' with $p_name? [y|n] or [a] to abort installation."
	pick_opt "y|n|a"
	case "$REPLY" in
		a|A) exit 0 ;;
		y|Y) newifs "$delim"; set -- $_args; unset curr_sh_g; eval "$recomm_sh \"$me\" $*"; exit ;;
		n|N) if [ -n "$bad_sh" ]; then exit 1; fi
	esac
}

# detects the init system and sources the OWRT -common script if needed
detect_init() {
	[ "$_OWRTFW" ] && return 0
	# check /run/systemd/system/
	[ -d "/run/systemd/system/" ] && { initsys=systemd; return 0; }
	# check /sbin/init strings
	initsys="$(awk 'match($0, /(upstart|systemd|procd|sysvinit|busybox)/) \
		{ print substr($0, RSTART, RLENGTH);exit; }' /sbin/init 2>/dev/null | grep .)" ||
		# check process with pid 1
		{
			_pid1="$(ls -l /proc/1/exe)"
			for initsys in systemd procd busybox upstart initctl unknown; do
					case "$_pid1" in *"$initsys"* ) break; esac
			done
		}
	case "$initsys" in
		initctl) initsys=sysvinit ;;
		unknown) die "Failed to detect the init system. Please notify the developer." ;;
		procd) . "$script_dir/OpenWrt/${p_name}-lib-owrt-common.sh" || exit 1
	esac
	:
}

# 1 - (optional) input filename, otherwise reads from STDIN
# (optional) -n - skip adding the shebang and the version
prep_script() {
	unset noshebang prep_args
	for i in "$@"; do
		[ "$i" = '-n' ] && noshebang=1 || prep_args="$prep_args$i "
	done
	set -- $prep_args
	# print new shebang and version
	[ ! "$noshebang" ] && printf '%s\n%s\n' "#!${curr_sh_g:-/bin/sh}" "curr_ver=$curr_ver"

	if [ "$_OWRTFW" ]; then
		# remove the shebang and comments
		p="^[[:space:]]*#.*$"
	else
		# remove the shebang and shellcheck directives
		p="^[[:space:]]*#(!/|[[:space:]]*shellcheck).*$"
	fi
	if [ "$1" ]; then grep -vxE "$p" "$1"; else grep -vxE "$p"; fi
}


#### Detect the init system
detect_init

#### Variables

export conf_dir="/etc/$p_name"
[ "$_OWRTFW" ] && {
	o_script="OpenWrt/${p_name}-owrt"
	owrt_init="$o_script-init.tpl"
	owrt_fw_include="$o_script-fw-include.tpl"
	owrt_mk_fw_inc="$o_script-mk-fw-include.tpl"
	owrt_comm="OpenWrt/${p_name}-lib-owrt-common.sh"
} || {
	check_compat="check-compat"
	init_check_compat=". \"\${_lib}-check-compat.sh\" &&"
}

detect_lan="${p_name}-detect-lan.sh"

script_files=
for f in fetch apply manage cronsetup run uninstall backup; do
	script_files="$script_files${p_name}-$f.sh "
done

unset lib_files ipt_libs
[ "$_fw_backend" = ipt ] && ipt_libs="ipt apply-ipt backup-ipt status-ipt"
for f in uninstall common arrays nft apply-nft backup-nft status status-nft setup ip-regex $check_compat $ipt_libs; do
	[ "$f" ] && lib_files="${lib_files}lib/${p_name}-lib-$f.sh "
done
lib_files="$lib_files $owrt_comm"

#### CHECKS

check_files "$script_files $lib_files cca2.list $detect_lan $owrt_init $owrt_fw_include $owrt_mk_fw_inc" ||
	die "missing files: $missing_files."

#### MAIN

[ ! "$_OWRTFW" ] && [ ! "$nointeract" ] && pick_shell

set_defaults

# parse command line args and make interactive setup if needed
[ ! "$inst_root_gs" ] && { get_prefs || die; }

export datadir lib_dir="/usr/lib"
export _lib="$lib_dir/$p_name-lib" conf_file="$conf_dir/$p_name.conf" use_shell="$curr_sh_g" status_file="$datadir/status"

## run the *uninstall script to reset associated cron jobs, firewall rules and ipsets
[ ! "$inst_root_gs" ] && { call_script "$p_script-uninstall.sh" || die "Pre-install cleanup failed."; }

## Copy scripts to $install_dir
printf %s "Copying scripts to $install_dir... "
copyscripts "$script_files $detect_lan"
OK

printf %s "Copying library scripts to $lib_dir... "
copyscripts -n "$lib_files" "$lib_dir"
OK

## Create a symlink from ${p_name}-manage.sh to ${p_name}
[ ! "$inst_root_gs" ] && {
	rm "$i_script" 2>/dev/null
	ln -s "$i_script-manage.sh" "$i_script" || install_failed "$FAIL create symlink from ${p_name}-manage.sh to $p_name."
	# add $install_dir to $PATH
	add2list PATH "$install_dir" ':'
}

# Create the directory for config
mkdir -p "$inst_root_gs$conf_dir"


# write config
printf %s "Setting config... "
nodie=1
setconfig datadir user_ccode "iplists=" geomode tcp_ports udp_ports geosource families "schedule=" \
	max_attempts ifaces autodetect nft_perf lan_ips_ipv4 lan_ips_ipv6 trusted_ipv4 trusted_ipv6 \
	reboot_sleep nobackup no_persist noblock "http=" || install_failed
OK

# create the -constants file
cat <<- EOF > "$inst_root_gs$conf_dir/${p_name}-constants" || install_failed "$FAIL set essential variables."
	export PATH="$PATH" initsys="$initsys"
	export use_shell="$curr_sh_g" default_schedule="$default_schedule"
EOF

. "$inst_root_gs$conf_dir/${p_name}-constants"

# create the -geoinit script
cat <<- EOF > "${i_script}-geoinit.sh" || install_failed "$FAIL create the -geoinit script"
	#!$curr_sh_g

	export conf_dir="/etc/$p_name" install_dir="/usr/bin" lib_dir="$lib_dir" iplist_dir="/tmp" lock_file="/tmp/$p_name.lock"
	export conf_file="$conf_file" _lib="\$lib_dir/$p_name-lib" i_script="\$install_dir/$p_name" _nl='
	'
	export LC_ALL=C POSIXLY_CORRECT=yes default_IFS="	 $_nl"

	$init_check_compat
	. "\${_lib}-common.sh" || exit 1
	[ "\$root_ok" ] || [ "\$(id -u)" != 0 ] && return 0
	. "$conf_dir/\${p_name}-constants" || exit 1
	_no_l="\$nolog"
	{ nolog=1 check_deps nft 2>/dev/null && export _fw_backend=nft; } ||
	{ check_deps iptables ip6tables iptables-save ip6tables-save iptables-restore ip6tables-restore ipset && export _fw_backend=ipt
	} || die "neither nftables nor iptables+ipset found."
	export root_ok=1
	r_no_l
	:
EOF

# copy cca2.list
cp "$script_dir/cca2.list" "$inst_root_gs$conf_dir/" || install_failed "$FAIL copy 'cca2.list' to '$conf_dir'."

[ ! "$inst_root_gs" ] && {
	# only allow root to read the $datadir and $conf_dir and files inside it
	mkdir -p "$datadir" && chmod -R 600 "$datadir" "$conf_dir" && chown -R root:root "$datadir" "$conf_dir" ||
		install_failed "$FAIL create '$datadir'."

	### Add iplist(s) for $ccodes to managed iplists, then fetch and apply the iplist(s)
	call_script "$i_script-manage.sh" configure -c "$ccodes" -s "$schedule" || install_failed "$FAIL create and apply the iplist."
}

# OpenWrt-specific stuff
[ "$_OWRTFW" ] && {
	init_script="/etc/init.d/${p_name}-init"
	fw_include="$install_dir/${p_name}-fw-include.sh"
	mk_fw_inc="$i_script-mk-fw-include.sh"

	echo "export _OWRT_install=1" >> "$inst_root_gs$conf_dir/${p_name}-constants"

	if [ "$no_persist" ]; then
		echolog -warn "Installed without persistence functionality."
	else
		echo "Adding the init script... "
		{
			echo "#!/bin/sh /etc/rc.common"
			eval "printf '%s\n' \"$(cat "$script_dir/$owrt_init")\"" | prep_script -n
		} > "$inst_root_gs$init_script" || install_failed "$FAIL create the init script."

		echo "Preparing the firewall include... "
		eval "printf '%s\n' \"$(cat "$script_dir/$owrt_fw_include")\"" | prep_script > "$inst_root_gs$fw_include" &&
		{
			printf '%s\n%s\n%s\n%s\n%s\n' "#!/bin/sh" "p_name=$p_name" \
				"install_dir=\"$install_dir\"" "conf_dir=\"$conf_dir\"" "fw_include_path=\"$fw_include\"" "_lib=\"$_lib\""
			prep_script "$script_dir/$owrt_mk_fw_inc" -n
		} > "$mk_fw_inc" || install_failed "$FAIL prepare the firewall include."

		[ ! "$inst_root_gs" ] && {
			chmod +x "$init_script" && chmod 555 "$fw_include" "$mk_fw_inc" ||
				install_failed "$FAIL set permissions."
			touch "$conf_dir/setupdone"
			enable_owrt_init || install_failed
		}
	fi
}


[ ! "$inst_root_gs" ] && {
	. "$_lib-$_fw_backend.sh" || die
	report_lists; statustip
}
echo "Install done."
