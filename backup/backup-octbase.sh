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
TEST_IMAGE="${TEST_IMAGE:-registry.access.redhat.com/hi/postgresql:18}"
TEST_CTR="octbase_bkptest_$$"
LOG="$BACKUP_ROOT/backup.log"
STAMP="$(date +%Y%m%d-%H%M%S)"

mkdir -p "$BACKUP_ROOT"
rc_overall=0

log() { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG"; }

cleanup() { podman rm -f "$TEST_CTR" >/dev/null 2>&1 || true; }
trap cleanup EXIT

# ── Discover Octbase Postgres containers ────────────────────────────────────
mapfile -t PG_CONTAINERS < <(podman ps --format '{{.Names}}' | grep -i postgres || true)
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
if ! podman exec "$TEST_CTR" pg_isready -U test >/dev/null 2>&1; then
	log "ERROR: restore-test instance did not become ready"
	exit 1
fi

# ── Per-container: dump, verify by restore, prune ───────────────────────────
for ctr in "${PG_CONTAINERS[@]}"; do
	user="$(podman exec "$ctr" printenv POSTGRES_USER 2>/dev/null || echo postgres)"
	db="$(podman exec "$ctr" printenv POSTGRES_DB 2>/dev/null || echo "$user")"
	dest="$BACKUP_ROOT/$ctr"
	mkdir -p "$dest"
	dump="$dest/${db}-${STAMP}.dump"

	log "[$ctr] dumping database '$db' (user '$user')"
	if ! podman exec "$ctr" pg_dump -U "$user" -d "$db" -Fc --no-owner >"$dump" 2>>"$LOG"; then
		log "[$ctr] ERROR: pg_dump failed"; rc_overall=1; rm -f "$dump"; continue
	fi
	size=$(stat -c%s "$dump" 2>/dev/null || echo 0)
	if [ "$size" -lt 1024 ]; then
		log "[$ctr] ERROR: dump suspiciously small (${size} bytes)"; rc_overall=1; continue
	fi
	log "[$ctr] dump written: $dump (${size} bytes)"

	# Source row count for a stable table, used to assert the restore is faithful.
	src_users="$(podman exec "$ctr" psql -U "$user" -d "$db" -tAc 'SELECT count(*) FROM users' 2>/dev/null | tr -d '[:space:]')"
	[ -z "$src_users" ] && src_users="NA"

	# ── Restore test ────────────────────────────────────────────────────
	podman exec "$TEST_CTR" psql -U test -d postgres -q \
		-c 'DROP DATABASE IF EXISTS restoretest' \
		-c 'CREATE DATABASE restoretest' >>"$LOG" 2>&1
	podman cp "$dump" "$TEST_CTR:/tmp/restore.dump"
	# pg_restore may print non-fatal notices; judge success by the assertions below.
	podman exec "$TEST_CTR" pg_restore -U test -d restoretest --no-owner /tmp/restore.dump >>"$LOG" 2>&1
	podman exec "$TEST_CTR" rm -f /tmp/restore.dump >/dev/null 2>&1

	tables="$(podman exec "$TEST_CTR" psql -U test -d restoretest -tAc \
		"SELECT count(*) FROM information_schema.tables WHERE table_schema='public'" 2>/dev/null | tr -d '[:space:]')"
	[ -z "$tables" ] && tables=0

	if [ "$tables" -lt 1 ]; then
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

	# ── Prune old dumps for this container ──────────────────────────────
	deleted=$(find "$dest" -maxdepth 1 -name '*.dump' -type f -mtime "+$RETENTION_DAYS" -print -delete | wc -l)
	[ "$deleted" -gt 0 ] && log "[$ctr] pruned $deleted dump(s) older than ${RETENTION_DAYS}d"
done

if [ "$rc_overall" -eq 0 ]; then
	log "backup run completed OK"
else
	log "backup run completed WITH ERRORS"
fi
exit "$rc_overall"
