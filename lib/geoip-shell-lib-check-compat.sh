#!/bin/sh
# shellcheck disable=SC2006,SC2154,SC2010

# geoip-shell-lib-check-compat.sh

# checks for supported shell and presence of some other required utilities

# Copyright: antonk (antonk.d3v@gmail.com)
# github.com/friendly-bits

# check for common deps
check_common_deps() {
	for dep in grep tr cut sort wc awk sed logger pgrep; do
		if ! command -v "$dep" 1>/dev/null; then echo "Error: missing dependency: '$dep'"; exit 1; fi
	done
}

check_shell() {
	if [ -n "$curr_sh_g" ]; then return 0; fi
	fast_sh="dash|ash|yash|ksh93|busybox sh|busybox"
	slow_sh="mksh|lksh|bash"
	compat_sh="${fast_sh}|${slow_sh}"
	incompat_sh="zsh|csh|posh"

	# not assuming a compatible shell at this point
	_g_test=`echo 0112 | grep -oE '1{2}'` # backticks on purpose
	if [ "$_g_test" != 11 ]; then echo "Error: grep doesn't support the required options." >&2; exit 1; fi

	# check for proc
	if [ ! -d "/proc" ]; then echo "Error: /proc not found."; exit 1; fi

	# check for supported shell
	if command -v readlink 1>/dev/null; then
		curr_sh_g=`readlink /proc/$$/exe`
	fi
	if [ -z "$curr_sh_g" ]; then
		curr_sh_g=`ls -l /proc/$$/exe | grep -oE '/[^[:space:]]+$'`
	fi

	ok_sh=`printf %s "$curr_sh_g" | grep -E "/($compat_sh)"`
	if [ -z "$curr_sh_g" ]; then
		echo "Warning: failed to identify current shell. $p_name may not work correctly. Please notify the developer." >&2
	elif [ -z "$ok_sh" ]; then
		bad_sh=`echo "$curr_sh_g" | grep -E "$incompat_sh"`
		if [ -n "$bad_sh" ]; then
			echo "Error: incompatible shell $curr_sh_g." >&2
			while [ "$n" -le 6 ]; do
				___sh="${compat_sh%%"|"*}"
				compat_sh="${compat_sh#*"|"}"
				if command -v "$___sh" 1>/dev/null; then
					case "$___sh" in *busybox*) ___sh="busybox sh"; esac
					echo "This system has a compatible shell '$___sh', you can use it with $p_name: '$___sh ${p_name}-install.sh'."
					break
				fi
				if [ -z "$compat_sh" ]; then break; fi
			done
			exit 1
		else
			echo "Warning: whether $p_name works with your shell $curr_sh_g is currently unknown. Please test and notify the developer." >&2
		fi
	fi
	case "$curr_sh_g" in *busybox*) curr_sh_g="$curr_sh_g sh"; esac
	export curr_sh_g
}

check_fw_backend() {
	case "$1" in
		nft) check_deps nft ;;
		ipt) check_deps iptables ip6tables iptables-save ip6tables-save iptables-restore ip6tables-restore ipset ;;
		*) echolog -err "Unsupported firewall backend '$1'."; return 1
	esac
}

:
