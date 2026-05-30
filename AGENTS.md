# AGENTS.md

Guidance for AI coding agents working in this repository.

## What this project is

A **single interactive Bash installer** that sets up a **fresh (clean)
[KumoMTA](https://kumomta.com) outbound email server on Ubuntu 22.04 LTS**.
There is no application code, build system, or dependency manifest — the entire
project is one script plus its documentation.

The installer performs: system checks → interactive configuration → KumoMTA
install (official APT repo) → OS tuning → live DNS verification → Let's Encrypt
SSL → DKIM key generation → KumoMTA policy generation → `kumod --validate` →
service start → UFW firewall → optional test send → prints & saves all DNS
records and SMTP credentials.

## Repository layout

```
install.sh    The whole installer (Bash). Edit this for any behavior change.
README.md     End-user docs: requirements, ports, firewall, DNS workflow, usage.
AGENTS.md     This file.
CLAUDE.md     Symlink -> AGENTS.md (so Claude Code reads the same guidance).
LICENSE       MIT license.
```

There are intentionally **no config files in the repo**. KumoMTA's policy files
(`init.lua`, `sources.toml`, `dkim_data.toml`, `shaping.toml`, `queues.toml`,
`listener_domains.toml`) are **generated at runtime by `install.sh`** on the
target server under `/opt/kumomta/etc/policy/`. Do not look for them here.

## How to validate changes

This sandbox has no `kumod`, `openssl`, `certbot`, or `lua`, so those steps run
only on the target host. For repo-side checks:

```bash
bash -n install.sh          # syntax check (required before commit)
shellcheck install.sh       # if available; aim for no warnings
```

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

These were validated against the official docs in Apr 2026; changing them risks
breaking the install or `kumod --validate`:

- **APT repo:** key `https://openrepo.kumomta.com/kumomta-ubuntu-22/public.gpg`
  dearmored to `/usr/share/keyrings/kumomta.gpg`; sources list downloaded from
  `https://openrepo.kumomta.com/files/kumomta-ubuntu22.list`. `install_kumomta`
  also reads the `signed-by=` path from the list and verifies the `kumomta`
  candidate exists before installing.
- **`kumod --validate`** is the supported pre-flight check (loads policy, inits
  the DKIM signer; does not bind listeners).
- **Shaper MUST be registered:** `local shaper = shaping:setup{...}` does nothing
  on its own — you must `kumo.on('get_egress_path_config', ...)`. The generated
  policy handles both function- and object-style returns.
- **Generated TOML is kept minimal on purpose** to avoid unknown-field errors:
  - `dkim_data.toml`: only `[domain."x"]` with `selector` + `headers` (helper
    derives key path `/opt/kumomta/etc/dkim/<domain>/<selector>.key`, defaults
    RSA sha256, relaxed/relaxed).
  - `queues.toml`: only `[queue.default]` with `egress_pool`.
  - `sources.toml`: `[source."x"]` (`source_address`, `ehlo_domain`) +
    `[pool."send-pool"."x"]` (`weight`).
  - `shaping.toml`: `["default"]` and per-domain `["gmail.com"]` etc. with
    `max_message_rate` (`/hr` is a valid period) and `connection_limit`.
- **Message handler order:** `queue_helper:apply(msg)` then `dkim_signer(msg)`
  (signing must be last).

## Conventions & guardrails

- **Never commit secrets.** DKIM private keys and the SMTP password are created
  on the target host only. The SMTP password lives in
  `/opt/kumomta/etc/secrets.env` (chmod 600) and is injected via a systemd
  `EnvironmentFile`. Do not write secrets into the repo or into the policy files.
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
- Install (Ubuntu): https://docs.kumomta.com/userguide/installation/linux/
- Example policy: https://docs.kumomta.com/userguide/configuration/example/
- HTTP injection: https://docs.kumomta.com/userguide/operation/httpinjection/
