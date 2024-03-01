#!/bin/sh
# calls the -run script with the 'restore' argument
# used for owrt firewall include

# the -install.sh script replaces variables with values

lock_file=\"$lock_file\"
[ -f \"\$lock_file\" ] && {
	logger -t \"${p_name}-fw-include.sh\" -p \"user.warn\" \"Lock file \$lock_file exists, refusing to open another instance.\"
	return 0
}

sh \"$install_dir/${p_name}-run.sh\" restore -a 1>/dev/null &
:
