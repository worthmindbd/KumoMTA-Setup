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
.github/workflows/ci.yml   CI: bash -n + ShellCheck on push / PR.
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
(`ask`, `ask_num`, `confirm`) write prompts to **stderr** and the chosen value
to **stdout**, so `var=$(ask ...)` captures only the answer.

## Script architecture (`install.sh`)

- Strict mode: `set -euo pipefail`. Keep it that way; guard commands that may
  return non-zero (`... || true`, or wrap in `if`).
- Tunable constants are grouped near the top (repo URLs, KumoMTA paths, user).
- Flow is a sequence of small functions orchestrated by `main()`.
- **Interactive prompts run BEFORE** `main()` redirects output to a tee log
  (`exec > >(tee -a "$INSTALL_LOG")`). Keep all `read`/prompt logic inside
  `gather_inputs`/`confirm_summary`, before that redirect, or prompts may buffer.
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
