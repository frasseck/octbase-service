# Octbase platform overview — repos, environments, and how they fit together

**Scope:** the whole octbase.io platform across its four working copies on the
production host. The [README](../README.md) documents *this* repo (the
per-client provisioning toolkit); this document is the map of everything
around it: which repo owns what, what actually runs on the host, how a change
travels from development to a client instance, and where the authoritative
documentation for each concern lives.
**Last reviewed:** 2026-08-07 (partial: §1/§2 checkout paths re-measured on
`dev01`, §6 updated during the domain-reference scrub — register D31 — and
§2/§6 de-branded in the same day's second scrub pass, register §2.15; last
deep review 2026-07-15, last full pass 2026-07-10).

Its companion, the [consistency register](consistency-register.md), lists the
cross-repo contracts that must stay in sync — read it before changing env
variables, ports, editions, versions, or health probing anywhere in the
platform.

## 1. The four repositories

| Working copy (host) | Git repo | Branch policy | What it is |
|---|---|---|---|
| `~/test.octbase.io` | `frasseck/octbase-app` | `release_vN` feature/release branches | **The application monorepo, development checkout.** Go API + desktop frontend + mobile SPA + shared JS + operations probe. Also the default `octbase_src` the client playbooks rsync from. |
| `~/octbase-web` | `frasseck/octbase-web` | `main` | **The marketing/landing site** — static no-build site + Go contact-form mailer. No dependency on the app. Carries the public pricing, privacy policy, terms and imprint. |
| `~/octbase-service` | `frasseck/octbase-service` | `main` | **This repo** — client ledger, Ansible playbooks, fleet monitoring, host backup. Provisions one production stack per client. |

There is exactly **one** app-repo checkout on the host. The legacy demo
deployment used to be a second one — a target that only ever moved by pulling
`main` — but the public demo became a ledger-managed client instance under its
own `oct-demo` account on 2026-07-11 (`migrate-instance.yml`), and that
checkout was removed afterwards. Deploy the demo like any other client, from
the admin machine, and never by pulling into a checkout on the host.

## 2. What runs on the host

Since 2026-07-11 only the **dev** stack still runs under the `claude`
account: the public demo was migrated into its own `oct-demo` account as the
first ledger-managed instance (`ledger/clients/demo.yml`, ports 8110–8112,
via `migrate-instance.yml`), and the marketing site moved to the `oct-web`
account on loopback port 8120 (8120 is reserved in `ledger.py` so it is never
allocated to a client). `scripts/setup-octbase-web.sh` is how that site is
stood up on a host today — it creates the account, deploys the stack and drops
the edge vhost snippet.

| Stack | Account | Compose project | systemd unit (user) | Host ports |
|---|---|---|---|---|
| Marketing `octbase.io` | `oct-web` | pre-rename ¹ | pre-rename ¹ | web 8120 (loopback) |
| Demo `demo.octbase.io` | `oct-demo` | `octbase` | `octbase.service` | frontend 8110 · api 8111 · postgres 8112 |
| Dev `test.octbase.io` | `claude` | `octbase_dev` | `octbase-dev.service` | postgres 8102 · api 8101 · frontend 8100 · Mailpit UI 8026 (dev overlay only) ² |
| DB backup (legacy, dev only) | `claude` | — | `octbase-backup.timer` (daily 03:30) | — |
| Client `<name>` | `oct-<name>` | `octbase` (per account) | per-user `octbase.service`, root `octbase-monitor.timer` + `octbase-fleet-backup.timer` (**not yet installed** — register D13) | frontend/api/postgres blocks from 8110, loopback-only |

¹ The `oct-web` account still runs the marketing stack under its
**pre-rename** compose project, unit, site directory and env-file names — all
carrying the platform's old brand (verified live 2026-08-07: the containers
still bear the old project name). The 2026-08-06 domain rename covered the
`claude` account's staging copy (now `~/octbase-web`, project `octbase-web`)
but not that account, which needs root. Do not "correct" this row until the
rename has actually been carried out there.

**Carrying it out.** `scripts/setup-octbase-web.sh` deploys under the *new*
names (`~oct-web/octbase.io`, `.env.octbase-web`, `octbase-web.service`), so
running it against this box without cleaning up first would leave the old unit
enabled alongside the new one — two units driving the same stack on the same
port. Retire the old unit, its user-unit file, the old site directory and env
file first, as root, keeping the secrets (the new script reads
`~oct-web/credentials/.env.octbase-web`). The literal pre-rename file names
and the exact command sequence were scrubbed from this doc on 2026-08-07
(register §2.15) — recover them from this section's git history before running
the cleanup. Then run the setup script and update this row. Note the edge currently serves
`octbase.io` from a block **inside** `/etc/caddy/Caddyfile`, not from a
snippet; the script refuses to run until that inline block is removed, rather
than creating a duplicate vhost Caddy would reject.

² The dev ports moved from `5433 / 8001 / 8081` (and Mailpit `8025`) on
2026-07-26; this row still carried the old set until 2026-08-07.
`~/test.octbase.io/.env` is the authority — `POSTGRES_PORT` / `API_PORT` /
`FRONTEND_PORT` / `MAILPIT_HTTP_PORT` — so read it rather than this table if
the two ever disagree again. A stale port here is worse than no port at all:
8000 and 5432 are free on this host now, so the old numbers do not fail
loudly, they just answer as whatever else happens to be listening.

Also on the host: `~/credentials/` (the real `.env` files for dev and
marketing — `~/test.octbase.io/.env` is a symlink into it), `~/backups/`
(legacy nightly dumps + `backup.log`; covers only what the `claude` account
can see, i.e. dev — the demo is the fleet backup's job, register D13). The
old `~/restart.sh` was removed with the migrations; deploy the demo with
`sync-instance.yml`.

**Port binding:** since 2026-07-10 the resident stacks bind Postgres and API
ports to `127.0.0.1`. The dev frontend is now loopback-bound too
(`127.0.0.1:8100`, via `FRONTEND_BIND_ADDR` in its `.env`) — verified against
the running containers on 2026-08-07. It used to sit on `0.0.0.0` because the
root-managed edge Caddyfile targeted the host's public IP instead of
`127.0.0.1` (readiness plan B4). The demo frontend currently also binds
`0.0.0.0:8110` although its edge vhost targets loopback — flip its
`FRONTEND_PORT` to `127.0.0.1:8110` and restart (register D14). Client
instances are fully loopback-bound via `env.j2`. See consistency register C9.

The public edge reverse proxy (root-managed Caddy, outside all four repos)
terminates TLS for `octbase.io`, `demo.octbase.io`, `test.octbase.io` and, later,
`<client>.octbase.io`, and forwards to the loopback/host ports above.

## 3. Inside the app stack (any instance)

Every app deployment — dev, demo, or client — is the same four-container
compose stack from the app repo:

```
edge proxy ──▶ octbase-frontend (Caddy front door, :8080 in-container)
                 ├── serves the desktop SPA (no build step, plain DOM)
                 ├── serves the mobile SPA under /m/  (octbase-mobile container)
                 └── reverse-proxies /api, /health, /docs, /metrics,
                     /openapi.yaml ──▶ octbase-api (Go, :8000 in-container)
                                          └── postgres (migrations run at API startup)
```

Layered compose files decide the flavour:

| Layer | Repo | Purpose |
|---|---|---|
| `podman-compose.yml` | app repo | The deployable base stack (demo mode **on**, localhost CORS) |
| `podman-compose.dev.yml` | app repo | Dev-only Mailpit mail capture — **never deploy** |
| `podman-compose.client.yml` | this repo | Production override: demo mode **off**, secure cookies, real CORS, ledger-managed edition/seat vars, persistent attachments mount |

The demo instance runs the base file alone — demo mode on is intended there,
and since v1.0.3 the base compose threads the public-origin and secure-cookie
env vars straight from the demo's `.env` (a temporary untracked demo override
bridged the gap for one day; see the consistency register D1). Client
instances always run base + client override.

## 4. How a change reaches production

1. **Develop** on a `release_vN` branch in `~/test.octbase.io`; the dev stack
   runs that working tree. CI (`.github/workflows/ci.yml`) gates lint, tests
   with a coverage floor, the frontend guards and a Playwright e2e run — and
   on every `main` push publishes per-commit images to GHCR
   (`ghcr.io/frasseck/octbase-app/octbase-{api,frontend,mobile}:<sha>`), the
   natural starting point for the "build once, distribute via a registry"
   roadmap item in the [README](../README.md)'s known gaps.
2. **Release** (app repo `release` skill): rename `## Unreleased` in
   `CHANGELOG.md` to the version + date, merge `release_vN` → `main` via
   `scripts/release.sh`. The build default version stays `beta` — releases
   are stamped per deployment via `OCTBASE_APP_VERSION` in each `.env`.
3. **Deploy the demo**: it is a ledger-managed client like any other since
   2026-07-11, so this is `ansible-playbook playbooks/sync-instance.yml -e
   client=demo` from the admin machine (or `set-version.yml` to deploy the
   ledger's `app_version` tag and stamp it). There is no legacy demo
   checkout to pull into and no `.env` on this host to edit — its `.env` lives
   in the unreadable `oct-demo` home, and `app_version` in
   `ledger/clients/demo.yml` is what stamps the version.
4. **Roll out to clients** (this repo): bump `octbase_version` in
   `inventory/group_vars/all/main.yml` (and/or `app_version` per ledger entry),
   make sure the `octbase_src` checkout is **on the released commit with a
   clean working tree** — the playbook rsyncs the tree as-is, uncommitted
   changes included — then run `create-instance.yml` per active client.
5. **Gate on health**: the playbook waits for `/health`; the fleet monitor
   keeps probing every 5 minutes afterwards.

## 5. Where the authoritative documentation lives

One concern, one owner — everything else should link, not copy:

| Concern | Authoritative source |
|---|---|
| Architecture decisions (normative) | app repo `docs/architecture.md` |
| Whole-stack technology reference | app repo `docs/technical_documentation.md` |
| Env variables (names, defaults) | app repo `.env.example` (+ `docs/operations.md`) |
| Single-instance operations (migrations, GDPR requests, TLS, JWT rotation) | app repo `docs/operations.md` |
| Health probing & reaction runbook | app repo `octbase-operations/` |
| Sizing, scaling models, hosting options | app repo `docs/hosting-concept.md` |
| App changelog / release history | app repo `CHANGELOG.md` |
| Client base (who, edition, seats, ports) | this repo `ledger/clients/*.yml` |
| Per-client provisioning & fleet runbooks | this repo [README](../README.md) |
| Security & data-protection concept (platform-wide) | this repo [`docs/security-data-protection-concept.md`](security-data-protection-concept.md) |
| Cross-repo contracts & drift | this repo [`docs/consistency-register.md`](consistency-register.md) |
| Public pricing / legal texts | `octbase.io` repo (`pricing.html`, `privacy.html`, `terms.html`, imprint) |

## 6. Naming

The **product** is *Octbase* (`frasseck/octbase-app`, `OCTBASE_*` env prefix,
`oct-` account prefix, `octbase-*` unit names). The **domain/brand of the
hosted platform** is **`octbase.io`**, adopted on 2026-08-06 in a rename from
the platform's original domain (subdomains per client, `base_domain` in
group_vars).

That rename was carried through everything addressable, in one pass:
hostnames, the host directories, the marketing repo's rename to
`frasseck/octbase-web`, its compose project and
`~/credentials/.env.octbase-web`, and the systemd unit descriptions. Product
naming was already `octbase-*` and did not move. On 2026-08-07, on Lars's
instruction, every mention of the old domain was scrubbed from this repo's
docs, skills and comments — including, in a second pass the same day, the
dated history entries and this section's own record of the old name. Git
history is the only remaining record (register §2.15).

The one place still *carrying* the old brand is live host state, not a
document: the `oct-web` account's pre-rename artifacts (§2, footnote ¹),
which need a root cleanup before `scripts/setup-octbase-web.sh` can take
over. Once that cleanup runs, remove the footnote and this paragraph.
Any occurrence of the old brand in this repo's files is a regression — fix it.
