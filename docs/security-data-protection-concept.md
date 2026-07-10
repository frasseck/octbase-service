# Octbase — Security & Data-Protection Concept

**Scope:** the ocete.ch platform — the marketing site (`ocete.ch`), the public
demo (`demo.ocete.ch`), the development stack (`dev.ocete.ch`) and the
per-client production instances (`<name>.ocete.ch`) provisioned by this repo.
**Owner:** platform operator (Lars Frasseck / beyags).
**Last reviewed:** 2026-07-10. **Review cadence:** at least annually and after
any material architecture change (see §10).

This is the operational security and data-protection concept for the platform.
It records *what* controls exist, *where* they are implemented, and *which*
external requirements they satisfy, so the operator can demonstrate a
datenschutzkonformer und sicherer Betrieb and hand a single reference to an
auditor or DPO. Deployment mechanics live in the [README](../README.md); the
per-tenant architecture is in the app repo's `docs/hosting-concept.md`.

## 1. Reference standards

| Ref | Document | Role |
|-----|----------|------|
| **RiLi-Webservices** | Muster-Richtlinie für den sicheren Betrieb von Webservices und Webservern (ISMS-Ratgeber) | Technical/operational baseline |
| **Merkblatt "Sichere Website"** | Datenschutzbeauftragte des Kantons Zürich, V2.0 (Okt. 2024) | Data-protection baseline for websites |
| **revDSG / revFADP** | Revised Swiss Federal Act on Data Protection (in force 1 Sept 2023) + DSV | Primary applicable law |
| **GDPR** | EU 2016/679 | Additionally applicable for EU/EEA data subjects |
| **OWASP Top 10 / API Top 10** | | Threat reference for the risk analysis |

## 2. Deployment & trust model

- **One stack per client**, each in its own rootless-podman user namespace
  (`oct-<name>`); distinct databases, secrets and data directories. Blast
  radius of a compromise is a single Linux account.
- **All service ports bind to `127.0.0.1`.** Only the root-managed edge proxy
  (Caddy), which terminates TLS, is reachable from the internet.
- **Secrets** (DB password, JWT/SCM/MFA keys, each ≥32 bytes) are generated at
  first deploy and stored only in the client's `.env` (mode 0600). The git
  ledger holds no secrets.

## 3. Technical measures (implemented)

Mapped to RiLi-Webservices sections and the Merkblatt.

### 3.1 Transport security — RiLi 8.2.2, Merkblatt §5
- TLS 1.2 minimum, TLS 1.3 preferred; TLS 1.0/1.1 disabled. Let's Encrypt
  certificates via ACME at the edge.
- **HSTS** (`Strict-Transport-Security: max-age=31536000; includeSubDomains`)
  sent by every front door (marketing, app frontend, mobile). HTTP→HTTPS via
  308 redirect.

### 3.2 Security headers & hardening — RiLi 8.2.4 / 8.2.8, Merkblatt §4
- Strict `Content-Security-Policy` (`default-src 'self'`, no third-party
  origins), `X-Frame-Options: DENY`, `X-Content-Type-Options: nosniff`,
  `Referrer-Policy: strict-origin-when-cross-origin`, `Permissions-Policy`
  locking down geolocation/camera/microphone.
- No analytics/tracking/advertising; the marketing site loads no third-party
  resources (privacy by default).

### 3.3 Authentication & sessions — RiLi 8.2.3 / 8.2.5 / 8.3.3, Merkblatt §4
- Individually attributable accounts; no shared accounts. JWT-only API
  (`Bearer`), short-lived access tokens.
- Refresh cookies: `HttpOnly`, `Secure` (`OCTBASE_SECURE_COOKIES=true` in
  production), `SameSite=Strict`, path-scoped, with expiry.
- Passwords: bcrypt cost 12 (salted one-way hash — Merkblatt §4); minimum 12
  characters plus a common-password blocklist.
- **MFA (TOTP)** available for every account, with optional **enforcement**
  (`OCTBASE_REQUIRE_MFA=off|admins|all`). When enforced, a login without MFA
  yields a scoped enrollment challenge (no session) until TOTP setup is
  complete. See [MFA enforcement](#5-mfa-enforcement-concept).
- Admin/service ports are not internet-exposed (edge-only reachability); the
  public demo should additionally be IP-/auth-restricted at the edge (§7).

### 3.4 Input handling — RiLi 8.2.6
- Whitelist validation and context-aware encoding in the app; the contact-form
  mailer adds header-injection protection, DNS/MX validation, length limits and
  a honeypot.

### 3.5 Abuse resistance — RiLi 8.2.8
- Rate limiting on auth routes and user management (anti-enumeration); the
  mailer rate-limits per source IP with a global backstop, using a
  non-spoofable client-IP resolution.

### 3.6 Logging, retention & data minimization — RiLi 8.2.7, revDSG Art. 8 / GDPR Art. 5, 32
- Security audit log (admin actions, sign-ins) with source IP and user agent.
- Automatic GDPR/revDSG retention purge (audit + activity default 365 days,
  expired tokens/invitations), configurable per deployment.

## 4. Backup & restore concept (Datensicherungskonzept) — RiLi 12.3, Merkblatt §4

Fulfils the "scheduled backup" gap previously listed in the README.

- **What:** every running Octbase Postgres container, dumped daily in
  `pg_dump -Fc` custom format.
- **Where:** `/home/claude/backups/<container>/<db>-<timestamp>.dump`; log at
  `/home/claude/backups/backup.log`. Retention 14 days (`RETENTION_DAYS`).
- **How:** `backup/backup-octbase.sh`, scheduled by the systemd user timer
  `backup/octbase-backup.{service,timer}` (daily 03:30, `Persistent=true`).
- **Restore test (mandatory, automated):** each dump is restored into a
  throwaway PostgreSQL instance and verified (table count + `users` row count
  match the source) on every run. A dump that cannot be restored fails the run
  — a backup is only counted once it has been proven restorable.
- **Version constraint:** the restore-test image must be ≥ the source server's
  major version (currently PostgreSQL 18.4), or `pg_restore` rejects the
  archive. `TEST_IMAGE` defaults accordingly.
- **Offboarding backup:** `remove-instance.yml` additionally takes a final
  `pg_dump` + attachments + `.env` snapshot to `/var/backups/octbase/`.
- **Roadmap:** extend to per-client attachment rsync and an off-host/immutable
  copy (hosting-concept §9.5; RiLi 12.3 immutable backups).

## 5. MFA enforcement concept

- `OCTBASE_REQUIRE_MFA` selects the enforcement scope: `off` (default),
  `admins` (ADMIN + SUPER_ADMIN), or `all`.
- On an in-scope login without MFA, the API issues a **scoped enrollment
  token** (distinct JWT issuer) that authorizes only the MFA enroll/confirm
  endpoints — it is not a session and authenticates nowhere else. After the
  user completes TOTP setup they re-authenticate into the normal MFA challenge
  flow.
- Enable per client only once the client-facing frontend that renders the
  forced-enrollment step is deployed. Recommended baseline: `admins` for every
  production client; `all` where the client's data warrants it (§6 risk).

## 6. Risk analysis (OWASP) — RiLi 9, Merkblatt §4

A structured OWASP Top-10 / API-Top-10 risk assessment is to be recorded per
release and before onboarding a client with elevated protection needs, and its
mitigations tracked here. The controls in §3 address the common categories
(broken access control, crypto failures, injection, security misconfiguration,
identification/authentication failures). Elevated-risk clients additionally get
`OCTBASE_REQUIRE_MFA` and, where warranted, a DSFA/DPIA (revDSG Art. 22).

## 7. Open organizational items (not code)

Tracked here until closed; required by RiLi ch. 6/16/17 and the Merkblatt §3.

- [ ] **AV/order-processing contracts** with the hosting **and** SMTP providers
      (contact-form and notification email carry personal data) — revDSG Art. 9
      / GDPR Art. 28.
- [ ] **Records of processing (VVT)** — GDPR Art. 30 / revDSG Art. 12.
- [ ] **TOMs documentation** and the periodic **penetration test / vulnerability
      scan** — RiLi 12/33, Merkblatt §4.
- [ ] **Edge restriction of `dev.ocete.ch` / `demo.ocete.ch`** (IP filter or
      basic-auth) — public demo instances carry known credentials by design.
- [ ] **SBOM / dependency inventory** — RiLi 14/19.
- [ ] **Incident-response plan** — RiLi 13/30.
- [ ] **Privacy policy** kept aligned with the revDSG (Swiss counsel review of
      the current published text).

## 8. Patch & change management — RiLi 11.2

Client images are rebuilt from the pinned app release via
`create-instance.yml`; security updates to base images and dependencies are
applied by re-running the playbook per active client. Changes to the ledger are
git-versioned and drive deployments idempotently.

## 9. Monitoring & incident detection — RiLi 8.3.5

`monitoring/monitor-all.sh` aggregates the app health probe across all client
stacks every 5 minutes and alerts on state changes (see README §Monitoring).
Journald retains per-run logs. Incident response is an open item (§7).

## 10. Review

This concept is reviewed at least annually and whenever the architecture,
the threat landscape, or the reference standards change materially. Each review
updates the "Last reviewed" date and the open-items checklist in §7.
