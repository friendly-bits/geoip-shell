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

# 11) run: make -j9 tools/install; make -j9 toolchain/install; make -j9 target/linux/compile
#     (assuming your machine has 8 physical or logical cores)
# If this is the first time you are running these commands, this may take a long while.

# 12) now you are ready to run this script
# 13) cross your fingers
# 14) cd into geoip-shell/OpenWrt
# 15) run: sh mk_owrt_package.sh


# if you want to make an updated package later, make sure that the '$curr_ver' value changed in the -geoinit script
# or change the '$pkg_ver' value in the prep-owrt-package.sh script
# then run the script again (no need for the above preparation anymore)

# command-line options:
# -l : build package from local source (otherwise builds from the releases repo)
# -n : noupload: only relevant if you are authorized to upload to the geoip-shell releases repo (most likely you are not)
# to build only for firewall3+iptables or firewall4+nftables, add '3' or '4' as an argument

# initial setup
pkg_ver=r1

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)

unset localbuild noupload
for arg in "$@"; do
	case "$arg" in
		'') ;;
		-l) localbuild=1 ;;
		-n) noupload=1 ;;
		3|4|all) _OWRTFW="$arg" ;;
		*) die "Unexpected argument '$arg'."
	esac
done
: "${_OWRTFW:=all}"

### prepare the build
. "$script_dir/prep-owrt-package.sh" || exit 1

### Paths
owrt_dist_dir="$HOME/openwrt"
owrt_dist_src_dir="$owrt_dist_dir/geoip_shell_owrt_src/net/network/$p_name"
export PATH="$HOME/openwrt/staging_dir/host/bin:$PATH_orig"

[ ! "$localbuild" ] && {
	[ ! "$gsh_dir" ] && die "Error: the \$gsh_dir var is empty."
	# clone the releases github repo
	owrt_releases_dir="$gsh_dir/geoip-shell-openwrt"

	cd "$gsh_dir" || exit 1
	[ ! -d "$owrt_releases_dir" ] && {
		printf '\n%s\n' "*** Cloning the github repo... ***"
		git clone "https://github.com/friendly-bits/geoip-shell-openwrt" &&
		cd "$owrt_releases_dir" || localbuild=1
	} || {
		printf '\n%s\n' "*** Updating from github repo... ***"
		cd "$owrt_releases_dir" &&
		git pull || localbuild=1
	}
}

[ ! "$localbuild" ] && {
	### check GH repo write permissions
	if [ ! "$noupload" ] && git push 1>/dev/null 2>/dev/null; then
		printf '\n%s\n' "*** Building package with upload to Github. ***"
		rm -rf "${owrt_releases_dir:?}/"*
		cp -r "$files_dir"/* "$owrt_releases_dir/" &&
		cd "$owrt_releases_dir" || exit 1
		git add $(find -- * -type f -print)
		git commit -a -m "v$curr_ver"
		GH_tag="v$curr_ver-$pkg_ver"
		{ git tag -l | grep "$GH_tag" >/dev/null && { git tag -d "$GH_tag"; git push --delete origin "$GH_tag"; }; }
		git tag v"$curr_ver-$pkg_ver"
		git push
		git push origin --tags
		:
	elif [ ! "$noupload" ]; then
		printf '\n%s\n' "*** NOTE: No write permissions for the Github releases repo, building package without upload to Github. ***"
		noupload=1
	fi

	last_commit="$(git rev-parse HEAD)"
	sed -i "s/\$last_commit/$last_commit/g;s/\.\/files/\$(PKG_BUILD_DIR)/g" "$build_dir/Makefile"
	:
} || {
	printf '\n%s\n' "*** Building package from local source. ***"
	new_makefile="$(grep -vE 'PKG_(SOURCE_PROTO|SOURCE_VERSION|SOURCE_URL|MIRROR_HASH)' "$build_dir/Makefile")"
	printf '%s\n' "$new_makefile" > "$build_dir/Makefile"
}


unset ipk_paths

### Checks
[ ! -d "$owrt_dist_dir" ] && die "*** Openwrt distribution dir '$owrt_dist_dir' doesn't exist. ***"
[ ! -f "$owrt_dist_dir/feeds.conf.default" ] && die "*** feeds.conf.default not found in '$owrt_dist_dir'. ***"


### Configure owrt feeds
printf '\n%s\n' "*** Preparing owrt feeds... ***"

new_feed="src-link local $owrt_dist_dir/geoip_shell_owrt_src"

cd "$owrt_dist_dir" || die "*** Failed to cd into '$owrt_dist_dir' ***"

rm -rf "$owrt_dist_src_dir" 2>/dev/null
mkdir -p "$owrt_dist_src_dir" || die "*** Failed to make dir '$owrt_dist_src_dir' ***"

[ "$localbuild" ] && {
	printf '\n%s\n' "*** Copying $p_name build into '$owrt_dist_src_dir'... ***"
	cp -r "$files_dir" "$owrt_dist_src_dir/" || die "*** Copy failed ***"
}

printf '\n%s\n' "*** Copying the Makefile into '$owrt_dist_src_dir'... ***"
cp "$build_dir/Makefile" "$owrt_dist_src_dir/" || die "*** Copy failed ***"
echo

curr_feeds="$(grep -v "$new_feed" "$owrt_dist_dir/feeds.conf.default")" ||
	die "*** Failed to grep '$owrt_dist_dir/feeds.conf.default' ***"
echo "*** Prepending entry '$new_feed' to '$owrt_dist_dir/feeds.conf.default'... ***"
printf '%s\n%s\n' "$new_feed" "$curr_feeds" > "$owrt_dist_dir/feeds.conf.default" || die "*** Failed ***"

# printf '\n%s\n' "*** Updating the $p_name feed... ***"
# ./scripts/feeds update "$p_name" || die "*** Failed to update owrt feeds."

printf '\n%s\n' "*** Installing feeds for $p_name... ***"
./scripts/feeds install $p_name || die "*** Failed to add $p_name to the make config."

### menuconfig
entry_missing=
rm -f "/tmp/${p_name}-temp-config" 2>/dev/null
for _fw_ver in $_OWRTFW; do
	_ipt=
	[ "$_fw_ver" = 3 ] && _ipt="-iptables"
	grep "$p_name$_ipt=m" "$owrt_dist_dir/.config" 1>/dev/null || {
		entry_missing=1
		printf '%s\n' "CONFIG_PACKAGE_$p_name$_ipt=m" >> "/tmp/${p_name}-temp-config"
	}
done

[ "$entry_missing" ] && {
	printf '\n%s\n' "*** Adding entries to config... ***"
	printf '%s\n%s\n' m m | make oldconfig "/tmp/${p_name}-temp-config" || make_failed=1
	rm -f "/tmp/${p_name}-temp-config"
	[ "$make_failed" ] && exit 1
	for _fw_ver in $_OWRTFW; do
		_ipt=
		[ "$_fw_ver" = 3 ] && _ipt="-iptables"
		grep "$p_name$_ipt=m" "$owrt_dist_dir/.config" 1>/dev/null || {
			echo "Failed."
			exit 1
		}
	done
	# printf '\n%s\n' "*** I will now run 'make menuconfig'. ***"
	# echo "Go to Network --->, scroll down till you see '$p_name' and make sure entries for $p_name are checked with <M>."
	# echo "Then exit and save."
	# echo "Press Enter when ready."
	# read -r dummy
	# make menuconfig
}


### make ipk's

printf '\n%s\n\n' "*** Making ipk's for $p_name... ***"
# echo "*** Running: make -j4 package/$p_name/clean ***"
# make -j4 "package/$p_name/clean"

rm -f "$owrt_dist_dir/dl/$p_name"*

[ ! "$localbuild" ] && {
	printf '\n%s\n\n' "*** Running: make package/$p_name/download V=s ***"
	make package/$p_name/download V=s

	# printf '\n%s\n\n' "*** Running: package/$p_name/check FIXUP=1 ***"
	# make package/$p_name/check FIXUP=1

	pkg_mirror_hash="$(sha256sum -b "$owrt_dist_dir/dl/$p_name-$curr_ver.tar."* | cut -d' ' -f1 | head -n1)"
	printf '\n%s\n\n' "*** Calculated PKG_MIRROR_HASH: $pkg_mirror_hash ***"
	sed -i "s/PKG_MIRROR_HASH:=skip/PKG_MIRROR_HASH:=$pkg_mirror_hash/" "$owrt_dist_src_dir/Makefile"
}

printf '\n%s\n\n' "*** Running: make -j8 package/$p_name/compile ***"
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

[ "$build_dir" ] && {
	printf '\n%s\n\n' "*** Copying the Makefile from '$owrt_dist_src_dir' to '$build_dir' ***"
	cp "$owrt_dist_src_dir/Makefile" "$build_dir/" || die "*** Copy failed ***"
	printf '\n%s\n%s\n' "*** The new build is available here: ***" "$build_dir"
	echo
	[ "${ipk_paths%"$_nl"}" ] && printf '%s\n%s\n' "*** New ipk's are available here:" "${ipk_paths%"$_nl"}"
}
