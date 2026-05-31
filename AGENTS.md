# AGENTS.md

Guidance for AI coding agents working in this repository.

## What this project is

A **single interactive Bash installer** that sets up a **fresh (clean)
[KumoMTA](https://kumomta.com) outbound email server** on **Rocky Linux 8 / 9**
(KumoMTA's officially recommended platform; also AlmaLinux / RHEL / CentOS
Stream 8/9) **or Ubuntu 20.04 / 22.04**. It auto-detects the OS family and uses
the matching package manager (`dnf`/`apt`) and firewall (`firewalld`/`ufw`).
There is no application code, build system, or dependency manifest — the entire
project is one script plus its documentation.

The installer performs: system checks → interactive configuration → KumoMTA
install (official dnf or apt repo) → OS tuning → live DNS verification → Let's
Encrypt SSL (certbot) → DKIM key generation → KumoMTA policy generation
(modeled on the official example, with Traffic Shaping Automation) →
`kumod --validate` → start `kumo-tsa-daemon` + `kumomta` → firewall → optional
test send → prints & saves all DNS records and SMTP credentials.

`enable-ssl.sh` is a separate, re-runnable helper to obtain the Let's Encrypt
cert and wire STARTTLS into the policy after the fact (also cross-distro).

## Repository layout

```
install.sh        The whole installer (Bash). Edit this for any behavior change.
enable-ssl.sh     Re-runnable helper: obtain LE cert + enable STARTTLS post-install.
check-rotation.sh Re-runnable helper: burst-inject + tally egress-source (IP)
                  rotation, and check each source IP's PTR.
README.md         End-user docs: requirements, ports, firewall, DNS workflow, usage.
AGENTS.md         This file.
CLAUDE.md         Symlink -> AGENTS.md (so Claude Code reads the same guidance).
LICENSE           MIT license.
```

There are intentionally **no config files in the repo**. KumoMTA's policy files
(`init.lua`, `tsa_init.lua`, `sources.toml`, `dkim_data.toml`, `shaping.toml`,
`queues.toml`, `listener_domains.toml`) are **generated at runtime by
`install.sh`** on the target server under `/opt/kumomta/etc/policy/`. Do not
look for them here.

## How to validate changes

This sandbox has no `kumod`, `openssl`, `certbot`, or `lua`, so those steps run
only on the target host. For repo-side checks:

```bash
bash -n install.sh          # syntax check (required before commit)
shellcheck install.sh       # if available; aim for no warnings
```

For a full end-to-end check, exercise the real functions inside containers for
all four targets: `rockylinux:9`, `rockylinux:8`, `ubuntu:22.04`, `ubuntu:20.04`.
A practical pattern: base64-encode `install.sh` and pass it via `-e` to
`docker run -i ... bash -s` (bind-mounting `/tmp` may not work in all sandboxes),
then `source` it (minus the final `main "$@"`), call `check_os`,
`install_dependencies`, `install_kumomta`, generate the policy, and run
`kumod --validate`. Verify on EL **and** Debian families since the package
manager, firewall, and certbot source all branch on `OS_FAMILY`.

For logic-only testing, copy individual functions into a scratch script and
feed simulated input via `printf '...\n' | func`. The input helpers
(`ask`, `ask_num`, `ask_secret`, `confirm`) write the prompt to the controlling
terminal (`$UI`, i.e. `/dev/tty`) and read input from `/dev/tty`, while the
chosen value is echoed to **stdout** — so `var=$(ask ...)` captures only the
answer and the prompt is always visible even inside command substitution.

## Script architecture (`install.sh`)

- Strict mode: `set -euo pipefail`. Keep it that way; guard commands that may
  return non-zero (`... || true`, or wrap in `if`).
- Tunable constants are grouped near the top (repo URLs, KumoMTA paths, user).
- Flow is a sequence of small functions orchestrated by `main()`.
- **All UI goes to `$UI` (the terminal), never stdout.** `say`/`info`/`ok`/
  `warn`/`err`/`header`/`banner` and every prompt write to `$UI` so they are
  visible even when a value-returning helper runs inside `$(...)`. Do not add
  a global `exec > >(tee ...)` redirect — it broke prompt visibility and spinner
  animation. Command output is captured to `$INSTALL_LOG` by `run_step`.
- **Long-running commands use `run_step "msg" cmd...`** which animates a spinner
  on `$UI`, logs output, and returns the command's exit code. Always pair with
  `|| die`, `|| true`, or an `if`.
- Config files are produced by `write_*` functions using heredocs that
  interpolate the gathered variables.

## Key domain facts (do not regress these)

- **KumoMTA supports STARTTLS only — not implicit TLS / SMTPS.** Therefore there
  is **no port 465 listener**. Submission is on **587 (STARTTLS)**; **25** is for
  delivery + inbound bounces. Confirmed by the KumoMTA team.
- **Outbound port 25 is blocked by default on most VPS providers** — the script
  probes it and warns; unblocking is a provider-side action.
- KumoMTA configuration is **Lua** (`/opt/kumomta/etc/policy/init.lua`) using the
  **`policy-extras` helpers** that read TOML data files. The service is
  `kumomta.service`; the binary is `/opt/kumomta/sbin/kumod`.
- **Rate limiting is per `(egress source -> destination provider)`**, not a
  single global daily counter. "Daily volume" input is only used for
  capacity/warmup guidance; `shaping.toml`'s `max_message_rate` is the real cap.
- **HTTP injection API** (used by the test send): `POST` to
  `http://127.0.0.1:8000/api/inject/v1` with JSON
  `{"envelope_sender","recipients":[{"email"}],"content"}`. In `content`, line
  breaks must be JSON `\n` escapes (literal backslash-n in the shell string).
- **Subdomain / HELO naming:** 1st IP → `smtp`, then `mta1`, `mta2`, … (`mtaN-1`
  for the Nth IP). Each must have a matching forward A record and PTR.
- **DKIM selector** defaults to `kumo` (record published at
  `kumo._domainkey.<domain>`); a fresh 2048-bit key is generated per install.

## Verified install/config facts (do not regress)

These were validated against the official docs and live container tests;
changing them risks breaking the install or `kumod --validate`:

- **OS detection (`check_os`)** sets `OS_FAMILY` to `el` or `debian` plus
  `EL_VER` (8/9) or `UBU_VER` (22/20). Package manager, firewall, and certbot
  source all branch on `OS_FAMILY`.
- **EL repo (dnf):** write `https://openrepo.kumomta.com/files/kumomta-rocky.repo`
  directly to `/etc/yum.repos.d/kumomta.repo` (avoids needing
  `dnf-plugins-core`/`config-manager`). It uses `$releasever`, so one file works
  on EL8 and EL9.
- **Ubuntu repo (apt):** dearmor the `kumomta-ubuntu-<22|20>/public.gpg` key to
  `/usr/share/keyrings/kumomta.gpg` and **`chmod 644`** it (apt fetches/verifies
  as the unprivileged `_apt` user; a 0600/0640 keyring makes apt silently skip
  the signed repo), then install the `kumomta-ubuntu<22|20>.list` sources file.
- **Install flow is 3-tier** (per family): normal install → clean-cache retry →
  direct `.rpm`/`.deb` download from the stable repo. The candidate check
  (`kumo_have_candidate`) **captures `apt-cache policy` to a var and matches with
  `[[ =~ ]]`** — never pipe into `grep -q`, which under `pipefail` dies from
  SIGPIPE and yields a false negative.
- **Do NOT add the `curl` package to the dnf install list** — Rocky ships
  `curl-minimal`; pulling full `curl` conflicts and aborts the transaction. (On
  Ubuntu `curl` is installed normally.)
- **Drop privileges with `runuser -u kumod --`** (util-linux; on both families),
  not `sudo -u`.
- **Traffic Shaping Automation (TSA) is enabled:** `init.lua` uses
  `shaping:setup_with_automation { publish/subscribe = http://127.0.0.1:8008,
  extra_files = {community (if present), local shaping.toml} }`, calls
  `shaper.setup_publish()` in `init`, and registers
  `get_egress_path_config`. A `tsa_init.lua` is generated and the
  `kumo-tsa-daemon` service is started before `kumomta`.
- **Helper setup ORDER matters:** set up shaping **before** the queue helper —
  both register `get_queue_config` and KumoMTA requires `queue.lua` to register
  LAST, or `kumod --validate` fails.
- **SMTP AUTH handler signature is 4 args:** `smtp_server_auth_plain(authz,
  authc, password, conn_meta)` — `authc` is the username. (AUTH is offered only
  after STARTTLS; KumoMTA has no AUTH LOGIN event, only PLAIN.)
- **Credentials are validated against a SQLite datasource**, the official
  inbound-auth pattern (docs.kumomta.com/userguide/policy/inbound_auth ->
  "Querying a Datasource for Authentication"). `init.lua` does
  `local sqlite = require 'sqlite'`, defines `sqlite_auth_check(user, password)`
  (returns false on blank password, else `select user from auth where user=? and
  pass=?` and compares `result[1] == user`), wraps it in `kumo.memoize`
  (`name='smtp_auth'`, `ttl='5 minutes'`, `capacity=100`) per the docs' warning,
  and calls the cached function from `smtp_server_auth_plain`. The DB is seeded
  by `write_auth_db()` at `/opt/kumomta/etc/auth.db`. Do NOT reintroduce the old
  `os.getenv('SMTP_NEWS_PASSWORD')` / `secrets.env` env-var scheme — it was not a
  documented KumoMTA pattern.
- **Authenticated relay requires `relay_from_authz`** in `listener_domains.toml`
  (the `["*"]` block lists the SMTP user). Successful AUTH alone does NOT grant
  relay; without this an authenticated external client gets `5.7.1 relaying not
  permitted`.
- **Generated TOML:**
  - `dkim_data.toml`: `[base]` with `over_sign = true` + the RFC 6376 header set;
    `[domain."x"]` with `selector` + `algo` (helper derives key path
    `/opt/kumomta/etc/dkim/<domain>/<selector>.key`). Do NOT sign
    `Content-Type`/`MIME-Version`.
  - `shaping.toml`: ONLY `["default"]` (connection_limit + max_message_rate).
    Do NOT add per-domain `["gmail.com"]` blocks — they alias to a provider site
    in the maintained ruleset and cause an "also matched by provider" error.
  - `queues.toml`: `[queue.default]` with `egress_pool` + `max_age`.
  - `sources.toml`: `[source."x"]` (`source_address`, `ehlo_domain`) +
    `[pool."send-pool"."x"]` (`weight`).
  - `listener_domains.toml`: `["*"]` with `relay_to=false`, `log_oob`, `log_arf`,
    `relay_from_authz=[<smtp user>]`.
- **Message handler order:** SMTP-smuggling guard
  (`msg:check_fix_conformance('NON_CANONICAL_LINE_ENDINGS','')`) →
  `queue_helper:apply(msg)` → `dkim_signer(msg)` (signing must be LAST).

## Conventions & guardrails

- **Never commit secrets.** DKIM private keys and the SMTP password are created
  on the target host only. The SMTP password lives in the SQLite auth datasource
  `/opt/kumomta/etc/auth.db` (chmod 600, owned by `kumod`) and is read by
  `init.lua` at AUTH time. Do not write secrets into the repo or into the policy
  files.
- Keep the installer **idempotent / re-runnable**: existing policy is backed up
  before regeneration, and an existing DKIM key is reused rather than
  regenerated (regenerating would invalidate the published DNS record).
- Prefer adding a small, well-named function over inlining logic in `main()`.
- When you change ports, firewall rules, generated config, or DNS output, update
  `README.md` to match in the same change.
- ASCII only in script output (no emoji); use the existing `info/ok/warn/err`
  helpers for messages.

## External references

- KumoMTA docs: https://docs.kumomta.com
- Install (Linux): https://docs.kumomta.com/userguide/installation/linux/
- Install tutorial (Rocky Linux): https://docs.kumomta.com/tutorial/installing_kumomta/
- Example policy: https://docs.kumomta.com/userguide/configuration/example/
- HTTP injection: https://docs.kumomta.com/userguide/operation/httpinjection/
