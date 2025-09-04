## geoip-shell on OpenWrt

Currently geoip-shell fully supports OpenWrt, both with firewall3 and with firewall4, both iptables and nftables, while providing the same user interface and features as on any other Linux system. So usage is the same as described in the main [README.md](/README.md) file, while some parts of the backend (namely persistence implementation), some defaults and the location of the data directory are different.

Installation is possible either via the -install script (as described in the main [README.md](/README.md)), or via a package. 

geoip-shell packages come in 2 flavors: _geoip-shell_ (for OpenWrt systems with nftables) and _geoip-shell-iptables_ (for OpenWrt systems with iptables).

## Download the latest OpenWrt package via the command line
First, connect to you device [via SSH](https://openwrt.org/docs/guide-quick-start/sshadministration).

Next, select the appropriate option below, copy the code and paste in your terminal, then press Enter. The package will be downloaded to `/tmp/`.

<details><summary>IPK for OpenWrt with nftables:</summary>

```
link="$(uclient-fetch https://api.github.com/repos/friendly-bits/geoip-shell/releases -O - | sed 's/\\r//g;s/\\n/\n/g' | grep -m1 -oE 'https://github.com/friendly-bits/geoip-shell/releases/download/v[0-9.]+/geoip-shell_[0-9.]+-r[0-9]+\.ipk')"; \
filename="${link##*/}"; \
if [ -n "$filename" ] && cd /tmp/ && uclient-fetch -O "$filename" "$link"; then echo "File saved as '$filename'."; else echo "Fetch failed. Please download geoip-shell manually."; fi
```
</details>

<details><summary>IPK for OpenWrt with iptables:</summary>

```
link="$(uclient-fetch https://api.github.com/repos/friendly-bits/geoip-shell/releases -O - | sed 's/\\r//g;s/\\n/\n/g' | grep -m1 -oE 'https://github.com/friendly-bits/geoip-shell/releases/download/v[0-9.]+/geoip-shell-iptables_[0-9.]+-r[0-9]+\.ipk')"; \
filename="${link##*/}"; \
if [ -n "$filename" ] && cd /tmp/ && uclient-fetch -O "$filename" "$link"; then echo "File saved as '$filename'."; else echo "Fetch failed. Please download geoip-shell manually."; fi
```
</details>

<details><summary>APK package for OpenWrt with nftables - for OpenWrt snapshots:</summary>

```
link="$(uclient-fetch https://api.github.com/repos/friendly-bits/geoip-shell/releases -O - | sed 's/\\r//g;s/\\n/\n/g' | grep -m1 -oE 'https://github.com/friendly-bits/geoip-shell/releases/download/v[0-9.]+/geoip-shell_[0-9.]+-r[0-9]+\.apk')"; \
filename="${link##*/}"; \
if [ -n "$filename" ] && cd /tmp/ && uclient-fetch -O "$filename" "$link"; then echo "File saved as '$filename'."; else echo "Fetch failed. Please download geoip-shell manually."; fi
```

</details>

<details><summary>APK package for OpenWrt with iptables - for OpenWrt snapshots:</summary>

```
link="$(uclient-fetch https://api.github.com/repos/friendly-bits/geoip-shell/releases -O - | sed 's/\\r//g;s/\\n/\n/g' | grep -m1 -oE 'https://github.com/friendly-bits/geoip-shell/releases/download/v[0-9.]+/geoip-shell-iptables_[0-9.]+-r[0-9]+\.apk')"; \
filename="${link##*/}"; \
if [ -n "$filename" ] && cd /tmp/ && uclient-fetch -O "$filename" "$link"; then echo "File saved as '$filename'."; else echo "Fetch failed. Please download geoip-shell manually."; fi
```

</details>

## Install the package
<details><summary>IPK packages</summary>

```
opkg install <file_name>
```
</details>

<details><summary>APK packages</summary>

```
apk --allow-untrusted add <file_name>
```
The `allow-untrusted` option is required because this package doesn't come from the official OpenWrt repository.
</details>

## LuCi interface
A LuCi interface has not been implemented (yet). As on any other Linux system, all geoip-shell user interface is provided via the command line (but my goal is to make this an easy experience). Contributions are welcome, and if you are interested in implementing a LuCi interface for geoip-shell, please get in touch.

## Usage after installation via a package
After installing the package, geoip-shell will be inactive until you configure it. To do so, run `geoip-shell configure` and follow the interactive setup. You can also run `geoip-shell -h` before that to find out about configuration options and then append certain options after the `configure` action, for example: `geoip-shell configure -c "de nl" -m whitelist` to configure geoip-shell in whitelist mode for countries Germany and Netherlands. The interactive setup will ask you about all the important options but some options are only available non-interactively (for example outbound geoblocking, or configuring geoblocking for certain selection of ports). You can always change these settings after initial configuration via the same `geoip-shell configure` command. Make sure to read the main [README.md](/README.md) for more information and examples.

## Uninstallation of geoip-shell if installed via ipk or apk
- For nftables-based systems: `opkg remove geoip-shell` (or `apk del geoip-shell` for current snapshots)
- For iptables-based systems: `opkg remove geoip-shell-iptables`

## Resources management on OpenWrt
Because OpenWrt typically runs on embedded devices with limited memory and very small flash storage, geoip-shell implements some techniques to conserve these resources as much as possible:
- During installation on OpenWrt via the install script, comments and the debug code are stripped from the scripts to reduce their size. The packages already come with comments and debug removed.
- Only the required modules are installed, depending on the system (iptables- or nftables- based).
- I've researched the most memory-efficient way for loading IP lists into nftables sets. Currently, nftables has some bugs related to this process which may cause unnecessarily high memory consumption. geoip-shell works around these bugs as much as possible.
- To avoid unnecessary flash storage wear, all filesystem-related tasks geoip-shell does which do not require permanent storage are done in the /tmp directory which in the typical OpenWrt installation is mounted on the ramdisk. Besides the scripts, by default geoip-shell only stores a tiny config file in permanent storage and that config file gets overwritten only when you change the config.
- Some defaults on OpenWrt are different to further minimize flash storage wear (read below).

### Scripts size
Typical geoip-shell installation on an OpenWrt system currently consumes around 170KiB. The distribution folder itself weighs quite a bit more (mainly because of documentation) but you can install via a package which doesn't remain in storage after installation, or if installing via the -install script, delete the distribution folder and free up space taken by it. geoip-shell does not install its documentation into the system.

To view all installed geoip-shell scripts in your system, run `ls -lh /usr/bin/geoip-shell-* /usr/lib/geoip-shell/* /etc/geoip-shell/*`.

To calculate total installed size, run

```
ls -l /usr/bin/geoip-shell-* /usr/lib/geoip-shell/* /etc/geoip-shell/* /etc/init.d/geoip-shell-init | awk '{s=s+$5} END{print "Installed geoip-shell size: " s/1024 " KiB"}'
```

## Persistence on OpenWrt
- Persistence of geoip firewall rules and IP sets works differenetly on OpenWrt than on other Linuxes, since geoip-shell has an OpenWrt-specific procd init script.
- The cron job which implements persistence on other Linuxes and runs at reboot is not created on OpenWrt.
- geoip-shell integrates into firewall3 or firewall4 via what's called a "firewall include". On OpenWrt, a firewall include is a setting which tells firewall3 or firewall4 to do something specific in response to certain events.
- The only task of the init script for geoip-shell is to call the geoip-shell-mk-fw-include.sh script, which makes sure that the firewall include exists and is correct, if not then creates the include.
- The firewall include is what does the actual persistence work. geoip-shell firewall include triggers on firewall reload (which happens either at reboot or when the system decides that a reload of the firewall is necessary, or when initiated by the user).
- When triggered, the include script calls the -run script with the "restore" action.
- The -run script verifies that geoip nftables/iptables rules and IP sets exist, and if not then it restores them from backup, or (if backup doesn't exist) initiates re-fetch of the IP lists and then re-creates the rules and the IP sets.
- By default, geoip-shell does not create backups on OpenWrt because typically the permanent storage is very small and prone to wear.
- Automatic updates of IP lists on OpenWrt are triggered from a cron job like on other Linuxes.

## Defaults for OpenWrt
Generally the defaults are the same as for other systems, except:
- the data directory which geoip-shell uses to store the status file and the backups is by default in `/tmp/geoip-shell-data`, rather than in `/var/lib/geoip-shell` as on other Linux systems. This is to avoid flash wear. You can change this by running the install script with the `-a <path>` option, or after installation via the command `geoip-shell configure -a <path>`.
- the 'nobackup' option is set to 'true', which configures geoip-shell to not create backups of the IP lists. With this option, geoip-shell will work as usual, except after reboot (and for iptables-based systems, after firewall restart) it will re-fetch the IP lists, rather than loading them from backup. You can change this by running the -install script with the `-o false` option (`-o` stands for nobackup), or after installation via the command `geoip-shell configure -o false`. To have persistent IP list backups, you will also need to change the data directory path as explained above.
- if using geoip-shell on a router with just a few MB of embedded flash storage, consider either leaving the nobackup and datadir path defaults as is, or connecting an external storage device to your router (preferably formatted to ext4) and configuring a directory on it as your geoip-shell data directory, then enabling automatic backups. For example, if your external storage device is mounted on _/mnt/somedevice_, you can do all this via this command: `geoip-shell configure -a /mnt/somedevice/geoip-shell-data -o false`.
- the default IP lists source for OpenWrt is ipdeny (rather than RIPE). While ipdeny is a 3rd party, they provide aggregated lists which consume less memory (on nftables-based systems the IP lists are automatically optimized after loading into memory, so there the source does not matter, but a smaller initial IP lists size will cause a smaller memory consumption spike while loading the IP list).
- the default local IP lists directory on OpenWrt is `/etc/geoip-shell/local_iplists`. If using geoip-shell on a router with flash storage which is prone to wear, **NOTE** that with the default configuration, imported local IP lists are written to flash. To avoid writing local IP lists to flash, either don't use local IP lists (don't use `geoip-shell configure [-B|-A]` commands) or configure geoip-shell to store local IP lists on an external storage device: `geoip-shell configure -L <path_to_directory>`.

## Building an OpenWrt package
The repository includes the _mk-owrt-package.sh_ and _prep-owrt-package_ scripts which automate creation of geoip-shell packages. The _makefile.tpl_ file is used as the base template for the Makefile. If you want to build the package by yourself, read the comments inside the _mk-_ script for instructions.

This is about it for this document. Much more information is available in the main [README.md](/README.md) and in the extra _.md_ files inside the Documentation directory. If you have any questions, go ahead and use the Discussions tab, or contact me in this thread:
https://forum.openwrt.org/t/geoip-shell-flexible-geoip-blocker-for-linux/189611

If you use this project, I will be happy to hear about your experience in the above thread or via the Discussions tab on Github. If for some reason geoip-shell is not working for you, I will want to know that as well so I can improve it.

Also, please consider giving this repository a star on Github - this helps other people to find it.
