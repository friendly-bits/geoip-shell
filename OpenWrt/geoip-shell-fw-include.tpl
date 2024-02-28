#!/bin/sh
# calls the -run script with the 'restore' argument
# used for owrt firewall include

# the -install.sh script replaces variables with values

sh \"$install_dir/${p_name}-run.sh\" restore 1>/dev/null &
:
