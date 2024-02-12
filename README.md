# **geoip-shell**
Geoip blocker for Linux. Utilizes the **nftables** firewall management utility.

**iptables** is supported in the [iptables branch](https://github.com/blunderful-scripts/geoip-shell/tree/geoip-shell-iptables).

This is a continuation of the [**geoblocker-bash**](https://github.com/blunderful-scripts/geoblocker-bash) project. To learn what's changed, check out [this announcement](https://github.com/blunderful-scripts/geoip-shell/discussions/1).

Should work on every modern'ish desktop/server Linux distribution, doesn't matter which hardware. Supports running on a router or on a host. Supports ipv4 and ipv6.

[![image](https://github.com/blunderful-scripts/geoip-shell/assets/134004289/09073139-4cfb-4703-aa48-922939057a7e)](https://github.com/blunderful-scripts/geoip-shell/assets/134004289/2e4d21cc-a074-4ea7-8d7f-7eecbca109a4)
[![image](https://github.com/blunderful-scripts/geoip-shell/assets/134004289/be2f6046-370a-460f-94b2-327a277e0a14)](https://github.com/blunderful-scripts/geoip-shell/assets/134004289/2f81b4f4-dc07-4368-9183-193be44ec113)

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

* ip lists are fetched either from RIPE (regional Internet registry for Europe, the Middle East and parts of Central Asia) or from ipdeny. Both sources provide updated ip lists for all regions.

* All configuration changes required for geoip blocking to work are applied to the firewall during installation.

* Implements optional (enabled by default) persistence of geoip blocking across system reboots and automatic updates of the ip lists.

### **Reliability**:
- Default source for ip lists is RIPE, which allows to avoid dependency on non-official 3rd parties.
- Downloaded ip lists go through validation which safeguards against application of corrupted or incomplete lists to the firewall.
- Utilizes nftables atomic rules replacement to completely eliminate time when geoip is disabled during an autoupdate.

<details> <summary>Read more:</summary>

- All scripts perform extensive error detection and handling.
- Verifies firewall rules coherence after each action.
- Automatic backup of the firewall state (optional, enabled by default).
- Automatic recovery of the firewall in case of unexpected errors.
</details>

### **Efficiency**:
- Optimizes geoip blocking for low memory consumption or for performance, depending on user preference.
- Supports the 'ipdeny' source which provides compacted ip lists (useful for embedded devices with limited memory).
- Implements smart update of ip lists via data timestamp checks, which avoids unnecessary downloads and reconfiguration of the firewall.

<details><summary>Read more:</summary>

- List parsing and validation are implemented through efficient regex processing which is very quick even on slow embedded CPU's.
- Scripts are only active for a short time when invoked either directly by the user or by a cron job.

</details>

### **User-friendliness**:
- Installation is easy, doesn't require many complex command line arguments and normally takes a very short time.
- Extensive documentation, including detailed installation and usage guides.

<details><summary>Read more:</summary>

- To simplify the installation procedure, implements autodetection of local subnets (for hosts) and WAN interfaces (for routers).
- Comes with an *uninstall script which completely removes the suite and geoip firewall rules. No restart is required.
- Sane settings are applied during installation by default, but also lots of command-line options for advanced users or for special corner cases are provided.
- Pre-installation, provides a utility _(check-ip-in-source.sh)_ to check whether specific ip addresses you might want to blacklist or whitelist are indeed included in the list fetched from the source (RIPE or ipdeny).
- Post-installation, provides a utility (symlinked to _'geoip-shell'_) for the user to change geoip config (turn geoip on or off, add or remove country codes, change the cron schedule etc).
- Post-installation, provides a command _('geoip-shell status')_ to check geoip blocking status, which also reports if there are any issues.
- In case of an error or invalid user input, provides useful error messages to help with troubleshooting.
- Most scripts display detailed 'usage' info when executed with the '-h' option.
- The code should be fairly easy to read and includes a healthy amount of comments.
</details>

### **Compatibility**:
- Since the project is written in shell code, it is compatible with virtually every Linux system (as long as it has the pre-requisites).
- The project avoids using non-common utilities by implementing their functionality in custom shell code, which makes it faster and compatible with a wider range of systems.
</details>

## **Installation**

_(Note that all commands require root privileges, so you will likely need to run them with `sudo`)_

**0)** If geoblocker-bash is installed, uninstall it first.

**1)** If your system doesn't have `wget`, `curl` or (OpenWRT utility) `uclient-fetch`, install one of them using your distribution's package manager.

**2)** Download the latest realease: https://github.com/blunderful-scripts/geoip-shell/releases

**3)** Extract all files included in the release into the same folder somewhere in your home directory and `cd` into that directory in your terminal

**4)** run `sh geoip-shell-install.sh -m <whitelist|blacklist> -c <"country_codes">`.
_<details><summary>Examples:</summary>_

- example (whitelist Germany and block all other countries): `sh geoip-shell-install.sh -m whitelist -c DE`
- example (blacklist Germany and Netherlands and allow all other countries): `sh geoip-shell-install.sh -m blacklist -c "DE NL"`

(if specifying multiple countries, use double quotes)
</details>

- **NOTE1**: If your machine has enough memory, consider installing with the `-p` option (for "performance"). For more detailed explanation, check out (4) in [NOTES.md](/Documentation/NOTES.md). 

- **NOTE2**: If your distro (or you) have enabled automatic nftables rules persistence, you can disable the built-in cron-based persistence feature by adding the `-n` (for no-persistence) option when running the -install script.

**5)** The `-install.sh` script will ask you several questions to gather data required for correct installation, then initiate download and application of the ip lists. If you are not sure how to answer some of the questions, read [INSTALLATION.md](/Documentation/INSTALLATION.md).

**6)** That's it! By default, ip lists will be updated daily at 4:15am local time (4:15 at night) - you can verify that automatic updates are working by running `cat /var/log/syslog | grep geoip-shell` on the next day (change syslog path if necessary, according to the location assigned by your distro. on some distributions, a different command should be used, such as `logread`).

## **Pre-requisites**
(if a pre-requisite is missing, the _-install.sh_ script will tell you which)
- Linux. Tested on Debian-like systems and occasionally on OPENWRT (support for which is not yet complete), should work on any desktop/server distribution and possibly on some embedded distributions.
- nftables - firewall management utility. Supports nftables 1.0.2 and higher (may work with earlier versions but I do not test with them).
- standard utilities including tr, cut, sort, wc, awk, sed, grep, and logger which are included with every server/desktop linux distribution. For embedded, may require installing some packages if some of these utilities don't come by default.
- `wget` or `curl` or `uclient-fetch` (OpenWRT-specific utility).
- for persistence and autoupdate functionality, requires the cron service to be enabled.

**Optional**: the _check-ip-in-source.sh_ script requires grepcidr. install it with `apt install grepcidr` on Debian and derivatives. For other distros, use their built-in package manager.

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

**To enable or change the autoupdate schedule**, use the `-s` option followed by the cron schedule expression in doulbe quotes:

`geoip-shell schedule -s <"schdedule_expression">`

_<details><summary>Example</summary>_

`geoip-shell schedule -s "1 4 * * *"`

</details>

**To disable ip lists autoupdates:** `geoip-shell schedule -s disable`

**To uninstall:** run `geoip-shell-uninstall.sh`

**To switch mode (from whitelist to blacklist or the opposite):** re-install

**To change ip lists source (from RIPE to ipdeny or the opposite):** re-install

## **Notes**
For some helpful notes about using this suite, read [NOTES.md](/Documentation/NOTES.md).

## **In detail**
For specifics about each script, read [DETAILS.md](/Documentation/DETAILS.md).

## **Privacy**
These scripts do not share your data with anyone, as long as you downloaded them from the official source, which is
https://github.com/blunderful-scripts/geoip-shell
If you are using the ipdeny source then note that they are a 3rd party which has its own data privacy policy.

## **P.s.**

- If you like this project, please take a second to give it a star on Github. This helps other people to find it.
- I would appreciate a report of whether it works or doesn't work on your system (please specify which). You can use the Github Discussions tab for that.
- If you find a bug or want to request a feature, please let me know by opening an issue.
