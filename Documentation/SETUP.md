## Notes about questions asked during the initial setup

### **'Your shell 'A' is supported by geoip-shell but a faster shell 'B' is available in this system, using it instead is recommended. Would you like to use 'B' with geoip-shell?'**

geoip-shell will work with the shell A you ran it from, but it will work faster with a shell B which is also installed in your system. If you type in `y`, geoip-shell installer will launch itself using shell B and configure geoip-shell to always use shell B. Otherwise your current shell will be used. Generally the simpler shells such as ash and dash are faster than complex shells such as bash.

### **'Please enter your country code':**

If you answer this question, the _-manage_ script will check that changes in ip lists which you request to make will not block your own country and warn you if they will. This applies both to the initial setup, and to any subsequent changes to the ip lists which you may want to make in the future. The idea behind this is to make this tool as fool-proof as possible. This information is written to the geoip-shell config file (only readable by root) on your device and geoip-shell does not send it anywhere. You can remove this config entry any time via the command `geoip-shell configure -r none`. You can skip the question by pressing Enter if you wish.

### **'Does this machine have dedicated WAN interface(s)? [y|n]':**

Answering this question is mandatory because the firewall is configured differently, depending on the answer. Answering it incorrectly may cause unexpected results, including having no geoip blocking or losing remote access to your machine.

A machine may have dedicated WAN network interfaces if it's a router or in certain cases a VPS (virtual private server). When geoip-shell is configured to work with certain network interfaces, geoblocking firewall rules are applied only to traffic going through these interfaces, and all other traffic is left alone.

Otherwise, geoip rules are applied to traffic going through all network interfaces, except the loopback interface. Besides that, when geoip-shell is configured in whitelist mode and you picked `n` in this question, additional firewall rules may be created which add LAN subnets or ip's to the whitelist in order to avoid blocking them (you can approve or configure this on the next step of the automated setup). This does not guarantee that your LAN subnets will not be blocked by another rule in another table, and in fact, if you prefer to block some of them then having them in whitelist will not matter. This is because while the 'drop' verdict is final, the 'accept' verdict is not.

### **'Automatically detected ipvX LAN subnets: ... [c]onfirm, c[h]ange, [s]kip or [a]bort?'**

You will see this question if configuring geoip-shell in whitelist mode and you chose `n` in the previous question about WAN network interfaces. The reason why under these conditions this question is asked is to avoid blocking your LAN from accessing your machine.

If you are absolutely sure that you will not need to access the machine from the LAN then you can type in 's' to skip.
Otherwise consider adding LAN subnets to the whitelist. You can either confirm the automatically detected subnets, or specify any combination of ip's and subnets on your LAN which you wish to allow connections from (or to, if using outbound geoblocking).

The automatic detection code should, in most cases, detect correct LAN subnets. However, it is up to you to verify that it's done its job correctly.

One way to do that is by typing in 'c' to confirm and once automated setup completes, verifying that you can still access the machine from LAN (note that if you have an active connection to that machine, for example through SSH, it will likely continue to work until disconnection even if autodetection of LAN subnets did not work out correctly).
Of course, this is risky in cases where you do not have physical access to the machine.

Another way to do that is by checking which ip address you need to access the machine from, and then verifying that said ip address is included in one of the automatically detected subnets. For example, if your other machine's ip is `192.168.1.5` and one of the detected subnets is `192.168.1.0/24` then you will want to check that `192.168.1.5` is included in subnet `192.168.1.0/24`. Provided you don't know how to make this calculation manually, you can use the `grepcidr` tool this way:
`echo "192.168.1.5" | grepcidr "192.168.1.0/24"`

The syntax to check in multiple subnets (note the double quotes):
`echo "[ip]" | grepcidr "[subnet1] [subnet2] ... [subnetN]"`

(also works for ipv6 addresses)

If the ip address is in range, grepcidr will print it, otherwise it will not. You may need to install grepcidr using your distribution's package manager.

Alternatively, you can use an online service which will do the same check for you. There are multiple services providing this functionality. To find them, look up 'IP Address In CIDR Range Check' in your preferred online search engine.

A third way to do that is by examining your network configuration (in your router) and making sure that the automatically detected subnets match those in the configuration.

If you find out that the subnets were detected incorrectly, you can type in 'h' and manually enter the correct subnets or ip addresses which you want to allow connections from.

### **'A[u]tomatically detect LAN subnets when updating ip lists or keep this config c[o]nstant?'**

As the above question, you will see this one if configuring geoip-shell in whitelist mode and you answered `n` to the question about WAN interfaces. You will not see this question if you specified custom subnets or ips in the previous question.

The rationale for this question is that network configuration may change, and if it does then previously correctly configured LAN subnets may become irrelevant.

If you type in 'a', each time geoip firewall rules are initialized or updated, LAN subnets will be re-detected.

If you type in 'c' then whatever subnets have been detected during the initial setup will be remembered forever (until you manually change the setting).

Generally if automatic detection worked as expected during initial setup, most likely it will work correctly every time, so it is a good idea to allow automatic detection with each update. If not then, well, not.

### **'Detected Busybox cron service. cron-based persistence may not work with Busybox cron on this device.'**
You will see this message when configuring geoip-shell on Busybox-based systems which use the built-in Busybox cron daemon. geoip-shell implements cron-based persistence via the `@reboot` crontab string which may or may not be supported by the specific Busybox installed on your device. geoip-shell has no way to detect whether the specific Busybox system does or does not support `@reboot`. If you would like to test whether your Busybox system supports it, run `geoip-shell configure -P true` to force cron-based persistence, then reboot your machine and run `geoip-shell status` - then geoip-shell will check whether the cron daemon is running and print a warning if it's not.

If your Busybox cron doesn't support the `@reboot` string, you can configure geoip-shell with the option `-n true` which will disable the persistence feature. This means that geoip-shell will not be able to automatically reactivate upon reboot. You could either manually start geoip-shell after each reboot by running `geoip-shell configure`, or implement a custom init script which would run on reboot. The script should call `/usr/bin/geoip-shell-run.sh update -a` - this will automatically restore geoip-shell state from backup, or if backup doesn't exist then configured ip lists will be automatically fetched and loaded into the firewall.
