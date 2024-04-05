#!/bin/sh
# shellcheck disable=SC2046,SC2034,SC2016

# prepares geoip-shell for OpenWrt (without compilation)
#  - to build only for firewall3+iptables or firewall4+nftables, add '3' or '4' as an argument

pkg_ver=r1

die() {
	# if first arg is a number, assume it's the exit code
	unset die_args
	for die_arg in "$@"; do
		die_args="$die_args$die_arg$_nl"
	done

	[ "$die_args" ] && {
		IFS="$_nl"
		for arg in $die_args; do
			printf '%s\n' "$arg" >&2
		done
	}
	exit 1
}

[ ! "$_OWRTFW" ] &&
	case "$1" in
		'') ;;
		3|4|all) _OWRTFW="$1" ;;
		*) die "Invalid openwrt firewall version '$1'. Expected '3' or '4' or 'all'."
	esac
: "${_OWRTFW:=all}"

### Variables
p_name="geoip-shell"
script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
src_dir="${script_dir%/*}"
install_dir="/usr/bin"
lib_dir="/usr/lib/$p_name"
conf_dir="/etc/$p_name"
init_dir="/etc/init.d"

curr_ver="$(grep -o -m 1 'curr_ver=.*$' "$src_dir/${p_name}-geoinit.sh" | cut -d\" -f2)"

_nl='
'
export _OWRTFW initsys=procd curr_sh_g="/bin/sh"
PATH_orig="$PATH"

### Main

build_dir="$script_dir/owrt-build"
files_dir="$build_dir/files"

# Prepare geoip-shell for OpenWrt

printf '\n%s\n\n' "*** Preparing $p_name for OpenWrt... ***"

rm -rf "$build_dir"

mkdir -p "$files_dir$install_dir" &&
mkdir -p "$files_dir$lib_dir" &&
mkdir -p "$files_dir/etc/init.d" || die "*** Failed to create directories for $p_name build. ***"


export PATH="/usr/sbin:/usr/bin:/sbin:/bin" inst_root_gs="$build_dir/files"
printf '%s\n' "*** Running '$src_dir/$p_name-install.sh'... ***"
sh "$src_dir/$p_name-install.sh" || die "*** Failed to run the -install script or it reported an error. ***"
echo
export PATH="$PATH_orig"

cp "$script_dir/$p_name-owrt-uninstall.sh" "${files_dir}${lib_dir}" ||
	die "*** Failed to copy '$script_dir/$p_name-owrt-uninstall.sh' to '${files_dir}${lib_dir}'. ***"

echo "*** Sanitizing the build... ***"
rm -f "${files_dir}${install_dir}/${p_name}-uninstall.sh"
rm -f "${files_dir}${conf_dir}/${p_name}.conf"

# remove debug stuff
sed -Ei 's/(\[[[:blank:]]*"\$debugmode"[[:blank:]]*\][[:blank:]]*&&[[:blank:]]*)*debugprint.*"(;){0,1}//g;s/^[[:blank:]]*(setdebug|debugentermsg|debugexitmsg)$//g;s/ debugmode_arg=1//g' \
	$(find -- "$build_dir"/* -print | grep '.sh$')
sed -i -n -e /"#@"/\{:1 -e n\;/"#@"/\{:2 -e n\;p\;b2 -e \}\;b1 -e \}\;p "${files_dir}${lib_dir}/$p_name-lib-common.sh" || exit 1

printf '%s\n' "*** Creating '$build_dir/Makefile'... ***"
cd "$files_dir" || die "*** Failed to cd into '$files_dir' ***"
{
	awk '{gsub(/\$p_name/,p); gsub(/\$install_dir/,i); gsub(/\$conf_dir/,c); gsub(/\$curr_ver/,v); gsub(/\$pkg_ver/,r); gsub(/\$lib_dir/,L)}1' \
		p="$p_name" c="$conf_dir" v="$curr_ver" r="$pkg_ver" i="$install_dir" L="$lib_dir" "$script_dir/makefile.tpl"

	printf '\n%s\n' "define Package/$p_name/install/Default"

	find -- * -print | grep -vE '(ipt|nft)' |
	awk '$0==c||$0==i||$0==n||$0==l {print "\n\t$(INSTALL_DIR) $(1)/" $0} \
		$0~f {print "\t$(INSTALL_CONF) ./files/" $0 " $(1)" s c} \
		$0~a {print "\t$(INSTALL_BIN) ./files/" $0 " $(1)" s i} \
		$0~t {print "\t$(INSTALL_BIN) ./files/" $0 " $(1)" s n} \
		$0~b {print "\t$(INSTALL_CONF) ./files/" $0 " $(1)" s l}' \
			c="${conf_dir#"/"}" i="${install_dir#"/"}" n="${init_dir#"/"}" l="${lib_dir#"/"}" s="/" \
			f="${conf_dir#"/"}/" a="${install_dir#"/"}/" t="${init_dir#"/"}/" b="${lib_dir#"/"}/"
	printf '\n%s\n\n' "endef"
} > "$build_dir/Makefile"

[ "$_OWRTFW" = all ] && _OWRTFW="4 3"
BP_calls=
for _fw_ver in $_OWRTFW; do
	case "$_fw_ver" in
		3) _ipt="-iptables" _fw=ipt ;;
		4) _ipt='' _fw=nft
	esac
	BP_calls="${BP_calls}\$(eval \$(call BuildPackage,$p_name$_ipt))$_nl"

	printf '%s\n' "*** Adding install defines for $p_name$_ipt... ***"
	{
		printf '\n%s\n%s\n' "define Package/$p_name$_ipt/install" \
			"\$(call Package/$p_name/install/Default,\$(1))"

		printf '\t%s\n' "\$(INSTALL_DIR) \$(1)$lib_dir"
		find -- * -print | grep -E "$_fw" |
		awk '$0~b {print "\t$(INSTALL_CONF) ./files/" $0 " $(1)" s l}' \
			l="${lib_dir#"/"}" s="/" b="${lib_dir#"/"}/"
		printf '\n%s\n\n' "endef"
	} >> "$build_dir/Makefile"
done

printf '%s\n\n' "$BP_calls" >> "$build_dir/Makefile"

printf '\n%s\n%s\n' "*** The new build is available here: ***" "$build_dir"
echo

:
