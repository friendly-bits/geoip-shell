## **Prelude**
- This document mainly intends to give some info on the purspose and basic use cases of each script and how they work in tandem.
- Most scripts display "usage" when called with the "-h" option. You can find out about some additional options specific to each script by running it with that option.
- If you understand some shell code and would like to learn more about some of the scripts, you are most welcome to read the code. It has a lot of comments and I hope that it's easily readable.

## **Overview**
The suite currently includes 14 scripts:
1. geoip-shell-install.sh
2. geoip-shell-uninstall.sh
3. geoip-shell-manage.sh
4. geoip-shell-run.sh
5. geoip-shell-fetch.sh
6. geoip-shell-apply.sh
7. geoip-shell-cronsetup.sh
8. geoip-shell-backup.sh
9. geoip-shell-common.sh
10. validate-cron-schedule.sh
11. check-ip-in-registry.sh
12. detect-local-subnets.sh
13. posix-arrays-a-mini.sh
14. ip-regex.sh

The scripts intended as user interface are **geoip-shell-install.sh**, **geoip-shell-uninstall.sh**, **geoip-shell-manage.sh** and **check-ip-in-source.sh**. All the other scripts are intended as a back-end, although they can be run by the user as well (I don't recommend that). If you just want to install and move on, you only need to run the -install script, specify mode with the -m option and specify country codes with the "-c" option. Provided you are not missing any pre-requisites, it should be as easy as that.
After installation, the user interface is provided by simply running "geoip-shell", which is a symlink to the -manage script.

The **geoip-shell-backup.sh** script can be used individually. By default, it is launched by the -run script to create a backup of the firewall state and the geoip ipsets after every change to ip sets in the firewall. If you encounter issues, you can use the -backup script with the 'restore' command to restore the firewall to its previous state. It also restores the previous config.

## **In detail**
**geoip-shell-install.sh**
- Checks pre-requisites.
- Creates system folder structure for scripts, config and data.
- Scripts are then copied to `/usr/local/bin`. Config goes in `/etc/geoip-shell`. Data goes in `/var/lib/geoip-shell`.
- Creates backup of pre-install policy for the PREROUTING chain (the backup is used by the -uninstall script to restore the policy).
- Calls the -manage script to set up geoip. The -manage script, in turn, calls the -run script, which calls the -fetch and -apply scripts to perform the requested actions.
- If an error occurs during the installation, it is propagated back through the execution chain and eventually the -install script calls the -uninstall script to revert any changes made to the system.
- Required arguments are `-c <"country_codes">` and `-m <whitelist|blacklist>`
- Accepts optional custom cron schedule expression for autoupdate schedule with the '-s' option. Default cron schedule is "15 4 * * *" - at 4:15 [am] every day. 'disable' instead of the schedule will disable autoupdates.
- Accepts the '-u' option to specify source for fetching ip lists. Currently supports 'ripe' and 'ipdeny', defaults to ripe.
- Accepts the '-f' option to specify the ip protocol family (ipv4 or ipv6). Defaults to both.
- Accepts the '-n' option to disable persistence (reboot cron job won't be created so after system reboot, there will be no more geoip blocking - although if you have an autoupdate cron job then it will eventually kick in and re-activate geoip blocking)
- Accepts the '-o' option to disable automatic backups of the firewall state, ipsets and config before an action is executed (actions include those launched by the cron jobs to implement autoupdate and persistence, as well as any action launched manually and which requires making changes to the firewall)
- Accepts the '-p' option to skip setting the default firewall policies to DROP. This can be used if installing in the whitelist mode to check everything before commiting to actually blocking. Note that with this option, whitelist geoip blocking will not be functional and to make it work, you'll need to re-install without it. This option does not affect the blacklist mode since in that mode, the default policies are not changed during installation.

**geoip-shell-uninstall.sh**
- Deletes associated cron jobs
- Restores pre-install state of default policies for the PREROUTING chain
- Removes geoip iptables rules and removes the associated ipsets
- Deletes scripts' data folder /var/lib/geoip-shell
- Deletes the config from /etc/geoip-shell
- Deletes the scripts from /usr/local/bin
- if called with the `-l` option, performs a reset instead of a full uninstall: cleans up previous geoip rules and ipsets in the firewall and resets the ip lists in the config
- if called with the `-r` option, prepares the system for re-installation of the suite: cleans up previous geoip rules and ipsets in the firewall and removes the config

**geoip-shell-manage.sh**: serves as the main user interface to configure geoip after installation. You can also call it by simply typing `geoip-shell` (as during installation, a symlink is created to allow that). As most scripts in this suite, you need to use it with 'sudo' because root privileges are required to access the firewall.

`geoip-shell <add|remove> [-c <"country_codes">]` :
* Adds or removes the specified country codes to/from the config file.
* Calls the -run script to fetch and apply the ip lists for specified countries to the firewall (or to remove them).

`geoip-shell status`
* Displays information on the current state of geoip blocking

`geoip-shell schedule -s <"schedule_expression">` : enables automatic ip lists update and configures the schedule for the periodic cron job which implements this feature.

`geoip-shell schedule -s disable` : disables ip lists autoupdate.

`geoip-shell restore` : re-fetches and re-applies geoip firewall rules and ip lists as per the config.

**geoip-shell-run.sh**: Serves as a proxy to call the -fetch, -apply and -backup scripts with arguments required for each action. Executes the requested actions, depending on the config set by the -install and -manage scripts, and the command line options. If persistence or autoupdates are enabled, the cron jobs call this script with the necessary options.

`geoip-shell-run add -l <"list_id [list_id] ... [list_id]">` : Fetches iplists and loads ipsets and iptables rules for specified list id's.
List id has the format of <country_code>_<family>. For example, ****US_ipv4** and **GB_ipv6** are valid list id's.

`geoip-shell-run remove -l <"list_ids">` : Removes iplists, ipsets and iptables rules for specified list id's.

`geoip-shell-run update` : Updates the ipsets for list id's that had been previously configured. Intended for triggering from periodic cron jobs.

`geoip-shell-run restore` : Restore previously downloaded lists from backup (skip fetching). Used by the reboot cron job to implement persistence.

**geoip-shell-fetch.sh**
- Fetches ip lists for given list id's from RIPE or from ipdeny. The source is selected during installation. If you want to change the default which is RIPE, install with the `-u ipdeny` option.
- Parses, validates, compiles the downloaded lists, and saves each one to a separate file.
- Implements extensive sanity checks at each stage (fetching, parsing, validating and saving) and handles errors if they occur.

(for specific information on how to use the script, run it with the -h option)

**geoip-shell-apply.sh**:  directly interfaces with the firewall. Creates or removes ipsets and iptables rules for specified country codes.

`geoip-shell-apply add -l <"list_ids">` :
- Loads ip list files for specified list id's into ipsets and sets iptables rules required to implement geoip blocking.

List id has the format of <country_code>_<family>. For example, **US_ipv4** and **GB_ipv6** are valid list id's.

`geoip-shell-apply remove -l <"list_ids">` :
- removes ipsets and associated iptables rules for specified list id's.

**geoip-shell-cronsetup.sh** manages all the cron-related logic and actions. Called by the -manage script. Cron jobs are created based on the settings stored in the config file.

(for specific information on how to use the script, run it with the -h option)

**geoip-shell-backup.sh**: Creates a backup of the current iptables state, current geoip blocking config and geoip-associated ipsets, or restores them from backup. By default (if you didn't run the installation with the '-o' option), backup will be created before every action you apply to the firewall and before automatic list updates are applied. Normally backups should not take much space, maybe a few megabytes if you have many ip lists. The -backup script also compresses them, so they take even less space. (and automatically extracts them when restoring). When creating a new backup, it overwrites the previous one, so only one backup copy is kept.

`geoip-shell-backup create-backup` : Creates a backup of the current iptables state, geoip blocking config and geoip-associated ipsets.

`geoip-shell-backup restore` : Can be manually used for recovery from fault conditions (unlikely that anybody will ever need this but implemented just in case).
- Restores ipsets, iptables state and geoip blocking config from the last backup.

**geoip-shell-common.sh** : Stores common functions and variables for the geoip-shell suite. Does nothing if called directly. Most other scripts won't work without it.

**validate-cron-schedule.sh** is used by the -cronsetup script. It accepts a cron schedule expression and attempts to make sure that it conforms to the crontab format. It can be used outside the suite as it doesn't depend on the -common script. This is a heavily modified and improved version of a prior 'verifycron' script I found circulating on the internets (not sure who wrote it so can't give them credit).

**check-ip-in-source.sh** can be used to verify that a certain ip address belongs to a subnet found in source records for a given country. It is intended for manual use and is not called from other scripts. It does depend on the *fetch script, and on the *common script (they just need to be in the same directory), and in addition, it requires the grepcidr utility installed in your system.

`sh check-ip-in-source.sh -c <country_code> -i <"ip [ip] [ip] ... [ip]"> [-u <source>]`

- Supported sources are 'ripe' and 'ipdeny'.
- Any combination of ipv4 and ipv6 addresses is supported.
- If passing multiple ip addresses, use double quotes around them.

**detect-local-subnets-AIO.sh**: detects and outputs local area network (LAN) subnets which the machine is connected to.

`sh detect-local-subnets-AIO.sh [-f <inet|inet6>] [-s] [-d]`

Optional arguments:
- `-f <inet|inet6|"inet inet6">` : only detect subnets for the specified family. Also accepts the other notation for the same thing: `-f <ipv4|ipv6|"ipv4 ipv6">`
- `-s` : only output the subnets (doesn't output the ip addresses and the other text)
- `-d` : debug

This script is called by the -apply script when the suite is installed in whitelist mode. The reason for its existence is that in whitelist mode, all incoming connections should be blocked, except what is explicitly allowed. Since this project doesn't aim to isolate your machine from your local network, when installed in whitelist mode it detects your local area networks and creates whitelist firewall rules for them, so they don't get blocked. If installed in blacklist mode, this script will not be called because in that mode, whitelisting local networks is not required.

I am developing this script in a separate repository:

https://github.com/blunderful-scripts/subnet-tools

**posix-arrays-a-mini.sh**: implements support for associative arrays in POSIX shell. Used in the -fetch script. This version is optimized for very small arrays, and includes a minimal subset of functions from the main project found here:

https://github.com/blunderful-scripts/POSIX-arrays

**ip-regex.sh**: loads regular expressions used in other scripts for validation of ipv4 and ipv6 addresses and subnets.