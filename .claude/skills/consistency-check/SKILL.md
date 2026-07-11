---
name: consistency-check
description: Run the cross-repo consistency review from docs/consistency-register.md — env-variable surface, product limits, editions, versions, ports, health probing across the four platform repos. Use after an app release, after changing env.j2 / the client compose override / ledger.py constants / group_vars, or when asked whether the repos are in sync.
---

# Consistency check — cross-repo contracts

The platform's four repos share env variables, ports, editions, limits and
version strings **by convention, not by CI**. The authoritative list of
contracts (C1–C15) and the drift log live in
[`docs/consistency-register.md`](../../../docs/consistency-register.md) —
read §1 first; this skill is the execution procedure for its §3 checklist.

All four working copies are on this host:

```bash
export OCTBASE_SRC=~/dev.ocete.ch     # app repo (dev checkout)
# ~/demo.ocete.ch (app repo, main) · ~/ocete.ch (marketing) · this repo
```

## Checklist (from register §3, with interpretation)

```bash
cd ~/octbase-service

# C1/C2 — env surface: every key in env.j2 exists in .env.example
# (commented-out optional keys like #OCTBASE_OPTION_JIRA_IMPORT=true count)
grep -oE '^OCTBASE_[A-Z_]+' playbooks/templates/env.j2 | sort -u \
  | while read k; do grep -qE "^#?$k=" $OCTBASE_SRC/.env.example || echo "MISSING in .env.example: $k"; done
# …and the same for the client compose override's env pass-throughs:
grep -oE 'OCTBASE_[A-Z_]+' playbooks/files/podman-compose.client.yml | sort -u \
  | while read k; do grep -qE "^#?$k=" $OCTBASE_SRC/.env.example || echo "MISSING in .env.example: $k"; done

# C4 — every stamped version has a dated changelog entry
grep -h '^OCTBASE_APP_VERSION=' ~/credentials/.env.dev ~/demo.ocete.ch/.env
grep -m1 '^## v' $OCTBASE_SRC/CHANGELOG.md
grep '^octbase_version' inventory/group_vars/all.yml
grep -h 'app_version' ledger/clients/*.yml 2>/dev/null

# C8 — live host ports vs ledger.py RESERVED_PORTS
podman ps --format '{{.Ports}}' | grep -oE '[0-9.]+:[0-9]+' | sort -u
grep -n 'RESERVED_PORTS' ledger/ledger.py

# C13 — deploy source clean and on the released commit
git -C $OCTBASE_SRC status -sb | head -3
```

Manual (no grep suffices):

- **C2 limits**: API code defaults (`$OCTBASE_SRC/octbase-api/cmd/octbase-api/main.go`:
  users 5, upload 10 MB, storage 512 MB) vs `env.j2` vs the pricing note on
  `~/ocete.ch/pricing.html` (the marketing repo's `product-claims-check`
  skill covers the copy side).
- **C3 editions**: `ledger.py` `EDITIONS` + add-on rule vs the API's
  `OCTBASE_EDITION`/`OCTBASE_OPTION_JIRA_IMPORT` gating vs the Business card
  on `pricing.html`.
- **C6/C7**: if health endpoints or compose project/container naming changed
  in the app repo, check `create-instance.yml`/`set-max-users.yml` health
  waits, `remove-instance.yml`'s `podman exec octbase_postgres_1`, and
  `monitoring/monitor-all.sh`.
- **C15 edge targets**: the root-managed `/etc/caddy/Caddyfile` targets must
  match how the resident stacks bind their frontend ports (currently public
  IP → 8080/8081/8082 stay on `0.0.0.0`; see register §2.1 before "fixing").

## Reporting

This check is advisory — report findings per contract, don't fix unless
asked. Any confirmed drift gets an entry in the register's §2 with a date
(and its resolution, once fixed); if a contract gains tooling, move it out
of the §3 manual checklist. Update the register's "Last full review" line
when a full pass is done.
