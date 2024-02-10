# geoip-shell
Geoip blocker for Linux focusing on reliability, compatibility and ease of use. Utilizes the 'iptables' firewall management utility. nftables support will get implemented eventually.

Should work on every modern'ish desktop/server Linux distribution, doesn't matter which hardware. Works on embedded, as long as it has the pre-requisites.

Supports ipv4 and ipv6.
 
## Features
_(for installation instructions, skip to the [**Installation**](#Installation) section)_

* Core functionality is automatic download of ip lists for user-specified countries, then using these lists to create either a whitelist or a blacklist (selected during installation) in the firewall.

* ip lists are fetched either from RIPE (regional Internet registry for Europe, the Middle East and parts of Central Asia) or from ipdeny. Both sources provide updated ip lists for all regions.

* All configuration changes required for geoip blocking to work are automatically applied to the firewall during installation.

* Implements optional (enabled by default) persistence of geoip blocking across system reboots and automatic updates of the ip lists.

**Reliability**:
- Default source for ip lists is RIPE, which allows to avoid dependency on non-official 3rd parties.
- Downloaded ip lists go through validation process, which safeguards against application of corrupted or incomplete lists to the firewall.

<details> <summary>Read more:</summary>

- All scripts perform extensive error detection and handling, so if something goes wrong, chances for bad consequences are rather low.
- Automatic backup of the firewall state before any changes or updates (optional, enabled by default).
- The *backup script also has a restore command. In case an error occurs while applying changes to the firewall (which normally should never happen), or if you mess something up in the firewall, you can use it to restore the firewall to its previous state.
</details>

**Efficiency**:
- When creating whitelists/blacklists, utilizes the 'ipset' utility , which makes the firewall much more efficient than applying a large amount of individual rules. This way the load on the CPU is minimal when the firewall is processing incoming connection requests.

<details><summary>Read more:</summary>
  
- When creating new ipsets, calculates optimized ipset parameters in order to maximize performance and minimize memory consumption.
- Creating new ipsets is done efficiently, so normally it takes less than a second for a very large list (depending on the CPU of course).
- Only performs necessary actions. For example, if a list is up-to-date and already active in the firewall, it won't be re-validated and re-applied to the firewall until the source data timestamp changes.
- List parsing and validation are implemented through efficient regex processing which is very quick even on slow embedded CPU's.
- Scripts are only active for a short time when invoked either directly by the user or by a cron job (once after a reboot and then periodically for an auto-update - both cron jobs are optional and enabled by default).

</details>

**Ease of use**:
- Detailed installation and usage guides are provided (check the [**Installation**](#Installation) and [**Usage**](#Usage) sections)
- Installation is easy, doesn't require many complex command line arguments and normally takes a few seconds.
- After installation, geoip blocking will be active for the specified countries and you don't have to do anything else for it to work.

<details><summary>Read more:</summary>

- Has only 1 non-standard dependency (_ipset_) which should be available from any modern'ish Linux distribution's package manager.
- Comes with an *uninstall script. It completely removes the suite, removes geoip firewall rules and restores pre-install firewall policies. No restart is required.
- Sane settings are applied during installation by default, but also lots of command-line options for advanced users or for special corner cases.
- Pre-installation, provides a utility _(check-ip-in-source.sh)_ to check whether specific ip addresses you might want to blacklist or whitelist are indeed included in the list fetched from the source (RIPE or ipdeny).
- Post-installation, provides a utility (symlinked to _'geoip-shell'_) for the user to manage and change geoip config (adding or removing country codes, changing the cron schedule etc).
- Post-installation, provides a command _('geoip-shell status')_ to check geoip blocking status, which also reports if there are any issues.
- All that is well documented, read **INSTALLAION**, **NOTES** and **DETAILS** sections for more info.
- Lots of comments in the code, in case you want to change something in it or learn how the scripts are working.
- Besides extensive documentation, each script displays detailed 'usage' info when executed with the '-h' option.
- Checks all user input for sanity and if the input doesn't make sense, tells you why.
</details>

**Compatibility**:
- Since the project is written in shell code, the suite is basically compatible with everything Linux (as long as it has the pre-requisites)
<details> <summary>Read more:</summary>
 
- I paid much attention to compatibility with typical Unix utilities, so the scripts should work even with embedded distributions.
- That said, embedded hardware-oriented distributions may be missing some required utilities.
- Some (mostly commercial) distros have their own firewall management utilities and even implement their own firewall persistence across reboots. The suite should work on these, too, provided they use iptables as the back-end, but you probably should disable the cron-based persistence solution (more info in the [Pre-requisites](#Pre-requisites) section).
- Scripts check for dependencies before running, so if you are missing some, the scripts just won't run at all.
</details>

## **Installation**

_Recommended to read the [NOTES.md](/NOTES.md) file._

**To install:**

**1)** Install pre-requisites. Use your distro's package manager to install ```ipset``` (also needs ```wget``` or ```curl``` but you probably have one of these installed already). For examples for most popular distros, check out the [Pre-requisites](#Pre-requisites) section.

**2)** Download the latest realease: https://github.com/blunderful-scripts/geoip-shell/releases

**3)** Extract all files included in the release into the same folder somewhere in your home directory and ```cd``` into that directory in your terminal

_<details><summary>4) Optional:</summary>_

- If intended use is whitelist and you want to install geoip-shell on a **remote** machine, you can run the ```check-ip-in-source.sh``` script before Installation to make sure that your public ip addresses are included in the fetched ip list.

_Example: (for US):_ ```sh check-ip-in-source.sh -c US -i "8.8.8.8 8.8.4.4"``` _(if checking multiple ip addresses, use double quotes)_

- If intended use is blacklist and you know in advance some of the ip addresses you want to block, you can use the check-ip-in-source.sh script to verify that those ip addresses are included in the fetched ip list. The syntax is the same as above.

**Note**: check-ip-in-source.sh has an additional pre-requisite: grepcidr. Install it with your distro's package manager.

</details>

**5)** run ```sudo sh geoip-shell-install -m <whitelist|blacklist> -c <"country_codes">```. The *install script will gracefully fail if it detects that you are missing some pre-requisites and tell you which.
_<details><summary>Examples:</summary>_

- example (whitelist Germany and block all other countries): ```sudo sh geoip-shell-install -m whitelist -c DE```
- example (blacklist Germany and Netherlands and allow all other countries): ```sudo sh geoip-shell-install -m blacklist -c "DE NL"```

(when specifying multiple countries, put the list in double quotes)
</details>

- **NOTE**: If your distro (or you) have enabled automatic iptables and ipsets persistence, you can disable the built-in cron-based persistence feature by adding the ```-n``` (for no-persistence) option when running the -install script.

**6)** That's it! By default, ip lists will be updated daily at 4am local time (4 o'clock at night) - you can verify that automatic updates work by running ```sudo cat /var/log/syslog | grep geoip-shell``` on the next day (change syslog path if necessary, according to the location assigned by your distro).

## **Usage**
Generally, once the installation completes, you don't have to do anything else for geoip blocking to work. But I implemented some tools to change geoip settings and check geoip blocking state.

**To check current geoip blocking status:** run ```sudo geoip-shell status```

**To add or remove ip lists for countries:** run ```sudo geoip-shell <action> [-c <"country_codes">]```

where 'action' is either ```add``` or ```remove```.

_<details><summary>Examples:</summary>_
- example (to add ip lists for Germany and Netherlands): ```sudo geoip-shell add -c "DE NL"```
- example (to remove the ip list for Germany): ```sudo geoip-shell remove -c DE```
</details>

 **To enable or change the autoupdate schedule**, use the ```-s``` option followed by the cron schedule expression in doulbe quotes:

```sudo geoip-shell schedule -s <"cron_schdedule_expression">```

 _<details><summary>Example</summary>_

```sudo geoip-shell schedule -s "1 4 * * *"```

</details>

**To disable ip lists autoupdates**, use the '-s' option followed by the word ```disable```: ```sudo geoip-shell schedule -s disable```
 
**To uninstall:** run ```sudo geoip-shell-uninstall```

**To switch mode (from whitelist to blacklist or the opposite):** simply re-install

For additional notes and recommendations for using the suite, check out the [NOTES.md](/NOTES.md) file.

For specifics about each script, read the [DETAILS.md](/DETAILS.md) file.

## **Pre-requisites**:
(if a pre-requisite is missing, the -install script will tell you which)
- Linux. Tested on Debian-like systems and occasionally on OPENWRT (support for which is not yet complete), should work on any desktop/server distribution and possibly on some embedded distributions (please let me know if you have a particular one you want to use it on).
- iptables - firewall management utility (nftables support will likely get implemented later)
- standard utilities including awk, sed, grep, psid which are included with every server/desktop linux distro. For embedded, may require installing a couple of packages that don't come by default.
- for persistence and autoupdate functionality, requires the cron service to be enabled

additional mandatory pre-requisites: ```ipset``` (also needs ```wget``` or ```curl``` but you probably have one of these installed already)

_<details><summary>Examples for popular distributions</summary>_

**Debian, Ubuntu, Linux Mint** and any other Debian/Ubuntu derivative: ```sudo apt install ipset```

**Arch**: (you need to have the Extra repository enabled) ```sudo pacman -S ipset```

**Fedora**: ```sudo dnf -y install ipset```

**OpenSUSE**: you may (?) need to add repositories to install ipset as explained here:
https://software.opensuse.org/download/package?package=ipset&project=security%3Anetfilter

then run ```sudo zypper install ipset```

(if you have verified information, please le me know)

**RHEL/CentOS**: install ipset with ```sudo yum install ipset```. If using a specialized firewall management utility such as 'scf', you would probably want to disable the suite's cron-based persistence feature.

</details>


**Optional**: the _check-ip-in-source.sh_ script requires grepcidr. install it with ```sudo apt install grepcidr``` on Debian and derivatives. For other distros, use their built-in package manager.

## **Notes**
For some helpful notes about using this suite, read [NOTES.md](/NOTES.md).

## **In detail**
For more detailed description of each script, read [DETAILS.md](/DETAILS.md).

## **Privacy**
These scripts do not share your data with anyone, as long as you downloaded them from the official source, which is
https://github.com/blunderful-scripts/geoip-shell
That said, if you are using the ipdeny source then note that they are a 3rd party which has its own data privacy policy.

## **P.s.**

- If you use and like this project, please consider giving it a star on Github. This helps other people to find it.
- I would appreciate a report of whether it works or doesn't work on your system (please specify which). You can use the Github Discussions tab for that.
- If you find a bug or want to request a feature, please let me know by opening an issue.
