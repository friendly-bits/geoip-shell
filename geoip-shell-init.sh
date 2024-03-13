#!/bin/sh
# the install script makes a new version of this file with system-specific variables in the config dir

lib_dir="$script_dir/lib"
_lib="$lib_dir/$p_name-lib"
. "${_lib}-check-compat.sh" || exit 1 # checks compatibility
. "${_lib}-common.sh" || exit 1
