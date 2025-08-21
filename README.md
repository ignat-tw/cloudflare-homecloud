**Homecloud: Cloudflare + Synology Drive (SSH)**
================================================

Expose your**Synology DSM**safely over HTTPS with a**Cloudflare Tunnel**, and get full-speed**Synology Drive (port 6690)
**using a**reverse SSH tunnel**through your Oracle VPS. Works great when your ISP blocks inbound ports or charges extra
for static IP.

**What you get**
----------------

* **DSM UI**(HTTPS) at https://$HOSTNAME via Cloudflare Tunnel

* **Synology Drive**client access at drive.$YOUR\_DOMAIN:6690 via Oracle → reverse SSH → NAS (end-to-end TLS on 6690, no
  Cloudflare throttling)

> Keep Cloudflare’s orange cloud**off**for the 6690 hostname (DNS-only), and**on**or via Tunnel for the DSM/UI hostname.

**Prereqs**
-----------

* macOS (or Linux) host running this repo

* **Docker**; on macOS we use**Colima**(can be disabled)

* **Cloudflare**account + a zone you control

*
    * SSH access via key (e.g.~/.ssh/mc-proxy.key)

* nginx with the**stream**module (or bind 0.0.0.0 directly—see below)

* Ingress rule allowing TCP**6690**and**443**(OCI security list)

* Local firewall (iptables/ufw) allowing the same

*
    * Synology**Drive Server**package installed and running

* Local firewall rule allowing TCP**6690**

* DSM reachable on https://$NAS\_IP:$DSM\_PORT

**Quick start**
---------------

1. **Clone & configure**

Plain
textANTLR4BashCC#CSSCoffeeScriptCMakeDartDjangoDockerEJSErlangGitGoGraphQLGroovyHTMLJavaJavaScriptJSONJSXKotlinLaTeXLessLuaMakefileMarkdownMATLABMarkupObjective-CPerlPHPPowerShell.propertiesProtocol
BuffersPythonRRubySass (Sass)Sass (Scss)
SchemeSQLShellSwiftSVGTSXTypeScriptWebAssemblyYAMLXML`   cp .env.example .env # or paste the block below into .env   `

**.env (example)**

Plain
textANTLR4BashCC#CSSCoffeeScriptCMakeDartDjangoDockerEJSErlangGitGoGraphQLGroovyHTMLJavaJavaScriptJSONJSXKotlinLaTeXLessLuaMakefileMarkdownMATLABMarkupObjective-CPerlPHPPowerShell.propertiesProtocol
BuffersPythonRRubySass (Sass)Sass (Scss)
SchemeSQLShellSwiftSVGTSXTypeScriptWebAssemblyYAMLXML`   # ---- Cloudflare Tunnel basics ---- TUNNEL_NAME=homecloud # Filled by ./run.sh bootstrap  TUNNEL_ID= HOSTNAME=cloud.demonsmp.win # NAS origin  NAS_IP=192.168.2.10  DSM_PORT=5001 # ---- Colima VM (headless Docker) ---- COLIMA_ENABLE=true  COLIMA_PROFILE=default  COLIMA_CPUS=1  COLIMA_MEMORY=1GiB  COLIMA_DISK=10GiB  COLIMA_VM_TYPE=vz # qemu fallback if vz isn't available # ---- Cloudflared runtime niceties ---- CF_LOGLEVEL=info  METRICS_PORT=49383 # exposes /metrics on host:49383 # ---- Oracle jump host for raw TCP (Synology Drive) ---- SSH_KEY_PATH=$HOME/.ssh/mc-proxy.key  JUMP_HOST=ubuntu@mc1.demonsmp.win # Where the tunnel connects on your LAN (NAS)  DRIVE_LOCAL_IP=192.168.2.10  DRIVE_LOCAL_PORT=6690 # Where SSH -R exposes the socket on the Oracle box  DRIVE_REMOTE_PORT=16690 # Public port on Oracle (nginx stream listens here)  DRIVE_PUBLIC_PORT=6690 # If "true", bind 0.0.0.0:$DRIVE_PUBLIC_PORT directly from SSH and skip nginx # (requires sshd_config: GatewayPorts clientspecified on the VPS)  DRIVE_REMOTE_BIND_ALL=false   `

1. **Create the Cloudflare Tunnel (for DSM UI)**

Plain
textANTLR4BashCC#CSSCoffeeScriptCMakeDartDjangoDockerEJSErlangGitGoGraphQLGroovyHTMLJavaJavaScriptJSONJSXKotlinLaTeXLessLuaMakefileMarkdownMATLABMarkupObjective-CPerlPHPPowerShell.propertiesProtocol
BuffersPythonRRubySass (Sass)Sass (Scss)
SchemeSQLShellSwiftSVGTSXTypeScriptWebAssemblyYAMLXML`   ./run.sh bootstrap # browser auth → creates tunnel + DNS route for $HOSTNAME   `

Update cf/config.yml(committed file) to map your services:

Plain
textANTLR4BashCC#CSSCoffeeScriptCMakeDartDjangoDockerEJSErlangGitGoGraphQLGroovyHTMLJavaJavaScriptJSONJSXKotlinLaTeXLessLuaMakefileMarkdownMATLABMarkupObjective-CPerlPHPPowerShell.propertiesProtocol
BuffersPythonRRubySass (Sass)Sass (Scss)
SchemeSQLShellSwiftSVGTSXTypeScriptWebAssemblyYAMLXML`   tunnel:   credentials-file: /etc/cloudflared/.json  loglevel: info  metrics: 127.0.0.1:49383  ingress:    - hostname: cloud.demonsmp.win      service: https://192.168.2.10:5001      originRequest:        noTLSVerify: true - hostname: manictime.demonsmp.win      service: http://192.168.2.88:38383      originRequest:        httpHostHeader: manictime.demonsmp.win - service: http_status:404   `

1. **Run Cloudflared in Docker**

Plain
textANTLR4BashCC#CSSCoffeeScriptCMakeDartDjangoDockerEJSErlangGitGoGraphQLGroovyHTMLJavaJavaScriptJSONJSXKotlinLaTeXLessLuaMakefileMarkdownMATLABMarkupObjective-CPerlPHPPowerShell.propertiesProtocol
BuffersPythonRRubySass (Sass)Sass (Scss)
SchemeSQLShellSwiftSVGTSXTypeScriptWebAssemblyYAMLXML`   ./run.sh start ./run.sh logs ./run.sh status   `

1. **Set up the Synology Drive reverse tunnel**


* **On the Oracle VPS**, configure**nginx stream**(recommended) to listen on**6690**and forward to the loopback socket
  we’ll create with SSH (127.0.0.1:$DRIVE\_REMOTE\_PORT).

/etc/nginx/streams-enabled/synology-drive.conf:

Plain
textANTLR4BashCC#CSSCoffeeScriptCMakeDartDjangoDockerEJSErlangGitGoGraphQLGroovyHTMLJavaJavaScriptJSONJSXKotlinLaTeXLessLuaMakefileMarkdownMATLABMarkupObjective-CPerlPHPPowerShell.propertiesProtocol
BuffersPythonRRubySass (Sass)Sass (Scss)
SchemeSQLShellSwiftSVGTSXTypeScriptWebAssemblyYAMLXML`   server { listen 6690; # public port (OCI must allow)      proxy_pass 127.0.0.1:16690; # matches DRIVE_REMOTE_PORT      proxy_timeout 1h; # long transfers      proxy_connect_timeout 10s; }   `

Enable + reload:

Plain
textANTLR4BashCC#CSSCoffeeScriptCMakeDartDjangoDockerEJSErlangGitGoGraphQLGroovyHTMLJavaJavaScriptJSONJSXKotlinLaTeXLessLuaMakefileMarkdownMATLABMarkupObjective-CPerlPHPPowerShell.propertiesProtocol
BuffersPythonRRubySass (Sass)Sass (Scss)
SchemeSQLShellSwiftSVGTSXTypeScriptWebAssemblyYAMLXML`   sudo nginx -t && sudo systemctl reload nginx   `

* **Open the port**on Oracle (examples):

Plain
textANTLR4BashCC#CSSCoffeeScriptCMakeDartDjangoDockerEJSErlangGitGoGraphQLGroovyHTMLJavaJavaScriptJSONJSXKotlinLaTeXLessLuaMakefileMarkdownMATLABMarkupObjective-CPerlPHPPowerShell.propertiesProtocol
BuffersPythonRRubySass (Sass)Sass (Scss)
SchemeSQLShellSwiftSVGTSXTypeScriptWebAssemblyYAMLXML`   # OCI security list: add ingress "TCP 6690" from 0.0.0.0/0 # Local firewall:  sudo iptables -C INPUT -p tcp --dport 6690 -j ACCEPT || \ sudo iptables -I INPUT -p tcp --dport 6690 -j ACCEPT  sudo iptables-save | sudo tee /etc/iptables/rules.v4 >/dev/null   `

* **Create the reverse SSH tunnel from your LAN to Oracle**

Plain
textANTLR4BashCC#CSSCoffeeScriptCMakeDartDjangoDockerEJSErlangGitGoGraphQLGroovyHTMLJavaJavaScriptJSONJSXKotlinLaTeXLessLuaMakefileMarkdownMATLABMarkupObjective-CPerlPHPPowerShell.propertiesProtocol
BuffersPythonRRubySass (Sass)Sass (Scss)
SchemeSQLShellSwiftSVGTSXTypeScriptWebAssemblyYAMLXML`   ./run.sh drive-tunnel-start ./run.sh drive-tunnel-status # (to restart) ./run.sh drive-tunnel-recreate # (to stop)    ./run.sh drive-tunnel-stop   `

This creates:

**Oracle 127.0.0.1:16690 → NAS 192.168.2.10:6690**, and nginx exposes**Oracle:6690**publicly.

1. **DNS (Cloudflare)**


* DSM UI hostname (e.g. cloud.demonsmp.win) → handled by**Tunnel**(orange cloud ok).

* **Drive hostname**(e.g. drive.demonsmp.win) →**A record to Oracle public IP**,**DNS only**(gray cloud).


1. **Synology Drive Client**


* Server:drive.demonsmp.win:6690(or your VPS IP:6690)

* Log in with NAS account. Transfers go**directly**through your SSH tunnel—no Cloudflare in the data path.

**Commands (cheatsheet)**
-------------------------

Plain
textANTLR4BashCC#CSSCoffeeScriptCMakeDartDjangoDockerEJSErlangGitGoGraphQLGroovyHTMLJavaJavaScriptJSONJSXKotlinLaTeXLessLuaMakefileMarkdownMATLABMarkupObjective-CPerlPHPPowerShell.propertiesProtocol
BuffersPythonRRubySass (Sass)Sass (Scss)
SchemeSQLShellSwiftSVGTSXTypeScriptWebAssemblyYAMLXML`   # Cloudflared (DSM UI via Tunnel)  ./run.sh bootstrap # login + create tunnel + route DNS ./run.sh start # start cloudflared in Docker ./run.sh logs ./run.sh status ./run.sh stop # Cloudflare tunnel admin ./run.sh tunnel-login ./run.sh tunnel-create ./run.sh tunnel-dns ./run.sh tunnel-list ./run.sh tunnel-id ./run.sh tunnel-delete # Synology Drive raw TCP tunnel (SSH → Oracle)  ./run.sh drive-tunnel-start ./run.sh drive-tunnel-status ./run.sh drive-tunnel-recreate ./run.sh drive-tunnel-stop   `

**Troubleshooting**
-------------------

*
    * ./run.sh drive-tunnel-status shows PID?

* On Oracle:ss -tlnp | grep 6690 and ss -tlnp | grep 16690

* nc -vz 127.0.0.1 16690 on Oracle should succeed

* Check nginx stream logs (if configured) and firewall (OCI + iptables/ufw)

* Verify NAS firewall allows**6690**

*
    * ./run.sh logs(cloudflared) for origin errors

* Confirm cf/config.yml uses correct NAS IP + port

* In Cloudflare DNS, the_tunnelled_hostname should be proxied (orange)

*
    * That’s why Drive uses the direct SSH/6690 path; ensure you’re using the drive.\*:6690 endpoint, not the Cloudflare
      URL.

**Security notes**
------------------

* Port**6690**is TLS-encrypted by Synology Drive itself. With the SSH reverse tunnel and nginx stream, you’re forwarding
  raw TLS end-to-end (Oracle does not decrypt).

* Keep SSH keys safe (SSH\_KEY\_PATH) and consider limiting Oracle’s inbound 6690 to your IP ranges if possible.

* For DSM UI, consider installing a proper certificate on DSM or terminate with Cloudflare Origin cert at the Tunnel
  edge.

**Optional: bind 0.0.0.0 directly (skip nginx)**
------------------------------------------------

Set in .env:

Plain
textANTLR4BashCC#CSSCoffeeScriptCMakeDartDjangoDockerEJSErlangGitGoGraphQLGroovyHTMLJavaJavaScriptJSONJSXKotlinLaTeXLessLuaMakefileMarkdownMATLABMarkupObjective-CPerlPHPPowerShell.propertiesProtocol
BuffersPythonRRubySass (Sass)Sass (Scss)
SchemeSQLShellSwiftSVGTSXTypeScriptWebAssemblyYAMLXML`   DRIVE_REMOTE_BIND_ALL=true   `

…and ensure Oracle’s sshd\_config has:

Plain
textANTLR4BashCC#CSSCoffeeScriptCMakeDartDjangoDockerEJSErlangGitGoGraphQLGroovyHTMLJavaJavaScriptJSONJSXKotlinLaTeXLessLuaMakefileMarkdownMATLABMarkupObjective-CPerlPHPPowerShell.propertiesProtocol
BuffersPythonRRubySass (Sass)Sass (Scss)
SchemeSQLShellSwiftSVGTSXTypeScriptWebAssemblyYAMLXML`   GatewayPorts clientspecified   `

Then the SSH command will bind**0.0.0.0:$DRIVE\_PUBLIC\_PORT**directly on Oracle, and you don’t need nginx stream. You
still must open 6690 in OCI + local firewall.

That’s it—DSM over Cloudflare Tunnel, bulk file sync over fast raw 6690.