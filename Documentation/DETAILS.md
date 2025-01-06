## **Prelude**
- geoip-shell supports a numer of different use cases, many different platforms, and 2 backend firewall utilities (nftables and iptables). For this reason I designed it to be modular rather than monolithic. In this design, the functionality is split between few main scripts. Each main script performs specific tasks and utilizes library scripts which are required for the task with the given platform and firewall utility.
- This document provides some info on the purpose and core options of the main scripts and how they work in tandem. And some information about the library scripts.
- The main scripts print "usage" info when called with the "-h" option. You can find out about some additional options specific to each script by running it with that option.

## **Overview**

### Main Scripts
- geoip-shell-install.sh
- geoip-shell-uninstall.sh
- geoip-shell-manage.sh
- geoip-shell-run.sh
- geoip-shell-fetch.sh
- geoip-shell-apply.sh
- geoip-shell-backup.sh
- geoip-shell-cronsetup.sh

### Helper Scripts
**geoip-shell-geoinit.sh**
- This script is sourced from all main scripts. It sets some essential variables, checks for compatible shell, then sources the -lib-common script, then sources the /etc/geoip-shell/geoip-shell.const file which stores some system-specific constants.

### Library Scripts
- lib/geoip-shell-lib-common.sh
- lib/geoip-shell-lib-setup.sh
- lib/geoip-shell-lib-ipt.sh
- lib/geoip-shell-lib-nft.sh
- lib/geoip-shell-lib-status.sh
- lib/geoip-shell-lib-non-owrt.sh
- lib/geoip-shell-lib-arrays.sh
- lib/geoip-shell-lib-uninstall.sh
- lib/geoip-shell-lib-ip-tools.sh


The -lib-common script includes a large number of functions used throughout the suite, and assigns some essential variables.

The lib-setup script implements some of the CLI interactive and noninteractive setup and arguments parsing. It is used by the -manage script.

The -lib-status script implements the status report which you can get by issuing the `geoip-shell status` command.

The -lib-ipt and -lib-nft scripts implement support for iptables and nftables, respectively. They are sourced from other scripts which need to interact with the firewall utility directly.

The -lib-non-owrt script includes some functions which are not needed for OpenWrt

The -lib-arrays script implements a minimal subset of functions emulating the functionality of associative arrays in POSIX-compliant shell. It is used in the -fetch script. It is a part of a larger project implementing much more of the arrays functionality. You can check my other repositories if you are interested.

The -lib-uninstall script has some functions which are used both for uninstallation and for reset if required.

The lib-ip-tools script is only used under specific conditions:
- During initial setup, with whitelist mode, and only if wan interfaces were set to 'all', and LAN subnets were not specified via command line args. geoip-shell then assumes that it is being configured on a host behind a router and firewall, uses this script to detect the LAN subnets and offers the user to add them to the whitelist, and to enable automatic detection of LAN subnets in the future.
- At the time of creating/updating firewall rules, and only if LAN subnets automatic detection is enabled. geoip-shell then re-detects LAN subnets automatically.

### OpenWrt-specific scripts
These are only installed on OpenWrt systems. The .tpl files are "templates" which are used to create the final scripts at the time of installation (when using the install script), or at the time of OpenWrt package preparation.
- geoip-shell-lib-owrt.sh
- geoip-shell-owrt-init.tpl
- geoip-shell-owrt-mk-fw-include.tpl
- geoip-shell-owrt-fw-include.tpl
- geoip-shell-owrt-uninstall.sh (only installed via an ipk package)
- prep-owrt-package.sh (does not get installed)
- mk-owrt-package.sh (does not get installed)

### Optional script
- check-ip-in-source.sh
  This script is intended for checks before installation. It does not get installed.

### User interface
Scripts intended as user interface are **geoip-shell-install.sh**, **geoip-shell-uninstall.sh**, **geoip-shell-manage.sh** and **check-ip-in-source.sh**. All the other scripts are intended as a back-end. If you just want to install and move on, you only need to run the -install script.
After installation, the user interface is provided by running "geoip-shell", which is a symlink to the -manage script.

## **Main scripts in detail**
**geoip-shell-manage.sh**: serves as the main user interface to configure geoip-shell after installation. You can also call it by simply typing `geoip-shell`. As most scripts in this suite, it requires root privileges because it needs to interact with the netfilter kernel component and access the data folder which is only readable and writable by root. Since it serves as the main user interface, it contains a lot of logic to parse, validate and initiate actions requested by the user (by calling other scripts as required), check for possible remote machine lockout and warn the user about it, check actions result, update the config and take corrective actions in case of an error. Describing all this is beyond the scope of this document but you can read the code. Sources the lib-status script when generating a status report. Sources lib-setup for some of the arguments parsing logic and interactive dialogs implementation.

`geoip-shell <on|off>` : Enable or disable the main geoblocking chain (via a rule in the base geoip chain)

`geoip-shell stop` : Kill any running geoip-shell processes, remove geoip-shell firewall rules and unload ip sets

`geoip-shell status`
* Displays information on the current state of geoip blocking
* For a list of all firewall rules in the geoip chain and for detailed count of ip ranges, run `geoip-shell status -v`.

`geoip-shell restore` : re-fetches and re-applies geoip firewall rules and ip lists as per the config.

`geoip-shell showconfig` : prints the contents of the config file.

`geoip-shell configure [options]` : changes geoip-shell configuration.

Initial configuration is possible either fully interactively (the -manage script gathers all important config via dialog with the user), partially interactively (you provide some command line arguments, the -manage script processes them and if needed, asks you additional questions), or completely non-interactively by calling the -manage script with the `-z` option which will force the command to fail if any required options are missing or invalid.

**Note** that at initial interactive setup, geoip-shell will only ask questions about **inbound** geoblocking. If you want to have **outbound** geoblocking (in addition to or instead of inbound geoblocking), use the command `geoip-shell configure -D outbound`. This will start interactive setup for that direction.

Any sensible combination of the following options is allowed in one command.

### **Options for the `geoip-shell configure` command:**

The options are divided into 2 categories: direction-specific options and general options.

#### **Direction-specific options for `geoip-shell configure`:**

These options apply to geoblocking direction (inbound or outbound) which you can specify via the `-D <direction>` option. When direction is not specified, options apply to the **inbound** direction.

`-m <whitelist|blacklist|disable>`: Change geoblocking mode.

`-c <"country codes">`: Change which country codes are included in the whitelist/blacklist (this command replaces all country codes with newly specified ones).

`-p <[tcp|udp]:[allow|block]:[all|<ports>]>`: Specify ports geoblocking will apply (or not apply) to, for tcp or udp. To specify ports for both tcp and udp, use the `-p` option twice. For more details, read [NOTES.md](/Documentation/NOTES.md), sections 10-12.

**Example commands:**

`geoip-shell configure -m whitelist -c DE -p tcp:allow:80 -p udp:allow:123` - this sets options for inbound geoblocking

`geoip-shell configure -D inbound -p tcp:block:123` - this also sets options for inbound geoblocking

`geoip-shell configure -D outbound -p tcp:block:123` - this sets options for outbound geoblocking

`geoip-shell configure -D inbound -p tcp:block:123 -p udp:allow:123 -D outbound -p tcp:block:321 -p udp:allow:321`

- the above command sets corresponding options for inbound and outbound geoblocking directions

#### **General options for `geoip-shell configure`:**

These options apply to geoblocking in both directions.

`-f <ipv4|ipv6|"ipv4 ipv6">`: Families (defaults to 'ipv4 ipv6'). Use double quotes for multiple families.

`-u [ripe|ipdeny|maxmind]`: Change ip lists source.

`-i <[ifaces]|auto|all>`: Change which network interfaces geoip firewall rules are applied to. `auto` will attempt to automatically detect WAN network interfaces. `auto` works correctly in **most** cases but not in **every** case. Don't use `auto` if the machine has no dedicated WAN network interfaces. The automatic detection occurs only when manually triggered by the user via this command.

`-l <"[lan_ips]"|auto|none>`: Specify LAN IPs or subnets to exclude from blocking (both ipv4 and ipv6). `auto` will trigger LAN subnets re-detection at every update of the ip lists. When specifying custom IPs or subnets, automatic detection is disabled. This option is only avaiable when using geoip-shell in whitelist mode.

`-t <"[trusted_ips]|none">`: Specify trusted IPs or subnets (anywhere on the Internet) to exclude from geoip blocking (both ipv4 and ipv6).

`-U <auto|pause|none|"[ip_addresses]">`: Policy for allowing automatic ip list updates when outbound geoblocking is enabled. Use `auto` to detect server ip addresses automatically once and always allow outbound connection to detected addresses. Or use `pause` to always temporarily pause outbound geoblocking before fetching ip list updates.
Or specify ip addresses for ip lists source (ripe or ipdeny or maxmind) to allow - for multiple addresses, use double quotes.
Or use `none` to remove previously assigned server ip addresses and disable this feature.

`-r <[user_country_code]|none>` : Specify user's country code. Used to prevent accidental lockout of a remote machine. `none` disables this feature.

`-s <"schedule_expression"|disable>` : Enables automatic ip lists updates and configures the schedule for the periodic cron job which implements this feature. `disable` disables automatic ip lists updates.

`-a <path>` : Set custom path to directory where backups and the status file will be stored. Default is '/tmp/geoip-shell-data' for OpenWrt, '/var/lib/geoip-shell' for all other systems.

`-w <ipt|nft>`: Specify the backend firewall management utility to use with geoip-shell. `ipt` for iptables, `nft` for nftables. Default is nftables if it is present in the system.

`-O <memory|performance>`: Specify optimization policy for nftables sets. By default optimizes for low memory consumption if system RAM is less than 2GiB, otherwise optimizes for performance. This option doesn't work with iptables.

`-o <true|false>` : No backup. If set to 'true', geoip-shell will not create backup of ip lists after applying changes, and will automatically re-fetch ip lists after each reboot. Default is 'true' for OpenWrt, 'false' for all other systems.

`-n <true|false>`: No-persistence. When set to `true`, geoip-shell will remove the persistence cron job and will avoid recreating it when processing cron jobs in the future. On OpenWrt, this will disable the init script and remove the firewall include. Default is `false`.

`-N <true|false>`: No-block. When set to `true`, geoip-shell will remove the "geoblocking enable" rules. All other geoip-shell firewall rules will remain in place but traffic will not be passing through them. The effect is the same as for the command `geoip-shell off`. The `-N` option may be useful in combination with other options when you want to check the resulting rules without starting to pass traffic through those rules.

`-P <true|false>`: Force cron-based persistence on Busybox-based systems. Depending on compile-time options of Busybox, in some cases Busybox crontab supports the `@reboot` string which is used by geoip-shell to implement persistence and in other cases it doesn't. geoip-shell has no way to tell whether the specific Busybox on your device does or does not support it. For this reason by default geoip-shell refuses to create the persistence cron job when Busybox crontab is detected. This option allows you to override this behavior, so the persistence cron job will be created anyway. You will want to check that it works by restarting your machine, waiting for a minute and running `geoip-shell status`.

### Other options
`-v`: Verbose status output

`-z`: Non-interactive setup. Will not ask any questions. Will fail if required options are not specified or invalid.

`-d`: Debug

`-V`: Version

`-h`: Prints 'usage' info


**geoip-shell-install.sh**
- Creates directories for config and data
- Compiles a list of files which need to be installed
- If prior installation exists, removes its firewall rules and ipsets - either by calling the -uninstall script from older version or by calling the relevant scripts from it (depending on which version was installed)
- The main scripts go to `/usr/bin`, library scripts to `/usr/lib/geoip-shell` config to `/etc/geoip-shell`
- If a previous installation exists, only updates files which have changed
- Creates a directory for data in `/var/lib/geoip-shell` (or in `/tmp/geoip-shell-data` on OpenWrt)
- Sets restrictive permissions for directories and files
- Calls the -manage script to set up geoblocking (which, in turn, calls additional scripts)
- The -install script does not install itself into the system

Options:

`-z`: Force non-interactive setup

`-d`: Print debug messages

**geoip-shell-uninstall.sh**
- Removes geoblocking firewall rules, geoip-shell cron jobs, scripts' data and config, deletes the scripts from /usr/bin and /usr/lib/geoip-shell, and on OpenWrt removes the init script and the firewall include
- If called from the distribution directory (e.g. by the geoip-shell installer), checks whether prior installation exists, and if so then calls the -uninstall script from the prior installation

Options:
- `-r`: prepares the system for re-installation of geoip-shell: does the same as normal uninstall but keeps the data and the config from previous installation

**geoip-shell-run.sh**: Coordinates and calls the -fetch, -apply and -backup scripts to perform requested action. Requested actions are executed depending on the config and the command line options. Writes to system log when starting and on action completion (or if any errors encountered). If persistence or automatic updates are enabled, this script is called by the cron jobs (or on OpenWrt, by the firewall include script). If a non-fatal error is encountered, the script has the facility to enter sort of a temporary daemon mode where it will re-try the action (up to a certain number of retries) with increasing time intervals. It also implements some logic to account for unexpected issues encountered during the 'restore' action (which runs after system reboot to impelement persistnece), such as missing backup, and in this situation will automatically change its action from 'restore' to 'update' and try to re-fetch and re-apply the ip lists.

Actions: `add`, `update`, `restore`.

`geoip-shell-run.sh add -l <"list_id [list_id] ... [list_id]">` : Fetches ip lists, loads them into ip sets and applies firewall rules for specified list id's.
List id has the format of `<country_code>_<family>`. For example, **US_ipv4** and **GB_ipv6** are valid list id's.

`geoip-shell-run.sh update` : Updates the ip sets for list id's that had been previously configured. Intended for triggering from periodic cron jobs.

`geoip-shell-run.sh restore` : Restore previously downloaded lists from backup. Used by the reboot cron job (or by the firewall include on OpenWrt) to implement persistence. If restore from backup fails, automatically changes the action to `update`, fetches the ip lists and tries to apply them.

`geoip-shell-run.sh <restore|update> -a` : Adding the `-a` option when calling the `-run` script with the `restore` and `update` actions enables the temporary daemon-like behavior where the script will try to re-fetch and re-apply ip lists if initial attempt fails.


**geoip-shell-fetch.sh**
- Fetches ip lists for given list id's from RIPE or from ipdeny or from MaxMind.
- Parses, validates, compiles the downloaded lists, and saves each one to a separate file.
- Implements extensive sanity checks at each stage (fetching, parsing, validating and saving) and handles errors if they occur.

Options:

`-l <"list_ids">` : ip list id's in the format <country_code>_<family> (if specifying multiple list id's, use double quotes)

`-p <path>` : Path to directory where downloaded and compiled ip lists will be stored.

`-o <output_file>` : Path to output file where fetched list will be stored.

`-s <path>`        : Path to a file to register fetch results in.

`-u <ripe|ipdeny|maxmind>` : Use this ip list source for download. Supported sources: ripe, ipdeny, maxmind.

Extra options:

`-r` : Raw mode (outputs newline-delimited ip lists rather than nftables-ready ones).

`-f` : Force using fetched lists even if list timestamp didn't change compared to existing list.


**geoip-shell-apply.sh**:  directly interfaces with the firewall backend (nftables or iptables). Creates or removes ip sets and firewall rules for specified list id's. Sources the lib-ipt or lib-nft library script.

Actions: `add`, `update`, `restore`, `on`, `off`

`geoip-shell-apply.sh add` :
- Recreate geoblocking rules based on config and add missing ipsets, loading them from files

`geoip-shell-apply.sh update` :
- Recreate geoblocking rules based on config, loading ipsets from files

`geoip-shell-apply.sh restore` :
- Recreate geoblocking rules based on config, re-using existing (previously loaded) ipsets

**geoip-shell-cronsetup.sh** manages cron-related logic and actions. Called by the -manage script. Cron jobs are created based on the settings stored in the config file. When called with the `-x <expression>` option, validates cron schedule specified by the user.

**geoip-shell-backup.sh**: Creates backup of current geoip-shell ip sets and current geoip-shell config, or restores them from backup. By default (except on OpenWrt or if you configured geoip-shell with the '-o' option), backup will be created after every change to ip sets in the firewall. Backups are automatically compressed and de-compressed with the best utility available to the system, in this order: `bzip2`, `xz`, `gzip`, or `cat` as a fallback if neither is available (which generally should never happen on Linux). Only one backup copy is kept. Sources the lib-ipt or the lib-nft library script.

`geoip-shell-backup.sh create-backup` : Creates backup of geoip-shell ip sets and config.

`geoip-shell-backup.sh restore` : Restores geoip-shell state and config from backup. Used by the `-run` script to implement persistence, and under some conditions by the `-manage` script. If run with the option `-n`, does not restore the config and the status files.

## **Optional script**
**check-ip-in-source.sh** can be used to verify that a certain ip address belongs to a subnet found in source records for a given country. It is intended for manual use and is not called from other scripts. It requires the grepcidr utility to be installed in your system.

`sh check-ip-in-source.sh -c <country_code> -i <"ip [ip] [ip] ... [ip]"> [-u <source>]`

- Supported sources are `ripe`, `ipdeny` and `maxmind`.
- Any combination of ipv4 and ipv6 addresses is supported.
- If passing multiple ip addresses, use double quotes around them.
