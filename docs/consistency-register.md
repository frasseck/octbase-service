# Consistency register — cross-repo contracts and known drift

The platform spans four repositories (see the
[platform overview](platform-overview.md)) that share names, ports, env
variables, limits and version strings **by convention, not by tooling** —
almost none of these contracts is enforced by CI across repo boundaries.
This register makes them explicit: what must stay in sync, where each side
lives, and the drift found at the last review.

**Last full review: 2026-07-10, two passes** (all four working trees + the
live host state; the second pass extended coverage to CI, scripts, the
operations layer, Caddy configs, all app docs, the mailer and locale parity).
**All drift found was fixed the same day** — §2 and §2.0 keep the findings
with their resolutions; the few genuinely open remainders are in §2.1.
Re-run the checks in §3 after any release, and record findings here with a
date — most recently done 2026-07-15 as a full deep review of this repo plus
the live host (§2.4; the v1.0.5–v1.0.7 releases had skipped this checklist).

## 1. The contracts

| # | Contract — what must stay in sync | Defined in | Must match |
|---|---|---|---|
| C1 | **Env variable surface**: every `OCTBASE_*` variable's name and default | app repo `.env.example` + code defaults | app `podman-compose.yml` pass-through · this repo `env.j2` + `podman-compose.client.yml` · app `README.md` env table |
| C2 | **Product limits sold = limits enforced**: min 5 seats, 10 MB/file, 0.5 GB/user | API code defaults (`main.go`: users 5, upload 10, storage 512) | `env.j2` (10/512) · client override fail-closed defaults · `ocete.ch` pricing note (“10 MB per file, 0.5 GB … per user”, “minimum 5 users”) |
| C3 | **Edition model**: `team \| business \| enterprise`; Jira import = add-on on business only, included in enterprise, never on team | API `OCTBASE_EDITION` / `OCTBASE_OPTION_JIRA_IMPORT` gating | `ledger.py` (`EDITIONS`, add-on rule) · `create-instance.yml` assert · `ocete.ch/pricing.html` (add-on shown only on the Business card) |
| C4 | **Version stamping**: a deployed `OCTBASE_APP_VERSION` must correspond to a dated `CHANGELOG.md` release entry | app repo `CHANGELOG.md` (release skill renames `Unreleased`) | `OCTBASE_APP_VERSION` in dev/demo `.env` · `octbase_version` in `inventory/group_vars/all.yml` · `app_version` per ledger entry |
| C5 | **API surface**: served routes = `api/openapi.yaml` = app `README.md` API reference | chi router | `TestEveryRouteIsDocumented` covers routes→spec **only** — a route removed from code is *not* flagged when it lingers in the spec or README; check those by hand |
| C6 | **Health contract**: `GET /health` returns 200 on the API port *and* through the frontend Caddy (`@backend` matcher) | app repo (API `main.go`, frontend `Caddyfile`) | `create-instance.yml` / `set-max-users.yml` health waits · `check-health.sh` · `monitor-all.sh` edge probe · external uptime checks |
| C7 | **Compose project/container naming**: client stacks use `COMPOSE_PROJECT_NAME=octbase` → containers `octbase_<service>_1` | `env.j2` | `remove-instance.yml` (`podman exec octbase_postgres_1`) · `set-max-users.yml` (compose-service label filter) · `monitor-all.sh` (`--project octbase`) · `backup-fleet.sh` + `migrate-host.yml` (`octbase_postgres_1`, api label filter) |
| C8 | **Host port registry**: no client port may collide with the dev/demo/marketing stacks | live `.env` files of the three resident stacks | `RESERVED_PORTS` in `ledger.py` (allocation starts at 8110 regardless) |
| C9 | **Isolation claim**: “all service ports bind to 127.0.0.1, only the edge is public” | [security concept §2](security-data-protection-concept.md) | `env.j2` (`127.0.0.1:<port>` — holds for clients) · dev/demo/marketing `.env` port values (**do not** hold, see D6) |
| C10 | **Reserved client names**: `www dev mail api octbase admin` (`demo` unreserved 2026-07-11 — the public demo became a ledger-managed instance, `clients/demo.yml` + `migrate-instance.yml`) | `ledger.py` `RESERVED_NAMES` | `create-instance.yml` assert · `_example.yml.sample` comment |
| C11 | **Postgres image**: all stacks and the backup restore-test use the same image, pinned to major `:18`; restore-test major version ≥ source (currently PG 18.4) | app `podman-compose.yml` | `backup-octbase.sh` `TEST_IMAGE` default · app README quick-start |
| C14 | **Built image names are per compose project** (`localhost/${COMPOSE_PROJECT_NAME}-api` …): two checkouts of the app repo on one host must never overwrite each other's image tags | app `podman-compose.yml` | dev (`octbase_dev`) vs demo (`octbase`) vs client (`octbase`, one per user namespace) builds |
| C15 | **Edge proxy targets**: the root-managed edge Caddyfile's `reverse_proxy` targets must match how the stacks bind their frontend ports | `/etc/caddy/Caddyfile` (root) | `FRONTEND_PORT`/`WEB_PORT` values in the three resident `.env` files; currently the edge targets the host's **public IP**, so those three ports must stay on `0.0.0.0` (see §2.1) |
| C12 | **Public claims = platform facts**: hosting location, data handling, feature/limit statements on `ocete.ch` | privacy policy / terms (legal texts) | marketing copy (features, pricing) · security concept · actual hosting |
| C13 | **Deploy source**: `octbase_src` must point at the released commit with a **clean tree** — `create-instance.yml` rsyncs the working tree as-is | `inventory/group_vars/all.yml` | state of `~/dev.ocete.ch` at rollout time (a live dev checkout, often on a release branch with uncommitted work) |
| C16 | **Client registry conf format** (`/etc/octbase/clients.d/<name>.conf`): `NAME`/`USER_ACCT`/`DOMAIN`/`FRONTEND_PORT`/`API_PORT`/`HOME_DIR`/`DISK_QUOTA_GB` (+ optional `EDGE_PROBE`) — sourced as shell variables | `playbooks/templates/client-registry.conf.j2` | `monitor-all.sh` (health, edge, disk) · `backup-fleet.sh` (dump + files) — a key rename must touch all three |
| C17 | **Instance placement**: a ledger `host:` value must name an entry in `inventory/hosts.yml`; per-client playbooks no-op on every other host, so a wrong value silently deploys nowhere (guarded by an assert + `ledger.py validate`) | `ledger/clients/*.yml` (`host:`) + `default_client_host` in group_vars | `inventory/hosts.yml` host names · the `end_host` guards in every per-client playbook |
| C13b | **Git deploy source**: `sync-instance.yml` deploys `octbase_branch` (default `main`) of `octbase_repo` instead of the `octbase_src` working tree — same rsync excludes, but a clean branch tip, not local edits. It does **not** re-stamp `OCTBASE_APP_VERSION` (that stays ledger/create-instance-driven, C4), so a branch synced ahead of its stamped version reports a stale version until `create-instance.yml` re-runs | `inventory/group_vars/all.yml` (`octbase_repo`/`octbase_branch`) | `sync-instance.yml` · app repo branch tip · C4 version stamp |

## 2. Drift found 2026-07-10 — all fixed same day

Findings from the full review, each with its resolution. “Where” names the
repo that carried the fix.

### D1 — Public demo missed the auth hardening (security) — **fixed**
The 2026-07-10 security review added `OCTBASE_JWT_SECRET` and
`OCTBASE_SECURE_COOKIES=true` to **dev**'s `.env` but not to **demo**'s: the
public demo API ran with an empty JWT secret (demo-mode fallback key — tokens
forgeable by anyone who reads the source), non-`Secure` refresh cookies, no
MFA encryption key, and `OCTBASE_CORS_ORIGIN=http://localhost:8080`.
**Resolution:** `demo.ocete.ch/.env` got its own strong JWT secret, secure
cookies, a fresh `OCTBASE_MFA_ENC_KEY`, and the real public origin
(CORS/app-URL). Because the base compose on `main` doesn't yet thread the
secure-cookie and CORS env vars, demo now layers an **untracked**
`podman-compose.demo.yml` (wired into `octbase.service` and `~/restart.sh`);
it becomes redundant once the next release lands the pass-throughs. Verified
live: `Set-Cookie … HttpOnly; Secure; SameSite=Strict`. Still open: edge
IP/auth restriction for dev+demo (security concept §7).

### D2 — Marketing site contradicted its own privacy policy (legal) — **fixed**
Features/pricing copy said “hosted in Germany”; the privacy policy locales
said “hosted in Switzerland”. Hosting **is** in Germany (operator-confirmed),
and the static HTML fallback in `privacy.html` already said so — only the
`locales/{en,de}.json` strings (which override the HTML at runtime) were
stale. **Resolution:** both locale strings now match the HTML fallback
(Germany, email via the same German processor); image rebuilt and verified
on the live site.

### D3 — Version 1.0.2 deployed without a changelog release (C4) — **fixed**
Deployments stamped `OCTBASE_APP_VERSION=1.0.2` but the changelog's latest
entry was `v1.0.1`, and `octbase_version` in group_vars said `1.0.1`.
**Resolution:** the committed `Unreleased` content (= exactly what `main`
ships on the demo) is now filed as `## v1.0.2 — 2026-07-10` in the app repo's
`CHANGELOG.md`; the still-unreleased `release_v14` work-in-progress entries
(MFA enforcement, password policy, HSTS, …) stay under `Unreleased`.
`octbase_version` bumped to `1.0.2`.

### D4 — Removed endpoints still documented (C5) — **fixed**
The removed `/api/v1/admin/import/{jira,confluence}` endpoints remained in
`api/openapi.yaml` and twice in the app README (invisible to CI: the parity
test only checks routes→spec). **Resolution:** both scrubbed; the README's
import/export docs now cover the actual surface incl. the whole-project ZIP
export/import routes, plus a note pointing former admin-importer users at the
per-project imports.

### D5 — App README env table was stale (C1) — **fixed**
`OCTBASE_MAX_UPLOAD_MB` documented as 25 (actual 10); missing rows for
`OCTBASE_MAX_USERS`, `OCTBASE_MAX_USER_STORAGE_MB`, `OCTBASE_REQUIRE_MFA`;
a leftover “4-hour sliding session” claim (actual: 60 minutes).
**Resolution:** table corrected and completed, session copy fixed.

### D6 — Loopback-binding claim didn't hold for the resident stacks (C9) — **fixed for DB/API; frontends blocked on the edge (§2.1)**
Dev, demo and marketing published everything on `0.0.0.0`, including both
Postgres ports with the default `octbase` password. **Resolution:** Postgres
and API ports now bind `127.0.0.1` (verified: edge and local health all
green). The three **frontend** ports must stay on `0.0.0.0` for now because
the root-managed edge Caddyfile targets the host's public IP
(`178.105.142.1:808x`), not `127.0.0.1` — attempting loopback there 502'd the
whole edge and was rolled back. See §2.1 for the remaining root-level step;
the `.env` comments mark the exact values to flip afterwards.

### D7 — Leftover/duplicated keys in deployed `.env` files — **fixed**
Marketing-split relics (`WEB_PORT`, real `WEB_SMTP_*` credentials) removed
from dev's and demo's `.env`; demo's dead `MAILPIT_HTTP_PORT` removed. The
SMTP credentials now live only in `~/credentials/.env.ocete` (rotation still
worth doing — the old copies sat in two extra files; see §2.1).

### D8 — Minor nits — **fixed**
- `ledger.py` `RESERVED_PORTS` now includes 8026 (C8).
- `_example.yml.sample` reserved-names comment now lists `octbase`, `admin` (C10).
- Layout tables completed: app `README.md`/`CLAUDE.md` now point at
  `docs/technical_documentation.md` (+ a catch-all row); `ocete.ch/README.md`
  lists all five pages.
- `ocete.ch` impressum/imprint mixup was a live bug, not just naming:
  `privacy.html`/`terms.html` loaded a non-existent `js/imprint.js` (404 —
  contact-detail deobfuscation never ran), while the file on disk was
  `js/impressum.js`, and `impressum.html` was an unshipped, unlinked
  duplicate. Standardised on “imprint”: file renamed, references fixed,
  dead page removed.
- Postgres image pinned to major `:18` (= 18.4 today, verified equal to the
  running clusters) in both app compose files, the READMEs and the backup
  script's `TEST_IMAGE` (C11).

### D9 — Dev and demo builds shared one image tag (found while fixing D1/D6) — **fixed**
Both checkouts built `localhost/octbase-api:latest` (same for frontend and
mobile), so whichever stack built last owned the tag and a later plain
`up -d` could recreate the *other* stack's containers from the wrong build.
This had already bitten: the dev API was crash-looping (95 restarts, `no
migration found for version 26`) because it had been recreated from demo's
`main` image while the dev database was already migrated by the `release_v14`
tree. **Resolution:** the app compose now names built images per project
(`localhost/${COMPOSE_PROJECT_NAME:-octbase}-api` …, contract C14); dev
rebuilt as `octbase_dev-*` and healthy (0 restarts, migration 26), demo's
tag rebuilt from its own `main` tree. Client stacks keep the default project
name and are unaffected.

## 2.0 Second review pass, 2026-07-10 (re-run)

A second full pass over all four repos after the morning's fixes, extending
coverage to the corners the first pass skimmed: CI workflow, `scripts/`,
`octbase-operations/`, both frontend Caddy configs, the frontend JS
architecture and guards, all app docs (`operations.md`,
`technical_documentation.md`, `architecture.md`, `business-plan.md`), the
marketing mailer, and full EN/DE locale parity. New findings, all fixed:

### F1 — Prometheus `/metrics` was world-readable through the front door — **fixed everywhere** (dev same day; demo with the v1.0.3 deploy)
The shipped `octbase-frontend/caddy/Caddyfile` proxied `/metrics` to the API,
so every deployed stack exposed Go runtime + per-route request metrics
publicly (verified live on `https://demo.ocete.ch/metrics`).
`docs/operations.md` claimed the route was private-range-restricted — but
that restriction only exists in the standalone `Caddyfile.tls`, which **no
current deployment uses** (the image's Containerfile ships plain
`Caddyfile`; TLS lives at the edge). Since the documented Prometheus scrape
target is the API service directly, the front door simply no longer proxies
`/metrics` (dev rebuilt and verified: SPA fallback, no metrics payload; API
port still serves them). `operations.md` and `technical_documentation.md`
corrected. Demo keeps the old image until the next release — the endpoint
there leaks only demo-stack metrics.

### F2 — CI tested against PostgreSQL 16, production runs 18 — **fixed**
`.github/workflows/ci.yml` used `postgres:16` service containers in both the
test and e2e jobs while every deployment runs the `hi/postgresql` 18.4 image.
Both jobs now use `postgres:18` (tag existence verified on Docker Hub).

### F3 — `scripts/sync-installs.sh` header described an obsolete world — **fixed**
It claimed dev and demo are *different git repos* (`frasseck/taskbase.git`!)
where "a git pull won't work" — today both are `frasseck/octbase` and the
demo's normal deploy path IS `git pull` (restart.sh / release skill). Header
rewritten: the script is an escape hatch for pushing an unmerged tree, and
the next `git pull` deploy overwrites whatever it synced. The related stale
comment on `octbase_src` in this repo's `group_vars/all.yml` was tightened to
the actual contract (released commit, clean tree — C13).

### F4 — `docs/operations.md` env table had the same staleness as the main README (C1) — **fixed**
The doc that `technical_documentation.md` declares the authoritative env-var
reference still said `OCTBASE_MAX_UPLOAD_MB` defaults to 25 (actual 10) and
was missing `OCTBASE_MAX_USERS`, `OCTBASE_MAX_USER_STORAGE_MB`,
`OCTBASE_REQUIRE_MFA`, `OCTBASE_EDITION` and `OCTBASE_OPTION_JIRA_IMPORT`.
All rows added/corrected. (The first pass only fixed the main README's
table — when an env var changes, **both** tables plus `.env.example` need
touching; that's why check §3/C1 exists.)

### F5 — Doc nits — **fixed**
- `technical_documentation.md` described the app CSP as
  `connect-src 'self' ws: wss:` "for websockets" — the actual CSP is
  `connect-src 'self'` and the app deliberately uses no WebSockets (SSE on
  its own origin).
- `CLAUDE.md`/README listed the shared modules as `i18n.js, meta.js` —
  `qrcode.js` is the third file the drift guard covers.

### F6 — Facts worth knowing (no defect)
- **CI already publishes per-commit images** to GHCR
  (`ghcr.io/frasseck/octbase/octbase-{api,frontend,mobile}:<sha>`) on every
  `main` push — directly relevant to this repo's "build once, distribute via
  a registry" roadmap item (README §Known gaps).
- Verified clean on this pass: EN/DE locale key parity is exact in all three
  frontends (marketing, desktop, mobile); the four frontend CI guards pass
  locally; the marketing mailer implements everything the security concept
  claims (per-IP + global rate limit, MX validation, length caps,
  header-injection guard, honeypot, trusted-proxy client IP);
  `business-plan.md` (EUR, Hetzner infra costs) does not conflict with the
  CHF customer pricing — different concerns; `octbase-api/README.md`
  correctly defers to `.env.example`; `architecture.md` and
  `octbase-frontend/js/README.md` match the code conventions.
- Residual quirk, acceptable: the shipped Caddyfile still contains the
  `/mailpit` dev proxy route (502s unless the dev overlay runs — documented
  in-file); HSTS max-age differs between `Caddyfile` (1y) and the unused
  `Caddyfile.tls` (2y).

## 2.1 Open remainders (not fixable from this repo / this account)

> The forward-looking, sequenced version of these (plus the launch blockers
> for client #1) is the
> [production-readiness plan](production-readiness-plan.md); this list only
> tracks drift-review leftovers.

1. **Repoint the edge Caddyfile to loopback** (root): change the three
   `reverse_proxy 178.105.142.1:<port>` targets in `/etc/caddy/Caddyfile` to
   `127.0.0.1:<port>` and reload Caddy; then set
   `FRONTEND_PORT=127.0.0.1:8080/8081` (demo/dev `.env`) and
   `WEB_PORT=127.0.0.1:8082` (marketing `.env`) and restart the three stacks.
   Bonus: the edge config also stops depending on the **dynamic** public IP.
2. ~~Release the pending `release_v14` work~~ — **done 2026-07-10 as
   v1.0.3** (`scripts/release.sh`, merged to `main`, demo redeployed via
   `git pull`). The compose env pass-throughs are on `main`, so demo's
   temporary untracked `podman-compose.demo.yml` was dropped again (unit and
   `~/restart.sh` back to plain `podman-compose`); the demo no longer serves
   public `/metrics` (verified) and reports v1.0.3 with migration 26.
3. **Rotate the marketing SMTP password** — it sat in three files until today.
4. Edge IP/auth restriction for `dev.ocete.ch`/`demo.ocete.ch` and the other
   organizational items — tracked in the security concept §7.

## 2.2 Release check 2026-07-11 (v1.0.4)

§3 checklist re-run after the v1.0.4 release (released and deployed to the
demo the same day; verified live: `/health` reports `1.0.4`, migration 27).
C1 (env surface) and C8 (live ports vs `RESERVED_PORTS`) clean;
`octbase_version` bumped `1.0.3` → `1.0.4` (C4). One new finding:

### D10 — Demo `.env` stamps the unreleased 1.1.0 (C4) — **open**
`~/demo.ocete.ch/.env` was edited to `OCTBASE_APP_VERSION=1.1.0` *after* the
v1.0.4 restart (the running stack was started with — and still reports —
`1.0.4`), so the mis-stamp only bites at the **next** demo restart, which
would then report a version with no dated changelog entry. Likely a mix-up
with dev's `.env` (dev now stamps `1.0.4` while its tree is on
`release_v15`, i.e. the future 1.1.0). **Fix (operator, one line):** set
`OCTBASE_APP_VERSION=1.0.4` back in the demo's `.env`; no restart needed.

Also noted, no defect: `octbase_src` (`~/dev.ocete.ch`) is currently a dirty
`release_v15` tree — fine between rollouts, but it must be on the released
commit with a clean tree (C13) before the pending demo migration or any
client rollout runs.

## 2.3 Fleet update 2026-07-12 (multi-host, resources, quotas, fleet backup)

The `docs/fleet-concept.md` change set (ledger `host:`/`disk_quota_gb`/
`resources:`, per-client host scoping, `migrate-host.yml`,
`suspend-instance.yml`, `set-resources.yml`, `install-backup.yml`, disk
monitoring). New contracts C16/C17 above. Two defects found in review and
fixed with it:

### D11 — Ledger `monitor_edge_probe` never reached the monitor registry — **fixed**
`client-registry.conf.j2` tested the bare variable `monitor_edge_probe`, but
`create-instance.yml` loads the ledger namespaced as `client_ledger` — so the
README-documented per-client edge-probe opt-out was silently ignored (the
registry conf never got an `EDGE_PROBE` line from the ledger). The template
now reads `client_ledger.monitor_edge_probe`.

### D12 — README claimed Ansible ≥ 2.14 works — **fixed**
The playbooks use `ansible.builtin.systemd_service`, which only exists since
ansible-core 2.15; on 2.14 every playbook fails to resolve the module. The
prerequisite now says ansible-core ≥ 2.16.

## 2.4 Deep review 2026-07-15 (this repo + live host, read-only)

Full review of every file in this repo plus read-only host inspection.
Repo-side defects were fixed in the same change set; host-side items need
the operator and are marked **open**. Context: the v1.0.5–v1.0.7 releases
skipped the §3 checklist entirely, which is how D15–D18 accumulated.

### D13 — Fleet monitoring & backup never installed on the host — **open (operator)**
`install-monitoring.yml` / `install-backup.yml` have never been run against
`prod`: no `octbase-monitor`/`octbase-fleet-backup` system units or timers,
`/usr/local/lib/octbase/` missing, no `status.json`. Consequence: the demo —
migrated to `oct-demo` on 2026-07-11 — has had **no database backup since
the migration** (the legacy `claude`-account job cannot see `oct-demo`'s
containers; its last demo dump is from 2026-07-11 03:33, pre-migration
data). Additionally the legacy backup itself has failed since 2026-07-14
("restore-test instance did not become ready"), unnoticed because
`alert_email` is empty and no monitor runs (readiness plan B2). The
fleet-concept "implemented 2026-07-12" and readiness-plan B1 "done" wording
meant the *tooling*, not the installation — both docs corrected. **Fix:**
run both install playbooks from the admin machine, then re-run
`create-instance.yml -e client=demo` (see D19), then fix the legacy job.

### D14 — Public Octbase API on 0.0.0.0:8000; demo frontend on 0.0.0.0:8110 (C9) — **identified 2026-07-15, cleanup open**
The `0.0.0.0:8000` API (`version: "beta"`, dev-default CORS, public
`/metrics`, DB at migration 31) was identified via the process table: a
**natively run e2e test API** — `PORT=8000 go run ./cmd/octbase-api` with
`OCTBASE_DEMO_MODE=true` against a throwaway `octbase_e2e` database on the
dev Postgres (5433) — started 2026-07-15 05:46 by a dev-session in
`~/dev.ocete.ch` (Go binds `:8000` on all interfaces by default). No client
or demo data behind it, but demo mode + public binding = seeded logins
reachable from outside if the firewall allows 8000, and it squats on the
reserved legacy-demo port. **Fix:** stop it when the e2e run is done; make
the e2e harness bind `127.0.0.1`; the durable guard is readiness plan B4
(loopback-only posture / external port scan). Separately, the demo frontend
binds `0.0.0.0:8110` although its edge vhost already targets
`127.0.0.1:8110` — set `FRONTEND_PORT=127.0.0.1:8110` in
`/home/oct-demo/octbase/.env` and restart. Until then C9's "holds for
clients" claim does not hold live.

### D15 — Marketing port 8120 missing from `RESERVED_PORTS` (C8) — **fixed**
`scripts/migrate-ocete-web.sh` moved the marketing site to
`127.0.0.1:8120`, inside the client allocation range (blocks of 10 from
8110; demo holds 8110–8112) — `ledger.py next-ports` would have handed
8120–8122 to the **next client**, whose frontend could then never bind.
8120 added to `RESERVED_PORTS`.

### D16 — Wrong host-scoping variable in three playbooks (C17) — **fixed**
`remove-instance.yml`, `sync-instance.yml` and `set-max-users.yml` scoped
with the undefined variable `host` instead of `client_ledger.host`, so they
always targeted `default_client_host`. Harmless with one inventory host;
on a multi-host fleet `remove-instance.yml` would have deregistered
monitoring/edge on the **wrong host**, silently skipped the account
teardown (its `getent` guard is non-failing) and reported the client
removed while the stack kept running. All three now use
`client_ledger.host | default(default_client_host)` like their siblings.

### D17 — `sync-instance.yml` hardcoded `main`; "no-op" claim false (C13b) — **fixed**
The git task pinned `version: main`, so the documented
`-e octbase_branch=…` override was silently ignored (now
`version: "{{ octbase_branch }}"`). Also, README and the playbook header
claimed a re-run at the branch tip is a no-op — the playbook deliberately
**always** rebuilds and restarts (code is baked into the images); both
texts now state that every sync run causes a brief restart.

### D18 — `octbase_version` stale at 1.0.4 (C4) — **fixed**
The app CHANGELOG's latest release is v1.0.7 (2026-07-14) and the demo
stamps 1.0.7, but group_vars still said 1.0.4 — a new client would have
been deployed from a 1.0.7+ tree yet report 1.0.4. Bumped to `1.0.7`.
Also noted: `octbase_src` (`~/dev.ocete.ch`) is currently a **dirty
`frontend-build-step` tree** — it must be on the released commit with a
clean tree (C13) before any client rollout.

### D19 — Demo's registry conf predates the fleet update (C16) — **open (one playbook run)**
`/etc/octbase/clients.d/demo.conf` (written 2026-07-11) lacks `HOME_DIR`
and `DISK_QUOTA_GB`, so `monitor-all.sh` would skip disk monitoring for the
demo once monitoring is installed. Re-run
`create-instance.yml -e client=demo` (or `set-resources.yml`) to refresh.

### D20 — `env.j2` ↔ app compose `BIND_ADDR` coupling across v1.0.7 (C1/C9) — **recorded**
Since app v1.0.7 the compose prefixes the postgres/API mappings with
`${BIND_ADDR:-127.0.0.1}`, and `env.j2` writes **port-only** values for
those two. The coupling cuts both ways: deploying a **pre-1.0.7 tree** with
the new `.env` binds Postgres/API on `0.0.0.0`; syncing a client whose
`.env` still has the old `127.0.0.1:<port>` values (the ports block is
created once and never rewritten) to a **≥1.0.7 tree** produces an invalid
mapping and the stack won't start. The demo's `.env` was hand-fixed; check
every client's `.env` port lines before crossing the 1.0.7 boundary in
either direction.

### D21 — Minor, noted without fix
- `migrate-instance.yml`'s vhost-retire regex (`\{[^}]*\}`) cannot match a
  Caddy vhost containing nested blocks (`header { … }` etc.); the leftover
  duplicate vhost then fails `caddy validate` **after** the data restore,
  stranding the migration at cutover. Worked for the demo's flat vhost;
  revisit before the next adoption/rename.
- `set-max-users.yml` filters on the `com.docker.compose.service` label
  where everything else uses `io.podman.compose.service` (C7); a miss only
  causes an unnecessary restart, not a wrong result.
- Both backup scripts start the restore-test Postgres **before** taking any
  dump, so an image-pull/startup failure aborts the night with zero dumps —
  exactly the live failure mode since 2026-07-14 (D13). Consider dumping
  first and restore-testing after.

## 2.5 v19 merged to main 2026-07-16 (frontend bind contract)

### D22 — Frontend mapping gained `FRONTEND_BIND_ADDR` (C1/C9) — **env.j2 fixed; live `.env` files open**
`release_v19` (merged to `main` as `0b1158a`, 2026-07-16) changed the
frontend mapping from `"${FRONTEND_PORT:-8080}:8080"` to
`"${FRONTEND_BIND_ADDR:-0.0.0.0}:${FRONTEND_PORT:-8080}:8080"` — the same
class of coupling as D20, now on the third port. `env.j2` wrote
`FRONTEND_PORT=127.0.0.1:<port>`, which expands to a four-segment mapping
(`0.0.0.0:127.0.0.1:8130:8080`); podman rejects it with *invalid port
format* and the frontend container never starts. Found live: `beyags`
create-instance failed at "Enable and start the stack" (podman-compose exit
125) while postgres/API/mobile — whose mappings didn't change — came up.
**Fixed here:** `env.j2` now writes `FRONTEND_BIND_ADDR=127.0.0.1` plus a
port-only `FRONTEND_PORT`. The explicit bind address is load-bearing, not
cosmetic: v19's default is `0.0.0.0` because a standalone stack is its own
public entry, so omitting it publishes every client frontend on all
interfaces and silently breaks C9.

**Open — the ports block is written once and never re-synced, so existing
`.env` files do not get this fix:**
- `beyags` — `.env` already created with the old shape; its stack cannot
  start until the two keys are corrected by hand (or the account is removed
  and re-created; no data yet).
- `demo` — still on 1.0.7 code with a 1.0.7-shaped `.env`. It breaks the
  moment it is deployed a v18+ tree. Fixing it also closes D14's
  `0.0.0.0:8110` frontend binding: `FRONTEND_BIND_ADDR=127.0.0.1` +
  `FRONTEND_PORT=8110`.
- `educaswiss` — never provisioned; gets the new template, no action.

### D23 — v19 merged to main without a changelog release (C4) — **open**
`main` carries v19 (including the `/m/metrics` exposure fix) but its
CHANGELOG top section is still `## Unreleased`; the newest dated entry is
`v1.0.7 — 2026-07-14`. `octbase_version` therefore stays at 1.0.7 and no
longer describes what `main` deploys — a client provisioned from main is
stamped `OCTBASE_APP_VERSION=1.0.7` while running post-1.0.7 code. Same
pattern as D3 and D10. **Fix:** cut the release in the app repo (the
`release` skill renames `Unreleased` to a dated entry), then bump
`octbase_version` here and re-run `create-instance.yml` per client.

## 3. Review checklist (run per release, ~10 minutes)

```bash
# C1/C2 — env surface: every key in env.j2/client override exists in .env.example
# (accept commented-out optional keys like #OCTBASE_OPTION_JIRA_IMPORT=true)
grep -oE '^OCTBASE_[A-Z_]+' playbooks/templates/env.j2 | sort -u \
  | while read k; do grep -qE "^#?$k=" $OCTBASE_SRC/.env.example || echo "MISSING in .env.example: $k"; done

# C4 — stamped versions have a changelog entry
grep -h '^OCTBASE_APP_VERSION=' ~/credentials/.env.dev ~/demo.ocete.ch/.env
grep -m1 '^## v' $OCTBASE_SRC/CHANGELOG.md
grep '^octbase_version' inventory/group_vars/all.yml

# C5 — spec/README paths that no longer exist in code (reverse parity, manual)
grep -oE '/api/v1/[a-z0-9/{}._-]+' $OCTBASE_SRC/api/openapi.yaml | sort -u \
  | while read p; do grep -rq -- "$(echo $p | sed 's/{[^}]*}/…/g' | cut -d… -f1)" \
      $OCTBASE_SRC/octbase-api --include='*.go' -l >/dev/null || echo "check: $p"; done

# C8 — live host ports vs the reserved list
podman ps --format '{{.Ports}}' | grep -oE '[0-9.]+:[0-9]+' | sort -u

# C13 — deploy source is clean and on the released commit
git -C $OCTBASE_SRC status -sb | head -3
```

Findings go into §2 with a date; contracts that gain tooling (e.g. a
reverse parity test for C5) move out of the manual checklist.
