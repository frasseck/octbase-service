#!/usr/bin/env bash
#
# backup-octbase.sh — dump every running Octbase PostgreSQL container, verify
# each dump by restoring it into a throwaway database, and prune old dumps.
#
# A backup you have never restored is a hope, not a backup. This script fails
# (non-zero exit) if a dump cannot be taken OR cannot be restored, so the
# systemd unit surfaces the problem instead of silently accumulating unusable
# files. Addresses the "regular backup + documented restore test" requirement
# of the datenschutz.ch "Sichere Website" guidance and RiLi-Webservices §12.3.
#
# Runs unprivileged via rootless podman. Config via env:
#   BACKUP_ROOT     where dumps are written        (default /home/claude/backups)
#   RETENTION_DAYS  delete dumps older than this   (default 14)
#   TEST_IMAGE      postgres image for restore test — MUST be >= the source
#                   server's major version or pg_restore rejects the archive
#                   (default: the same image the live stacks run)
set -uo pipefail

BACKUP_ROOT="${BACKUP_ROOT:-/home/claude/backups}"
RETENTION_DAYS="${RETENTION_DAYS:-14}"
# Pinned to the exact version the live stacks run (PG 18.4): a major-only tag
# that is already cached never re-pulls, so it could silently fall behind the
# server and erode the "restore client >= server" guarantee. Bump this pin
# together with server upgrades.
TEST_IMAGE="${TEST_IMAGE:-registry.access.redhat.com/hi/postgresql:18.4}"
TEST_CTR="octbase_bkptest_$$"
LOG="$BACKUP_ROOT/backup.log"
STAMP="$(date +%Y%m%d-%H%M%S)"

mkdir -p "$BACKUP_ROOT"
chmod 700 "$BACKUP_ROOT"   # dumps hold client data — owner-only, like the fleet job
rc_overall=0

log() { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG"; }

cleanup() { podman rm -f "$TEST_CTR" >/dev/null 2>&1 || true; }
trap cleanup EXIT

# ── Discover Octbase Postgres containers ────────────────────────────────────
# ps -a, not just ps: a stopped stack still has data worth backing up, and a
# run that silently omits it would look like success. Every postgres container
# that exists but is not running fails the run loudly instead.
# Discovery is scoped to compose-managed postgres services by label — a name
# grep also matched any unrelated exited container with "postgres" in its
# name (a scratch run, a renamed experiment) and turned every nightly red
# until someone removed it. The label is what the playbooks resolve by too.
PG_LABEL="io.podman.compose.service=postgres"
mapfile -t ALL_PG < <(podman ps -a --filter "label=$PG_LABEL" --format '{{.Names}}')
mapfile -t PG_CONTAINERS < <(podman ps --filter "label=$PG_LABEL" --format '{{.Names}}')
if [ "${#ALL_PG[@]}" -eq 0 ]; then
	log "ERROR: no postgres containers found — nothing to back up"
	exit 1
fi
for ctr in "${ALL_PG[@]}"; do
	if ! printf '%s\n' "${PG_CONTAINERS[@]}" | grep -qxF "$ctr"; then
		log "ERROR: postgres container '$ctr' exists but is NOT running — not backed up (start it or remove the stale container)"
		rc_overall=1
	fi
done
if [ "${#PG_CONTAINERS[@]}" -eq 0 ]; then
	log "ERROR: no running postgres containers found — nothing to back up"
	exit 1
fi

# ── Start one throwaway Postgres for the restore tests ──────────────────────
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
# pg_isready can answer during the image's initdb bootstrap, before the final
# server is up (the first DROP/CREATE would then fail with no retry) — so
# require a real query to succeed before trusting the instance.
ready=0
for _ in $(seq 1 30); do
	if podman exec "$TEST_CTR" psql -U test -d postgres -tAc 'SELECT 1' >/dev/null 2>&1; then
		ready=1; break
	fi
	sleep 1
done
if [ "$ready" -ne 1 ]; then
	log "ERROR: restore-test instance did not become ready"
	exit 1
fi

# ── Per-container: dump, verify by restore ──────────────────────────────────
for ctr in "${PG_CONTAINERS[@]}"; do
	user="$(podman exec "$ctr" printenv POSTGRES_USER 2>/dev/null || echo postgres)"
	db="$(podman exec "$ctr" printenv POSTGRES_DB 2>/dev/null || echo "$user")"
	dest="$BACKUP_ROOT/$ctr"
	mkdir -p "$dest"
	chmod 700 "$dest"
	dump="$dest/${db}-${STAMP}.dump"

	# Source row count for a stable table, used to assert the restore is
	# faithful. Counted immediately before the dump (pg_dump snapshots at
	# start): a write landing in the remaining window can still cause a rare
	# false mismatch — rerun before trusting a one-off failure.
	src_users="$(podman exec "$ctr" psql -U "$user" -d "$db" -tAc 'SELECT count(*) FROM users' 2>/dev/null | tr -d '[:space:]')"
	[ -z "$src_users" ] && src_users="NA"

	log "[$ctr] dumping database '$db' (user '$user')"
	if ! podman exec "$ctr" pg_dump -U "$user" -d "$db" -Fc --no-owner >"$dump" 2>>"$LOG"; then
		log "[$ctr] ERROR: pg_dump failed"; rc_overall=1; rm -f "$dump"; continue
	fi
	size=$(stat -c%s "$dump" 2>/dev/null || echo 0)
	if [ "$size" -lt 1024 ]; then
		# keep nothing: a known-bad dump lying around invites restoring it
		log "[$ctr] ERROR: dump suspiciously small (${size} bytes) — deleted"; rc_overall=1; rm -f "$dump"; continue
	fi
	chmod 600 "$dump"
	log "[$ctr] dump written: $dump (${size} bytes)"

	# ── Restore test ────────────────────────────────────────────────────
	podman exec "$TEST_CTR" psql -U test -d postgres -q \
		-c 'DROP DATABASE IF EXISTS restoretest' \
		-c 'CREATE DATABASE restoretest' >>"$LOG" 2>&1
	podman cp "$dump" "$TEST_CTR:/tmp/restore.dump"
	# pg_restore prints notices too, but a nonzero exit means at least one
	# object failed to restore — that fails the test outright; the assertions
	# below additionally catch silent corruption.
	podman exec "$TEST_CTR" pg_restore -U test -d restoretest --no-owner /tmp/restore.dump >>"$LOG" 2>&1
	restore_rc=$?
	podman exec "$TEST_CTR" rm -f /tmp/restore.dump >/dev/null 2>&1

	tables="$(podman exec "$TEST_CTR" psql -U test -d restoretest -tAc \
		"SELECT count(*) FROM information_schema.tables WHERE table_schema='public'" 2>/dev/null | tr -d '[:space:]')"
	[ -z "$tables" ] && tables=0

	if [ "$restore_rc" -ne 0 ]; then
		log "[$ctr] ERROR: restore test FAILED — pg_restore exited $restore_rc (see $LOG)"; rc_overall=1
	elif [ "$tables" -lt 1 ]; then
		log "[$ctr] ERROR: restore test FAILED — restored schema has no tables"; rc_overall=1
	elif [ "$src_users" != "NA" ]; then
		dst_users="$(podman exec "$TEST_CTR" psql -U test -d restoretest -tAc 'SELECT count(*) FROM users' 2>/dev/null | tr -d '[:space:]')"
		[ -z "$dst_users" ] && dst_users="NA"
		if [ "$dst_users" = "$src_users" ]; then
			log "[$ctr] restore test OK — $tables tables, users $dst_users == source $src_users"
		else
			log "[$ctr] ERROR: restore test FAILED — users mismatch (source $src_users, restored $dst_users)"; rc_overall=1
		fi
	else
		log "[$ctr] restore test OK — $tables tables restored (no 'users' table to cross-check)"
	fi
done

# ── Prune old dumps ─────────────────────────────────────────────────────────
# Across ALL directories under the backup root, not just the containers seen
# this run — otherwise the dirs of removed/renamed containers keep their dumps
# forever, past every retention promise.
deleted=$(find "$BACKUP_ROOT" -name '*.dump' -type f -mtime "+$RETENTION_DAYS" -print -delete | wc -l)
[ "$deleted" -gt 0 ] && log "pruned $deleted dump(s) older than ${RETENTION_DAYS}d"
# A removed container's directory lingers after its last dump ages out; sweep
# emptied dirs so the root reflects what actually has backups. An active
# container's dir is never empty here — its dump was written above.
find "$BACKUP_ROOT" -mindepth 1 -type d -empty -delete

if [ "$rc_overall" -eq 0 ]; then
	log "backup run completed OK"
else
	log "backup run completed WITH ERRORS"
fi
exit "$rc_overall"
