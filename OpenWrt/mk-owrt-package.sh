#!/bin/sh

# Copyright: friendly bits
# github.com/friendly-bits

# Creates an openwrt package (ipk) for geoip-shell.

# *** BEFORE USING THIS SCRIPT ***
# 1) install dependencies for the OpenWrt build system:
# https://openwrt.org/docs/guide-developer/toolchain/install-buildsystem
# 2) cd into your home directory: 'cd ~'
# 3) clone openwrt git repo:
# 'git clone https://git.openwrt.org/openwrt/openwrt.git'
# 4) 'cd openwrt'
# NOTE: this script expects the openwrt build directory in the above path. It won't work if you have it in a different path.

# 5) 'git checkout v23.05.3' (or later version if exists)
# 6) update feeds:
# './scripts/feeds update -a'; ./scripts/feeds install -a'
# 7) 'make menuconfig'
# 8) select Target system --> [X] x86 (probably this doesn't matter but it may? build faster if you select the same architecture as your CPU)
# 9) select Subtarget --> X86-64 (same comment as above)
# 10) Exit and save

# 11) 'make -j4 tools/install'
# 12) 'make -j4 toolchain/install'
# if this is the first time you are installing tools and toolchain, this may take a long while

# if you previously tried to compile geoip-shell, run './scripts/feeds uninstall geoip-shell'

# now you are ready to run this script
# cross your fingers
# run as a regular user (no sudo) "mk_owrt_package [3|4]" - 3 for systems with firewall3, 4 for systems with firewall 4

# if you want to make an updated package later, make sure that the '$curr_ver' value changed in the -install script
# or change the '$pkg_ver' in this script
# then run the script again (no need for the above preparation anymore)

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
build_dir="$script_dir/owrt-build"

# *** Versions
curr_ver="$(grep -o -m 1 'curr_ver=.*$' "$src_dir/${p_name}-install.sh" | cut -d\" -f2)"
pkg_ver=25

# More variables

export _OWRTFW="$1" initsys=procd curr_sh_g="/bin/sh" inst_root_gs="$build_dir/files" PATH="/usr/sbin:/usr/bin:/sbin:/bin"
unset ipt variant
case "$_OWRTFW" in
	3) export _fw_backend=ipt; ipt="-iptables"; depends="+ipset +iptables +kmod-ipt-ipset"; variant="VARIANT:=iptables" ;;
	4) export _fw_backend=nft; depends="+firewall4" ;;
	*) echo "Specify OpenWrt firewall version!"; exit 1
esac
owrt_dist_dir="$HOME/openwrt"
owrt_dist_src_dir="$owrt_dist_dir/my_packages/net/network/$p_name$ipt"

install_dir="/usr/bin"
lib_dir="/usr/lib"
conf_dir="/etc/${p_name}"
init_dir="/etc/init.d"
files_dir="$build_dir/files"
_lib="$/usr/lib"
_nl='
'
export PATH="$HOME/openwrt/staging_dir/host/bin:$PATH"

### Checks
[ ! -d "$owrt_dist_dir" ] && die "openwrt distribution dir '$owrt_dist_dir' doesn't exist."
[ ! -f "$owrt_dist_dir/feeds.conf.default" ] && die "feeds.conf.default not found in '$owrt_dist_dir'."


### Prepare geoip-shell for OpenWrt

echo "Preparing geoip-shell for OpenWrt..."

rm -rf "$build_dir"

mkdir -p "$files_dir$install_dir" &&
mkdir -p "$files_dir$lib_dir" &&
mkdir -p "$files_dir/etc/init.d" || die "Failed to create directories for $p_name build."


echo "running '$src_dir/$p_name-install.sh'"
sh "$src_dir/$p_name-install.sh" || die "Failed to run the -install script or it reported an error."
echo
# mkdir -p "$inst_root_gs$datadir"


rm -f "$files_dir/usr/bin/$p_name-uninstall.sh"
cp "$script_dir/$p_name-owrt-uninstall.sh" "$files_dir/usr/bin" ||
	die "Failed to copy '$script_dir/$p_name-owrt-uninstall.sh' to '$files_dir/usr/bin'."

[ "$_OWRTFW" = 3 ] && rm -f "$files_dir/usr/lib/$p_name-"*nft.sh

cd "$files_dir" || die "Failed to cd into '$files_dir'"

echo "creating the '$build_dir/Makefile'"
{
	awk '{gsub(/\$p_name_c/,P); gsub(/\$p_name/,p); gsub(/\$install_dir/,i); sub(/\$curr_ver/,v); sub(/\$_OWRTFW/,o); \
		sub(/\$pkg_ver/,r); sub(/\$depends/,d); sub(/\$variant/,V); gsub(/\$_fw_backend/,f); \
		gsub(/\$ipt/,I); gsub(/\$_lib/,l)}1' \
		p="$p_name" P="$p_name_c" v="$curr_ver" r="$pkg_ver" o="$_OWRTFW" i="$install_dir" l="$lib_dir/$p_name-lib" \
			f="$_fw_backend" I="$ipt" d="$depends" V="$variant" "$script_dir/makefile.tpl"

	printf '\n%s\n' "define Package/$p_name$ipt/install"

	find -- * -print |
	awk '$0==c||$0==i||$0==n||$0==l {print "\n\t$(INSTALL_DIR) $(1)/" $0} \
		$0~f {print "\t$(INSTALL_CONF) ./files/" $0 " $(1)" s c} \
		$0~a {print "\t$(INSTALL_BIN) ./files/" $0 " $(1)" s i} \
		$0~t {print "\t$(INSTALL_BIN) ./files/" $0 " $(1)" s n} \
		$0~b {print "\t$(INSTALL_CONF) ./files/" $0 " $(1)" s l}' \
			c="${conf_dir#"/"}" i="${install_dir#"/"}" n="${init_dir#"/"}" l="${lib_dir#"/"}" s="/" \
			f="${conf_dir#"/"}/" a="${install_dir#"/"}/" t="${init_dir#"/"}/" b="${lib_dir#"/"}/" s="/"

	printf '\n%s\n\n%s\n\n' "endef" "\$(eval \$(call BuildPackage,$p_name$ipt))"
} > "$build_dir/Makefile"
echo

### Configure owrt feeds
printf '\n%s\n' "Preparing owrt feeds..."
cd "$owrt_dist_dir" || die "failed to cd into '$owrt_dist_dir'"

mkdir -p "$owrt_dist_src_dir" || die "failed to make dir '$owrt_dist_src_dir'"

printf '%s\n' "copying $p_name$ipt build into '$owrt_dist_src_dir'..."
cp -r "$build_dir"/* "$owrt_dist_src_dir" || die "copy failed"
echo

### delete previous ipks if any
printf '\n%s\n' "Looking for existing $p_name$ipt ipk's..."
old_ipks="$(find . -name "${p_name}${ipt}_$curr_ver*.ipk" -exec echo {} \;)"
[ "$old_ipks" ] && {
	echo "Removing existing ipks..."
	rm -f "$(printf  %s "$old_ipks" | tr '\n' ' ')"
	:
} || echo "old $p_name$ipt ipk's not found"

curr_feeds="$(grep -v "my_packages" "$owrt_dist_dir/feeds.conf.default")" || die "failed to cat '$owrt_dist_dir/feeds.conf.default'"
echo "Prepending entry 'src-link local $owrt_dist_dir/my_packages' to '$owrt_dist_dir/feeds.conf.default'..."
printf '%s\n%s\n' "src-link local $owrt_dist_dir/my_packages" "$curr_feeds" > "$owrt_dist_dir/feeds.conf.default" ||
	die "failed to add 'my_packages' src dir to '$owrt_dist_dir/feeds.conf.default"

printf '\n%s\n' "Updating Openwrt feeds..."
./scripts/feeds update -a || die "Failed to update owrt feeds."
echo "Installing feed '$p_name$ipt'..."
./scripts/feeds install $p_name$ipt || die "Failed to add $p_name$ipt to the make config."

grep "$p_name$ipt=m" .config 1>/dev/null || {
	printf '\n%s\n' "I will now run 'make menuconfig'. Go to Image Configuration ---> Separate feed repositories ---> Check [*] Enable local feeds"
	echo "Then Go to Network --->, scroll down till you see '$p_name$ipt' and make sure '$p_name$ipt' is checked with <M>."
	echo "Then exit and save."

	echo "Press Enter when ready."
	read -r dummy
	make menuconfig
}



### make new ipk
printf '\n%s\n' "Making new ipk..."
echo "running: make -j4 package/$p_name$ipt/clean"
make -j4 "package/$p_name$ipt/clean"
echo "running: make -j1 V=sc package/$p_name$ipt/compile"
make -j1 V=sc "package/$p_name$ipt/compile"

ipk_path="$(find . -name "${p_name}${ipt}_$curr_ver*.ipk" -exec echo {} \; | head -n1)"
[ ! "$ipk_path" ] || [ ! -f "$ipk_path" ] && die "Can not find file '$ipk_path'"
mv "$ipk_path" "$build_dir/"

[ -f "$build_dir/${ipk_path##*/}" ] && printf '%s\n' "new ipk is available at '$build_dir/${ipk_path##*/}"

