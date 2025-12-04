## Purpose

This document defines the canonical, tunnel-free, and stable networking setup for:
•	mc-proxy (Oracle VPS with static IP)
•	cloud (Synology DS720 via Tailscale)
•	backupcloud (secondary NAS)
•	macOS hosts (M1 → M2 migration)


## Network Overview

### Tailscale nodes

```
mc-proxy       100.68.47.124   (Oracle VPS, entrypoint)
cloud          100.101.105.75  (Main Synology DS720)
backupcloud    100.71.86.79    (Secondary NAS)
```

### Traffic direction

```
Internet → mc1.demonsmp.win → mc-proxy  
mc-proxy → Tailscale WireGuard → cloud (Synology)  
```

Goal now - replacing legacy tunnels:
•	autossh Drive tunnels
•	autossh DSM HTTPS tunnels
•	autossh Plex tunnels
•	ssh -R ports on Oracle
•	Nginx stream listeners supporting those tunnels

All deprecated after migration.

### Requirements
   •	Tailscale installed & logged in on:
   •	mc-proxy
   •	cloud (Synology — Docker package or Synology app)
   •	Optional: backupcloud, Mac hosts
   •	Linux kernel IP forwarding enabled (mc-proxy only)
   •	iptables-persistent installed to persist rules across reboot

⸻

## 1. Kill the old SSH tunnels

On Mac mini in cloudflare-homecloud:

```
./run.sh drive-tunnel-stop
./run.sh cloud-tunnel-stop
./run.sh plex-tunnel-stop
```

Also check they’re not auto-started via:
•	crontab -e
•	launchd plist
•	systemd user services

If they are, remove those entries – you don’t want autossh coming back after reboot.

From now on, JUMP_HOST=ubuntu@mc1.demonsmp.win is no longer used.

⸻

## 2. Enable routing on mc-proxy

On mc-proxy:

```
sudo sh -c 'echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-forwarding.conf'
sudo sysctl -p /etc/sysctl.d/99-forwarding.conf
```

⸻

## 3. Direct forwarding mc-proxy → Synology over Tailscale

We’ll use cloud’s Tailscale IP:

```
SYNO_TS_IP=100.101.105.75
```

3.1 NAT + forwarding rules

Run on mc-proxy:

```
SYNO_TS_IP=100.101.105.75

# Allow established connections
sudo iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# Allow new traffic to Synology on the relevant ports
for port in 6690 6691 5001 32400; do
sudo iptables -A FORWARD -p tcp -d $SYNO_TS_IP --dport $port -j ACCEPT
done

# NAT: client → mc-proxy public IP → Synology via Tailscale
for port in 6690 6691 5001 32400; do
sudo iptables -t nat -A PREROUTING -p tcp --dport $port -j DNAT --to-destination $SYNO_TS_IP:$port
done

# Masquerade traffic going to Synology (so replies go back via mc-proxy)
sudo iptables -t nat -A POSTROUTING -d $SYNO_TS_IP -j MASQUERADE
```

What this does:
•	Anyone hitting mc1.demonsmp.win:6690 will actually hit 100.101.105.75:6690 (Synology) over Tailscale.
•	Same for:
•	6691 → Synology Drive Web
•	5001 → DSM HTTPS
•	32400 → Plex

If you want different public ports than internal, we can adjust rules per-port instead of the for loop.

⸻

## 4. Test the new path

From mc-proxy:

# Can mc-proxy reach Synology over Tailscale?
```
nc -vz 100.101.105.75 5001
nc -vz 100.101.105.75 6690
nc -vz 100.101.105.75 6691
nc -vz 100.101.105.75 32400
```

From outside (internet):
•	Test DSM:

```
curl -k https://mc1.demonsmp.win:5001
```

	•	Test Synology Drive port:

```
nc -vz mc1.demonsmp.win 6690
```

	•	Test Plex:

```
nc -vz mc1.demonsmp.win 32400
```


If those work → your Oracle → Tailscale → Synology chain is good and SSH tunnels are officially dead.

⸻

## 5. Persist iptables across reboot

On mc-proxy:

```
sudo apt update
sudo apt install -y iptables-persistent

# Save current rules
sudo netfilter-persistent save
```

Now the rules survive reboots.


## 6. Cloudflare tunnels vs this setup
* Cloudflare HTTP(S) tunnel (config.yml with ingress) is separate and doesn't depend on mc1 at all.

* We can:
* Keep Cloudflare for HTTP/S names (*.demonsmp.win → 192.168.2.x), OR
* Eventually re-point Cloudflare origins to the Tailscale IP (e.g. http://100.101.105.75:5001) and get rid of M1 from the path entirely.

But raw TCP tunnels (Drive, DSM via autossh, Plex) can be fully removed now. mc1 forwards directly over Tailscale.