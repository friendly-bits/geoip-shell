# **geoip-shell**
User-friendly and versatile geoblocker for Linux. Supports both **nftables** and **iptables** firewall management utilities.

The idea of this project is making geoblocking (i.e. restricting access from or to Internet addresses based on geolocation) easy on (almost) any Linux system, no matter which hardware, including desktop, server, container, VPS or router, while also being reliable and providing flexible configuration options for the advanced users.

If you find this project useful, please take a second to give it a star on Github. This helps other people to find it.

[![image](https://github.com/friendly-bits/geoip-shell/assets/134004289/e1a70e9d-a0eb-407b-9372-ddcbe6134d88)](https://github.com/friendly-bits/geoip-shell/assets/134004289/24010da9-a62a-428f-ae4d-cb1d4ae97f73)
[![image](https://github.com/friendly-bits/geoip-shell/assets/134004289/ef622182-a6cf-49ff-9bed-64fc29653255)](https://github.com/friendly-bits/geoip-shell/assets/134004289/b35e199f-465d-487c-809b-9c5a8f0644be)


## Table of contents
- [Main Features](#main-features)
- [Installation](#installation)
- [Usage](#usage)
- [Outbound geoblocking](#outbound-geoblocking)
- [Local allowlists and blocklists](#local-allowlists-and-blocklists)
- [Pre-requisites](#pre-requisites)
- [Notes](#notes)
- [In detail](#in-detail)
- [OpenWrt](#openwrt)
- [Privacy](#privacy)
- [P.s.](#ps)

## **Main Features**
* Core functionality is creating either a whitelist or a blacklist in the firewall using automatically downloaded IP lists for user-specified countries.

* IP lists are fetched either from **RIPE** (regional Internet registry for Europe, the Middle East and parts of Central Asia) or from **ipdeny**, or from **MaxMind**. All 3 sources provide updated IP lists for all regions.

* All firewall rules and IP sets required for geoblocking to work are created automatically during the initial setup.

* Supports automated interactive setup for easy configuration.

* Automates creating auxiliary firewall rules based on user's preferences (for example, when configuring on a host in whitelist mode, geoip-shell will detect LAN subnets and suggest to add them to the whitelist)

* Implements optional (enabled by default) persistence of geoblocking across system reboots and automatic updates of the IP lists.

* After installation, a utility is provided to check geoblocking status and firewall rules or change country codes and geoblocking-related config.

* Supports inbound and outbound geoblocking.

* Supports ipv4 and ipv6.

* Supports running on OpenWrt.

### **Reliability**:
- Downloaded IP lists go through validation which safeguards against application of corrupted or incomplete lists to the firewall.

<details> <summary>Read more:</summary>

- Default source for IP lists is RIPE, which allows to avoid dependency on non-official 3rd parties.
- Supports the 'MaxMind' commercial source which provides more accurate IP lists, both the free GeoLite2 database and the paid GeoIP2 database. Note that in order to use the MaxMind source, you need to have a MaxMind account.
- With nftables, utilizes nftables atomic rules replacement to make the interaction with the system firewall fault-tolerant and to completely eliminate time when geoip is disabled during an automatic update.
- All scripts perform extensive error detection and handling.
- All user input is validated to reduce the chance of accidental mistakes.
- Verifies firewall rules coherence after each action.
- Automatic backup of geoip-shell state (optional, enabled by default except on OpenWrt).
- Automatic recovery of geoip-shell firewall rules after a reboot (a.k.a persistence) or in case of unexpected errors.
- Supports specifying trusted IP addresses anywhere on the Internet which will bypass geoip blocking to make it easier to regain access to the machine if something goes wrong.
</details>

### **Efficiency**:
- Utilizes the native nftables sets (or, with iptables, the ipset utility) which allows to create efficient firewall rules with thousands of IP ranges.

<details><summary>Read more:</summary>

- With nftables, optimizes geoblocking for low memory consumption or for performance, depending on the RAM capacity of the machine and on user preference. With iptables, automatic optimization is implemented.
- IP list parsing and validation are implemented through efficient regex processing which is very quick even on slow embedded CPU's.
- Implements smart update of IP lists via data timestamp checks, which avoids unnecessary downloads and reconfiguration of the firewall.
- For inbound geoblocking, uses the "prerouting" hook in kernel's netfilter component which shortens the path unwanted packets travel in the system and may reduce the CPU load if any additional firewall rules process incoming traffic down the line.
- Supports the 'ipdeny' source which provides aggregated IP lists (useful for embedded devices with limited memory).
- Scripts are only active for a short time when invoked either directly by the user or by the init script/reboot cron job/update cron job.

</details>

### **User-friendliness**:
- Installation and initial setup are easy and normally take a very short time.
- Good command line interface and useful console messages.

<details><summary>Read more:</summary>

- Extensive and (usually) up-to-date documentation.
- Comes with an uninstall script which completely removes the suite and the geoblocking firewall rules. No restart is required.
- Sane settings are applied during installation by default, but also lots of command-line options for advanced users or for special corner cases are provided.
- Pre-installation, provides a utility _(check-ip-in-source.sh)_ to check whether specific IP addresses you might want to blacklist or whitelist are indeed included in the IP lists fetched from the source (RIPE or ipdeny or MaxMind).
- Post-installation, provides a utility (symlinked to _'geoip-shell'_) for the user to change geoblocking config (turn geoblocking on or off, configure outbound geoblocking, change country codes, change geoblocking mode, change IP lists source, change the cron schedule etc).
- Post-installation, provides a command _('geoip-shell status')_ to check geoblocking status, which also reports if there are any issues.
- In case of an error or invalid user input, provides useful error messages to help with troubleshooting.
- All main scripts display detailed 'usage' info when executed with the '-h' option.
- Most of the code should be fairly easy to read and includes a healthy amount of comments.
</details>

### **Compatibility**:
- Since the project is written in POSIX-compliant shell code, it is compatible with virtually every Linux system (as long as it has the [pre-requisites](#pre-requisites)). It even works well on simple embedded routers with 8MB of flash storage and 128MB of memory (for nftables, 256MB is recommended if using large IP lists such as the one for US until the nftables team releases a fix reducing memory consumption).
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
  
  - to extract, run: `tar -zxvf geoip-shell.tar.gz`
  </details>

**3)** Extract all files included in the release into the same folder somewhere in your home directory and `cd` into that directory in your terminal.

**4)** For installation followed by interactive setup, run `sh geoip-shell-install.sh`. For non-interactive installation, run `sh geoip-shell-install.sh -z`.

  **NOTE:** If the install script says that your shell is incompatible but you have another compatible shell installed, use it instead of `sh` to call the -install script. For example: `dash geoip-shell-install.sh`. Check out [Pre-Requisites](#pre-requisites) for a list of compatible shells. If you don't have one of these installed, use your package manager to install one (you don't need to make it your default shell).

**5)** Unless you installed in non-interactive mode, the install script will suggest you to configure geoip-shell. If you type in `y`, geoip-shell will ask you several questions, then initiate download and application of the IP lists.


## **Initial setup**
Once the installation completes, the installer will suggest to automatically start the interactive setup. If you ran the install script non-interactively or interrupted the setup at some point, you can manually (re)start interactive setup by running `geoip-shell configure`.

Interactive setup gathers the important config via dialog with the user and does not require any command line arguments. If you are not sure how to answer some of the questions, read [SETUP.md](/Documentation/SETUP.md).

Alternatively, some or all of the config options may be provided via command-line arguments.

**NOTE:** Some features are only accessible via command-line arguments. In particular, by default, initial setup only configures inbound geoblocking and leaves outbound geoblocking in disabled state. If you want to configure outbound geoblocking, read the section [Outbound geoblocking](#outbound-geoblocking).

_To find out more, run `geoip-shell -h` or read [NOTES.md](/Documentation/NOTES.md) and [DETAILS.md](/Documentation/DETAILS.md)_

## **Usage**
_(Note that all commands require root privileges, so you will likely need to run them with `sudo`)_

Generally, once the installation completes, you don't have to do anything else for **inbound** geoblocking to work (if you installed via an OpenWrt ipk package, read the [OpenWrt README](/OpenWrt/README.md)).

By default, IP lists will be updated daily around 4:15am local time (to avoid everyone loading the servers at the same time, the default minute is randomized to +-5 precision at the time of initial setup and the seconds are randomized at the time of automatic update).

If you want to change geoblocking config or check geoblocking status, you can do that via the provided utilities.
A selection of options is given here, for additional options run `geoip-shell -h` or read [NOTES.md](/Documentation/NOTES.md) and [DETAILS.md](/Documentation/DETAILS.md).

**Note** that when using the `geoip-shell configure` command, if direction is not specified, direction-specific options apply to **inbound** geoblocking. Direction-specific options are `-m <whitelist|blacklist|disable>`, `-c <country_codes>`, `-p <ports>`. To specify direction, add `-D <inbound|outbound>` before specifying options for that direction (for more details, read the section [Outbound geoblocking](#outbound-geoblocking)).


**To check current geoip blocking status:** `geoip-shell status`. For a list of all firewall rules in the main geoblocking chains and for a detailed count of IP ranges in each IP list: `geoip-shell status -v`.

**To configure geoblocking mode:**

`geoip-shell configure -m <whitelist|blacklist|disable>`

(`disable` unloads all IP lists and removes firewall geoblocking rules for given direction)

**To change countries in the geoblocking whitelist/blacklist:**

`geoip-shell configure -c <"country_codes">`

The `-c` option accepts any combination of valid 2-letter country codes and/or region codes (RIPE, ARIN, APNIC, AFRINIC, LACNIC).

_<details><summary>Example:</summary>_
- to set countries to Germany and Netherlands: `geoip-shell configure -c "DE NL"`
</details>

**To geoblock or allow specific ports or ports ranges:**

`geoip-shell configure -p <[tcp|udp]:[allow|block]:[all|<ports>]>`

_(for detailed description of this feature, read [NOTES.md](/Documentation/NOTES.md), sections 10-12)_

**To enable or disable geoblocking** (only adds or removes the geoblocking enable rules, leaving all other firewall geoblocking rules and IP sets in place):

`geoip-shell <on|off>`

**To change IP lists source:** `geoip-shell configure -u <ripe|ipdeny|maxmind>`

**To have certain trusted IP addresses or subnets, either in your LAN or anywhere on the Internet, bypass geoblocking:**

`geoip-shell configure -t <["ip_addresses"]|none>`

`none` removes previously set trusted IP addresses.

**To have certain LAN IP addresses or subnets bypass geoip blocking:**

`geoip-shell configure -l <["ip_addresses"]|auto|none>`

LAN addresses can only be configured when geoblocking mode for at least one direction is set to `whitelist`. Otherwise there is no need to whitelist LAN addresses. Also whitelisting LAN addresses is typically only needed if the machine has no dedicated WAN network interfaces. Otherwise you should apply geoblocking only to those WAN interfaces, so traffic from your LAN to the machine will bypass the geoblocking filter without any special rules for that.

`auto` will automatically detect LAN subnets (only use this if the machine has no dedicated WAN interfaces). `none` removes previously set LAN IP addresses.

**To check whether certain IP addresses belong to any of the IP sets loaded by geoip-shell:**

`geoip-shell lookup [-I <"ip_addresses">] [-F <path_to_file>] [-v]`

For detailed description of this feature, run `geoip-shell -h` or read [DETAILS.md](/Documentation/DETAILS.md).

**To enable or change the automatic update schedule:** `geoip-shell configure -s <"schedule_expression">`

_<details><summary>Example</summary>_

`geoip-shell configure -s "1 4 * * *"`

</details>

**To disable automatic updates of IP lists:** `geoip-shell configure -s disable`

**To update or re-install geoip-shell:** run the -install script from the (updated) distribution directory.

**To temporarily stop geoip-shell:** `geoip-shell stop`. This will kill any running geoip-shell processes, remove geoip-shell firewall rules and unload IP sets. To reactivate geoblocking, run `geoip-shell configure`.

**To uninstall:** `geoip-shell-uninstall.sh`

On OpenWrt, if installed via an ipk package: `opkg remove <geoip-shell|geoip-shell-iptables>`. For apk package: `apk del geoip-shell`.

**To set up reports of success or failure:**
<details>

geoip-shell supports specifying a custom shell script which defines any or both functions `gs_success`, `gs_failure` to be called on success or failure when geoip-shell is running automatically, eg after reboot or during automatic IP lists updates. This feature can be used to eg send an email/SMS/msg.

You can implement functions `gs_success` and/or `gs_failure` as you like. When calling `gs_failure`, geoip-shell will provide session log collected during the run as the first argument. When calling `gs_success`, geoip-shell will not provide session log, unless errors or warnings were encountered.

Example below for free Brevo (formerly sendinblue) email service, but use your favourite smtp/email/SMS etc method.

1. Install mailsend
2. Sign up for free Brevo account (not affiliated!)
3. Create file `/usr/libexec/geoip-shell_custom-script.sh` (you can use any other suitable path) - replace variables in CAPITALS below with your specific details:

```sh
#!/bin/sh

gs_success()
{
	mailbody="${1}"
	mailsend -port 587 -smtp smtp-relay.brevo.com -auth -f FROM@EMAIL.COM -t TO@EMAIL.COM -user BREVO@USERNAME.COM -pass PASSWORD -sub "geoip-shell automatic run successful" -M "${mailbody}"
}

gs_failure()
{
	mailbody="${1}"
	mailsend -port 587 -smtp smtp-relay.brevo.com -auth -f FROM@EMAIL.COM -t TO@EMAIL.COM -user BREVO@USERNAME.COM -pass PASSWORD -sub "geoip-shell automatic run failed" -M "${mailbody}"
}
```

- the Brevo password is supplied within their website, not the one created on sign-up.
- If copy-pasting from Windows, avoid copy-pasting Windows-style newlines. To make sure, in Windows use a text editor which supports changing newline style (such as Notepad++) and make sure it is set to Unix (LF), rather than Windows (CR LF).

4. Make sure to set permissions for the custom script, eg `chmod 640 "<custom_script_path>" && chown root:root "<custom_script_path>"`
5. Configure the custom script in geoip-shell:

```
geoip-shell configure -S "<custom_script_path>"
```

6. To test calling the custom script:
```
geoip-shell-run.sh update -a
```

To disable calling the custom script:
```
geoip-shell configure -S none
```
</details>

**Examples of using the `configure` command:**
<details>

- configuring **inbound** geoblocking on a server located in Germany, which has nftables and is behind a firewall (no direct WAN connection), whitelist Germany and Italy and block all other countries:

`geoip-shell configure -r DE -i all -l auto -m whitelist -c "DE IT"`

- configuring **inbound** geoblocking on a router (which has a WAN network interface called `pppoe-wan`) located in the US, blacklist Germany and Netherlands and allow all other countries:

`geoip-shell configure -m blacklist -c "DE NL" -r US -i pppoe-wan`

</details>


## **Outbound geoblocking**

When using the `geoip-shell configure` command, if direction is not specified, direction-specific options apply to the **inbound** geoblocking direction.

Direction-specific options are `-m <whitelist|blacklist|disable>`, `-c <country_codes>`, `-p <ports>`. To specify direction, add `-D <inbound|outbound>` before specifying options for that direction.

So to configure outbound geoblocking, use same commands as described in the [Usage](#usage) section above, except add the `-D outbound` option before any direction-specific options.

Examples:

**To enable and configure outbound geoblocking:**

`geoip-shell configure -D outbound -m <whitelist|blacklist>`.

**To configure geoblocking mode for both inbound and outbound directions:**

`geoip-shell configure -D inbound -m <whitelist|blacklist> -D outbound -m <whitelist|blacklist>`

To configure **inbound and outbound** geoblocking, whitelisting Germany and Italy and blocking all other countries for incoming traffic, blacklisting France for outgoing traffic:

`geoip-shell configure -D inbound -m whitelist -c "DE IT" -D outbound -m blacklist -c FR`

**To change protocols and ports outbound geoblocking applies to:**

`geoip-shell configure -D outbound -p <[tcp|udp]:[allow|block]:[all|<ports>]>`

## **Local allowlists and blocklists**
geoip-shell supports importing custom newline-separated IP lists into locally stored files. These files are then used to create additional allow or block rules. Rules for local IP lists will be created regardless of whether geoblocking mode is whitelist or blacklist, and for any enabled geoblocking direction (inbound or outbound or both).

To import a custom IP list, use this command:

`geoip-shell configure [-A|-B] <"[path_to_file]"|remove>`

Use `-A` to import the IP list as allowlist. Use `-B` to import the IP list as blocklist.

The `remove` keyword tells geoip-shell to remove any existing local iplists of the specified type (allowlist or blocklist).

Each IP list file can contain IP addresses and/or IP ranges (in CIDR format) of one family (ipv4 or ipv6).
_<details><summary>Example source file contents</summary>_
```
8.8.8.8
1.1.1.1/24
```
</details>

_<details><summary>Example command</summary>_
`geoip-shell configure -A /tmp/my-ip-list.txt` - This will import specified file as an allowlist.
</details>

You can sequentially import multiple IP lists and geoip-shell will add IP addresses from each file to locally stored IP lists.

**NOTE** that blocklist rules take precedence over allowlist rules. So if same IP address is included both in a local allowlist and in a local blocklist, it will be blocked.

**NOTE** that when importing custom IP lists, geoip-shell creates local allow- and blocklist files in `/etc/geoip-shell/local_iplists/` on OpenWrt, or in `/var/lib/geoip-shell/local_iplists/` on all other systems. The original files used to import the IP lists can be deleted after they are imported to free up space. To change the directory where imported local IP lists are stored, use the command `geoip-shell configure -L <path>`.

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
- for the MaxMind source, requires the utilities: `unzip`, `gzip`, `gunzip` (`apt install unzip gzip`)

**Optional**: the _check-ip-in-source.sh_ optional script requires **grepcidr**. install it with `apt install grepcidr` on Debian and derivatives. For other distros, use their built-in package manager.

## **Notes**
For some helpful notes about using this suite, read [NOTES.md](/Documentation/NOTES.md).

## **In detail**
For specifics about each script, read [DETAILS.md](/Documentation/DETAILS.md).

## **OpenWrt**
For information about OpenWrt support, read the [OpenWrt README](/OpenWrt/README.md).

## **Privacy**
geoip-shell does not share your data with anyone.
If you are using the ipdeny or the maxmind source then note that they are a 3rd party which has its own data privacy policy.

## **P.s.**

- I would appreciate a report of whether it works or doesn't work on your system (please specify which). You can use the Github Discussions tab for that.
- If you find a bug or want to request a feature, please let me know by opening an issue.
