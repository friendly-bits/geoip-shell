## geoip-shell on OpenWrt

Generally, geoip-shell is designed to run on any Linux system. For OpenWrt, because it's so minimalistic, a lot of effort has been put into implementing specific support for it. This includes translating the project from Bash to POSIX-compliant shell language, replacing certain utilities which don't come by default on OpenWrt (or come without certain features) with custom shell code, implementing support for uclient-fetch, implementing an init script and some other scripts for persistence, a lot of learning and testing and much much more.

Currently geoip-shell fully supports OpenWrt, both with firewall3 + iptables and with firewall4 + nftables, while providing exactly the same user interface and features as on any other Linux system.

A LuCi interface has not been implemented (yet) and the project has not been (yet) packaged for OpenWrt. As on any other Linux system, installation, uninstallation and all user interface is via a command line (but my goal is to make this an easy experience regardless). If either of these things discourages you from using geoip-shell, please let me know. Having a few people ask for implementing these features will motivate me to prioritize them.

## Resources management on OpenWrt
I am very much aware of the fact that OpenWrt typically runs on embedded devices with limited memory and very small flash storage. geoip-shell is designed to conserve these resources as much as possible, and some specific techniques are implemented for OpenWrt:
- during installation on OpenWrt, comments are stripped from the scripts to reduce their size.
- the install script selectively copies only the required scripts and libraries, depending on the system and the installation options.
- I've researched the most memory-efficient way for loading ip lists into nftables sets. Currently, nftables has some bugs related to this process which may cause unnecessarily high memory consumption. geoip-shell works around these bugs.
- the install script supports the `-o` option (for 'nobackup') which configures geoip-shell to not create backups of the ip lists. While backups are compressed, a backup of a dozen large ip lists may consume 0.5MB and for some systems, this is too much. When installed with the `-o` option, geoip-shell will work as usual, except after reboot (and for iptables-based systems, after firewall restart) it will re-fetch (and re-validate) the ip lists, rather than loading them from backup.
- to avoid unnecessary flash storage wear, all filesystem-related tasks geoip-shell does which do not require permanent storage are done in the /tmp directory which in the typical OpenWrt installation is mounted on the ramdisk.

### Scripts size
Typical geoip-shell installation on nftables-based OpenWrt system currently consumes around 85kB. The distribution folder itself weighs quite a bit more (mainly because of documentation) but once geoip-shell has been installed, you can delete the distribution folder and free up space taken by it. geoip-shell does not install its documentation into the system.

To view all installed geoip-shell scripts in your system and their sizes, run `ls -lh /usr/bin/geoip-shell-*`.

On iptables-based systems, the installation takes additional ~20kB because in that case geoip-shell installs both libraries required for iptables and for nftables, so if you upgrade your system to nftables at some point, geoip-shell should not break. If you are certain that you won't need these nftables library scripts then you can manually delete them from the /usr/bin directory. You can recognize them by the `-lib-nft` suffix.

## Defaults for OpenWrt
Generally the defaults are the same as for other systems, except:
- the default ip lists source for OpenWrt is ipdeny (rather than ripe). While ipdeny is a 3rd party, they provide aggregated lists which take less space and consume less memory (on nftables-based systems the ip lists are automatically optimized after loading into memory, so there the source does not matter, but a smaller initial ip lists size will cause a smaller memory consumption spike while loading the ip list).
- the default ip lists cron update schedule for OpenWrt is "15 4 * * 5", which translates to "Friday, 4:15am". The default for other Linux systems is daily updates. This is mainly to reduce the stress on the flash storage (in case backups are enabled). You can change the cron schedule during installation or after it if you choose to.
- the data folder which geoip-shell uses to store the status file and the backups, is in `/etc/geoip-shell/data`, rather than in `/var/lib/geoip-shell` as on every other Linux system. This is because the `/var/lib` path in OpenWrt may be mounted in the ramdisk.

This is about it for this document. If you have any questions, go ahead and use the Discussions tab, or contact me in this thread:
https://forum.openwrt.org/t/geoip-shell-flexible-geoip-blocker-for-linux-now-supports-openwrt/189611