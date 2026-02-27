## **Notes**
1) Which shell to use with geoip-shell:

   geoip-shell detects the shell it's running in during installation, verifies that it's compatible and replaces the "shebang" in all of the installed geoip-shell scripts to point to the detected shell. So for example, if you like to use zsh (an incompatible shell), you can install a package which provides a simpler shell like dash and then run the -install script from it. For example: `dash geoip-shell-install.sh`. This way you can continue to use a fancy shell for your other tasks, while geoip-shell will happily use a simple and compatible shell. This also makes sense from the performance perspective since a simpler shell runs 3x to 4x faster.

2) Firewall rules structure created by geoip-shell:
    <details> <summary>iptables:</summary>

    - With **iptables**, all firewall rules created by geoip-shell are in the table `mangle`. The reason to use `mangle` is that this table has built-in chains `PREROUTING` and `POSTROUTING` which are attached to the `prerouting` and `postrouting` hooks in the netfilter kernel component. For the ingress, by utilizing the `PREROUTING` chain, geoip-shell creates one set of rules which applies to all ingress traffic for a given IP family, rather than having to create and maintain separate rules for chains INPUT and FORWARDING which would be possible in the default `filter` table. Same applies to egress traffic which is filtered by geoip-shell in the `POSTROUTING` chain.
    - This also means that any rules you might have in the `filter` table will only see ingress traffic which is allowed by geoip-shell rules, which may reduce the CPU load as a side-effect.
    - Note that **iptables** features separate tables for ipv4 and ipv6, hence geoip-shell creates separate rules for each family (unless the user restricts geoip-shell to a certain family).
    - Inside the table `mangle`, geoip-shell creates custom chains: `GEOIP-SHELL_IN`, `GEOIP-SHELL_OUT` (depending on which geoblocking directions you configured). These are the main geoblocking chains, all traffic filtering happens inside these chains. A rule in the `PREROUTING` chain redirects traffic to `GEOIP-SHELL_IN` and a rule in the `POSTROUTING` chain redirects traffic to `GEOIP-SHELL_OUT`. geoip-shell calls these rule "enable" rules which can be removed or re-added on-demand with the commands `geoip-shell on` and `geoip-shell off`. If the "enable" rule is not present, system firewall will act as if all other geoip-shell rules (for a given IP family and direction) are not present.
    - If geoblocking is configured for specific network interfaces, the "enable" rule directs traffic to a 2nd custom chain `GEOIP-SHELL_WAN_IN` or `GEOIP_SHELL_WAN_OUT` rather than to the aforementioed chains. geoip-shell creates rules in the `GEOIP-SHELL_WAN_[IN|OUT]` chain which selectively redirect traffic only from the specified network interfaces to the main geoblocking chains.
    - With iptables, geoip-shell removes the "enable" rule before making any changes to the IP sets and rules, and re-adds it once the changes have been successfully made. This is a precaution measure intended to minimize any chance of potential problems. Typically loading IP lists into the firewall does not take more than a few seconds, and on reasonably fast systems less than a second, so the time when geoblocking is not enabled is normally very brief.
    </details>

    <details> <summary>nftables:</summary>

    - With **nftables**, all firewall rules created by geoip-shell are in the table named `geoip-shell`, family "inet", which is a term nftables uses for tables applying to both IP families. The `geoip-shell` table includes rules for both IP families and any nftables sets geoip-shell creates. geoip-shell creates custom chains in that table, depending on which geoblocking directions you enabled: `GEOIP-SHELL-BASE_IN`, `GEOIP-SHELL-BASE_OUT`, `GEOIP-SHELL_IN`, `GEOIP-SHELL_OUT`. The `IN` chains serve for ingress traffic geoblocking, the `OUT` chains for egress traffic geoblocking. The `_IN` base chain attaches to netfilter's `prerouting` hook and has a rule which directs traffic to the `GEOIP-SHELL_IN` chain. The `_OUT` base chain attaches to netfilter's `postrouting` hook and has a rule which directs traffic to the `GEOIP-SHELL_OUT` chain. That rule is the geoip-shell "enable" rule for nftables-based systems which acts exactly like the "enable" rule in the iptables-based systems, except it applies to both IP families.
    - **nftables** allows for more control over which network interfaces each rule applies to, so when certain network interfaces are specified in the config, geoip-shell specifies these interfaces directly in the rules inside the `GEOIP-SHELL_[IN|OUT]` chains, and so (contrary to iptables-based systems) there is no need in an additional chain.
    - **nftables** features atomic rules replacement, meaning that when issuing multiple nftables commands at once, if any command fails, all changes get cancelled and the system remains in the same state as before. geoip-shell utilizes this feature for fault-tolerance and to completely eliminate time when geoip blocking is disabled during an update of the sets or rules.
    - **nftables** current version (up to 1.0.8 and probably 1.0.9) has some bugs causing unnecessarily high transient memory consumption when performing certain actions, including adding new sets. These bugs are known and for the most part, already have patches implemented which should eventually roll out to the distributions. This mostly matters for embedded hardware with less than 512MB of memory. geoip-shell works around these bugs as much as possible. One of the workarounds is to avoid using the atomic replacement feature for nftables sets. Instead, when updating sets, geoip-shell first adds new sets one by one, then atomically applies all other changes, including rules changes and removing the old sets. In case of an error during any stage of this process, all changes get cancelled, old rules and sets remain in place and geoip-shell then destroys the new sets. This is less efficient but with current versions of nftables, this actually lowers the minimum memory bar for the embedded devices. Once a new version of nftables will be rolled out to the distros and widely adopted, geoip-shell will adapt the algorithm accordingly.
    </details>

    <details> <summary>nftables and iptables:</summary>

    - With both **nftables** and **iptables**, geoip-shell goes a long way to make sure that firewall rules and IP sets are correct and matching the user-defined config. Automatic corrective mechanisms are implemented which should restore geoip-shell firewall rules in case they do not match the config (which normally should never happen).
    - geoip-shell implements rules and IP sets "tagging" to distinguish between its own rules and other rules and sets. This way, geoip-shell never makes any changes to any rules or sets which geoip-shell did not create.
    - When uninstalling, geoip-shell removes all its rules, chains and IP sets.
    </details>

3) Allow-rules:

   Depending on the options you specified during interactive setup or via the command line, geoip-shell creates additional firewall rules which are designed to prevent blocking essential traffic. Most of the rules are only created in whitelist mode. Specifics:

   - In whitelist and blacklist modes, geoip-shell creates rules to allow **related and established connections**. This means that if, for example, you configured inbound geoblocking in whitelist mode for only 1 country (your own), you will still be able to connect to servers in other countries and receive a response from them. So this allows connections which were established on your initiative.
   - In whitelist and blacklist modes, if you configured **trusted addresses** (or IP ranges), geoip-shell adds rules to allow traffic to or from them.
   - In whitelist mode, geoip-shell adds rules to allow **link-local addresses** (both ipv4 and ipv6).
   - In whitelist mode, geoip-shell adds rules to allow **DHCP-related traffic** (limited to private IP ranges and to ports 67, 68 for ipv4 and 546, 547 for ipv6).
   - In whitelist mode, and as long as you configured **LAN IP addresses or IP ranges**, geoip-shell creates rules to allow traffic to or from these addresses.
   - geoip-shell combines the trusted addresses, the LAN addresses and the link-local addresses in one ipset and creates one rule for each IP family and enabled geoblocking direction.
   - If both geoblocking directions need the same set of allowed addresses, geoip-shell creates only one ipset per IP family and reuses it for both directions. Otherwise geoip-shell creates separate ipsets for each direction.

4) How to manually check firewall rules created by geoip-shell:
    - With nftables: `nft -t list table inet geoip-shell`. This will display all geoip-shell rules and sets.
    - With iptables: `iptables -vL -t mangle` and `ip6tables -vL -t mangle`. This will report all geoip-shell rules. To check ipsets created by geoip-shell, use `ipset list -n | grep geoip-shell`. For a more detailed view, use this command: `ipset list -t`.

5) Supported IP list sources:
	- geoip-shell currently supports the following sources: RIPE, ipdeny and MaxMind.
	- RIPE and ipdeny sources are free-to-use and require no license. Maxmind requires a license and offers both a free (GeoLite2) and a paid (GeoIP2) databases.
	- RIPE and ipdeny IP lists are typically effectively the same, except ipdeny provides aggregated IP lists, meaning in short that there are less entries for same effective geoblocking. With iptables, the machine which these lists are loaded on has to do less work when processing incoming connection requests. With nftables, this does not affect the load on the CPU because nftables automatically optimizes loaded IP lists, so IP lists from RIPE perform identically to IP lists from ipdeny. The downloaded lists from ipdeny are still smaller, so even with nftables, there is still a benefit of lower transient memory consumption while loading the lists (which mostly matters for embedded hardware with very limited memory capacity).
	- MaxMind manages proprietary geoip database which typically provides more accurate data than RIPE and ipdeny, both in the paid and in the free version (the paid version may provide even higher accuracy). Note that in order to use the MaxMind source, you need to have a MaxMind account.
	- geoip-shell uses RIPE as the default source for IP lists, except on OpenWrt. RIPE is a regional registry, and as such, is expected to stay online and free for the foreseeable future. However, RIPE may be fairly slow in some regions, and the downloads from RIPE are typically larger than from ipdeny. For this reason, I implemented support for fetching IP lists from ipdeny, which is also the default source on OpenWrt.

6) Scripts intended as user interface are: **-install**, **-uninstall**, **-manage** (also called by running '**geoip-shell**' after installation) and **check-ip-in-source.sh**. The -manage script saves the config to a file and implements coherence checks between that file and the actual firewall state. While you can run the other scripts individually, if you make changes to firewall geoip rules, next time you run the -manage script it may insist on reverting those changes since they are not reflected in the config file.

7) System log entries: When performing automatic IP list updates or when restoring geoblocking rules upon reboot, geoip-shell registers success and failure messages in the system log. To verify that cron jobs ran successfully, on older Debian and derivatives run `cat /var/log/syslog | grep geoip-shell`. On distributions using the systemd journalctl log daemon (including Debian Bookworm and later Debian versions), run `journalctl | grep geoip-shell`. On OpenWrt, use the command `logread | grep geoip-shell`. On other distributions, you may need to figure out how to access the syslog.

8) geoip-shell will not run in the background consuming resources (except for a short time when triggered by the cron jobs). All the actual blocking is done by the netfilter component in the kernel. geoip-shell offers an easy and relatively fool-proof interface with netfilter, config persistence, automated IP lists fetching and update.

9) Sometimes IP list source servers are temporarily unavailable and if you're unlucky enough to attempt installing geoip-shell during that time frame, the fetch script will fail which will cause the initial setup to fail as well. Try again after some time or use another source. Once the initial setup succeeds, an occasional fetch failure during automatic update won't cause any issues as last successfully fetched IP list will be used until the next update cycle succeeds.

10) How to geoblock or allow specific protocols and ports.
	For TCP and UDP, geoip-shell allows to limit geoblocking to certain **destination** ports.

    The general syntax is:
	
	```
	geoip-shell configure [-D <inbound|outbound>] -p <[tcp|udp]:[allow|block]:[all|<ports>]>
	```

    Where `ports` may be any combination of comma-separated individual ports or port ranges (for example: `125-130` or `5,6` or `3,140-145,8`).

	The `allow` keyword means that **only** specified ports are not geoblocked. The `block` keyword means that **only** specified ports are geoblocked.

	The `all` keyword is self-explanatory. For example, `-p tcp:block:all` will geoblock all TCP traffic for the specified direction (inbound or outbound). `-p udp:allow:all` will **not** geoblock any UDP traffic for the specified direction.

	For ICMP, geoip-shell allows to either geoblock all ICMP traffic for given direction, or make all ICMP traffic for that direction bypass the geoblocking filter. The syntax is:
	
	```
	geoip-shell configure [-D <inbound|outbound>] -p icmp:[allow|block]
	```

    You can use the `-p` option multiple times in one command or in consequtive commands to cover any combination of TCP, UDP and ICMP, for example: `-p tcp:allow:22,23 -p udp:block:128-256,512 -p icmp:allow`

	When geoblocking direction is not specified via the `-D <inbound|outbound>` option, the command applies to **inbound** geoblocking.

	You can configure protocols and ports for both directions in one command this way:
	`geoip-shell configure -D inbound -p <options> [-p <options>] [-p <options>] -D outbound -p <options> [-p <options>] [-p <options>]`

	Alternatively, you can achieve the same in two separate commands:
	```
	geoip-shell configure -D inbound -p <options> [-p <options>] [-p <options>]
	geoip-shell configure -D outbound -p <options> [-p <options>] [-p <options>]
	```

    <details> <summary>Examples</summary>

    `geoip-shell configure -p tcp:block:all` - for inbound TCP traffic, geoblock all packets for all destination ports (default behavior)

    `geoip-shell configure -D outbound -p udp:allow:1,5-7,1024` - for outbound UDP traffic, geoblock all packets **except** those which have destination ports 1, 5-7, 1024

    `geoip-shell configure -D inbound -p tcp:block:125-135,7` - for inbound TCP traffic, only geoblock packets which have destination ports 125-135 and 7, do not geoblock inbound traffic on all other TCP ports

    `geoip-shell configure -p icmp:allow` - allow all inbound ICMP traffic through the geoblocking filter

	</details>

11) How to reset protocols and ports configuration to default:

    `geoip-shell configure [-D <inbound|outbound>] -p [tcp|udp]:block:all`.

    `geoip-shell configure [-D <inbound|outbound>] -p icmp:block`.

    <details> <summary>Examples</summary>

    `geoip-shell configure -p tcp:block:all` will remove prior port-specific rules for the TCP protocol, inbound direction. All inbound TCP packets with all destination ports will now go through the geoblocking filter.

    `geoip-shell configure -D outbound -p udp:block:all` will remove prior port-specific rules for the UDP protocol, outbound direction. All outbound UDP packets with all destination ports will now go through geoblocking filter.

    `geoip-shell configure -p icmp:block` will reset specific rules for the ICMP protocol to default (geoblock all ICMP traffic).
	</details>

12) How to make all traffic for a specific protocol bypass the geoblocking filter:

    `geoip-shell configure [-D <inbound|outbound>] -p [tcp|udp]:allow:all`

    `geoip-shell configure [-D <inbound|outbound>] -p icmp:allow`

    <details> <summary>Example</summary>

    `geoip-shell configure -p udp:allow:all` will allow all inbound udp traffic to bypass the geoblocking filter.
	</details>

13) geoip-shell creates both 'accept' and 'drop' firewall rules, depending on your config. The 'drop' verdict is final: once a packet encounters the 'drop' rule, it is dropped. The 'accept' verdict is not final: a packet accepted by geoip-shell rules may still get dropped by other rules you may have in your firewall. So essentially geoip-shell acts as a filter which is only capable of narrowing down machine's exposure to the Internet but not overriding other blocking rules which you may have.

14) Firewall rules persistence, as well as automatic IP list updates, is implemented via cron jobs: a periodic job running by default on a daily schedule, and a job that runs at system reboot (after 30 seconds delay). Either or both cron jobs can be disabled (run `geoip-shell -h` to find out how, or read [DETAILS.md](/Documentation/DETAILS.md)). On OpenWrt, persistence is implemented via an init script and a firewall include rather than via a cron job.

15) You can specify a custom schedule for the periodic cron job this way: `geoip-shell configure -s <your_cron_schedule>`.

16) If you want to change the autoumatic update schedule but you don't know the crontab expression syntax, check out https://crontab.guru/ (no affiliation). geoip-shell includes a script which validates cron expressions you request, so don't worry about making a mistake.

17) Note that cron jobs will be run as root.

18) When geoip-shell detects both iptables and nftables during the initial setup, it will default to using nftables. If you have nftables installed but for some reason you are using iptables rules (via the nft_compat kernel module which is provided by packages like nft-iptables etc), you can and probably should configure geoip-shell with the option `-w ipt` which will force it to use iptables+ipset. For example: `geoip-shell configure -w ipt`.

    When installed via an OpenWrt package, geoip-shell can only use the firewall utility supported by the package. For nftables, install the package _geoip-shell_, for iptables, install the package _geoip-shell-iptables_. Changing firewall backend is not supported in this case.

19) To change the firewall backend (from nftables to iptables or vice-versa), you can use this command: `geoip-shell configure -w <ipt|nft>`. This will configure geoip-shell to use the new backend, then remove all existing geoblocking rules and ipsets and re-create them for the requested firewall backend, based on your existing config. If you are on OpenWrt and installed via a package, this does not apply: instead, you will need to uninstall the existing geoip-shell package (_geoip-shell_ or _geoip-shell-iptables_) and install the geoip-shell package intended for the desired backend.

20) If your machine uses nftables, depending on the RAM capacity of the machine and the number and size of the IP lists, consider installing with the `-O performance` or `-O memory` option. This will create nft sets optimized either for performance or for low memory consumption. By default, when the machine has more than 2GiB of memory, the `performance` option is used, otherwise the `memory` option is used.

21) If your distro (or you) have enabled automatic nftables/iptables rules persistence, you can disable the built-in cron-based persistence feature by adding the `-n` (for no-persistence) option when running the -install script.

22) If for some reason you need to install or configure geoip-shell in strictly non-interactive mode, you can call the -install or the -manage script with the `-z` option which will avoid asking the user any questions. In non-interactive mode, commands will fail if required config is incomplete or invalid.

23) To test before deployment:
    <details> <summary>Read more:</summary>

    - If you prefer to check geoip-shell rules before committing to actual geoblocking, you can install geoip-shell with the `-z` option which will prevent geoip-shell from starting automated setup when installation completes: `sh geoip-shell-install.sh -z`. Then call the -manage script with the `-N true` option (N stands for noblock) to apply all actions and create all firewall rules except the geoblocking enable rule: `geoip-shell configure -N true`.
    - You can configure geoip-shell with the `-n true` option (n stands for nopersistence) to skip creating the reboot cron job which implements persistence (or the init script on OpenWrt) and with the '-s disable' option to skip creating the autoupdate cron job: `geoip-shell configure -n true -s disable`. This way, a simple machine restart should undo all changes made to the firewall (unless you have some software which restores firewall settings after reboot). To enable persistence and automatic updates later, use the command `geoip-shell configure -n false -s <"your_cron_schedule_expression">` (default cron schedule expression is `15 4 * * *`).

    </details>

24) How to get yourself locked out of your remote server and how to prevent this:
    <details> <summary>Read more:</summary>

    There are 4 scenarios where you can lock yourself out of your remote server with geoip-shell:
    - configure geoip-shell to work in whitelist mode without including your country in the whitelist
    - configure geoip-shell to work in whitelist mode and later remove your country from the whitelist
    - geoip-shell to work in blacklist mode and add your country to the blacklist
    - your remote machine has no dedicated WAN interfaces (it is behind a router) and you incorrectly specified LAN IP ranges the machine belongs to

    As to the first 3 scenarios, the -manage script will warn you in each of these situations and wait for your input (you can press Y and do it anyway), but that depends on you correctly specifying your country code during the initial setup. The -manage script will ask you about it. If you prefer, you can skip by pressing Enter - that will disable this feature. If you do specify your country code, it will be added to the config file on your machine and the -manage script will read the value and perform the necessary checks, during the initial setup or later when you want to make changes to the blacklist/whitelist.

    As to the 4th scenario, geoip-shell implements LAN IP ranges automatic detection and asks you to verify that the detected LAN IP ranges are correct. If you are not sure how to verify this, reading the [SETUP.md](/Documentation/SETUP.md) file should help. Read the documentation, follow it and you should be fine. If you specify your own LAN IP addresses or IP ranges (rather than using the automatically detected ones), geoip-shell validates them, meaning it makes sure that they appear to be valid by checking them with regex, and asking the kernel. This does not prevent a situation where you provide technically valid IP addresses/IP ranges which however are not actually used in the LAN your machine belongs to. So double-check. Also note that LAN IP ranges **may** change in the future, for example if someone changes some config in the router or replaces the router etc. For this reason, when configuring geoip-shell for **all** network interfaces, the -manage script offers to enable automatic detection of LAN IP ranges at each periodic update. If you do not enable this feature, you will need to make the necessary precautions when changing LAN IP ranges your remote machine belongs to.

	As an additional measure, you can specify trusted IP addresses or IP ranges anywhere on the Internet which will not be geoblocked, so in case something goes very wrong, you will be able to regain access to the remote machine. This does require to have a known static public IP address or IP range. To specify trusted IPs, use this command: `geoip-shell configure -t <"[trusted_ips]">`.

    </details>
