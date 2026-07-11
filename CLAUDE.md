# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Operations toolkit for the **ocete.ch** hosting platform: one Octbase stack
per client, provisioned by Ansible from a git-versioned client ledger, plus
fleet monitoring and host backups. The [README](README.md) is the full
reference (layout, ledger fields, runbooks); `docs/platform-overview.md` maps
this repo against the other three (`dev.ocete.ch`, `demo.ocete.ch`,
`ocete.ch`). One concern, one owner — link to the authoritative doc rather
than copying content between repos (see platform-overview §5).

**Where this checkout runs:** on the production host itself, but the
playbooks are designed to run **from a separate admin machine** over SSH
(`inventory/hosts.yml` targets `root@ocete.ch`) — and **Ansible is not
installed on this host**. So from here you can edit playbooks/templates,
manage the ledger, and inspect live host state (stacks, timers, backups),
but you cannot execute playbooks. Don't try to install Ansible or run
playbooks locally to "help" — that is an operator decision.

## Commands

```bash
./ledger/ledger.py new <name> --display "…" --edition business [--jira-import] \
    --max-users N --contact a@b.c        # scaffold a client file, allocate ports
./ledger/ledger.py list                  # client table
./ledger/ledger.py validate              # names, editions, add-on rules, port collisions
./ledger/ledger.py next-ports            # next free frontend/api/postgres triplet

# Syntax-check YAML and Jinja2 without Ansible (see the playbook-check skill)
python3 -c "import yaml,glob; [yaml.safe_load_all(open(f).read()) and print('ok', f) for f in glob.glob('playbooks/*.yml')]"

# From the admin machine only:
ansible-playbook playbooks/create-instance.yml -e client=<name>   # create OR update (idempotent)
ansible-playbook playbooks/remove-instance.yml -e client=<name> -e confirm=<name>
ansible-playbook playbooks/migrate-instance.yml -e client=<name>   # move an installation (prompts for the source)
ansible-playbook playbooks/set-max-users.yml -e client=<name>
ansible-playbook playbooks/install-monitoring.yml
```

There is no CI, test suite, or linter in this repo.

Prefer the project skills — they encode the exact procedures and the current
platform state:
- `client-ops` — onboard / reconfigure / offboard a client; release rollout to clients
- `migrate-instance` — move an installation to its own account and/or domain (adopt a legacy stack, rename a client)
- `playbook-check` — validate playbook/template/ledger changes before they ship (no Ansible here)
- `consistency-check` — the cross-repo contract review (register §3) after releases or env/port/version changes
- `fleet-health` — monitoring, backup, and live host state; where to diagnose an unhealthy stack

## Key conventions

- **The ledger is the single source of truth** (`ledger/clients/*.yml`, one
  file per client; file name = subdomain label = Linux account suffix).
  Playbooks read it directly. Always `./ledger/ledger.py validate` before
  committing a ledger change. Offboarded clients keep their file with
  `status: removed` — it is the historical record.
- **No secrets in the ledger or this repo.** Per-client secrets are generated
  at first deploy and live only in the client's `.env` on the server (0600).
  SMTP credentials belong in Ansible Vault, not `group_vars/all.yml`.
- **`create-instance.yml` is also the update path** — it is idempotent and
  re-applies ledger- and platform-managed settings without touching secrets
  or data. A change to `env.j2`, the client compose override, or
  `group_vars/all.yml` reaches clients only when the playbook is re-run for
  each active client.
- **Cross-repo contracts are conventions, not CI.** Before changing env
  variables, ports, editions, limits, versions, or health probing anywhere,
  read `docs/consistency-register.md` — `playbooks/templates/env.j2` and
  `playbooks/files/podman-compose.client.yml` must track the app repo's
  `.env.example` and compose file (contracts C1/C2), `ledger.py`'s
  `RESERVED_PORTS`/`RESERVED_NAMES`/`EDITIONS` mirror host and product facts
  (C3/C8/C10). Record found drift in the register's §2 with a date.
- **Version stamping:** `octbase_version` in `inventory/group_vars/all.yml`
  (and per-client `app_version`) must correspond to a dated release entry in
  the app repo's `CHANGELOG.md` (contract C4).
- **Docs carry state:** `docs/production-readiness-plan.md` owns the ordered
  launch-blocker list; the register owns drift tracking. When work closes a
  gap listed there or in the README's "Known gaps", update that list in the
  same commit.

## Behavioral Guidelines

1. **Production safety first** — this repo *is* the production control plane.
   Read-only inspection of the host (`podman ps`, `systemctl --user status`,
   `journalctl`, reading `~/backups/backup.log`) is always fine; anything
   that starts/stops/restarts stacks, edits live `.env` files, or touches
   other checkouts' state needs an explicit ask.
2. **Think before coding** — state assumptions; if multiple interpretations
   exist, present them instead of picking one silently; if something is
   unclear, stop and ask.
3. **Simplicity first** — minimum change that solves the problem; no
   unrequested configurability or abstractions.
4. **Surgical changes** — every changed line traces to the request; match
   existing style (the playbooks favor explicit, commented tasks and
   `ansible.builtin.` FQCNs).
