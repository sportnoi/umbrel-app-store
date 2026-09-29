# LAN reverse proxy

Gives every self-hosted app a clean `https://<name>.casa` URL on the home
network, with no port number.

## Why this exists

umbrelOS 2.0 binds **both** 80 and 443 on the host, as wildcards:

```
LISTEN *:80    users:(("node",pid=1177))
LISTEN *:443   users:(("node",pid=1177))
```

A wildcard socket covers every address the host has, so the kernel refuses any
competing bind. Three approaches died on that fact before this one:

- rebinding Nginx Proxy Manager to 443 — worked on umbrelOS 1.7.4 when only port
  80 was taken, but umbrelOS re-rendered the app's compose on every update, and
  2.0 took the port outright
- giving the host a second LAN address — the wildcard covers it too
- forwarding from a second address to NPM's high port — the listener cannot be
  created in the first place

A **container** is different. It has its own network namespace and, on an ipvlan
network, its own LAN address. The host's wildcard sockets do not reach into it,
so it owns 80 and 443 on that address outright.

`ipvlan` rather than `macvlan` because this Umbrel is on WiFi. ipvlan L2 shares
the parent interface's MAC address, which access points accept; macvlan needs a
second MAC and promiscuous mode, which WiFi adapters will not do.

```
192.168.1.113  Umbrel host      dashboard on 80/443 (umbreld)
192.168.1.50   lan-proxy        80/443 for every app
```

## Install

Run on the Umbrel host.

**1. Certificates.** This assumes the local CA from the main README already
exists at `/home/umbrel/certs`. Move the existing leaf certificate across and
mint new ones with the script:

```sh
mkdir -p /home/umbrel/lan-proxy/certs
sudo sh scripts/new-cert.sh finance.casa
```

The CA private key stays in `/home/umbrel/certs` and is never mounted into a
container.

**2. Configure.**

```sh
cp -r lan-proxy /home/umbrel/lan-proxy
cd /home/umbrel/lan-proxy
cp proxy.env.example proxy.env
$EDITOR proxy.env      # PROXY_IP, LAN_SUBNET, LAN_GATEWAY, LAN_PARENT
$EDITOR Caddyfile      # one block per app
```

`PROXY_IP` must be **outside the UniFi DHCP pool**. An address DHCP can also
hand out produces a conflict that shows up as intermittent, hard-to-read
failures rather than a clean error.

**3. Start it.**

```sh
sudo cp lan-proxy.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now lan-proxy
systemctl status lan-proxy --no-pager
```

**4. Point DNS at it.** In UniFi, change the `finance.casa` local DNS record
from the Umbrel's address to `PROXY_IP`.

**5. Check.**

```sh
curl -sk -o /dev/null -w "%{http_code}\n" https://finance.casa/
curl -s -o /dev/null -w "%{http_code} -> %{redirect_url}\n" http://finance.casa/
```

`307` on the first (the app's login redirect) and `308` to `https://` on the
second. The HTTP redirect is new — it was impossible while umbreld held port 80.

## Adding an app

```sh
sudo sh /home/umbrel/scripts/new-cert.sh photos.casa
```

Add to the `Caddyfile`:

```
photos.casa {
	tls /certs/photos.casa.crt /certs/photos.casa.key
	reverse_proxy 172.17.0.1:2342
}
```

Add the UniFi DNS record, then `sudo systemctl restart lan-proxy`. No new
certificate trust on any device — they already trust the CA.

The upstream is `172.17.0.1`, the docker bridge gateway, which is the Umbrel
host. ipvlan containers cannot reach their own parent host directly, which is
why the proxy is attached to the bridge network as well. Use whatever port the
app publishes — its `port:` in `umbrel-app.yml`.

## What this replaces

Nginx Proxy Manager is no longer in the path for `finance.casa`. Leave it
installed if other things use it, or uninstall it.

## Known limits

- **LAN only.** Nothing here is reachable from outside the house. Tailscale
  covers that case and issues publicly trusted certificates, at the cost of
  `*.ts.net` names instead of your own.
- **Devices must trust the CA.** Already done for the machines set up earlier;
  new ones need `casa-ca.crt` installed once.
- **The proxy's address is static.** If the LAN is renumbered, `proxy.env`, the
  UniFi DNS records and the ipvlan network all need updating.
