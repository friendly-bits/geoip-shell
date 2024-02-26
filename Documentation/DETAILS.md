## **Prelude**
- This document mainly intends to give some info on the purspose and basic use cases of each script and how they work in tandem.
- Most scripts display "usage" when called with the "-h" option. You can find out about some additional options specific to each script by running it with that option.
- If you understand some shell code and would like to learn more about some of the scripts, you are most welcome to read the code. It has a lot of comments and I hope that it's easily readable.

## **Overview**
The suite currently includes 15 scripts:
1. geoip-shell-install.sh
2. geoip-shell-uninstall.sh
3. geoip-shell-manage.sh
4. geoip-shell-run.sh
5. geoip-shell-fetch.sh
6. geoip-shell-apply.sh
7. geoip-shell-cronsetup.sh
8. geoip-shell-backup.sh
9. geoip-shell-common.sh
10. geoip-shell-nft.sh
11. validate-cron-schedule.sh
12. check-ip-in-registry.sh
13. detect-local-subnets-AIO.sh
14. posix-arrays-a-mini.sh
15. ip-regex.sh

The scripts intended as user interface are **geoip-shell-install.sh**, **geoip-shell-uninstall.sh**, **geoip-shell-manage.sh** and **check-ip-in-source.sh**. All the other scripts are intended as a back-end. If you just want to install and move on, you only need to run the -install script, specify mode with the -m option and specify country codes with the "-c" option.
After installation, the user interface is provided by running "geoip-shell", which is a symlink to the -manage script.

## **In detail**
**geoip-shell-install.sh**
- Creates system folder structure for scripts, config and data.
- Copies the scripts to `/usr/sbin`, config to `/etc/geoip-shell`, and creates a folder for data in `/var/lib/geoip-shell`.
- Calls the -manage script to set up geoip.
- If an error occurs during the installation, it is propagated back through the execution chain and eventually the -install script calls the -uninstall script to revert any changes made to the system.
- Required arguments are `-c <"country_codes">` and `-m <whitelist|blacklist>`

Additional options:
- `-u <source>`: specify source for fetching of ip lists. Currently supports 'ripe' and 'ipdeny', defaults to ripe.
- `-i <wan|all>`: specify whether firewall rules will be applied to specific WAN network interface(s) or to all network interfaces. If not specified, asks during installation.
- `-a`: autodetect LAN subnets or WAN interfaces (depending on whether geoip is applied to wan interfaces or to all interfaces). If not specified, asks during installation.
- `-f`: specify the ip protocol family (ipv4 or ipv6). Defaults to both.
- `-p [tcp|udp]:[allow|block]:[all|ports]`: specify ports geoip blocking will apply (or not apply) to, for tcp or udp. To specify ports for both protocols, use the `-p` option twice. For more details, read [NOTES.md](/Documentation/NOTES.md), sections 10-12.
- `-s <"schedule_expression"|disable>`: specify custom cron schedule expression for the autoupdate schedule. Default cron schedule is "15 4 * * *" - at 4:15 [am] every day. 'disable' instead of the schedule will disable autoupdates.
- `-n`: disable persistence (reboot cron job won't be created so after system reboot, there will be no more geoip blocking - until the autoupdate cron job kicks in).
- `-o`: disable automatic backups of the firewall geoip rules and geoip config.
- `-k`: skip adding the geoip 'enable' rule. This can be used if you want to check everything before commiting to geoip blocking. To enable blocking later, use the *manage script.
- `-e`: create ip sets with the 'performance' policy (defaults to 'memory' policy for low memory consumption)

**geoip-shell-uninstall.sh**
- Removes geoip firewall rules, geoip cron jobs, scripts' data and config, and deletes the scripts from /usr/sbin

Advanced options:
- `-l`: cleans up previous firewall geoip rules and resets the ip lists in the config
- `-c`: cleans up previous firewall geoip rules, removes geoip cron jobs and resets the ip lists in the config
- `-r`: prepares the system for re-installation of the suite: cleans up previous firewall geoip rules and removes the config

**geoip-shell-manage.sh**: serves as the main user interface to configure geoip after installation. You can also call it by simply typing `geoip-shell`. As most scripts in this suite, it requires root privileges.

`geoip-shell <on|off> [-c <"country_codes">]` : Enable or disable the geoip blocking chain (via a rule in the base geoip chain)

`geoip-shell <add|remove> [-c <"country_codes">]` :
* Adds or removes the specified country codes to/from the config file.
* Calls the -run script to fetch the ip lists for specified countries and apply them to the firewall (or to remove them).

`geoip-shell status`
* Displays information on the current state of geoip blocking
* For a list of all firewall rules in the geoip chain, run `geoip-shell status -v`.

`geoip-shell schedule -s <"schedule_expression">` : enables automatic ip lists update and configures the schedule for the periodic cron job which implements this feature.

`geoip-shell schedule -s disable` : disables ip lists autoupdate.

`geoip-shell restore` : re-fetches and re-applies geoip firewall rules and ip lists as per the config.

`geoip-shell apply -p [tcp|udp]:[allow|block]:[all|<ports>]`: specify ports geoip blocking will apply (or not apply) to, for tcp or udp. To specify ports for both protocols, use the `-p` option twice. For more details, read [NOTES.md](/Documentation/NOTES.md), sections 10-12.

`geoip-shell showconfig` : prints the contents of the config file.


**geoip-shell-run.sh**: Serves as a proxy to call the -fetch, -apply and -backup scripts with arguments required for each action. Executes the requested actions, depending on the config set by the -install and -manage scripts, and the command line options. If persistence or autoupdates are enabled, the cron jobs call this script with the necessary options.

`geoip-shell-run add -l <"list_id [list_id] ... [list_id]">` : Fetches ip lists, loads them into ip sets and applies firewall rules for specified list id's.
List id has the format of <country_code>_<family>. For example, ****US_ipv4** and **GB_ipv6** are valid list id's.

`geoip-shell-run remove -l <"list_ids">` : Removes iplists and firewall rules for specified list id's.

`geoip-shell-run update` : Updates the ip sets for list id's that had been previously configured. Intended for triggering from periodic cron jobs.

`geoip-shell-run restore` : Restore previously downloaded lists from backup (skip fetching). Used by the reboot cron job to implement persistence.

**geoip-shell-fetch.sh**
- Fetches ip lists for given list id's from RIPE or from ipdeny. The source is selected during installation. If you want to change the default which is RIPE, install with the `-u ipdeny` option.
- Parses, validates, compiles the downloaded lists, and saves each one to a separate file.
- Implements extensive sanity checks at each stage (fetching, parsing, validating and saving) and handles errors if they occur.

(for specific information on how to use the script, run it with the -h option)

**geoip-shell-apply.sh**:  directly interfaces with the firewall. Creates or removes ip sets and firewall rules for specified list id's.

`geoip-shell-apply add -l <"list_ids">` :
- Loads ip list files for specified list id's into ip sets and applies firewall rules required for geoip blocking.

List id has the format of <country_code>_<family>. For example, **US_ipv4** and **GB_ipv6** are valid list id's.

`geoip-shell-apply remove -l <"list_ids">` :
- removes ip sets and geoip firewall rules for specified list id's.

**geoip-shell-cronsetup.sh** manages all the cron-related logic and actions. Called by the -manage script. Cron jobs are created based on the settings stored in the config file.

(for specific information on how to use the script, run it with the -h option)

**geoip-shell-backup.sh**: Creates a backup of current firewall state and current geoip config, or restores them from backup. By default (if you didn't run the installation with the '-o' option), backup will be created after every change to ip sets in the firewall. Backups are automatically compressed and de-compressed. Only one backup copy is kept.

`geoip-shell-backup create-backup` : Creates a backup of the current firewall state and geoip blocking config.

`geoip-shell-backup restore` : Restores the firewall state and the config from backup. Used by the *run script to implement persistence. Can be manually used for recovery from fault conditions.

**geoip-shell-common.sh** : Library of common functions and variables for geoip-shell.

**geoip-shell-nft.sh** : Library of nftables-related functions.

**validate-cron-schedule.sh** is used by the -cronsetup script. It accepts a cron schedule expression and attempts to make sure that it conforms to the crontab format.

**check-ip-in-source.sh** can be used to verify that a certain ip address belongs to a subnet found in source records for a given country. It is intended for manual use and is not called from other scripts. It requires the grepcidr utility to be installed in your system.

`sh check-ip-in-source.sh -c <country_code> -i <"ip [ip] [ip] ... [ip]"> [-u <source>]`

- Supported sources are 'ripe' and 'ipdeny'.
- Any combination of ipv4 and ipv6 addresses is supported.
- If passing multiple ip addresses, use double quotes around them.

**detect-local-subnets-AIO.sh**: detects and outputs local area network (LAN) subnets which the machine is connected to.

`sh detect-local-subnets-AIO.sh [-f <inet|inet6>] [-s] [-d]`

Options:
- `-f <inet|inet6>` : only detect subnets for the specified family.
- `-s` : only output the subnets (doesn't output the ip addresses and other text)
- `-d` : debug

This script is called by the -apply script when the suite is installed in whitelist mode. The reason for its existence is that in whitelist mode, all incoming connections should be blocked, except what is explicitly allowed. Since this project doesn't aim to isolate your machine from your local network, when installed in whitelist mode it detects your local area networks and creates whitelist firewall rules for them, so they don't get blocked. If installed in blacklist mode, this script will not be called because in that mode, whitelisting local networks is not required. The "accept" firewall verdict is not final, so if you want to manually block segments of your local network, these rules won't interfere with that.

This script is being developed in a separate repository:

https://github.com/friendly-bits/subnet-tools

**posix-arrays-a-mini.sh**: implements support for associative arrays in POSIX shell. Used in the -fetch script. This version is optimized for very small arrays, and includes a minimal subset of functions from the main project found here:

https://github.com/friendly-bits/POSIX-arrays

**ip-regex.sh**: loads regular expressions used in other scripts for validation of ipv4 and ipv6 addresses and subnets.
