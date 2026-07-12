# Path to production — readiness concept

**State as of 2026-07-11 (app v1.0.4):** the software itself is
production-grade — enforced test coverage, migration gates, a hardened auth
stack, fail-closed commercial defaults, and consistency-reviewed docs (see the
[consistency register](consistency-register.md)). What still gates real
paying clients is the **platform around it**: backup locality, alerting,
an unexercised client path, and one fragile edge config. This document is the
ordered plan to close that gap. Detailed status lives in the register and the
[security concept](security-data-protection-concept.md) §7 — this document
owns the *sequence and acceptance criteria*, not the tracking.

**Target for stage 1** (what "production" means here): a handful of small,
single-tenant clients on one node — hosting-concept §5 Model A, roadmap
phases 0–1 — with an SLA that honestly states single-node availability.
HA is explicitly *not* a stage-1 goal; the triggers for revisiting that are
in the app repo's `docs/hosting-concept.md` §14.

---

## Phase 0 — launch blockers (before client #1)

Roughly three focused workdays. Order matters: B1 and B2 protect the canary
in B3, and B4 is a prerequisite for the loopback end-state.

### B1 — Backups leave the host, attachments included  *(~1 day)*

Today the nightly job (`backup/backup-octbase.sh`) dumps every Postgres
container **to the same disk it protects** (`~/backups`) and covers the
database only; attachments are captured solely in the offboarding snapshot.
A disk failure or ransomware event loses data *and* backup together.

Plan:
1. **Attachments into the nightly rotation** — ✅ done 2026-07-12: the
   root-level fleet backup (`backup/backup-fleet.sh` via
   `install-backup.yml`) dumps every registered client's DB (with the
   mandatory restore test) *and* archives attachments + `.env`, per client,
   nightly. Root-level rather than per-tenant units because rootless podman
   is per-user — one account cannot see the others' containers.
2. **Off-host, versioned copy — still open.** Set `backup_offhost_cmd`
   (group_vars → `install-backup.yml`) to sync the backup roots after each
   run to object storage in Germany — encrypted client-side (e.g. `rclone`
   with a crypt remote or `restic`), with bucket-side
   versioning/immutability so a compromised host cannot destroy history.
   Credentials live only on the host, write-only if the provider supports
   it. The hook exists and fails the unit loudly; the destination decision
   and credentials are what's missing.
3. **Keep the restore test mandatory.** The throwaway-Postgres restore
   verification stays the definition of "a backup happened" (fleet script
   included); add a periodic (monthly) restore test *from the off-host copy*
   once 2. exists.

**Accept when:** a nightly run produces DB dump + attachments per stack, the
off-host copy exists with independent versioning, a file deleted locally is
recoverable from off-host, and `backup.log` + the systemd unit fail loudly
when the sync fails.

### B2 — Alerting actually reaches a human  *(~½ day)*

The fleet monitor is designed but not live: `/etc/octbase` doesn't exist,
`alert_email` is empty, and nothing external watches the sites.

1. Set `alert_email` in `inventory/group_vars/all.yml`; verify the host can
   send mail (`sendmail` path — the marketing SMTP relay can serve as
   smarthost).
2. `ansible-playbook playbooks/install-monitoring.yml`.
3. Point an external uptime service at `https://<site>/health` for demo and
   every client (the same endpoint the monitor probes) — external coverage
   catches DNS/edge/TLS failures the host cannot see about itself.
4. **Fire a test alert** (stop a stack, watch the mail arrive, start it).

**Accept when:** a deliberately broken stack produces a mail within one
monitor interval (5 min) *and* an external probe alarm; both verified once.

### B3 — Canary tenant: exercise the whole client path  *(~½–1 day)*

No client has ever been provisioned; the ledger holds only the demo's
adoption entry (its `migrate-instance.yml` run is itself still pending) and
the playbooks are unproven end-to-end. The demo migration will exercise
`create-instance.yml` for real once, but not the full lifecycle — so still
onboard **ourselves** as the first tenant
(`./ledger/ledger.py new canary …`, DNS record, edge include) and run the
full lifecycle:

create → `/health` green through the edge → login/MFA/upload smoke test →
edition/seat change via ledger re-run → nightly backup visible off-host →
monitor shows the tenant → `remove-instance.yml` dry-offboard **of a second
throwaway tenant** (keep `canary` permanently as the fleet smoke instance
and upgrade guinea pig — future releases hit canary before clients).

**Accept when:** every runbook in the [README](../README.md) has been
executed once for real, and the surprises found are fixed or filed in the
register.

### B4 — Repoint the edge to loopback  *(minutes, root)*

The root-managed edge Caddyfile proxies to the host's **dynamic public IP**
(`178.105.142.1:<port>`), which (a) breaks every site when the IP rotates
and (b) forces the three resident frontends to stay on `0.0.0.0`
(register C15, §2.1). As root: change the three `reverse_proxy` targets to
`127.0.0.1:<port>`, reload Caddy, then flip the commented
`FRONTEND_PORT`/`WEB_PORT` values in the three `.env` files and restart the
stacks. While there: decide dynamic-IP handling (static IP from the
provider, or DDNS + short TTL) — the A-records share the problem.

**Accept when:** all public sites are green, every published port on the
host binds `127.0.0.1`, and an external port scan shows only 80/443/SSH.

---

## Phase 1 — structural (before ~client #3)

### S1 — Separate production from dev/demo  *(1–2 days)*
Client stacks currently would share the host with the dev working tree and
the public demo — a host failure takes everything, dev builds compete for
client resources, and dev/demo carry known credentials by design. Provision
a dedicated production node (the tooling already assumes remote SSH:
`inventory/hosts.yml`), install monitoring + backups there, and keep
dev/demo on the current host. Move `canary` first; it validates the
migration procedure clients will later follow. Tooling is in place since
2026-07-12: add the node to `inventory/hosts.yml`, run the two install
playbooks, set the ledger `host:`, run `playbooks/migrate-host.yml`
(admin-machine-staged; see `docs/fleet-concept.md`) — what remains here is
the actual node, its edge Caddy and the first real cross-host move.

### S2 — Secrets hygiene  *(½ day)*
`smtp_pass` into Ansible Vault (the group_vars comment already demands it);
rotate the marketing SMTP password (register §2.1 item 3); document where
vault keys and off-host-backup encryption keys are kept — a backup nobody
can decrypt after a laptop loss is not a backup.

### S3 — Deploy from the registry, not per-client builds  *(1 day)*
CI already publishes per-commit images to GHCR (register F6). Teach
`create-instance.yml` to `podman pull` a pinned release tag instead of
rsync + local build: faster onboarding, identical bits per client, and the
release stamp (`app_version` in the ledger) becomes the image tag. Keep the
build-from-source path as fallback. This also removes the C13 clean-tree
footgun entirely.

### S4 — Restriction of the non-client surface  *(½ day)*
IP-filter or basic-auth `dev.ocete.ch` at the edge, and decide the same for
the demo (it exists to be public — but rate-limit it at the edge). Security
concept §7.

---

## Phase 2 — maturity (as the client base grows)

Triggered by growth, not by the calendar — thresholds per hosting-concept
§14: Postgres major-upgrade procedure (the `:18` pin is deliberate — plan
the 18→19 migration before it is forced), packed-node capacity management
(the per-account slice caps + disk quotas from 2026-07-12 are the knobs;
`suspend-instance.yml` exists), and the Model B/C decision once a client
demands HA or the node fills up.

## Parallel track — organizational (not code, still gating B2B sales)

Owned in the security concept §7, summarized here because "production
ready" includes them: AV/order-processing contracts (hosting + SMTP), VVT,
incident-response plan (who is paged by B2's alerts, and what do they do —
the reaction runbook in `octbase-operations/` is the technical half),
TOMs + pentest, and SLA wording that matches the single-node reality.

---

## Go/no-go checklist for client #1

| # | Gate | Proven by |
|---|---|---|
| 1 | Off-host, encrypted, versioned backups incl. attachments (B1) | Restore from off-host copy performed once |
| 2 | Alerting live, internally and externally (B2) | Test alert received end-to-end |
| 3 | Full client lifecycle exercised (B3) | `canary` running; throwaway tenant offboarded |
| 4 | Edge on loopback targets, host loopback-only (B4) | External port scan |
| 5 | AV contract + incident-response minimum (org track) | Documents exist, alert recipient named |

Review this plan whenever a phase completes or the register gains a
material finding; keep effort estimates honest by updating them with
actuals from the canary run.
