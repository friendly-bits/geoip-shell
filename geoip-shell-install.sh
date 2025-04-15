#!/bin/sh
# shellcheck disable=SC2086,SC1090,SC2154,SC2034,SC2016

# geoip-shell-install.sh

# Copyright: antonk (antonk.d3v@gmail.com)
# github.com/friendly-bits

# Installer for geoip blocking suite of shell scripts

# Creates system folder structure for scripts, config and data.
# Copies the required scripts to /usr/sbin.
# Optionally calls the *manage script to set up geoip-shell and then call additional scripts to set up geoblocking.

#### Initial setup
p_name="geoip-shell"
script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)

export manmode=1 first_setup=1 nolog=1

. "$script_dir/$p_name-geoinit.sh" &&
. "$_lib-uninstall.sh" || exit 1

san_args "$@"
newifs "$delim"
set -- $_args; oldifs


#### USAGE

usage() {
cat <<EOF

Usage: $me [-z] [-d] [-V] [-h]

Installer for $p_name.

Options:
  -z : $nointeract_usage
  -d : Debug
  -V : Version
  -h : This help

EOF
}

#### PARSE ARGUMENTS

while getopts ":zdVh" opt; do
	case $opt in
		z) nointeract_arg=1 ;;
		d) debugmode=1 ;;
		V) echo "$curr_ver"; exit 0 ;;
		h) usage; exit 0 ;;
		*) unknownopt
	esac
done
shift $((OPTIND-1))
extra_args "$@"

# inst_root_gs is set by an external packaging script
[ ! "$inst_root_gs" ] && is_root_ok
debugentermsg


#### FUNCTIONS

check_files() {
	missing_files=
	err=0
	for dep_file in $1; do
		if [ "$dep_file" ] && [ ! -s "$dep_file" ]; then
			missing_files="${missing_files}'$dep_file', "
			err=$((err+1))
		fi
	done
	missing_files="${missing_files%, }"
	return "$err"
}

compare_files() {
	[ -s "$1" ] && [ -s "$2" ] &&
	md5sum "$1" "$2" 2>/dev/null | \
		$awk_cmd 'BEGIN{rv=1} NF==0{next}; {i=i+1} i==2{ if ($1==rec) {rv=0; exit} else {exit}} {rec=$1; next} END{exit rv}' &&
			return 0
	return 1
}

set_permissions() {
	update_perm() {
		chmod "$2" "$1" && chown root:root "$1" || { echolog -err "$FAIL set permissions for file '$1'."; exit 1; }
	}

	while IFS='' read -r entry; do
		[ -z "$entry" ] && continue
		IFS="$delim"
		set -- $entry
		f_path="$1" set_perm="$2" wrong_perm=
		IFS="$default_IFS"

		case "${set_perm%% *}" in [0-9][0-9][0-9]) ;; *)
			echolog -err "File '$reg_permissions' contains invalid entry."; exit 1
		esac

		f_perm="$(ls -l "$f_path")"
		upd_perm=
		case "${f_perm%% *}" in
			d*) echolog -err "'$f_path' should be a file but it is a directory."; exit 1 ;;
			*[!-lxrw]*|'')
				echolog -err "$FAIL check permissions of file '$f_path' ('${f_perm}')."
				upd_perm=1 ;;
			*r-xr-xr-x) [ "$set_perm" != 555 ] && upd_perm=1 ;;
			*r--r--r--) [ "$set_perm" != 444 ] && upd_perm=1 ;;
			*rw-------) [ "$set_perm" != 600 ] && upd_perm=1 ;;
			*) upd_perm=1
		esac
		[ "$upd_perm" ] && update_perm "$f_path" "$set_perm"
		:
	done < "$reg_permissions" || install_failed "$FAIL set permissions."
}

copy_files() {
	[ ! -s "$cp_files_reg" ] && { printf '%s\n' "All files are up-to-date. Nothing to copy."; return 0; }
	printf %s "Copying files... "
	while IFS='' read -r entry; do
		[ -z "$entry" ] && continue
		IFS="$delim"
		set -- $entry
		src_file="$1" dest_file="$2"
		IFS="$default_IFS"
		[ -n "$src_file" ] && [ -s "$src_file" ] && [ -n "$dest_file" ] ||
			{ echolog -err "File '$cp_files_reg' includes an invalid entry."; exit 1; }
		cp "$src_file" "$dest_file" || { echolog -err "$FAIL copy file '$src_file' to '$dest_file'."; exit 1; }
		:
	done < "$cp_files_reg" || preinstall_failed "$FAIL copy files."
	OK
	:
}

# create processed scripts in $tmp_dir and register them
# 1 - list of src files, 2 - target directory, 3 - permissions
add_scripts() {
	src_files="$1" target_dir="$2" _mod="$3"
	mkdir -p "$tmp_dir$target_dir" || preinstall_failed "$FAIL create directory '$tmp_dir$target_dir'."

	for f in $src_files; do
		f_name="${f##*/}"
		tmp_dest="$tmp_dir$target_dir/$f_name"
		dest="$target_dir/$f_name"
		prep_script "$f" > "$tmp_dest" || preinstall_failed "$FAIL create '$tmp_dest'."

		[ ! "$inst_root_gs" ] && { chmod "$_mod" "$tmp_dest" && chown root:root "${tmp_dest}"; } 2>/dev/null

		add_file "$tmp_dest" "$dest" "$_mod"
	done
	:
}

# register the file in $reg_permissions
# check whether the file need to be updated and register the result in $cp_files_reg
# 1 - src, 2 - dest, 3 - permissions
add_file() {
	af_src="$1" af_dest="$inst_root_gs$2" _mod="$3"
	printf '%s\n' "${af_dest}${delim}${_mod}" >> "$reg_permissions" || install_failed "$FAIL write to file '$reg_permissions'."

	# check if the file changed
	compare_files "$af_src" "$af_dest" && return 0
	printf '%s\n' "${af_src}${delim}${af_dest}" >> "$cp_files_reg" || install_failed "$FAIL write to file '$cp_files_reg'."
	:
}

preinstall_failed() {
	[ "$*" ] && printf '%s\n' "$*" >&2
	printf '\n%s\n' "Installation failed." >&2
	rm -rf "$tmp_dir"
	exit 1
}

install_failed() {
	[ "$*" ] && printf '%s\n' "$*" >&2
	printf '\n%s\n' "Installation failed." >&2
	rm -rf "$tmp_dir"
	[ ! "$inst_root_gs" ] && {
		echo "Uninstalling ${p_name}..." >&2
		call_script "$p_script-uninstall.sh" -r
		rm_data
	}
	exit 1
}

manage_interr() {
	: "${manage_rv:=$?}"
	trap - INT TERM HUP QUIT
	printf '\n\n%s\n' "${yellow}Configuration was interrupted.${n_c} $please_configure" >&2
	rm -f "$status_file"
	exit $manage_rv
}

pick_shell() {
	unset sh_msg f_shs_avail s_shs_avail
	curr_sh_g_b="${curr_sh_g##*"/"}"
	is_included "$curr_sh_g_b" "$fast_sh" "|" && return 0
	[ -z "$ok_sh" ] && {
		printf '\n%s\n%s\n\n' "${yellow}NOTE:${n_c} I'm running under an untested/unsupported shell '$blue$curr_sh_g_b$n_c'." \
		"Consider runing $p_name-install.sh from a supported shell, such as ${blue}dash${n_c} or ${blue}bash${n_c}."
		return 0
	}

	newifs "|" psh
	for ___sh in $fast_sh; do
		checkutil "$___sh" && add2list f_shs_avail "$___sh"
	done
	oldifs psh
	[ -z "$f_shs_avail" ] && {
		is_included "$curr_sh_g_b" "$slow_sh" "|" && printf '\n%s\n%s\n\n' \
			"${yellow}NOTE:${n_c} You are running $p_name in '$curr_sh_g_b' which makes it run slower than necessary." \
			"Consider installing a faster shell, such as ${blue}dash${n_c}, and running $p_name-install again."
		return 0
	}

	recomm_sh="${f_shs_avail%% *}"
	[ -z "$recomm_sh" ] && return 0
	[ "$recomm_sh" = busybox ] && recomm_sh="busybox sh"
	printf '\n%s\n%s\n%s\n' \
		"${blue}Your shell '$curr_sh_g_b' is supported by $p_name but a faster shell '$recomm_sh'" \
		"is available in this system, using it instead is recommended.$n_c" \
		"Would you like to use '$recomm_sh' with $p_name? [y|n] or [a] to abort installation."
	pick_opt "y|n|a"
	case "$REPLY" in
		a) exit 0 ;;
		y)
			newifs "$delim" psh
			set -- $_args
			unset curr_sh_g
			oldifs psh
			eval "$recomm_sh \"$script_dir/$p_name-install.sh\" $*"
			exit ;;
		n) if [ -n "$bad_sh" ]; then exit 1; fi
	esac
}

# detects the init system and sources the OWRT -common script if needed
detect_init() {
	check_openrc() { grep 'sysinit:/.*/openrc sysinit' /etc/inittab 1>/dev/null 2>/dev/null && initsys=openrc; }
	check_strings() {
		$awk_cmd 'BEGIN{IGNORECASE=1; rv=1} match($0, /(upstart|systemd|procd|sysvinit|busybox|openrc)/) \
			{ print substr($0, RSTART, RLENGTH); rv=0; exit; } END{exit rv}' "$1"
	}

	[ "$_OWRTFW" ] && { initsys=procd; [ "$inst_root_gs" ] && return 0; }
	# check /run/systemd/system/
	[ -d "/run/systemd/system/" ] && { initsys=systemd; return 0; }
	if [ ! "$initsys" ]; then
		# check /sbin/init strings
		initsys="$(check_strings /sbin/init 2>/dev/null)" ||
			# check process with pid 1
			{
				_pid1="$(ls -l /proc/1/exe | awk '{print $NF}')"
				_pid1_lc="$(printf %s "$_pid1" | tr 'A-Z' 'a-z')"
				for initsys in systemd procd busybox openrc upstart initctl unknown; do
					case "$_pid1_lc" in *"$initsys"* ) break; esac
				done
				if [ "$initsys" = unknown ]; then
					[ -n "$_pid1" ] && [ -f "$_pid1" ] && initsys="$(check_strings "$_pid1")" || initsys=unknown
				fi
			}
	fi
	case "$initsys" in
		busybox) check_openrc ;;
		initctl|sysvinit) initsys=sysvinit; check_openrc ;;
		unknown) die "Failed to detect the init system. Please notify the developer." ;;
		procd) . "$script_dir/OpenWrt/${p_name}-lib-owrt.sh" || exit 1
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

	# print new shebang, version and copyright
	[ ! "$noshebang" ] &&
	cat <<- EOF
		#!${curr_sh_g:-/bin/sh}

		curr_ver=$curr_ver

		# Copyright: antonk (antonk.d3v@gmail.com)
		# github.com/friendly-bits

	EOF

	# filter pattern
	if [ "$_OWRTFW" ]; then
		# remove the shebang and comments, leave debug markers
		p="^[[:space:]]*#[^@].*$"
	else
		# remove the shebang, copyright and shellcheck directives
		p="^[[:space:]]*#(!/|[[:space:]]*(shellcheck|Copyright|github)).*$"
	fi

	# apply the filter, condense empty lines
	if [ "$1" ]; then grep -vxE "$p" "$1"; else grep -vxE "$p"; fi | grep -vA1 "^${blank}*$" | grep -v '^--$'
}


checkvars install_dir lib_dir p_script i_script _lib lock_file _nl

#### Detect the init system
detect_init
debugprint "Detected init: '$initsys'."

#### Variables

export nointeract_arg debugmode lib_dir="/usr/lib/$p_name" conf_dir="/etc/$p_name" \
	tmp_dir="${inst_root_gs}/tmp/${p_name}-install"
export conf_file="$conf_dir/$p_name.conf"

reg_file="$lib_dir/${p_name}-components"
reg_permissions="$tmp_dir/${p_name}-permissions"
reg_tmp="$tmp_dir/${p_name}-components"
cp_files_reg="$tmp_dir/${p_name}-components-replace"
please_configure="Please run '$p_name configure' to complete the setup."

unset fw_libs ipt_libs nft_libs set_posix non_owrt init_non_owrt_pt1
ipt_fw_libs=ipt
nft_fw_libs=nft
all_fw_libs="ipt nft"

[ "$_OWRTFW" ] && {
	o_script="OpenWrt/${p_name}-owrt"
	owrt_init="$o_script-init.tpl"
	owrt_fw_include="$o_script-fw-include.tpl"
	owrt_mk_fw_inc="$o_script-mk-fw-include.tpl"
	owrt_comm="${script_dir}/OpenWrt/${p_name}-lib-owrt.sh"
	case "$_OWRTFW" in
		3) _fw_backend=ipt ;;
		4) _fw_backend=nft ;;
		all) _fw_backend=all
	esac
	set_owrt_install="export _OWRT_install=1${_nl}. \"\${_lib}-owrt.sh\" || die"
	eval "fw_libs=\"\$${_fw_backend}_fw_libs\""
} || {
	non_owrt="non-owrt"
	set_posix="
	if [ -z \"\$posix_o_set\" ]; then
		if set -o | grep '^posix[ \t]' 1>/dev/null; then
			set -o posix
			export posix_o_set=1
		else
			export posix_o_set=0
		fi
	elif [ \"\$posix_o_set\" = 1 ]; then
		set -o posix
	fi"

	init_non_owrt_pt1=". \"\${_lib}-non-owrt.sh\" || exit 1${_nl}check_common_deps${_nl}check_shell"
	fw_libs="$all_fw_libs"
}

script_files=
for f in fetch apply manage cronsetup run uninstall backup; do
	script_files="$script_files${script_dir}/${p_name}-$f.sh "
done

lib_files=
for f in uninstall common arrays status setup ip-tools $non_owrt $fw_libs; do
	[ "$f" ] && lib_files="${lib_files}${script_dir}/lib/${p_name}-lib-$f.sh "
done
lib_files="$lib_files $owrt_comm"


#### CHECKS
printf %s "Checking files... "
check_files "$script_files $lib_files $script_dir/cca2.list $owrt_init $owrt_fw_include $owrt_mk_fw_inc" ||
	die "missing files: $missing_files."
OK

[ ! "$inst_root_gs" ] && { detect_fw_backends 1>/dev/null || die; }


#### MAIN

[ ! "$_OWRTFW" ] && [ ! "$nointeract_arg" ] && pick_shell
: "${curr_sh_g:=/bin/sh}"
export _lib="$lib_dir/$p_name-lib" use_shell="$curr_sh_g"

rm -rf "$tmp_dir"
dir_mk -n "$tmp_dir" || die

[ ! "$inst_root_gs" ] && {
	# add $install_dir to $PATH
	add2list PATH "$install_dir" ':'

	[ -s "$conf_file"  ] && nodie=1 get_config_vars && export datadir status_file="$datadir/status"

	reg_file_ok=
	[ -s "$reg_file" ] && reg_file_ok=1 && while read -r f; do
		[ -s "$f" ] && continue
		reg_file_ok=
		break
	done < "$reg_file"

	if [ "$reg_file_ok" ] && [ -s "$conf_file" ] &&
			nodie=1 getconfig _fw_backend_prev _fw_backend &&
			[ "$_fw_backend_prev" ] && [ -s "${_lib}-$_fw_backend_prev.sh" ] &&
			(
				. "${_lib}-$_fw_backend_prev.sh" &&
				kill_geo_pids &&
				rm_lock &&
				rm_all_georules
			) &&
			prev_reg_file_cont="$(cat "$reg_file")"
	then
		:
	else
		echolog "Cleaning up previous installation (if any)..."
		call_script "$p_script-uninstall.sh" -r || die "Pre-install cleanup failed."
	fi
	rm -f "$conf_dir/setupdone"
}

## add scripts
printf '%s\n' "Preparing to install $p_name..."
add_scripts "$script_files" "$install_dir" 555
add_scripts "$lib_files" "$lib_dir" 444

# create the .const file
cat <<- EOF > "$tmp_dir/${p_name}.const" || preinstall_failed "$FAIL create file '"$tmp_dir/${p_name}.const"'."
	export PATH="$PATH" initsys="$initsys" use_shell="$curr_sh_g"
EOF
add_file "$tmp_dir/${p_name}.const" "$conf_dir/${p_name}.const" 600

export PATH initsys use_shell="$curr_sh_g"

# create the -geoinit script
cat <<EOF > "$tmp_dir/$p_name-geoinit.sh" || preinstall_failed "$FAIL create file '$tmp_dir/$p_name-geoinit.sh'."
#!$curr_sh_g

# Copyright: antonk (antonk.d3v@gmail.com)
# github.com/friendly-bits

export conf_dir="/etc/$p_name" install_dir="/usr/bin" lib_dir="$lib_dir" iplist_dir="/tmp/$p_name"
export lock_file="/tmp/$p_name.lock" excl_file="$conf_dir/iplist-exclusions.conf"
export p_name="$p_name" conf_file="$conf_file" _lib="\$lib_dir/$p_name-lib" i_script="\$install_dir/$p_name" _nl='
'
export LC_ALL=C POSIXLY_CORRECT=YES default_IFS="	 \$_nl"

$set_posix

$init_non_owrt_pt1

[ "\$root_ok" ] || { [ "\$(id -u)" = 0 ] && export root_ok="1"; }
$set_owrt_install
. "\${_lib}-common.sh" || exit 1
[ "\$fwbe_ok" ] || [ ! "\$root_ok" ] && return 0
[ -f "\$conf_dir/\${p_name}.const" ] && { . "\$conf_dir/\${p_name}.const" || die; } ||
	{ [ ! "\$in_uninstall" ] && die "\$conf_dir/\${p_name}.const is missing. Please reinstall \$p_name."; }

[ -s "\$conf_file" ] && nodie=1 getconfig _fw_backend
if [ ! "\$_fw_backend" ]; then
	rm -f "\$conf_dir/setupdone"
	[ "\$first_setup" ] && return 0
	case "\$me \$1" in "\$p_name configure"|"\${p_name}-manage.sh configure"|*" -h"*|*" -V"*) return 0; esac
	[ ! "\$in_uninstall" ] && die "Config file \$conf_file is missing or corrupted. Please run '\$p_name configure'."
elif ! check_fw_backend "\$_fw_backend"; then
	_fw_be_rv=\$?
	if [ "\$in_uninstall" ]; then
		_fw_backend=
	else
		case \$_fw_be_rv in
			1) die ;;
			2) die "Firewall backend '\${_fw_backend}ables' not found." ;;
			3) die "Utility 'ipset' not found."
		esac
	fi
fi
export fwbe_ok=1 _fw_backend
:
EOF
add_scripts "$tmp_dir/$p_name-geoinit.sh" "$install_dir" 444

# add cca2.list
add_file "$script_dir/cca2.list" "$conf_dir/cca2.list" 444

# add iplist-exclusions.conf
add_file "$script_dir/iplist-exclusions.conf" "$conf_dir/iplist-exclusions.conf" 444

# OpenWrt-specific stuff
[ "$_OWRTFW" ] && {
	tmp_init_script="$tmp_dir/$p_name-init"
	tmp_fw_include="$tmp_dir/$p_name-fw-include.sh"
	tmp_mk_fw_inc="$tmp_dir/$p_name-mk-fw-include.sh"

	echo "Adding the init script... "
	{
		printf '%s\n' "#!/bin/sh /etc/rc.common"
		eval "printf '%s\n' \"$(cat "$script_dir/$owrt_init")\"" | prep_script -n
	} > "$tmp_init_script" &&
	add_file "$tmp_init_script" "/etc/init.d/$p_name-init" 555

	echo "Preparing the firewall include... "
	eval "printf '%s\n' \"$(cat "$script_dir/$owrt_fw_include")\"" | prep_script > "$tmp_fw_include" &&
	{
		cat <<- EOF
			#!/bin/sh
			p_name=$p_name
			install_dir="$install_dir"
			conf_dir="$conf_dir"
			fw_include_path="$i_script-fw-include.sh"
			_lib="$_lib"
		EOF
		prep_script "$script_dir/$owrt_mk_fw_inc" -n
	} > "$tmp_mk_fw_inc" || preinstall_failed "$FAIL prepare the firewall include."
	add_file "$tmp_fw_include" "$i_script-fw-include.sh" 555 &&
	add_file "$tmp_mk_fw_inc" "$i_script-mk-fw-include.sh" 555
}

[ ! "$inst_root_gs" ] && {
	cut -d"$delim" -f1 "$reg_permissions" > "$reg_tmp"
	add_file "$reg_tmp" "$reg_file" 600
}

printf %s "Creating directories... "
for dir in "$inst_root_gs$lib_dir" "$inst_root_gs$conf_dir"; do
	mkdir -p "$dir" || preinstall_failed "$FAIL create directory '$dir'."
done
OK

copy_files

[ "$inst_root_gs" ] && {
	rm -rf "$tmp_dir"
	exit 0
}

## Create a symlink from ${p_name}-manage.sh to ${p_name}
printf %s "Creating symlink... "
rm -f "$i_script"
ln -s "$i_script-manage.sh" "$i_script" || install_failed "$FAIL create symlink from ${p_name}-manage.sh to $p_name."
printf '%s\n' "${i_script}${delim}555" >> "$reg_permissions"
OK

# set permissions
printf %s "Setting permissions... "
chmod 755 "$conf_dir" && chown -R root:root "$conf_dir" || install_failed "$FAIL set permissions for '$conf_dir'."
set_permissions
OK

# clean up unneeded files
[ "$prev_reg_file_cont" ] && {
	rm_files=
	subtract_a_from_b "$(cat "$reg_tmp")" "$(printf '%s\n' "$prev_reg_file_cont" | grep -v '[^[:alnum:]/.-]' | \
			grep -E "^${i_script}|${lib_dir}|${conf_dir}|/etc/init.d/${p_name}-init")" rm_files "$_nl" || {
		printf '%s\n' "Removing files from previous installation..."
		rm -f $(printf %s "$rm_files" | tr '\n' ' ')
	}
}

rm -rf "$tmp_dir"
echo "Install done."

REPLY=n
[ -z "$nointeract_arg" ] && {
	printf '\n%s\n' "Configure $p_name now? [y|n]"
	pick_opt "y|n"
}
[ "$REPLY" = n ] && { echolog "$please_configure"; exit 0; }

trap 'manage_interr' INT TERM HUP QUIT
call_script "$i_script-manage.sh" configure || {
	manage_rv=$?
	case $manage_rv in
		1) die "$p_name-manage.sh exited with error code 1." ;;
		*) manage_interr
	esac
}

trap - INT TERM HUP QUIT

:
