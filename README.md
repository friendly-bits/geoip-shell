# geoip-shell
Geoip blocker for Linux focusing on reliability, compatibility and ease of use. Utilizes the 'nftables' firewall management utility ('iptables' is supported in the legacy version of the suite). This is a continuation of the 'geoblocker-bash' project.

Should work on every modern'ish desktop/server Linux distribution, doesn't matter which hardware.

Supports ipv4 and ipv6.

## Features
_(for installation instructions, skip to the [**Installation**](#Installation) section)_

* Core functionality is creating either a whitelist or a blacklist in the firewall using automatically downloaded ip lists for user-specified countries.

* ip lists are fetched either from RIPE (regional Internet registry for Europe, the Middle East and parts of Central Asia) or from ipdeny. Both sources provide updated ip lists for all regions.

* All configuration changes required for geoip blocking to work are automatically applied to the firewall during installation.

* Implements optional (enabled by default) persistence of geoip blocking across system reboots and automatic updates of the ip lists.

**Reliability**:
- Default source for ip lists is RIPE, which allows to avoid dependency on non-official 3rd parties.
- Downloaded ip lists go through validation process, which safeguards against application of corrupted or incomplete lists to the firewall.

<details> <summary>Read more:</summary>

- All scripts perform extensive error detection and handling, so if something goes wrong, chances for bad consequences are low.
- Automatic backup of the firewall state (optional, enabled by default).
</details>

**Efficiency**:
- Optimized for low memory use
- Only performs necessary actions. For example, if a list is up-to-date and already active in the firewall, it won't be re-validated and re-applied to the firewall until the source data timestamp changes.

<details><summary>Read more:</summary>

- Creating and updating ip sets is done efficiently, so normally it takes less than a second for a very large list (depending on the CPU).
- List parsing and validation are implemented through efficient regex processing which is very quick even on slow embedded CPU's.
- Scripts are only active for a short time when invoked either directly by the user or by a cron job.

</details>

**Ease of use**:
- Installation is easy, doesn't require many complex command line arguments and normally takes a few seconds.
- Detailed installation and usage guides are provided (check the [**Installation**](#Installation) and [**Usage**](#Usage) sections)

<details><summary>Read more:</summary>

- Comes with an *uninstall script which completely removes the suite and geoip firewall rules. No restart is required.
- Sane settings are applied during installation by default, but also lots of command-line options for advanced users or for special corner cases.
- Pre-installation, provides a utility _(check-ip-in-source.sh)_ to check whether specific ip addresses you might want to blacklist or whitelist are indeed included in the list fetched from the source (RIPE or ipdeny).
- Post-installation, provides a utility (symlinked to _'geoip-shell'_) for the user to manage and change geoip config (adding or removing country codes, changing the cron schedule etc).
- Post-installation, provides a command _('geoip-shell status')_ to check geoip blocking status, which also reports if there are any issues.
- Lots of comments in the code, in case you want to change something in it or learn how the scripts are working.
- Most scripts display detailed 'usage' info when executed with the '-h' option.
- In case of an error or invalid user input, provides useful error messages to help with troubleshooting.
</details>

**Compatibility**:
- Since the project is written in shell code, is is basically compatible with everything Linux (as long as it has the pre-requisites).
- The project avoids using non-common utilities by implementing their functionality in custom shell code, which makes it faster and compatible with a wider range of systems.
</details>

## **Installation**

_Recommended to read the [NOTES.md](/NOTES.md) file._

_(Note that all commands require root privileges, so you will likely need to run them with `sudo`)_

**1)** If your system doesn't have `wget`, `curl` or (OpenWRT utility) `uclient-fetch`, install one of them using your distribution's the package manager.

**2)** Download the latest realease: https://github.com/blunderful-scripts/geoip-shell/releases

**3)** Extract all files included in the release into the same folder somewhere in your home directory and `cd` into that directory in your terminal

_<details><summary>4) Optional:</summary>_

- If intended use is whitelist and you want to install geoip-shell on a remote machine, you can run the `check-ip-in-source.sh` script before Installation to make sure that your public ip addresses are included in the fetched ip list.

_Example: (for US):_ `sh check-ip-in-source.sh -c US -i "8.8.8.8 8.8.4.4"` _(if checking multiple ip addresses, use double quotes)_

- If intended use is blacklist and you know in advance some of the ip addresses you want to block, you can use the check-ip-in-source.sh script to verify that those ip addresses are included in the fetched ip list. The syntax is the same as above.

**Note**: check-ip-in-source.sh has an additional pre-requisite: grepcidr. Install it with your distro's package manager.

</details>

**5)** run `sh geoip-shell-install -m <whitelist|blacklist> -c <"country_codes">`.
_<details><summary>Examples:</summary>_

- example (whitelist Germany and block all other countries): `sh geoip-shell-install -m whitelist -c DE`
- example (blacklist Germany and Netherlands and allow all other countries): `sh geoip-shell-install -m blacklist -c "DE NL"`

(if specifying multiple countries, use double quotes)
</details>

- **NOTE**: If your distro (or you) have enabled automatic nftables persistence, you can disable the built-in cron-based persistence feature by adding the `-n` (for no-persistence) option when running the -install script.

**6)** That's it! By default, ip lists will be updated daily at 4am local time (4 o'clock at night) - you can verify that automatic updates work by running `cat /var/log/syslog | grep geoip-shell` on the next day (change syslog path if necessary, according to the location assigned by your distro).

## **Usage**
_(Note that all commands require root privileges, so you will likely need to run them with `sudo`)_

Generally, once the installation completes, you don't have to do anything else for geoip blocking to work. But I implemented some tools to change geoip settings and check geoip blocking state.

**To check current geoip blocking status:** run `geoip-shell status`. For a list of all firewall rules in the geoip chain, run `geoip-shell status -v`.

**To add or remove ip lists for countries:** run `geoip-shell <action> [-c <"country_codes">]`

where 'action' is either `add` or `remove`.

_<details><summary>Examples:</summary>_
- example (to add ip lists for Germany and Netherlands): `geoip-shell add -c "DE NL"`
- example (to remove the ip list for Germany): `geoip-shell remove -c DE`
</details>

**To enable or disable geoip blocking:** run `geoip-shell <on|off>`

**To enable or change the autoupdate schedule**, use the `-s` option followed by the cron schedule expression in doulbe quotes:

`geoip-shell schedule -s <"cron_schdedule_expression">`

_<details><summary>Example</summary>_

`geoip-shell schedule -s "1 4 * * *"`

</details>

**To disable ip lists autoupdates**, use the '-s' option followed by the word `disable`: `geoip-shell schedule -s disable`

**To uninstall:** run `geoip-shell-uninstall`

**To switch mode (from whitelist to blacklist or the opposite):** re-install

For additional notes and recommendations for using the suite, check out the [NOTES.md](/NOTES.md) file.

For specifics about each script, read the [DETAILS.md](/DETAILS.md) file.

## **Pre-requisites**:
(if a pre-requisite is missing, the -install script will tell you which)
- Linux. Tested on Debian-like systems and occasionally on OPENWRT (support for which is not yet complete), should work on any desktop/server distribution and possibly on some embedded distributions.
- nftables - firewall management utility. Supports nftables 1.0.2 and higher (may work with earlier versions but I do not test with them).
- standard utilities including awk, sed, grep, psid which are included with every server/desktop linux distro. For embedded, may require installing a few packages that don't come by default.
- for persistence and autoupdate functionality, requires the cron service to be enabled

Additional mandatory pre-requisites: `wget` or `curl`

**Optional**: the _check-ip-in-source.sh_ script requires grepcidr. install it with `apt install grepcidr` on Debian and derivatives. For other distros, use their built-in package manager.

## **Notes**
For some helpful notes about using this suite, read [NOTES.md](/NOTES.md).

## **In detail**
For more detailed description of each script, read [DETAILS.md](/DETAILS.md).

## **Privacy**
These scripts do not share your data with anyone, as long as you downloaded them from the official source, which is
https://github.com/blunderful-scripts/geoip-shell
If you are using the ipdeny source then note that they are a 3rd party which has its own data privacy policy.

## **P.s.**

- If you like this project, please take a second to give it a star on Github. This helps other people to find it.
- I would appreciate a report of whether it works or doesn't work on your system (please specify which). You can use the Github Discussions tab for that.
- If you find a bug or want to request a feature, please let me know by opening an issue.
