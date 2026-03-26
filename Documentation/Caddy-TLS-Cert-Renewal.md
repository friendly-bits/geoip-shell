# Let's Encrypt TLS Certificate Renewal With Caddy

Or, how to allow certificate renewal on Caddy when geoip-shell is running there.

## The issue

Caddy greatly automates the retrieval and renewal of TLS certificates by "Let's Encrypt". However, if you decide to geo-block incoming traffic directly on the Caddy server, some, if not all, IP addresses of Let's Encrypt's servers might get blocked. This will lead to errors in the certificate renewal with your TLS certificates becoming invalid over time.

## Possible Solutions

### Allow-listing IP addresses

While this would be a sensible solution, Let's Encrypt decidedly do _not_ publish IP addresses of their servers because they are subject to change anytime.

There is information out there about their IP addresses, e.g., the [LetsEncryptIPs](https://github.com/n3roGit/LetsEncryptIPs) repository on Github. But the issue of IP changes remains, and you'd have to maintain the allowlist, which makes this approach quite unstable.

### Using  Caddy's Event Hooks

> [!TIP]
> If you run Caddy in an unprivileged LXC (e.g., on Proxmox), skip down to "Using a cron job". Otherwise you'll run into several privilege-related errors ("read-only filesystem").
>
> Also skip down if you run into unresolvable errors with this approach.

This assumes that Caddy runs under its own user (a typical setup and recommended security measure) and has `sudo` privileges.

Caddy provides events that fire during the certificate renewal process. Together with the plugin "caddy-events-exec", this allows for an easy configuration in the Caddyfile to switch geoblocking off and on again.

To configure,

- Get the Caddy binary with the "caddy-events-exec" plugin by
  - [selecting it on the download page](https://caddyserver.com/download)
  - **OR** by compiling the binary yourself.
- Place the binary in the corresponding folder (/usr/bin on most Linuxes)
- Add the following lines _at the top_ of your Caddyfile:

```
# Switch GeoIP fencing OFF during certificate renewal
# Needs module "caddy-events-exec"
{
       events {
               on cert_obtaining exec sudo geoip-shell off
               on cert_obtained exec sudo geoip-shell on
               on cert_failed exec sudo geoip-shell on
       }
}
```

- Restart Caddy (Linux with systemd: `systemctl restart caddy`).
- Check the logfile for TLS renewal events. You should see entries like `caddy : PWD=/ ; USER=root ; COMMAND=/usr/bin/geoip-shell off` next to them.

### Using a cron job to renew certificates

This is a more pragmatic solution that works in most cases when the event hook approach doesn't work. 

One such use case is a Proxmox environment where Caddy runs in an unprivileged LXC.

The basic idea is to have a Shell script that

- runs weekly (or whichever interval you deem necessary),
- switches geoblocking off,
- gives Caddy time to renew the Letsencrypt certs and
- switches geoblocking on again.

**Solution:**

Create a script "renew-certs.sh" in the root home folder:

```bash
#!/bin/sh
# Switch Geoblocking off to allow Caddy to renew TLS certificates

echo "Turning geoip-shell off"
/usr/bin/geoip-shell off

echo "Restarting Caddy to trigger TLS Cert renewal"
systemctl restart caddy

##############################################################################
### Optional part: access your website to trigger an initial TLS handshake
### This causes Caddy to obtain a certificate if none exists for this domain
### Uncomment and change "www.example.com" to your domain
### (You need curl installed on your system)
# echo "Triggering first TLS handshake"
# curl --resolve www.example.com:443:127.0.0.1 https://www.example.com 1>/dev/null
##### END optional part ######################################################

echo "30s pause to give Caddy time for cert renewal..."
sleep 30s
echo "Shields UP!"
/usr/bin/geoip-shell on
```

Then add a cron job to root's crontab (e.g., with `crontab -e`):

```text
6 6 * * 6 /root/renew_certs.sh 1>/tmp/renew_certs.log 2>&1 # ACME Cert renewal
```

The above example runs the shell script every Sunday at 06:06 in the morning.

Check the log file "/tmp/renew_certs.log" for successful execution.
