## **Notes**
1) The suite uses RIPE as the default source for ip lists. RIPE is a regional registry, and as such, is expected to stay online and free for the foreseeable future. However, RIPE may be fairly slow in some regions. For that reason, I implemented support for fetching ip lists from ipdeny. ipdeny provides aggregated ip lists, meaning in short that there are less entries for same effective geoip blocking, so the machine which these lists are installed on has to do less work when processing incoming connection requests. All ip lists the suite fetches from ipdeny are aggregated lists.

2) The scripts intended as user interface are: **-install**, **-uninstall**, **-manage** (also called by running '**geoip-shell**' after installation) and **check-ip-in-registry.sh**. The -manage script saves the config to a file and implements coherence checks between that file and the actual firewall state. While you can run the other scripts individually, if you make changes to firewall geoip rules, next time you run the -manage script it may insist on reverting those changes since they are not reflected in the config file. The **-backup** script can be used individually. By default, it creates a backup of geoip-shell state after every successful action involving changes to or updates of the ip lists. If you encounter issues, you can use it with the 'restore' command to restore geoip-shell to its previous state. It also restores the config, so the -manage script will not mind.

3) Geoip blocking, as well as automatic list updates, is made persistent via cron jobs: a periodic job running by default on a daily schedule, and a job that runs at system reboot (after 30 seconds delay). Either or both cron jobs can be disabled (run the *install script with the -h option to find out how, or read [DETAILS.md](/Documentation/DETAILS.md)). On OpenWrt, persistence is implemented via an init script and a firewall include rather than via a cron job.

4) By default, nftables sets are configured with policy 'memory' in order to minimize memory consumption (at the expense of some performance). If your machine has enough memory (perhaps 512MB or higher), consider using the 'performance' policy for sets. This can be enabled by running the _-install.sh_ script with the `-e` option. This does not apply to iptables ip sets as these are configured differently and balancing memory and performance is managed automatically by the -apply script.

5) The run, fetch and apply scripts write to syslog in case an error occurs. The run and fetch scripts also write to syslog upon success. To verify that cron jobs ran successfully, on Debian and derivatives run `cat /var/log/syslog | grep geoip-shell`. On other distributions, you may need to figure out how to access the syslog.

6) These scripts will not run in the background consuming resources (except for a short time when triggered by the cron jobs). All the actual blocking is done by the netfilter component in the kernel. The scripts offer an easy and relatively fool-proof interface with netfilter, config persistence, automated ip lists fetching and auto-update.

7) Sometimes ip list source servers are temporarily unavailable and if you're unlucky enough to attempt installation during that time frame, the fetch script will fail which will cause the installation to fail as well. Try again after some time or use another source. Once the installation succeeds, an occasional fetch failure during autoupdate won't cause any issues as last successfully fetched ip list will be used until the next autoupdate cycle succeeds.

8) How to geoblock or allow specific ports (applies to the _-install_ and _-manage_ scripts).
    The general syntax is: `-p <[tcp|udp]:[allow|block]:[all|ports]>`
    Where `ports` may be any combination of comma-separated individual ports or port ranges (for example: `125-130` or `5,6` or `3,140-145,8`).
    Multiple `-p` options are allowed, for example: `-p tcp:allow:22,23 -p udp:block:128-256,3`

    Examples with the -install script:

    `sh geoip-shell-install -c de -m whitelist -p tcp:allow:125-135,7` - for tcp, allow incoming traffic on ports 125-135 and 7, geoblock incoming traffic on other tcp ports (doesn't affect UDP traffic)

    `sh geoip-shell-install -c de -m blacklist -p udp:allow:3,15-20,1024-2048` - for udp, allow incoming traffic on ports 15-20 and 3, geoblock all other incoming udp traffic (doesn't affect TCP traffic)

    Examples with the -manage script (also called via 'geoip-shell' after installation) :

    `geoip-shell apply -p tcp:block:all` - for tcp, geoblock all ports (default behavior)

    `geoip-shell apply -p udp:allow:all` - for udp, don't geoblock any ports (completely disables geoblocking for udp)

    `geoip-shell apply -p tcp:block:125-135,7` - for tcp, only geoblock incoming traffic on ports 125-135 and 7, allow incoming traffic on all other tcp ports

9) How to remove specific ports assignment:

    use `-p [tcp|udp]:block:all`.

    Example: `geoip-shell -p tcp:block:all` will remove prior port-specific rules for the tcp protocol. All tcp packets on all ports will now go through geoip filter.

10) How to make specific protocol packets bypass geoip blocking:

    use `p [tcp|udp]:allow:all`

    Example: `geoip-shell -p udp:allow:all` will allow all udp packets on all ports to bypass the geoip filter.

11) You can specify a custom schedule for the periodic cron job by passing an argument to the install script. Run it with the '-h' option for more info.

12) If you want to change the autoupdate schedule but you don't know the crontab expression syntax, check out https://crontab.guru/ (no affiliation)

13) Note that cron jobs will be run as root.

14) To test before deployment:
<details> <summary>Read more:</summary>

  - You can run the install script with the "-k" (noblock) option to apply all actions except actually blocking incoming connections. This way you can make sure no errors are encountered and check the resulting firewall config before commiting to actual blocking. To enable blocking later, use the *manage script.
  - You can run the install script with the "-n" option to skip creating the reboot cron job which implements persistence and with the '-s disable' option to skip creating the autoupdate cron job. This way, a simple machine restart should undo all changes made to the firewall (unless you have some software that restores firewall settings after reboot). For example: `sh geoip-shell-install -c <country_code> -m whitelist -n -s disable`. To enable persistence and autoupdate later, reinstall without both options.

</details>

15) How to get yourself locked out of your remote server and how to prevent this:
    <details> <summary>Read more:</summary>

    There are 4 scenarios where you can lock yourself out of your remote server with this suite:
    - install in whitelist mode without including your country in the whitelist
    - install in whitelist mode and later remove your country from the whitelist
    - blacklist your country (either during installation or later)
    - your remote machine has no dedicated WAN interfaces (it is behind a router) and you incorrectly specified LAN subnets the machine belongs to

    As to the first 3 scenarios, the -manage script will warn you in each of these situations and wait for your input (you can press Y and do it anyway), but that depends on you correctly specifying your country code during installation. The -install script will ask you about it. If you prefer, you can skip by pressing Enter - that will disable this feature. If you do provide the -install script your country code, it will be added to the config file on your machine and the -manage script will read the value and perform the necessary checks, during installation or later when you want to make changes to the blacklist/whitelist.

    As to the 4th scenario, there is not much I can do to prevent it, besides implementing LAN subnets automatic detection and asking you to verify that the detected LAN subnets are correct. Which is what the -install script does. The INSTALL.md file also explains how to do the verification if you don't know how. Read the documentation, follow it and you should be fine. Also note that LAN subnets **may** change in the future, for example if someone changes some config in the router or replaces the router etc. For this reason, when installing the suite for **all** network interfaces, the -install script offers to enable automatic detection of LAN subnets at each periodic update. If for some reason you do not enable this feature, you will need to make the necessary precautions when changing the LAN subnets your remote machine belongs to.

</details>
