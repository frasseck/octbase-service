---
name: playbook-check
description: Validate changes to Ansible playbooks, Jinja2 templates, inventory, or ledger files before they reach production — without Ansible (not installed on this host). Use after editing anything under playbooks/, inventory/, or ledger/, or before committing such changes.
---

# Playbook check — validating ops changes without Ansible

**Ansible is not installed on this host** (playbooks run from an admin
machine), so `ansible-playbook --syntax-check` / `--check --diff` are not
available here. These local checks catch the mechanical errors; recommend a
`--check --diff` dry-run from the admin machine for anything beyond trivial.

## Checks (run from the repo root)

1. **Ledger** — always, if anything under `ledger/` changed:
   ```bash
   ./ledger/ledger.py validate && ./ledger/ledger.py list
   ```

2. **YAML parses** — playbooks, inventory, ledger files:
   ```bash
   python3 - <<'EOF'
   import yaml, glob, sys
   bad = 0
   for f in glob.glob('playbooks/*.yml') + glob.glob('inventory/**/*.yml', recursive=True) + glob.glob('ledger/clients/*.yml'):
       try:
           list(yaml.safe_load_all(open(f)))
           print('ok  ', f)
       except yaml.YAMLError as e:
           bad += 1; print('FAIL', f, '--', e)
   sys.exit(1 if bad else 0)
   EOF
   ```

3. **Jinja2 templates compile** (syntax only — undefined variables surface
   only at playbook runtime):
   ```bash
   python3 - <<'EOF'
   import glob, sys
   from jinja2 import Environment
   env = Environment()
   bad = 0
   for f in glob.glob('playbooks/templates/*.j2'):
       try:
           env.parse(open(f).read()); print('ok  ', f)
       except Exception as e:
           bad += 1; print('FAIL', f, '--', e)
   sys.exit(1 if bad else 0)
   EOF
   ```

4. **Variable wiring** — for each `{{ var }}` you added to a template or
   playbook, confirm it is defined in `inventory/group_vars/all.yml`, set by
   the playbook (`set_fact`/`vars:`), or a documented ledger field
   (`ledger/clients/_example.yml.sample`). Grep, don't assume:
   ```bash
   grep -rn '<var_name>' inventory/ playbooks/ ledger/clients/_example.yml.sample
   ```

5. **Contract check** — if the change touches `env.j2`,
   `podman-compose.client.yml`, ports, editions, versions, or health waits,
   run the `consistency-check` skill (register contracts C1–C15). Minimum,
   for env vars (C1): every `OCTBASE_*` key in `env.j2` must exist in the app
   repo's `.env.example`:
   ```bash
   grep -oE '^OCTBASE_[A-Z_]+' playbooks/templates/env.j2 | sort -u \
     | while read k; do grep -qE "^#?$k=" ~/dev.ocete.ch/.env.example || echo "MISSING in .env.example: $k"; done
   ```

6. **State docs** — if the change closes an item in the README's "Known
   gaps" or `docs/production-readiness-plan.md`, update that list in the same
   commit.

## What this cannot catch

Task-level semantics (wrong module args, handler names, `when:` logic),
undefined variables, and host-state assumptions. Those need
`ansible-playbook --syntax-check` and a `--check --diff` run from the admin
machine — say so in the summary when relevant rather than claiming the
playbook is verified.
