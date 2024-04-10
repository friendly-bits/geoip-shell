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
#     don't change Target and Subtarget later to avoid problems
# 10) Exit and save

# 11) run: make -j8 tools/install; make -j8 toolchain/install; make -j8 target/linux/compile
#     (assuming your machine has 8 physical or logical cores)
# If this is the first time you are running these commands, this may take a long while.

# 12) now you are ready to run this script
# 13) cross your fingers
# 14) cd into geoip-shell/OpenWrt
# 15) run: sh mk_owrt_package.sh

#  - to build only for firewall3+iptables or firewall4+nftables, add '3' or '4' as an argument

# if you want to make an updated package later, make sure that the '$curr_ver' value changed in the -geoinit script
# or change the '$pkg_ver' value in the prep-owrt-package.sh script
# then run the script again (no need for the above preparation anymore)

prep_docs() {
	printf '\n%s\n' "*** Preparing documentation... ***"
	cp -r "$src_dir/Documentation" "$files_dir/"

	# Prepare the main README.md
	sed 's/OpenWrt\/README.md/OpenWrt-README.md/g' "$src_dir/README.md" | sed 's/\[\!\[image\].*//g' | \
	sed -n -e /"## \*\*Installation\*\*"/\{:1 -e n\;/"That's\ it"/\{:2 -e n\;p\;b2 -e \}\;b1 -e \}\;p |
	sed 's/Post-installation, provides/Provides/;
		s/ Except on OpenWrt, persistence.*//' |
	sed -n '/^## \*\*P\.s\.\*\*/q;
		/- Installation is easy.*/n;
		/- Comes with an uninstall script.*/n;
		/.*once the installation completes.*/n;
		/.*require root privileges.*/n;
		/\*\*To uninstall:\*\*.*/n;
		/\*\*To uninstall:\*\*.*/n;
		/.*shell is incompatible.*/n;
		/.*Default source for ip lists is RIPE.*/n;
		/.*check-ip-in-source.sh.*/n;
		/.*if a pre-requisite is missing.*/n;
		/- \[Installation\](#installation)/n;
		/- \[P\.s\.\](#ps)/n;
		p' |
	grep -vA1 '^[[:blank:]]*$' | grep -v '^--$' > "$files_dir/README.md"

	# Prepare OpenWrt-README.md
	cat "$script_dir/README.md" | \
	sed 's/ipk packages are a new feature .* from the Releases. //;
		s/Installation is possible.*\.ipk\. //;
		s/ or via the Discussions tab on Github//' | \
	sed 's/go ahead and use the Discussions tab, or //' | \
	sed -n -e /"  _<details><summary>To download"/\{:1 -e n\;/"<\/details>"/\{:2 -e n\;p\;b2 -e \}\;b1 -e \}\;p | \
	sed -n -e /"## Building an OpenWrt package"/\{:1 -e n\;/"read the comments inside that script for instructions\."/\{:2 -e n\;p\;b2 -e \}\;b1 -e \}\;p |
	sed -n -e /" please consider giving this repository a star"/q\;p | \
	grep -vA1 '^[[:blank:]]*$' | grep -v '^--$' > \
	"$files_dir/OpenWrt-README.md"
}

# initial setup
script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)

case "$1" in
	'') ;;
	'-d') docs_only=1 ;;
	3|4|all) _OWRTFW="$1" ;;
	*) die "Invalid openwrt firewall version '$1'. Expected '3' or '4' or 'all'."
esac
: "${_OWRTFW:=all}"


### prepare the build
. "$script_dir/prep-owrt-package.sh" || exit 1

[ "$docs_only" ] && { prep_docs; exit; }

### Paths
owrt_dist_dir="$HOME/openwrt"
owrt_dist_src_dir="$owrt_dist_dir/geoip_shell_owrt_src/net/network/$p_name"
export PATH="$HOME/openwrt/staging_dir/host/bin:$PATH_orig"

unset ipk_paths

### Checks
[ ! -d "$owrt_dist_dir" ] && die "*** Openwrt distribution dir '$owrt_dist_dir' doesn't exist. ***"
[ ! -f "$owrt_dist_dir/feeds.conf.default" ] && die "*** feeds.conf.default not found in '$owrt_dist_dir'. ***"


### Configure owrt feeds
printf '\n%s\n' "*** Preparing owrt feeds... ***"
cd "$owrt_dist_dir" || die "*** Failed to cd into '$owrt_dist_dir' ***"

rm -rf "$owrt_dist_src_dir" 2>/dev/null
mkdir -p "$owrt_dist_src_dir" || die "*** Failed to make dir '$owrt_dist_src_dir' ***"

printf '%s\n' "*** Copying $p_name build into '$owrt_dist_src_dir'... ***"
cp -r "$build_dir"/* "$owrt_dist_src_dir" || die "*** Copy failed ***"
echo

curr_feeds="$(grep -v "geoip_shell_owrt_src" "$owrt_dist_dir/feeds.conf.default")" ||
	die "*** Failed to cat '$owrt_dist_dir/feeds.conf.default' ***"
echo "*** Prepending entry 'src-link local $owrt_dist_dir/geoip_shell_owrt_src' to '$owrt_dist_dir/feeds.conf.default'... ***"
printf '%s\n%s\n' "src-link local $owrt_dist_dir/geoip_shell_owrt_src" "$curr_feeds" > "$owrt_dist_dir/feeds.conf.default" ||
	die "*** Failed to add 'geoip_shell_owrt_src' src dir to '$owrt_dist_dir/feeds.conf.default ***"

printf '\n%s\n' "*** Updating Openwrt feeds... ***"
./scripts/feeds update -a || die "*** Failed to update owrt feeds."

printf '\n%s\n' "*** Installing feeds for $p_name... ***"
./scripts/feeds install $p_name || die "*** Failed to add $p_name to the make config."

entry_missing=
for _fw_ver in $_OWRTFW; do
	_ipt=
	[ "$_fw_ver" = 3 ] && _ipt="-iptables"
	grep "$p_name$_ipt=m" "$owrt_dist_dir/.config" 1>/dev/null || entry_missing=1
done

[ "$entry_missing" ] && {
	printf '\n%s\n' "*** I will now run 'make menuconfig'. ***"
	echo "Go to Network --->, scroll down till you see '$p_name' and make sure entries for $p_name are checked with <M>."
	echo "Then exit and save."
	echo "Press Enter when ready."
	read -r dummy
	make menuconfig
}

### make ipk's

printf '\n%s\n\n' "*** Making ipk's for $p_name... ***"
# echo "*** Running: make -j4 package/$p_name/clean ***"
# make -j4 "package/$p_name/clean"
echo "*** Running: make -j8 package/$p_name/compile ***"
make -j8 "package/$p_name/compile"

for _fw_ver in $_OWRTFW; do
	_ipt=
	[ "$_fw_ver" = 3 ] && _ipt="-iptables"

	ipk_path="$(find . -name "${p_name}${_ipt}_$curr_ver*.ipk" -exec echo {} \; | head -n1)"
	if [ ! "$ipk_path" ] || [ ! -f "$ipk_path" ]; then
		printf '%s\n' "*** Can not find file '${p_name}${_ipt}_$curr_ver*.ipk' ***" >&2
	else
		new_ipk_path="$build_dir/$p_name${_ipt}_$curr_ver-$pkg_ver.ipk"
		mv "$ipk_path" "$new_ipk_path" && ipk_paths="$ipk_paths$new_ipk_path$_nl" ||
			printf '%s\n' "*** Failed to move '$ipk_path' to '$new_ipk_path' ***" >&2
	fi
done

prep_docs

[ "$build_dir" ] && {
	printf '\n%s\n%s\n' "*** The new build is available here: ***" "$build_dir"
	echo
	[ "${ipk_paths%"$_nl"}" ] && printf '%s\n%s\n' "*** New ipk's are available here:" "${ipk_paths%"$_nl"}"
}
