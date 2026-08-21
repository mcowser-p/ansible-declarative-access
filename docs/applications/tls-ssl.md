# TLS / SSL administration

*Audience: college-freshman level and up. Shared reference for every service
that encrypts traffic — the web servers ([httpd](httpd.md), [nginx](nginx.md),
[Tomcat](tomcat.md)) and the databases ([MySQL](mysql.md),
[PostgreSQL](postgresql.md)).*

## What TLS is (and why "SSL")

**TLS** (Transport Layer Security) encrypts traffic between a client and your
server, so nobody in between can read or tamper with it. It's what puts the
padlock and the **https://** on a website. "SSL" is TLS's older name — the two
are used interchangeably in tool names and config keywords (`mod_ssl`,
`ssl_certificate`), but everything modern is really TLS.

TLS does two things at once: **encrypts** the connection, and **proves the
server's identity** using a *certificate* signed by a trusted authority.

## The three files you'll handle

Every TLS setup comes down to a small set of files:

| File | What it is | Who may read it |
|---|---|---|
| **Certificate** (`.crt`, `.pem`) | Public proof of identity, signed by a CA | Anyone — it's public |
| **Private key** (`.key`) | The secret half; proves you own the cert | **Only the service. Guard it.** |
| **Chain / intermediate** (`.crt`) | Links your cert to the trusted root CA | Anyone — public |

**The one rule that matters most: protect the private key.** If it leaks,
anyone can impersonate your server. It is never world-readable and never
leaves the host.

## Getting a certificate

You don't make a trusted certificate yourself — a **Certificate Authority
(CA)** signs it. The usual flow:

```bash
# 1. Generate a private key + a Certificate Signing Request (CSR):
openssl req -newkey rsa:2048 -nodes \
  -keyout myservice.example.edu.key \
  -out myservice.example.edu.csr \
  -subj "/CN=myservice.example.edu"

# 2. Submit the .csr to your institutional CA (or use an ACME client like
#    certbot for automated issuance). You get back a signed .crt (+ chain).
# 3. Keep the .key you generated — it never leaves the host.
```

For quick internal testing only, a **self-signed** cert works (browsers will
warn, because no CA vouches for it):

```bash
openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
  -keyout test.key -out test.crt -subj "/CN=test.local"
```

## Where the files live on EL

Red Hat / AlmaLinux have a standard home for these:

| Directory | Contents | Permissions |
|---|---|---|
| `/etc/pki/tls/certs/` | Certificates + chains (public) | `0644` (world-readable is fine) |
| `/etc/pki/tls/private/` | **Private keys** | `0600 root` — or `0640 root:<service>` |

```bash
sudo cp myservice.example.edu.crt /etc/pki/tls/certs/
sudo cp myservice.example.edu.key /etc/pki/tls/private/
sudo chmod 0644 /etc/pki/tls/certs/myservice.example.edu.crt
sudo chown root:root /etc/pki/tls/private/myservice.example.edu.key
sudo chmod 0600 /etc/pki/tls/private/myservice.example.edu.key
```

**SELinux:** files under `/etc/pki/tls` are labeled correctly already. If you
keep certs somewhere custom, label them `cert_t`
(`sudo semanage fcontext -a -t cert_t '/path(/.*)?' && sudo restorecon -Rv /path`)
or the service will be denied access.

## Wiring it into each service

### nginx and httpd — plain PEM files

Both read the certificate and key directly as PEM files.

**nginx** (`/etc/nginx/conf.d/mysite.conf`):
```nginx
server {
    listen 443 ssl;
    server_name myservice.example.edu;
    ssl_certificate     /etc/pki/tls/certs/myservice.example.edu.crt;
    ssl_certificate_key /etc/pki/tls/private/myservice.example.edu.key;
}
```

**httpd** — install `mod_ssl` first (`sudo dnf install mod_ssl`), then in
`/etc/httpd/conf.d/mysite-ssl.conf`:
```apache
<VirtualHost *:443>
    ServerName myservice.example.edu
    SSLEngine on
    SSLCertificateFile    /etc/pki/tls/certs/myservice.example.edu.crt
    SSLCertificateKeyFile /etc/pki/tls/private/myservice.example.edu.key
</VirtualHost>
```

Test and reload — **no restart needed**:
```bash
sudo nginx -t && sudo systemctl reload nginx        # nginx
sudo apachectl configtest && sudo systemctl reload httpd   # httpd
```

### Tomcat uses a Java keystore

Java doesn't read PEM files directly. Convert your cert + key into a **PKCS12
keystore** (one binary file holding both), then point a TLS connector at it:

```bash
# Combine PEM cert + key into a keystore:
sudo openssl pkcs12 -export \
  -in  /etc/pki/tls/certs/myservice.example.edu.crt \
  -inkey /etc/pki/tls/private/myservice.example.edu.key \
  -out /etc/tomcat/myservice.p12 -name tomcat \
  -passout pass:CHANGE_ME
sudo chown root:tomcat /etc/tomcat/myservice.p12
sudo chmod 0640 /etc/tomcat/myservice.p12
```

Then add a connector in `/etc/tomcat/server.xml`:
```xml
<Connector port="8443" protocol="org.apache.coyote.http11.Http11NioProtocol"
           SSLEnabled="true" scheme="https" secure="true">
    <SSLHostConfig>
        <Certificate certificateKeystoreFile="/etc/tomcat/myservice.p12"
                     certificateKeystorePassword="CHANGE_ME"
                     type="RSA" />
    </SSLHostConfig>
</Connector>
```

`sudo systemctl restart tomcat` (Tomcat has no graceful reload).

> **Simpler alternative — terminate TLS at a front proxy.** A very common
> pattern is to leave Tomcat on plain 8080 and put **nginx or httpd in front**
> doing HTTPS, forwarding to Tomcat over localhost. Then only the proxy handles
> keystores/certs, and Tomcat stays simple. If you already run nginx, prefer
> this.

### Databases encrypt the connection

Databases use TLS to encrypt the link between the **application and the
database**, not for a browser.

**PostgreSQL** — in `postgresql.conf`:
```conf
ssl = on
ssl_cert_file = 'server.crt'   # relative to the data dir /var/lib/pgsql/data
ssl_key_file  = 'server.key'   # MUST be 0600 postgres:postgres
```
Place `server.crt`/`server.key` in `/var/lib/pgsql/data/`, then require it per
connection with a `hostssl` line in `pg_hba.conf`. `sudo systemctl reload
postgresql`.

**MySQL** — version 8 auto-generates self-signed certs in `/var/lib/mysql` on
first start, so TLS already works. For CA-signed certs and to *force* TLS, add
a `/etc/my.cnf.d` drop-in:
```ini
[mysqld]
ssl-ca   = /etc/pki/tls/certs/ca-chain.crt
ssl-cert = /etc/pki/tls/certs/myservice.example.edu.crt
ssl-key  = /etc/pki/tls/private/myservice.example.edu.key
require_secure_transport = ON
```
`sudo systemctl restart mysqld`. Verify with `\s` in the `mysql` client (look
for "Cipher in use").

## Renewal — the thing that bites everyone

**Certificates expire** (often yearly). When one does, the service keeps
running but clients get security errors. To renew: replace the cert (and key,
if it changed) with the new files, then **reload** the service — a reload picks
up new certs gracefully for web servers, no downtime:

```bash
sudo cp new.crt /etc/pki/tls/certs/myservice.example.edu.crt
sudo systemctl reload nginx      # or httpd; restart for tomcat/mysql
```

Track expiry so it never surprises you:
```bash
openssl x509 -enddate -noout -in /etc/pki/tls/certs/myservice.example.edu.crt
# notAfter=Jun  1 12:00:00 2027 GMT
```

Automated issuance (ACME/certbot, or a config-management job) is worth setting
up so renewal isn't a manual calendar reminder.

## TLS under restricted access

Once a team is in the **restricted admin** group
([the lifecycle](../application-deployment-lifecycle.md)), how TLS work splits:

- **Reloading/restarting after a renewal** — *granted.* It's a `systemctl`
  verb on their own service, which their profile already allows.
- **Editing their service's TLS config** (the `conf.d` drop-in, `server.xml`,
  `my.cnf.d`) — *granted* via the folder ACLs in their profile.
- **Placing or rotating the certificate and private key** under
  `/etc/pki/tls/private/` — **not** granted by default. Those files are
  `root:0600`, outside the app's config tree, and handing out write access to
  the private-key store is a deliberate decision, not an install default.

So the clean division is: **the platform team (or an automated
certbot/cert-manager job) owns the key material; the app team configures and
reloads their service to use it.** If a team genuinely needs to manage their
own certs, grant it explicitly — the repo ships a ready example,
`playbooks/application_profile_examples/tls-alma-linux.yml`, which grants
scoped modify access to `/etc/pki/tls/` for a certificate-admin group.

## Quick reference

```bash
# check a cert's expiry
openssl x509 -enddate -noout -in /etc/pki/tls/certs/NAME.crt
# check what a running server presents (from any host)
openssl s_client -connect myservice.example.edu:443 -servername myservice.example.edu </dev/null 2>/dev/null | openssl x509 -noout -dates
# permissions sanity: the key must NOT be world-readable
ls -l /etc/pki/tls/private/NAME.key      # want -rw------- root
# apply a new cert (web servers)
sudo systemctl reload nginx              # or httpd
```
