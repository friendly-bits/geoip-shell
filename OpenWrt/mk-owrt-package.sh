#!/bin/sh
# shellcheck disable=SC2046,SC2034

# mk-owrt-package.sh

# Copyright: antonk (antonk.d3v@gmail.com)
# github.com/friendly-bits

# Creates Openwrt-specific packages for geoip-shell and compiles the ipk's.

# *** BEFORE USING THIS SCRIPT ***
# NOTE: I've had all sorts of unresolvable problems when not doing things exactly in this order, so better to stick to it.
# 1) install dependencies for the OpenWrt build system:
# https://openwrt.org/docs/guide-developer/toolchain/install-buildsystem
# 2) cd into your home directory:
# 	run: cd ~
# 3) clone openwrt git repo:
# run: git clone https://git.openwrt.org/openwrt/openwrt.git
# 4) run: cd openwrt
# NOTE: this script expects the openwrt build directory in the above path (~/openwrt).
# It won't work if you have it in a different path or under a different name.

# 5) run: git checkout v23.05.3
#     (or later version if exists)
# 6) update feeds:
# run: ./scripts/feeds update -a; ./scripts/feeds install -a
# 7) run: make menuconfig
# 8) select Target system --> [X] x86
#     (probably this doesn't matter but it may? build faster if you select the same architecture as your CPU)
# 9) select Subtarget --> X86-64 (same comment as above)
#     don't change Target and Subtargets later to avoid problems
# 10) Exit and save

# 11) run: make -j8 tools/install; make -j8 toolchain/install; make -j8 target/linux/compile
#     (assuming your machine has 8 physical or logical cores)
# If this is the first time you are running these commands, this may take a long while.

# 12) now you are ready to run this script
# 13) cross your fingers
# 14) cd into geoip-shell/OpenWrt
# 15) run: sh mk_owrt_package.sh
#  - to build only for firewall3+iptables or firewall4+nftables, add '3' or '4' as an argument

# if you want to make an updated package later, make sure that the '$curr_ver' value changed in the -install script
# or change the '$pkg_ver' value in this script
# then run the script again (no need for the above preparation anymore)

pkg_ver=r1

die() {
	# if first arg is a number, assume it's the exit code
	unset die_args
	for die_arg in "$@"; do
		die_args="$die_args$die_arg$_nl"
	done

	[ "$die_args" ] && {
		IFS="$_nl" die
		for arg in $die_args; do
			printf '%s\n' "$arg" >&2
		done
	}
	exit 1
}

### Variables
p_name="geoip-shell"
p_name_c="${p_name%%-*}_${p_name#*-}"
script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
src_dir="${script_dir%/*}"
install_dir="/usr/bin"
lib_dir="/usr/lib/$p_name"
conf_dir="/etc/${p_name}"
init_dir="/etc/init.d"
_lib="$/usr/lib"

curr_ver="$(grep -o -m 1 'curr_ver=.*$' "$src_dir/${p_name}-geoinit.sh" | cut -d\" -f2)"
owrt_dist_dir="$HOME/openwrt"

_nl='
'
export _OWRTFW=all initsys=procd curr_sh_g="/bin/sh"
PATH_orig="$PATH"

### Checks
[ ! -d "$owrt_dist_dir" ] && die "*** Openwrt distribution dir '$owrt_dist_dir' doesn't exist. ***"
[ ! -f "$owrt_dist_dir/feeds.conf.default" ] && die "*** feeds.conf.default not found in '$owrt_dist_dir'. ***"


### Main

unset build_dirs ipk_paths

owrt_dist_src_dir="$owrt_dist_dir/my_packages/net/network/$p_name"

build_dir="$script_dir/owrt-build"
files_dir="$build_dir/files"

# Prepare geoip-shell for OpenWrt

printf '\n%s\n\n' "*** Preparing $p_name for OpenWrt with firewall$_OWRTFW... ***"

rm -rf "$build_dir"

mkdir -p "$files_dir$install_dir" &&
mkdir -p "$files_dir$lib_dir" &&
mkdir -p "$files_dir/etc/init.d" || die "*** Failed to create directories for $p_name build. ***"


export PATH="/usr/sbin:/usr/bin:/sbin:/bin" inst_root_gs="$build_dir/files"
printf '%s\n' "*** Running '$src_dir/$p_name-install.sh'... ***"
sh "$src_dir/$p_name-install.sh" || die "*** Failed to run the -install script or it reported an error. ***"
echo
export PATH="$HOME/openwrt/staging_dir/host/bin:$PATH_orig"

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

	printf '\n%s\n' "define Package/$p_name/install"

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

for _OWRTFW in 4 3; do
	case "$_OWRTFW" in
		3) _fw="-iptables" _fw_short="ipt" ;;
		4) _fw="-nftables" _fw_short="nft" ;;
		*) echo "*** Specify OpenWrt firewall version! ***"; exit 1
	esac


	printf '%s\n' "*** Adding install defines for $p_name$_fw... ***"
	{
		printf '\n%s\n%s\n' "define Package/$p_name$_fw/install" \
			"\$(call Package/$p_name/install,\$(1))"

		printf '\n\t%s\n' "\$(INSTALL_DIR) \$(1)$lib_dir"
		find -- * -print | grep -E "$_fw_short" |
		awk '$0~b {print "\t$(INSTALL_CONF) ./files/" $0 " $(1)" s l}' \
			l="${lib_dir#"/"}" s="/" b="${lib_dir#"/"}/"
		printf '\n%s\n\n' "endef"
	} >> "$build_dir/Makefile"
done

printf '%s\n%s\n\n' \
	"\$(eval \$(call BuildPackage,$p_name-nftables))" \
	"\$(eval \$(call BuildPackage,$p_name-iptables))" >> "$build_dir/Makefile"
echo

### Configure owrt feeds
printf '\n%s\n' "*** Preparing owrt feeds... ***"
cd "$owrt_dist_dir" || die "*** Failed to cd into '$owrt_dist_dir' ***"

mkdir -p "$owrt_dist_src_dir" || die "*** Failed to make dir '$owrt_dist_src_dir' ***"

printf '%s\n' "*** Copying $p_name build into '$owrt_dist_src_dir'... ***"
cp -r "$build_dir"/* "$owrt_dist_src_dir" || die "*** Copy failed ***"
echo

curr_feeds="$(grep -v "my_packages" "$owrt_dist_dir/feeds.conf.default")" ||
	die "*** Failed to cat '$owrt_dist_dir/feeds.conf.default' ***"
echo "*** Prepending entry 'src-link local $owrt_dist_dir/my_packages' to '$owrt_dist_dir/feeds.conf.default'... ***"
printf '%s\n%s\n' "src-link local $owrt_dist_dir/my_packages" "$curr_feeds" > "$owrt_dist_dir/feeds.conf.default" ||
	die "*** Failed to add 'my_packages' src dir to '$owrt_dist_dir/feeds.conf.default ***"

printf '\n%s\n' "*** Updating Openwrt feeds... ***"
./scripts/feeds update -a || die "*** Failed to update owrt feeds."

printf '\n%s\n' "*** Installing feeds for $p_name... ***"
./scripts/feeds install $p_name || die "*** Failed to add $p_name to the make config."

grep "$p_name-nftables=m" .config 1>/dev/null && grep "$p_name-iptables=m" .config 1>/dev/null || {
	printf '\n%s\n' "*** I will now run 'make menuconfig'. ***"
	echo "Go to Network --->, scroll down till you see '$p_name' and make sure both entries for $p_name are checked with <M>."
	echo "Then exit and save."
	echo "Press Enter when ready."
	read -r dummy
	make menuconfig
}

### make ipk's

printf '\n%s\n\n' "*** Making ipk's for $p_name... ***"
# echo "*** Running: make -j4 package/$p_name$_fw/clean ***"
# make -j4 "package/$p_name$_fw/clean"
echo "*** Running: make -j8 package/$p_name/compile ***"
make -j8 "package/$p_name/compile"

for _OWRTFW in 4 3; do
	_fw=
	case "$_OWRTFW" in
		3) _fw="-iptables" ;;
		4) _fw="-nftables"
	esac

	ipk_path="$(find . -name "${p_name}${_fw}_$curr_ver*.ipk" -exec echo {} \; | head -n1)"
	if [ ! "$ipk_path" ] || [ ! -f "$ipk_path" ]; then
		printf '%s\n' "*** Can not find file '${p_name}${_fw}_$curr_ver*.ipk' ***" >&2
	else
		new_ipk_path="$build_dir/$p_name${_fw}_$curr_ver-$pkg_ver.ipk"
		mv "$ipk_path" "$new_ipk_path" && ipk_paths="$ipk_paths$new_ipk_path$_nl" ||
			printf '%s\n' "*** Failed to move '$ipk_path' to '$new_ipk_path' ***" >&2
	fi
done


[ "$build_dir" ] && {
	printf '\n%s\n%s\n' "*** New build is available here:" "$build_dir"
	echo
	[ "${ipk_paths%"$_nl"}" ] && printf '%s\n%s\n' "*** New ipk's are available here:" "${ipk_paths%"$_nl"}"
}
