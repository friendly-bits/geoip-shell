# **geoip-shell**
Geoip blocker for Linux. Supports both **nftables** and **iptables** firewall management utilities.

The idea of this project is making geoip blocking easy on (almost) any Linux system, no matter which hardware, including desktop, server, VPS or router, while also being reliable and providing flexible configuration options for the advanced users.

Supports running on OpenWrt. Supports ipv4 and ipv6.

[![image](https://github.com/friendly-bits/geoip-shell/assets/134004289/e1a70e9d-a0eb-407b-9372-ddcbe6134d88)](https://github.com/friendly-bits/geoip-shell/assets/134004289/24010da9-a62a-428f-ae4d-cb1d4ae97f73)
[![image](https://github.com/friendly-bits/geoip-shell/assets/134004289/ef622182-a6cf-49ff-9bed-64fc29653255)](https://github.com/friendly-bits/geoip-shell/assets/134004289/b35e199f-465d-487c-809b-9c5a8f0644be)


## Table of contents
- [Features](#features)
- [Installation](#installation)
- [Pre-requisites](#pre-requisites)
- [Usage](#usage)
- [Notes](#notes)
- [In detail](#in-detail)
- [Privacy](#privacy)
- [P.s.](#ps)

## **Features**
* Core functionality is creating either a whitelist or a blacklist in the firewall using automatically downloaded ip lists for user-specified countries.

* ip lists are fetched either from **RIPE** (regional Internet registry for Europe, the Middle East and parts of Central Asia) or from **ipdeny**. Both sources provide updated ip lists for all regions.

* All firewall rules and ip sets required for geoip blocking to work are created during installation.

* After installation, a tool is provided to check geoip status and firewall rules or change geoip-related config, including adding or removing countries, turning geoip on or off etc.

* Implements optional (enabled by default) persistence of geoip blocking across system reboots and automatic updates of the ip lists.

### **Reliability**:
- Default source for ip lists is RIPE, which allows to avoid dependency on non-official 3rd parties.
- Downloaded ip lists go through validation which safeguards against application of corrupted or incomplete lists to the firewall.
- With nftables, utilizes nftables atomic rules replacement to make the interaction with the system firewall fault-tolerant and to completely eliminate time when geoip is disabled during an automatic update.

<details> <summary>Read more:</summary>

- All scripts perform extensive error detection and handling.
- Verifies firewall rules coherence after each action.
- Automatic backup of geoip-shell state (optional, enabled by default).
- Automatic recovery of geoip-shell state after a reboot (a.k.a persistence) or in case of unexpected errors.
</details>

### **Efficiency**:
- Utilizes the native nftables sets (or, with iptables, the ipset utility) which allows to create efficient firewall rules with thousands of ip ranges.

<details><summary>Read more:</summary>

- With nftables, optimizes geoip blocking for low memory consumption or for performance, depending on user preference. With iptables, automatic optimization is implemented.
- Ip list parsing and validation are implemented through efficient regex processing which is very quick even on slow embedded CPU's.
- Implements smart update of ip lists via data timestamp checks, which avoids unnecessary downloads and reconfiguration of the firewall.
- Uses the "prerouting" hook in kernel's netfilter component which shortens the path unwanted packets travel in the system and may reduce the CPU load if any additional firewall rules process incoming traffic down the line.
- Supports the 'ipdeny' source which provides aggregated ip lists (useful for embedded devices with limited memory).
- Scripts are only active for a short time when invoked either directly by the user or by the init script/reboot cron job/update cron job.

</details>

### **User-friendliness**:
- Installation is easy and normally takes a very short time.

<details><summary>Read more:</summary>

- Good command line interface and useful console messages.
- Extensive and (usually) up-to-date documentation.
- Comes with an *uninstall script which completely removes the suite and the geoip firewall rules. No restart is required.
- Sane settings are applied during installation by default, but also lots of command-line options for advanced users or for special corner cases are provided.
- Pre-installation, provides a utility _(check-ip-in-source.sh)_ to check whether specific ip addresses you might want to blacklist or whitelist are indeed included in the list fetched from the source (RIPE or ipdeny).
- Post-installation, provides a utility (symlinked to _'geoip-shell'_) for the user to change geoip config (turn geoip on or off, add or remove country codes, change the cron schedule etc).
- Post-installation, provides a command _('geoip-shell status')_ to check geoip blocking status, which also reports if there are any issues.
- In case of an error or invalid user input, provides useful error messages to help with troubleshooting.
- Most scripts display detailed 'usage' info when executed with the '-h' option.
- The code should be fairly easy to read and includes a healthy amount of comments.
</details>

### **Compatibility**:
- Since the project is written in POSIX-compliant shell code, it is compatible with virtually every Linux system (as long as it has the pre-requisites). It even works well on simple embedded routers with 8MB of flash storage and 128MB of memory (for nftables, 256MB is recommended if using large ip lists such as the one for US until the nftables team releases a fix reducing memory consumption).

<details><summary>Read more:</summary>

- Supports running on OpenWrt.
- The project avoids using non-common utilities by implementing their functionality in custom shell code, which makes it faster and compatible with a wider range of systems.
</details>

## **Installation**
NOTE: Installation can be run interactively, which does not require any command line arguments and gathers the important config via dialog with the user. Alternatively, config may be provided via command-line arguments.

Some features are only accessible via command-line arguments.
_To find out more, use `sh geoip-shell-install.sh -h` or read [NOTES.md](/Documentation/NOTES.md) and [DETAILS.md](/Documentation/DETAILS.md)_

_(Note that all commands require root privileges, so you will likely need to run them with `sudo`)_

**1)** If your system doesn't have `wget`, `curl` or (OpenWRT utility) `uclient-fetch`, install one of them using your distribution's package manager. Systems which only have `iptables` also require the `ipset` utility.

**2)** Download the latest realease: https://github.com/friendly-bits/geoip-shell/releases

**3)** Extract all files included in the release into the same folder somewhere in your home directory and `cd` into that directory in your terminal.

**4)** For interactive installation, run `sh geoip-shell-install.sh`.

_<details><summary>Examples for non-interactive installation options:</summary>_

- installing on a server located in Germany, which has nftables and is behind a firewall (no direct WAN connection), whitelist Germany and Italy and block all other countries:

`sh geoip-shell-install.sh -m whitelist -c "DE IT" -r DE -i all -l auto -e`

- installing on a router located in the US, blacklist Germany and Netherlands and allow all other countries:

`sh geoip-shell-install.sh -m blacklist -c "DE NL" -r US -i pppoe-wan`

- if you prefer to fetch the ip lists from a specific source, add `-u <source>` to the arguments
- to block or allow specific ports, use `-p <tcp|udp>:<block|allow>:<ports>`. This option may be used twice in one command to specify ports for both tcp and udp
- to exclude certain trusted subnets on the internet from geoip blocking, add `-t "<subnets_list>"` to the arguments
- if your machine uses nftables and has enough memory, consider installing with the `-e` option (for "performance")
- if your distro (or you) have enabled automatic nftables/iptables rules persistence, you can disable the built-in cron-based persistence feature by adding the `-n` (for no-persistence) option when running the -install script.
- if for some reason you need to install the suite in strictly non-interactive mode, you can call the install script with the `-z` option which will avoid asking the user any questions and will fail if required config is incomplete or invalid.
</details>

**5)** The `-install.sh` script will ask you several questions to configure the installation, then initiate download and application of the ip lists. If you are not sure how to answer some of the questions, read [INSTALLATION.md](/Documentation/INSTALLATION.md).

**6)** That's it! By default, ip lists will be updated daily at 4:15am local time (4:15 at night) - you can verify that automatic updates are working by running `cat /var/log/syslog | grep geoip-shell` on the next day (change syslog path if necessary, according to the location assigned by your distro. on some distributions, a different command should be used, such as `logread`).

## **Pre-requisites**
(if a pre-requisite is missing, the _-install.sh_ script will tell you which)
- **Linux**. Tested on Debian-like systems and on OPENWRT, should work on any desktop/server distribution and possibly on some other embedded distributions.
- **POSIX-compliant shell**. Should work on most relatively modern shells, including **bash**, **dash**, **yash** and **ash**. Shells slightly deviating from the POSIX standard should work as well. **ksh** should work (please let me know if you try it) if the `POSIXLY_CORRECT=yes` environment var is set (upcoming geoiop-shell release will set this var automatically). Does **not** work on **tcsh** and **zsh**.
- **nftables** - firewall management utility. Supports nftables 1.0.2 and higher (may work with earlier versions but I do not test with them).
- OR **iptables** - firewall management utility. Should work with any relatively modern version.
- for **iptables**, requires the **ipset** utility - install it using your distribution's package manager
- standard Unix utilities including **tr**, **cut**, **sort**, **wc**, **awk**, **sed**, **grep**, and **logger** which are included with every server/desktop linux distribution (and with OpenWrt). Both GNU and non-GNU versions are supported, including BusyBox implementation.
- **wget** or **curl** or **uclient-fetch** (OpenWRT-specific utility).
- for the autoupdate functionality, requires the **cron** service to be enabled. Except on OpenWrt, persistence also requires the cron service.

**Optional**: the _check-ip-in-source.sh_ optional script requires **grepcidr**. install it with `apt install grepcidr` on Debian and derivatives. For other distros, use their built-in package manager.

## **Usage**
_(Note that all commands require root privileges, so you will likely need to run them with `sudo`)_

Generally, once the installation completes, you don't have to do anything else for geoip blocking to work. But I implemented some tools which provide functionality for changing geoip config and checking current geoip blocking status.

**To check current geoip blocking status:** run `geoip-shell status`. For a list of all firewall rules in the geoip chain and for a detailed count of ip ranges in each ip list, run `geoip-shell status -v`.

**To add or remove ip lists for countries:** run `geoip-shell <add|remove> -c <"country_codes">`

_<details><summary>Examples:</summary>_
- example (to add ip lists for Germany and Netherlands): `geoip-shell add -c "DE NL"`
- example (to remove the ip list for Germany): `geoip-shell remove -c DE`
</details>

**To enable or disable geoip blocking:** run `geoip-shell <on|off>`

**To change protocols and ports geoblocking applies to:** run `geoip-shell apply -p [tcp|udp]:[allow|block]:[all|<ports>]`

_(for details, read [NOTES.md](/Documentation/NOTES.md), sections 8-10)_

**To enable or change the autoupdate schedule**, use the `-s` option followed by the cron schedule expression in doulbe quotes:

`geoip-shell schedule -s <"schdedule_expression">`

_<details><summary>Example</summary>_

`geoip-shell schedule -s "1 4 * * *"`

</details>

**To disable ip lists autoupdates:** `geoip-shell schedule -s disable`

**To uninstall:** run `geoip-shell-uninstall.sh`

**To switch mode (from whitelist to blacklist or the opposite):** re-install

**To change ip lists source (from RIPE to ipdeny or the opposite):** re-install

**For info about some additional actions:** run `geoip-shell -h`

## **Notes**
For some helpful notes about using this suite, read [NOTES.md](/Documentation/NOTES.md).

## **In detail**
For specifics about each script, read [DETAILS.md](/Documentation/DETAILS.md).

## **Privacy**
These scripts do not share your data with anyone, as long as you downloaded them from the official source, which is
https://github.com/friendly-bits/geoip-shell
If you are using the ipdeny source then note that they are a 3rd party which has its own data privacy policy.

## **P.s.**

- If you like this project, please take a second to give it a star on Github. This helps other people to find it.
- I would appreciate a report of whether it works or doesn't work on your system (please specify which). You can use the Github Discussions tab for that.
- If you find a bug or want to request a feature, please let me know by opening an issue.
