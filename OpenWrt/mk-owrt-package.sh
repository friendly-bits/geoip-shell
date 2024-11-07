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

# 5) run: git checkout master
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

# in some cases after updating the master, you will need to rebuild tools and toolchain

# command-line options:
# -r : build a specific version fetched from the releases repo (otherwise builds from local source). requies to specify version with '-v'
# -v : specify version to fetch and build from the releases repo. only use with '-r'
# -u : upload: only relevant if you are authorized to upload to the geoip-shell releases repo (most likely you are not)
# -t : troubleshoot: if make fails, use this option to run make with '-j1 V=s'
# to build only for firewall3+iptables or firewall4+nftables, add '3' or '4' as an argument

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

# initial setup
p_name=geoip-shell
pkg_ver=r1

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)

unset build_from_remote troubleshoot upload ipk_paths
for arg in "$@"; do
	case "$arg" in
		'') ;;
		-r) build_from_remote=1 ;;
		-u) upload=1 ;;
		-d) export debugmode=1 ;;
		-t) troubleshoot=1 ;;
		3|4|all) _OWRTFW="$arg" ;;
		-v) curr_ver_arg=check ;;
		*) [ "$curr_ver_arg" = check ] && curr_ver_arg="$arg" ||
			{ printf '%s\n' "Unexpected argument '$arg'."; exit 1; }
	esac
done
[ "$curr_ver_arg" = check ] && die "Specify version with '-v'."
curr_ver="$curr_ver_arg"


# validate options
[ "$build_from_remote" ] && [ "$upload" ] && die "*** Incompatible options: -r and -u. **"
[ "$curr_ver_arg" ] && { [ "$upload" ] || [ ! "$build_from_remote" ]; } && die "*** Options don't make sense. ***"
[ "$build_from_remote" ] && [ ! "$curr_ver" ] && die "*** Specify version for build from remote. ***"

### Vars
: "${_OWRTFW:=all}"
_nl='
'

### Paths
owrt_dist_dir="$HOME/openwrt"
owrt_dist_src_dir="$owrt_dist_dir/geoip_shell_owrt_src/net/network/$p_name"
gsh_dir="$HOME/geoip-shell"
build_dir="$gsh_dir/owrt-build"
files_dir="$build_dir/files"
owrt_releases_dir="$gsh_dir/geoip-shell-openwrt"

releases_url="https://github.com/friendly-bits/geoip-shell-openwrt"
releases_url_api="https://api.github.com/repos/friendly-bits/geoip-shell-openwrt"

rm -rf "$build_dir" 2>/dev/null

### prepare the build
[ ! "$build_from_remote" ] && { . "$script_dir/prep-owrt-package.sh" || exit 1; }

export PATH="$HOME/openwrt/staging_dir/host/bin:$PATH"

[ "$_OWRTFW" = all ] && _OWRTFW="4 3"

rm -rf "$owrt_dist_src_dir" 2>/dev/null
mkdir -p "$owrt_dist_src_dir"
mkdir -p "$files_dir"

if [ "$build_from_remote" ]; then
	printf '\n%s\n' "*** Fetching the Makefile... ***"
	curl -L "$(curl -s "$releases_url_api/releases" | \
		grep -m1 -o "$releases_url/releases/download/v$curr_ver.*/Makefile")" > "$build_dir/Makefile"; rv=$?
	[ $rv != 0 ] || [ ! -s "$build_dir/Makefile" ] && die "*** Failed to fetch the Makefile. ***"
	pkg_ver="$(grep -o "PKG_RELEASE:=.*" < "$build_dir/Makefile" | cut -d'=' -f2)"
	[ ! "$pkg_ver" ] && die "*** Failed to determine package version from the downloaded Makefile. ***"
	pkg_ver="r$pkg_ver"
	curr_ver="${curr_ver%-r*}"

	printf '\n%s\n' "*** Fetching the release... ***"
	curl -L "$(curl -s $releases_url_api/releases | \
		grep -m1 -o "$releases_url_api/tarball/[^\"]*")" > /tmp/geoip-shell.tar.gz &&
			tar --strip=1 -xvf /tmp/geoip-shell.tar.gz -C "$files_dir/" >/dev/null; rv=$?
	rm -rf /tmp/geoip-shell.tar.gz 2>/dev/null
	[ $rv != 0 ] && die "Failed to fetch the release from Github."

elif [ ! "$upload" ]; then
	printf '\n%s\n' "*** Building package from local source. ***"
	new_makefile="$(grep -vE 'PKG_(SOURCE_PROTO|SOURCE_VERSION|SOURCE_URL|MIRROR_HASH)' "$build_dir/Makefile")"
	printf '%s\n' "$new_makefile" > "$build_dir/Makefile"
fi


### Checks
[ ! -d "$owrt_dist_dir" ] && die "*** Openwrt distribution dir '$owrt_dist_dir' doesn't exist. ***"
[ ! -f "$owrt_dist_dir/feeds.conf.default" ] && die "*** feeds.conf.default not found in '$owrt_dist_dir'. ***"


### Configure owrt feeds
printf '\n%s\n' "*** Preparing owrt feeds... ***"

new_feed="src-link local $owrt_dist_dir/geoip_shell_owrt_src"

cd "$owrt_dist_dir" || die "*** Failed to cd into '$owrt_dist_dir' ***"

[ ! "$build_from_remote" ] && {
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

printf '\n%s\n' "*** Installing feeds for $p_name... ***"
./scripts/feeds install $p_name || die "*** Failed to add $p_name to the make config."

# printf '\n%s\n' "*** Updating the $p_name feed... ***"
# ./scripts/feeds update "$p_name" || die "*** Failed to update owrt feeds."

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
	printf '%s\n%s\n' m m | make oldconfig "/tmp/${p_name}-temp-config" 1>/dev/null || make_failed=1
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


### upload to the Github releases repo
[ "$upload" ] && {
	printf '\n%s\n' "*** Building package with upload to Github. ***"

	# [ -s "$token_path" ] || die "*** Token file not found. ***"
	command -v gh 1>/dev/null || die "*** 'gh' utility not found. ***"
	# printf '\n%s\n' "*** Authenticating to Github... ***"
	# gh auth login --with-token < "$token_path" || die "*** Failed to authenticate with token. ***"


	# copy files
	printf '\n%s\n' "*** Copying files to '$owrt_releases_dir/'... ***"
	mkdir -p "$owrt_releases_dir"
	rm -rf "${owrt_releases_dir:?}/"*
	cp -r "$files_dir"/* "$owrt_releases_dir/" || die "*** Failed to copy '$files_dir/*' to '$owrt_releases_dir/'. ***"
	cd "$owrt_releases_dir" || die "*** Failed to cd into '$owrt_releases_dir'. ***"
	git push 1>/dev/null 2>/dev/null || die "*** No permissions to push to the github repo. ***"

	# add all files in release directory
	printf '\n%s\n' "*** Pushing to Github... ***"
	git add $(find -- * -type f -print)
	git commit -a -m "v$curr_ver-$pkg_ver"

	GH_tag="v$curr_ver-$pkg_ver"
	# remove existing release and tag with the same name
	git tag -l | grep "$GH_tag" >/dev/null && {
		gh release delete "$GH_tag" -y
		git tag -d "$GH_tag"
		git push --delete origin "$GH_tag"
	}

	# add new tag
	git tag "$GH_tag" &&
	git push &&
	git push origin --tags || die "*** Failed to to push to Github. ***"
	
	# Update the Makefile with PKG_SOURCE_VERSION etc
	last_commit="$(git rev-parse HEAD)"
	sed -i "s/\$pkg_source_version/$last_commit/g;
		s/\.\/files/\$(PKG_BUILD_DIR)/g" \
			"$owrt_dist_src_dir/Makefile"

	printf '\n%s\n\n' "*** Running: make package/$p_name/download V=s ***"
	cd "$owrt_dist_dir" || exit 1
	make package/$p_name/download V=s

	# printf '\n%s\n\n' "*** Running: package/$p_name/check FIXUP=1 ***"
	# make package/$p_name/check FIXUP=1

	# Update the Makefile with PKG_MIRROR_HASH
	pkg_mirror_hash="$(sha256sum -b "$owrt_dist_dir/dl/$p_name-$curr_ver.tar."*)" &&
	pkg_mirror_hash="$(printf '%s\n' "$pkg_mirror_hash" | cut -d' ' -f1 | head -n1)"; rv=$?
	[ $rv != 0 ] || [ ! "$pkg_mirror_hash" ] && die "*** Failed to calculate PKG_MIRROR_HASH. ***"
	printf '\n%s\n\n' "*** Calculated PKG_MIRROR_HASH: $pkg_mirror_hash ***"
	sed -i "s/PKG_MIRROR_HASH:=skip/PKG_MIRROR_HASH:=$pkg_mirror_hash/" "$owrt_dist_src_dir/Makefile"

	# create new release
	printf '\n%s\n' "*** Creating Github release... ***"
	cd "$owrt_releases_dir" || die "*** Failed to cd into '$owrt_releases_dir'. ***"
	gh release create "$GH_tag" --verify-tag --latest --target=main --notes "" ||
		die "*** Failed to create Github release via the 'gh' utility. ***"

	# upload the Makefile
	printf '\n%s\n' "*** Attaching the Makefile to the Github release... ***"
	gh release upload --clobber "$GH_tag" "$owrt_dist_src_dir/Makefile" ||
		die "*** Failed to upload the Makefile to Github via the 'gh' utility. ***"
}


make_opts='-j9'
[ "$troubleshoot" ] && make_opts='-j1 V=s'

printf '\n%s\n\n' "*** Running: make $make_opts package/$p_name/compile ***"
cd "$owrt_dist_dir" || exit 1
make $make_opts "package/$p_name/compile" || die "*** Make failed. ***"

for _fw_ver in $_OWRTFW; do
	_ipt=
	[ "$_fw_ver" = 3 ] && _ipt="-iptables"

	ipk_path="$(find . -name "${p_name}${_ipt}_$curr_ver*.ipk" -exec echo {} \; | head -n1)"
	if [ ! "$ipk_path" ] || [ ! -f "$ipk_path" ]; then
		die "*** Can not find file '${p_name}${_ipt}_$curr_ver*.ipk' ***" >&2
	else
		new_ipk_path="$build_dir/$p_name${_ipt}_$curr_ver-$pkg_ver.ipk"
		mv "$ipk_path" "$new_ipk_path" && ipk_paths="$ipk_paths$new_ipk_path$_nl" ||
			die "*** Failed to move '$ipk_path' to '$new_ipk_path' ***"
	fi
done

[ "$build_dir" ] && {
	printf '\n%s\n\n' "*** Copying the Makefile from '$owrt_dist_src_dir' to '$build_dir' ***"
	cp "$owrt_dist_src_dir/Makefile" "$build_dir/" || die "*** Copy failed ***"
}


[ "$build_dir" ] && {
	printf '\n%s\n%s\n' "*** The new build is available here: ***" "$build_dir"
	echo
	[ "${ipk_paths%"$_nl"}" ] && printf '%s\n%s\n' "*** New ipk's are available here:" "${ipk_paths%"$_nl"}"
}
