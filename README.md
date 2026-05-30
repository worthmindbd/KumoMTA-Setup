# KumoMTA Setup — neumannassociatesnews.io

KumoMTA configuration migrated from a PowerMTA setup, for a RackNerd Ubuntu
22.04 VPS (4 vCPU / 6 GB / 150 GB) with six IPv4 sending IPs.

- **Sending (From) domain:** `neumannassociatesnews.io`
- **SMTP server / HELO identities:** subdomains `smtp`, `node1`–`node5`
- **Injectors:** MailWizz / Listmonk via port **587 + STARTTLS**

> Files under `etc/` mirror `/opt/kumomta/etc/`. Deploy by copying `etc/` into
> `/opt/kumomta/etc/`. Private keys are **git-ignored** and must be placed
> manually (see step 4).

## Repository layout

```
scripts/
  install.sh             Interactive installer (RECOMMENDED) — see below
  system-prep.sh         Standalone OS tuning only (subset of install.sh)
etc/
  policy/
    init.lua               Main policy — wires the helpers together
    sources.toml           Sending IPs + pool  (PowerMTA virtual-mta / pool)
    dkim_data.toml         DKIM signing        (PowerMTA dkim-* / domain-key)
    shaping.toml           Rate / connection limits (PowerMTA max-msg-rate)
    queues.toml            Pool assignment + bounce-after (max_age)
    listener_domains.toml  Inbound bounce / FBL handling
  dkim/
    neumannassociatesnews.io/
      pmta.key             <- YOU place this (git-ignored). Reuse old PMTA key!
```

> The static files under `etc/policy/` are the **hand-tuned reference** for the
> existing `neumannassociatesnews.io` migration. `scripts/install.sh` instead
> **generates** equivalent files dynamically from your answers — use whichever
> fits: the installer for a fresh guided setup, or the static files to deploy
> the reviewed migration config directly.

## Quick start — interactive installer

```bash
git clone https://github.com/worthmindbd/KumoMTA-Setup.git
cd KumoMTA-Setup
sudo bash scripts/install.sh
```

The installer will:

1. **Check the system** — OS, CPU/RAM/disk, detect IPv4s, probe outbound port 25,
   and offer to disable a conflicting MTA (postfix/exim).
2. **Ask configuration** — main (From) domain, which IPs to use, a HELO subdomain
   per IP (auto `smtp`, `mta1`, `mta2`, … or custom), SMTP AUTH user + password
   (auto-generated), daily volume + per-IP/provider hourly cap, optional warmup,
   DKIM (generate new or reuse an existing key), Let's Encrypt email, DMARC rua,
   and firewall.
3. **Print DNS early** and pause so you can create the A records (required before
   SSL issuance) and set PTRs.
4. **Install KumoMTA**, tune the OS (sysctl/ulimits/hostname), obtain a
   **Let's Encrypt** cert (with an auto-reload renewal hook), set up **DKIM**,
   generate all policy files, **validate**, and start the service.
5. **Print and save** all DNS entries + SMTP credentials to
   `/root/kumomta-install-summary.txt` (chmod 600).

### Notes on the installer's design

- **"Daily limit" vs rate:** KumoMTA throttles per `(IP -> receiving provider)`,
  not as one global daily counter. The installer uses your daily number for
  capacity/warmup advice, and writes a per-IP/provider hourly cap into
  `shaping.toml` (that's the limit that protects deliverability).
- **TLS for `kumod`:** Let's Encrypt private keys are root-only, so certs are
  copied into `/opt/kumomta/etc/tls/` owned by `kumod`; the renewal deploy-hook
  re-copies and restarts the service.
- **Secrets:** the SMTP password is stored in `/opt/kumomta/etc/secrets.env`
  (chmod 600) and injected via a systemd `EnvironmentFile` — never in git.
- **Port 465 (implicit TLS):** the listeners use 587 + STARTTLS; verify implicit
  TLS support in your installed version if you specifically need 465.

## PowerMTA → KumoMTA mapping

| PowerMTA | KumoMTA |
|---|---|
| `<virtual-mta>` / `smtp-source-host` | `[source]` in `sources.toml` |
| `<virtual-mta-pool>` | `[pool]` in `sources.toml` |
| `<domain> max-msg-rate` | `max_message_rate` in `shaping.toml` |
| `dkim-*` / `domain-key` | `dkim_data.toml` + key in `etc/dkim/` |
| `default-virtual-mta pmta-pool` | `egress_pool` in `queues.toml` |
| `bounce-after` | `max_age` in `queues.toml` |
| `<smtp-user>` | `smtp_server_auth_plain` in `init.lua` |
| `always-allow-relaying no` | `relay_hosts` / `relay_to = false` |
| `acct.csv` / `diag.csv` | JSON logs via `configure_local_logs` |

## Manual deploy (static reference files)

> Use this path only if you want to deploy the reviewed migration config
> directly instead of running `scripts/install.sh`.

```bash
# 0. Install KumoMTA from the official APT repo first
#    (see https://docs.kumomta.com/userguide/installation/linux/)

# 1. Clone this repo
git clone https://github.com/worthmindbd/KumoMTA-Setup.git
cd KumoMTA-Setup

# 2. One-time OS prep (hostname, sysctl, ulimits, spool/log dirs)
bash scripts/system-prep.sh
systemctl daemon-reload

# 3. Copy policy into place
mkdir -p /opt/kumomta/etc/policy /opt/kumomta/etc/dkim
cp -r etc/policy/* /opt/kumomta/etc/policy/

# 4. Install the DKIM private key (REUSE the old PowerMTA key — do not regenerate)
mkdir -p /opt/kumomta/etc/dkim/neumannassociatesnews.io
cp /your/backup/etc/pmta/pmta.pem \
   /opt/kumomta/etc/dkim/neumannassociatesnews.io/pmta.key
chown -R kumod:kumod /opt/kumomta/etc/dkim /var/spool/kumomta /var/log/kumomta
chmod 600 /opt/kumomta/etc/dkim/neumannassociatesnews.io/pmta.key

# 5. Provide the submission password to the service (keeps it out of git)
mkdir -p /etc/systemd/system/kumomta.service.d
printf '[Service]\nEnvironment=SMTP_NEWS_PASSWORD=CHANGE_ME\n' \
   > /etc/systemd/system/kumomta.service.d/env.conf
systemctl daemon-reload

# 6. Validate the config BEFORE starting
sudo -u kumod /opt/kumomta/sbin/kumod \
     --policy /opt/kumomta/etc/policy/init.lua --validate

# 7. Start
systemctl enable --now kumomta
journalctl -u kumomta -f
```

## DNS checklist (publish on `neumannassociatesnews.io`)

- **PTR (reverse DNS)** — ask RackNerd to set, and confirm forward A resolves back:
  | IP | PTR / HELO |
  |---|---|
  | 192.236.240.52 | smtp.neumannassociatesnews.io |
  | 192.236.240.53 | node1.neumannassociatesnews.io |
  | 192.236.240.54 | node2.neumannassociatesnews.io |
  | 192.236.240.55 | node3.neumannassociatesnews.io |
  | 192.236.240.56 | node4.neumannassociatesnews.io |
  | 192.236.240.57 | node5.neumannassociatesnews.io |
- **SPF** (on the domain used in MAIL FROM / Return-Path):
  `v=spf1 ip4:192.236.240.52 ip4:192.236.240.53 ip4:192.236.240.54 ip4:192.236.240.55 ip4:192.236.240.56 ip4:192.236.240.57 -all`
- **DKIM** — already published from PowerMTA at
  `pmta._domainkey.neumannassociatesnews.io`. Reuse the same key (step 4) so it
  keeps validating.
- **DMARC** — `_dmarc.neumannassociatesnews.io`, start in monitor mode:
  `v=DMARC1; p=none; rua=mailto:dmarc@neumannassociatesnews.io`

## Notes / decisions

- **IPv6 dropped.** The VPS has no IPv6 bound to `eth0`, and major receivers
  enforce stricter rules on IPv6 senders. The old IPv6 virtual-mta was removed.
  Re-add later only if you provision an IPv6 address *and* set its PTR.
- **`max_age = 1d`** replaces PowerMTA `bounce-after 1m`. One minute would bounce
  greylisted/temporarily-deferred mail almost instantly; change it back in
  `queues.toml` only if that was truly intended.
- **Same IPs = reputation preserved.** These are the IPs PowerMTA used, so no
  fresh warmup is needed as long as PTR + DKIM are intact.
- **Port 465 (implicit TLS):** KumoMTA's ESMTP listener targets STARTTLS.
  Inject via 587 + STARTTLS; verify 465 support in your version if required.
- **Outbound port 25:** confirm RackNerd has it unblocked, or remote delivery
  will fail with connection timeouts.

## Validation reminder

`init.lua` follows KumoMTA's helper model, but helper APIs evolve between
releases. Always run the `--validate` step (step 6) and cross-check against the
[official example policy](https://docs.kumomta.com/userguide/configuration/example/)
for your installed version. The TOML data files are the stable core of this
migration.
