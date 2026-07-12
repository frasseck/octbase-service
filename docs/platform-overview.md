# Octbase platform overview — repos, environments, and how they fit together

**Scope:** the whole ocete.ch platform across its four working copies on the
production host. The [README](../README.md) documents *this* repo (the
per-client provisioning toolkit); this document is the map of everything
around it: which repo owns what, what actually runs on the host, how a change
travels from development to a client instance, and where the authoritative
documentation for each concern lives.
**Last reviewed:** 2026-07-11 (v1.0.4 release check, host state
re-verified; last full pass 2026-07-10).

Its companion, the [consistency register](consistency-register.md), lists the
cross-repo contracts that must stay in sync — read it before changing env
variables, ports, editions, versions, or health probing anywhere in the
platform.

## 1. The four repositories

| Working copy (host) | Git repo | Branch policy | What it is |
|---|---|---|---|
| `~/dev.ocete.ch` | `frasseck/octbase` | `release_vN` feature/release branches | **The application monorepo, development checkout.** Go API + desktop frontend + mobile SPA + shared JS + operations probe. Also the default `octbase_src` the client playbooks rsync from. |
| `~/demo.ocete.ch` | `frasseck/octbase` | `main` only, deployed by `git pull` | **The public demo instance** — same repo, second checkout. Runs whatever is merged to `main`, with `OCTBASE_DEMO_MODE=true` (seeded demo logins by design). |
| `~/ocete.ch` | `frasseck/ocete` | `main` | **The marketing/landing site** — static no-build site + Go contact-form mailer. No dependency on the app. Carries the public pricing, privacy policy, terms and imprint. |
| `~/octbase-service` | `frasseck/octbase-service` | `main` | **This repo** — client ledger, Ansible playbooks, fleet monitoring, host backup. Provisions one production stack per client. |

Two checkouts of the same app repo is deliberate: `dev.ocete.ch` is a working
tree (it may be on a release branch with uncommitted work); `demo.ocete.ch`
is a deployment target that only ever moves by pulling `main`.

## 2. What runs on the host

All four stacks run rootless under the `claude` account today; client
instances (none onboarded yet) will each get their own `oct-<name>` account
as described in the README. The demo is prepared to become the first
ledger-managed instance (`ledger/clients/demo.yml`, ports 8110–8112) — the
move to its own `oct-demo` account via `migrate-instance.yml` is pending,
so until that runs the table below is still the live state.

| Stack | Compose project | systemd unit (user) | Host ports |
|---|---|---|---|
| Marketing `ocete.ch` | `ocete` | `octbase-web.service` | web 8082 |
| Demo `demo.ocete.ch` | `octbase` | `octbase.service` | postgres 5432 · api 8000 · frontend 8080 |
| Dev `dev.ocete.ch` | `octbase_dev` | `octbase-dev.service` | postgres 5433 · api 8001 · frontend 8081 · Mailpit UI 8025 (dev overlay only) |
| DB backup | — | `octbase-backup.timer` (daily 03:30) | — |
| Client `<name>` (future) | `octbase` (per account) | per-user `octbase.service`, root `octbase-monitor.timer` + `octbase-fleet-backup.timer` | frontend/api/postgres blocks from 8110, loopback-only |

Also on the host: `~/restart.sh` (rebuilds the three stacks; for demo it
`git pull`s first), `~/credentials/` (the real `.env` files for dev and
marketing — `~/dev.ocete.ch/.env` and `~/ocete.ch/.env` are symlinks into
it), `~/backups/` (nightly dumps + `backup.log`).

**Port binding:** since 2026-07-10 the resident stacks bind Postgres and API
ports to `127.0.0.1`; only their frontend ports (8080/8081/8082) remain on
`0.0.0.0`, because the root-managed edge Caddyfile targets the host's public
IP instead of `127.0.0.1`. Once the edge is repointed (root change), prefix
the three `FRONTEND_PORT`/`WEB_PORT` values too. Client instances are always
fully loopback-bound via `env.j2`. See consistency register C9.

The public edge reverse proxy (root-managed Caddy, outside all four repos)
terminates TLS for `ocete.ch`, `demo.ocete.ch`, `dev.ocete.ch` and, later,
`<client>.ocete.ch`, and forwards to the loopback/host ports above.

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

1. **Develop** on a `release_vN` branch in `~/dev.ocete.ch`; the dev stack
   runs that working tree. CI (`.github/workflows/ci.yml`) gates lint, tests
   with a coverage floor, the frontend guards and a Playwright e2e run — and
   on every `main` push publishes per-commit images to GHCR
   (`ghcr.io/frasseck/octbase/octbase-{api,frontend,mobile}:<sha>`), the
   natural starting point for the "build once, distribute via a registry"
   roadmap item in the [README](../README.md)'s known gaps.
2. **Release** (app repo `release` skill): rename `## Unreleased` in
   `CHANGELOG.md` to the version + date, merge `release_vN` → `main` via
   `scripts/release.sh`. The build default version stays `beta` — releases
   are stamped per deployment via `OCTBASE_APP_VERSION` in each `.env`.
3. **Deploy the demo**: `git pull` + compose rebuild in `~/demo.ocete.ch`
   (that is what `~/restart.sh` does), bump `OCTBASE_APP_VERSION` in
   `demo.ocete.ch/.env`.
4. **Roll out to clients** (this repo): bump `octbase_version` in
   `inventory/group_vars/all.yml` (and/or `app_version` per ledger entry),
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
| Public pricing / legal texts | `ocete.ch` repo (`pricing.html`, `privacy.html`, `terms.html`, imprint) |

## 6. Naming

The **product** is *Octbase* (`frasseck/octbase`, `OCTBASE_*` env prefix,
`oct-` account prefix, `octbase-*` unit names). The **domain/brand of the
hosted platform** is *ocete.ch* (`frasseck/ocete`, subdomains per client).
Directory names on the host follow the domain (`dev.ocete.ch`,
`demo.ocete.ch`), repo names follow the product — this split is intentional;
don't "fix" one to match the other without deciding for the whole platform.
