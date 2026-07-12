#!/usr/bin/env bash
#
# backup-fleet.sh — per-client Octbase backup, runs as ROOT via
# octbase-fleet-backup.timer (installed by playbooks/install-backup.yml).
#
# Rootless podman is per-user: a job running as one account cannot even see
# another account's containers — which is why this runs as root and drives
# the same per-host client registry the monitor uses
# (/etc/octbase/clients.d/*.conf). For every registered client it:
#   1. pg_dumps the client's database (custom format) from inside the
#      client's own podman context (container octbase_postgres_1, contract C7),
#   2. verifies the dump by RESTORING it into one throwaway Postgres
#      (a backup you have never restored is a hope, not a backup),
#   3. tars the attachments directory and the .env (the secrets a
#      disaster-restore needs),
#   4. prunes files older than RETENTION_DAYS in that client's directory.
# Afterwards, if OFFHOST_SYNC_CMD is set, it is executed once; its failure
# fails the run. Any per-client failure yields a non-zero exit so the systemd
# unit surfaces it (journalctl -u octbase-fleet-backup.service).
#
# The legacy per-account job (backup-octbase.sh, claude account) keeps
# covering the resident dev/demo stacks; ledger-managed clients are ours.
#
# Config: /etc/octbase/backup.conf (written by install-backup.yml), env wins:
#   BACKUP_ROOT       where per-client dirs live (default /var/backups/octbase/fleet)
#   RETENTION_DAYS    prune horizon in days      (default 14)
#   TEST_IMAGE        restore-test postgres image — major version must be >=
#                     the clients' server major (contract C11)
#   OFFHOST_SYNC_CMD  optional command run after the backups (e.g. rclone sync …)
set -uo pipefail

CONF=/etc/octbase/backup.conf
[ -f "$CONF" ] && . "$CONF"
BACKUP_ROOT="${BACKUP_ROOT:-/var/backups/octbase/fleet}"
RETENTION_DAYS="${RETENTION_DAYS:-14}"
TEST_IMAGE="${TEST_IMAGE:-registry.access.redhat.com/hi/postgresql:18}"
OFFHOST_SYNC_CMD="${OFFHOST_SYNC_CMD:-}"

REGISTRY=/etc/octbase/clients.d
TEST_CTR="octbase_fleet_bkptest_$$"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="$BACKUP_ROOT/backup.log"

[ "$(id -u)" -eq 0 ] || { echo "must run as root (rootless podman is per-user)" >&2; exit 3; }
mkdir -p "$BACKUP_ROOT"
chmod 700 "$BACKUP_ROOT"
rc_overall=0

log() { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG"; }
as_user() { # as_user <account> <uid> <cmd…> — run in the client's podman context
  local acct="$1" uid="$2"; shift 2
  sudo -u "$acct" XDG_RUNTIME_DIR="/run/user/$uid" "$@"
}

cleanup() { podman rm -f "$TEST_CTR" >/dev/null 2>&1 || true; }
trap cleanup EXIT

shopt -s nullglob
confs=("$REGISTRY"/*.conf)
if [ ${#confs[@]} -eq 0 ]; then
  log "no clients registered in $REGISTRY — nothing to back up"
  exit 0
fi

# ── One throwaway Postgres (root podman) for all restore tests ──────────────
log "starting restore-test instance ($TEST_IMAGE)"
if ! podman run -d --name "$TEST_CTR" \
    -e POSTGRES_PASSWORD=test -e POSTGRES_USER=test -e POSTGRES_DB=postgres \
    "$TEST_IMAGE" >/dev/null 2>&1; then
  log "ERROR: could not start restore-test container"
  exit 1
fi
for _ in $(seq 1 30); do
  podman exec "$TEST_CTR" pg_isready -U test >/dev/null 2>&1 && break
  sleep 1
done
if ! podman exec "$TEST_CTR" pg_isready -U test >/dev/null 2>&1; then
  log "ERROR: restore-test instance did not become ready"
  exit 1
fi

# ── Per registered client: dump, restore-test, files, prune ─────────────────
for f in "${confs[@]}"; do
  NAME="" USER_ACCT="" HOME_DIR=""
  . "$f"
  [ -n "$NAME" ] && [ -n "$USER_ACCT" ] || continue

  uid="$(id -u "$USER_ACCT" 2>/dev/null)"
  if [ -z "$uid" ]; then
    log "[$NAME] ERROR: account $USER_ACCT missing"; rc_overall=1; continue
  fi
  HOME_DIR="${HOME_DIR:-/home/$USER_ACCT}"
  app_dir="$HOME_DIR/octbase"
  dest="$BACKUP_ROOT/$NAME"
  mkdir -p "$dest"
  dump="$dest/db-${STAMP}.dump"

  # 1) Dump (cd /tmp: sudo -u refuses to start in a cwd the target account
  # cannot read — same trap the playbooks work around).
  log "[$NAME] dumping database"
  if ! (cd /tmp && as_user "$USER_ACCT" "$uid" \
      podman exec octbase_postgres_1 pg_dump -U octbase -d octbase -Fc --no-owner \
      >"$dump" 2>>"$LOG"); then
    log "[$NAME] ERROR: pg_dump failed"; rc_overall=1; rm -f "$dump"; continue
  fi
  size=$(stat -c%s "$dump" 2>/dev/null || echo 0)
  if [ "$size" -lt 1024 ]; then
    log "[$NAME] ERROR: dump suspiciously small (${size} bytes)"; rc_overall=1; continue
  fi

  src_users="$(cd /tmp && as_user "$USER_ACCT" "$uid" \
    podman exec octbase_postgres_1 psql -U octbase -d octbase -tAc \
    'SELECT count(*) FROM users' 2>/dev/null | tr -d '[:space:]')"
  [ -z "$src_users" ] && src_users="NA"

  # 2) Restore test
  podman exec "$TEST_CTR" psql -U test -d postgres -q \
    -c 'DROP DATABASE IF EXISTS restoretest' \
    -c 'CREATE DATABASE restoretest' >>"$LOG" 2>&1
  podman cp "$dump" "$TEST_CTR:/tmp/restore.dump"
  podman exec "$TEST_CTR" pg_restore -U test -d restoretest --no-owner /tmp/restore.dump >>"$LOG" 2>&1
  podman exec "$TEST_CTR" rm -f /tmp/restore.dump >/dev/null 2>&1

  tables="$(podman exec "$TEST_CTR" psql -U test -d restoretest -tAc \
    "SELECT count(*) FROM information_schema.tables WHERE table_schema='public'" 2>/dev/null | tr -d '[:space:]')"
  [ -z "$tables" ] && tables=0

  if [ "$tables" -lt 1 ]; then
    log "[$NAME] ERROR: restore test FAILED — no tables restored"; rc_overall=1
  elif [ "$src_users" != "NA" ]; then
    dst_users="$(podman exec "$TEST_CTR" psql -U test -d restoretest -tAc \
      'SELECT count(*) FROM users' 2>/dev/null | tr -d '[:space:]')"
    if [ "${dst_users:-}" = "$src_users" ]; then
      log "[$NAME] restore test OK — $tables tables, users $dst_users == source"
    else
      log "[$NAME] ERROR: restore test FAILED — users mismatch (source $src_users, restored ${dst_users:-?})"; rc_overall=1
    fi
  else
    log "[$NAME] restore test OK — $tables tables (no users table to cross-check)"
  fi

  # 3) Attachments + .env (tar reads as root; -C keeps paths relative)
  files_tar="$dest/files-${STAMP}.tar.gz"
  tar_members=()
  [ -d "$app_dir/attachments" ] && tar_members+=("octbase/attachments")
  [ -f "$app_dir/.env" ] && tar_members+=("octbase/.env")
  if [ ${#tar_members[@]} -gt 0 ]; then
    if tar czf "$files_tar" -C "$HOME_DIR" "${tar_members[@]}" 2>>"$LOG"; then
      chmod 600 "$files_tar"
      log "[$NAME] files archived: $files_tar ($(stat -c%s "$files_tar") bytes)"
    else
      log "[$NAME] ERROR: files archive failed"; rc_overall=1
    fi
  else
    log "[$NAME] WARNING: no attachments/.env found under $app_dir"
  fi
  chmod 600 "$dump"
  log "[$NAME] dump written: $dump (${size} bytes)"

  # 4) Prune
  deleted=$(find "$dest" -maxdepth 1 \( -name '*.dump' -o -name '*.tar.gz' \) \
    -type f -mtime "+$RETENTION_DAYS" -print -delete | wc -l)
  [ "$deleted" -gt 0 ] && log "[$NAME] pruned $deleted file(s) older than ${RETENTION_DAYS}d"
done

# ── Off-host copy (readiness plan B1) ────────────────────────────────────────
if [ -n "$OFFHOST_SYNC_CMD" ]; then
  log "off-host sync: $OFFHOST_SYNC_CMD"
  if ! bash -c "$OFFHOST_SYNC_CMD" >>"$LOG" 2>&1; then
    log "ERROR: off-host sync FAILED"; rc_overall=1
  fi
else
  log "off-host sync not configured (backup_offhost_cmd) — backups stay on this host"
fi

if [ "$rc_overall" -eq 0 ]; then
  log "fleet backup completed OK (${#confs[@]} client(s))"
else
  log "fleet backup completed WITH ERRORS"
fi
exit "$rc_overall"
