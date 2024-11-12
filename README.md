# **geoip-shell**
Powerful geoblocker for Linux. Supports both **nftables** and **iptables** firewall management utilities.

The idea of this project is making geoblocking (i.e. restricting access from or to Internet addresses based on geolocation) easy on (almost) any Linux system, no matter which hardware, including desktop, server, container, VPS or router, while also being reliable and providing flexible configuration options for the advanced users.

If you find this project useful, please take a second to give it a star on Github. This helps other people to find it.

[![image](https://github.com/friendly-bits/geoip-shell/assets/134004289/e1a70e9d-a0eb-407b-9372-ddcbe6134d88)](https://github.com/friendly-bits/geoip-shell/assets/134004289/24010da9-a62a-428f-ae4d-cb1d4ae97f73)
[![image](https://github.com/friendly-bits/geoip-shell/assets/134004289/ef622182-a6cf-49ff-9bed-64fc29653255)](https://github.com/friendly-bits/geoip-shell/assets/134004289/b35e199f-465d-487c-809b-9c5a8f0644be)


## Table of contents
- [Main Features](#main-features)
- [Installation](#installation)
- [Usage](#usage)
- [Pre-requisites](#pre-requisites)
- [Notes](#notes)
- [In detail](#in-detail)
- [OpenWrt](#openwrt)
- [Privacy](#privacy)
- [P.s.](#ps)

## **Main Features**
* Core functionality is creating either a whitelist or a blacklist in the firewall using automatically downloaded ip lists for user-specified countries.

* ip lists are fetched either from **RIPE** (regional Internet registry for Europe, the Middle East and parts of Central Asia) or from **ipdeny**. Both sources provide updated ip lists for all regions.

* All firewall rules and ip sets required for geoblocking to work are created automatically during the initial setup.

* Supports automated interactive setup for easy configuration.

* Automates creating auxiliary firewall rules based on user's preferences (for example, when configuring on a host in whitelist mode, geoip-shell will detect LAN subnets and suggest to add them to the whitelist)

* Implements optional (enabled by default) persistence of geoblocking across system reboots and automatic updates of the ip lists.

* After installation, a utility is provided to check geoblocking status and firewall rules or change country codes and geoblocking-related config.

* Supports inbound and outbound geoblocking.

* Supports ipv4 and ipv6.

* Supports running on OpenWrt.

### **Reliability**:
- Downloaded ip lists go through validation which safeguards against application of corrupted or incomplete lists to the firewall.

<details> <summary>Read more:</summary>

- Default source for ip lists is RIPE, which allows to avoid dependency on non-official 3rd parties.
- With nftables, utilizes nftables atomic rules replacement to make the interaction with the system firewall fault-tolerant and to completely eliminate time when geoip is disabled during an automatic update.
- All scripts perform extensive error detection and handling.
- All user input is validated to reduce the chance of accidental mistakes.
- Verifies firewall rules coherence after each action.
- Automatic backup of geoip-shell state (optional, enabled by default except on OpenWrt).
- Automatic recovery of geoip-shell firewall rules after a reboot (a.k.a persistence) or in case of unexpected errors.
- Supports specifying trusted ip addresses anywhere on the Internet which will bypass geoip blocking to make it easier to regain access to the machine if something goes wrong.
</details>

### **Efficiency**:
- Utilizes the native nftables sets (or, with iptables, the ipset utility) which allows to create efficient firewall rules with thousands of ip ranges.

<details><summary>Read more:</summary>

- With nftables, optimizes geoblocking for low memory consumption or for performance, depending on the RAM capacity of the machine and on user preference. With iptables, automatic optimization is implemented.
- Ip list parsing and validation are implemented through efficient regex processing which is very quick even on slow embedded CPU's.
- Implements smart update of ip lists via data timestamp checks, which avoids unnecessary downloads and reconfiguration of the firewall.
- For inbound geoblocking, uses the "prerouting" hook in kernel's netfilter component which shortens the path unwanted packets travel in the system and may reduce the CPU load if any additional firewall rules process incoming traffic down the line.
- Supports the 'ipdeny' source which provides aggregated ip lists (useful for embedded devices with limited memory).
- Scripts are only active for a short time when invoked either directly by the user or by the init script/reboot cron job/update cron job.

</details>

### **User-friendliness**:
- Installation and initial setup are easy and normally take a very short time.
- Good command line interface and useful console messages.

<details><summary>Read more:</summary>

- Extensive and (usually) up-to-date documentation.
- Comes with an uninstall script which completely removes the suite and the geoblocking firewall rules. No restart is required.
- Sane settings are applied during installation by default, but also lots of command-line options for advanced users or for special corner cases are provided.
- Pre-installation, provides a utility _(check-ip-in-source.sh)_ to check whether specific ip addresses you might want to blacklist or whitelist are indeed included in the ip lists fetched from the source (RIPE or ipdeny).
- Post-installation, provides a utility (symlinked to _'geoip-shell'_) for the user to change geoblocking config (turn geoblocking on or off, configure outbound geoblocking, change country codes, change geoblocking mode, change ip lists source, change the cron schedule etc).
- Post-installation, provides a command _('geoip-shell status')_ to check geoblocking status, which also reports if there are any issues.
- In case of an error or invalid user input, provides useful error messages to help with troubleshooting.
- All main scripts display detailed 'usage' info when executed with the '-h' option.
- Most of the code should be fairly easy to read and includes a healthy amount of comments.
</details>

### **Compatibility**:
- Since the project is written in POSIX-compliant shell code, it is compatible with virtually every Linux system (as long as it has the [pre-requisites](#pre-requisites)). It even works well on simple embedded routers with 8MB of flash storage and 128MB of memory (for nftables, 256MB is recommended if using large ip lists such as the one for US until the nftables team releases a fix reducing memory consumption).
- The code is regularly tested on Debian, Linux Mint and OpenWrt, and occasionally on Alpine Linux and Gentoo.
- While not specifically tested by the developer, there have been reports of successful use in LXC containers (if encountering an error with running geoip-shell in LXC container, check out [issue #24](/../../issues/24) for possible solution).

<details><summary>Read more:</summary>

- Supports running on OpenWrt.
- The project avoids using non-common utilities by implementing their functionality in custom shell code, which makes it faster and compatible with a wider range of systems.
</details>

## **Installation**
_(Note that some commands require root privileges, so you will likely need to run them with `sudo`)_

**1)** If your system doesn't have `curl`, `wget` or (OpenWRT utility) `uclient-fetch`, install one of them using your distribution's package manager (for Debian and derivatives: `apt-get install curl`). Systems which only have `iptables` also require the `ipset` utility (`apt-get install ipset`).

**2)** Download the latest realease: https://github.com/friendly-bits/geoip-shell/releases. Unless you are installing on OpenWrt, download **Source code (zip or tar.gz)**. For installation on OpenWrt, read the [OpenWrt README](/OpenWrt/README.md).
  _<details><summary>**Or download using the command line**:</summary>_
  - either run `git clone https://github.com/friendly-bits/geoip-shell` - this will include all the latest changes but may not always be stable
  - or to download the latest release (requires curl):

    `curl -L "$(curl -s https://api.github.com/repos/friendly-bits/geoip-shell/releases | grep -m1 -o 'https://api.github.com/repos/friendly-bits/geoip-shell/tarball/[^"]*')" > geoip-shell.tar.gz`
  
  - to extract, run: `tar -xvf geoip-shell.tar.gz`
  </details>

**3)** Extract all files included in the release into the same folder somewhere in your home directory and `cd` into that directory in your terminal.

**4)** For installation followed by interactive setup, run `sh geoip-shell-install.sh`. For non-interactive installation, run `sh geoip-shell-install.sh -z`.

  **NOTE:** If the install script says that your shell is incompatible but you have another compatible shell installed, use it instead of `sh` to call the -install script. For example: `dash geoip-shell-install.sh`. Check out [Pre-Requisites](#pre-requisites) for a list of compatible shells. If you don't have one of these installed, use your package manager to install one (you don't need to make it your default shell).

**5)** Unless you installed in non-interactive mode, the install script will suggest you to configure geoip-shell. If you type in `y`, geoip-shell will ask you several questions, then initiate download and application of the ip lists.


## **Initial setup**
Once the installation completes, the installer will suggest to automatically start the interactive setup. If you ran the install script non-interactively or interrupted the setup at some point, you can manually (re)start interactive setup by running `geoip-shell configure`.

Interactive setup gathers the important config via dialog with the user and does not require any command line arguments. If you are not sure how to answer some of the questions, read [SETUP.md](/Documentation/SETUP.md).

Alternatively, some or all of the config options may be provided via command-line arguments.

**NOTE:** Some features are only accessible via command-line arguments. In particular, by default, initial setup only configures inbound geoblocking and leaves outbound geoblocking in disabled state. If you want to configure outbound geoblocking, run `geoip-shell configure -D outbound -m <whitelist|blacklist>`.

_To find out more, run `geoip-shell -h` or read [NOTES.md](/Documentation/NOTES.md) and [DETAILS.md](/Documentation/DETAILS.md)_

_<details><summary>Examples for non-interactive configuration options:</summary>_

- configuring **inbound** geoblocking on a server located in Germany, which has nftables and is behind a firewall (no direct WAN connection), whitelist Germany and Italy and block all other countries:

`geoip-shell configure -r DE -i all -l auto -m whitelist -c "DE IT"`

- configuring **inbound and outbound** geoblocking on a server located in Germany, whitelist Germany and Italy and block all other countries for incoming traffic, blacklist France for outgoing traffic:

`geoip-shell configure -r DE -i all -l auto -D inbound -m whitelist -c "DE IT" -D outbound -m blacklist -c FR`

- configuring **inbound** geoblocking on a router (which has a WAN network interface called `pppoe-wan`) located in the US, blacklist Germany and Netherlands and allow all other countries:

`geoip-shell configure -m blacklist -c "DE NL" -r US -i pppoe-wan`

- if you prefer to fetch the ip lists from a specific source, add `-u <source>` to the arguments, where `<source>` is `ripe` or `ipdeny`.
- to geoblock or allow specific ports or ports ranges, use `<[tcp|udp]:[allow|block]:all|[ports]>`. This option may be used twice in one command (for each geoblocking direction) to specify ports for both tcp and udp _(for examples, read [NOTES.md](/Documentation/NOTES.md), sections 9-11)_.
- to exclude certain trusted ip addresses or subnets on the internet from geoip blocking, add `-t <"[trusted_ips]">` to the arguments
- if your machine uses nftables, depending on the RAM capacity of the machine and the number and size of the ip lists, consider installing with the `-O performance` or `-O memory` option. This will create nft sets optimized either for performance or for low memory consumption. By default, when the machine has more than 2GiB of memory, the `performance` option is used, otherwise the `memory` option is used.
- if your distro (or you) have enabled automatic nftables/iptables rules persistence, you can disable the built-in cron-based persistence feature by adding the `-n` (for no-persistence) option when running the -install script.
- if your system has nftables installed and also a package like _xtables-compat_ (utilizing the nft_compat module) which allows to manage the nftables backend using iptables rules, you can override the geoip-shell default to utilize the nftables backend with option `-w ipt`. This will create iptables rules and ipsets for geoip-shell rather than nftables rules and sets. You will need the `ipset` utility installed for this.
- if for some reason you need to install or configure geoip-shell in strictly non-interactive mode, you can call the -install or the -manage script with the `-z` option which will avoid asking the user any questions. In non-interactive mode, commands will fail if required config is incomplete or invalid.
</details>

## **Usage**
_(Note that all commands require root privileges, so you will likely need to run them with `sudo`)_

Generally, once the installation completes, you don't have to do anything else for **inbound** geoblocking to work (if you installed via an OpenWrt ipk package, read the [OpenWrt README](/OpenWrt/README.md)).

By default, ip lists will be updated daily around 4:15am local time (to avoid everyone loading the servers at the same time, the default minute is randomized to +-5 precision at the time of initial setup and the seconds are randomized at the time of automatic update).

If you want to change geoblocking config or check geoblocking status, you can do that via the provided utilities.
A selection of options is given here, for additional options run `geoip-shell -h` or read [NOTES.md](/Documentation/NOTES.md)and [DETAILS.md](/Documentation/DETAILS.md).

**Note** that when using the `geoip-shell configure` command, if direction is not specified, direction-specific options apply to the **inbound** geoblocking direction. Direction-specific options are `-m <whitelist|blacklist|disable>`, `-c <country_codes>`, `-p <ports>`. To specify direction, add `-D <inbound|outbound>` before specifying options for that direction.

**To check current geoip blocking status:** `geoip-shell status`. For a list of all firewall rules in the main geoblocking chains and for a detailed count of ip ranges in each ip list: `geoip-shell status -v`.

**To enable and configure outbound geoblocking:**

`geoip-shell configure -D outbound -m <whitelist|blacklist>`.

**To configure geoblocking mode for both inbound and outbound directions:**

`geoip-shell configure -D inbound -m <whitelist|blacklist> -D outbound -m <whitelist|blacklist>`

**To change countries in the geoblocking whitelist/blacklist:**

`geoip-shell configure [-D <inbound|outbound>] -c <"country_codes">`

_<details><summary>Examples:</summary>_
- to set Germany and Netherlands as countries for inbound geoblocking: `geoip-shell configure -c "DE NL"`
- to set Germany and Netherlands as countries for outbound geoblocking: `geoip-shell configure -D outbound -c "DE NL"`
</details>

**To change protocols and ports geoblocking applies to:**

`geoip-shell configure [-D <inbound|outbound>] -p <[tcp|udp]:[allow|block]:[all|<ports>]>`

_(for detailed description of this feature, read [NOTES.md](/Documentation/NOTES.md), sections 9-11)_

**To enable or disable geoblocking** (only adds or removes the geoblocking enable rules, leaving all other firewall geoblocking rules and ip sets in place):

`geoip-shell <on|off>`

**To disable geoblocking, unload all ip lists and remove firewall geoblocking rules for both directions:**

`geoip-shell configure -D inbound -m disable -D outbound -m disable`

**To change ip lists source:** `geoip-shell configure -u <ripe|ipdeny>`

**To configure inbound geoblocking mode:** `geoip-shell configure -m <whitelist|blacklist>`

**To have certain trusted ip addresses or subnets bypass geoblocking:**

`geoip-shell configure -t <["ip_addresses"]|none>`

`none` removes previously set trusted ip addresses.

**To have certain LAN ip addresses or subnets bypass geoip blocking:**

`geoip-shell configure -l <["ip_addresses"]|auto|none>`

`auto` will automatically detect LAN subnets (only use this if the machine has no dedicated WAN interfaces). `none` removes previously set LAN ip addresses. This is only needed when using geoip-shell in whitelist mode, and typically only if the machine has no dedicated WAN network interfaces. Otherwise you should apply geoblocking only to those WAN interfaces, so traffic from your LAN to the machine will bypass the geoblocking filter.

**To enable or change the automatic update schedule:** `geoip-shell configure -s <"schedule_expression">`

_<details><summary>Example</summary>_

`geoip-shell configure -s "1 4 * * *"`

</details>

**To disable automatic updates of ip lists:** `geoip-shell configure -s disable`

**To update or re-install geoip-shell:** run the -install script from the (updated) distribution directory.

**To uninstall:** `geoip-shell-uninstall.sh`

On OpenWrt, if installed via an ipk package: `opkg remove <geoip-shell|geoip-shell-iptables>`

## **Pre-requisites**
(if a pre-requisite is missing, the _-install.sh_ script will tell you which)
- **Linux**. Tested on Debian-like systems and on OPENWRT, should work on any desktop/server distribution and possibly on some other embedded distributions.
- **POSIX-compliant shell**. Works on most relatively modern shells, including **bash**, **dash**, **ksh93**, **yash** and **ash** (including Busybox **ash**). Likely works on **mksh** and **lksh**. Other flavors of **ksh** may or may not work _(please let me know if you try them)_. Does **not** work on **tcsh** and **zsh**.

    **NOTE:** If the install script says that your shell is incompatible but you have another compatible shell installed, use it instead of `sh` to call the -install script. For example: `dash geoip-shell-install.sh` The shell you use to install geoip-shell will be the shell it runs in after installation. Generally prefer the simpler shells (like dash or ash) over complex shells (like bash and mksh) due to better performance.
- **nftables** - firewall management utility. Supports nftables 1.0.2 and higher (may work with earlier versions but I do not test with them).
- OR **iptables** - firewall management utility. Should work with any relatively modern version.
- for **iptables**, requires the **ipset** utility - install it using your distribution's package manager
- standard Unix utilities including **tr**, **cut**, **sort**, **wc**, **awk**, **sed**, **grep**, **pgrep**, **pidof** and **logger** which are included with every server/desktop linux distribution (and with OpenWrt). Both GNU and non-GNU versions are supported, including BusyBox implementation.
- **wget** or **curl** or **uclient-fetch** (OpenWRT-specific utility).
- for the autoupdate functionality, requires the **cron** service to be enabled. Except on OpenWrt, persistence also requires the cron service.

**Optional**: the _check-ip-in-source.sh_ optional script requires **grepcidr**. install it with `apt install grepcidr` on Debian and derivatives. For other distros, use their built-in package manager.

## **Notes**
For some helpful notes about using this suite, read [NOTES.md](/Documentation/NOTES.md).

## **In detail**
For specifics about each script, read [DETAILS.md](/Documentation/DETAILS.md).

## **OpenWrt**
For information about OpenWrt support, read the [OpenWrt README](/OpenWrt/README.md).

## **Privacy**
geoip-shell does not share your data with anyone.
If you are using the ipdeny source then note that they are a 3rd party which has its own data privacy policy.

## **P.s.**

- I would appreciate a report of whether it works or doesn't work on your system (please specify which). You can use the Github Discussions tab for that.
- If you find a bug or want to request a feature, please let me know by opening an issue.
