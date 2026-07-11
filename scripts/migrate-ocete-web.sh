#!/usr/bin/env bash
#
# migrate-ocete-web.sh
# ---------------------------------------------------------------------------
# Move the public ocete.ch marketing site into its own dedicated Linux
# account (oct-web) as a rootless-podman stack that starts on boot, and cut
# the edge reverse proxy over to it.
#
#   * ocete.ch + www.ocete.ch          -> served by the NEW oct-web instance
#                                         (rootless podman, bound 127.0.0.1:8120)
#   * dev.ocete.ch                     -> LEFT UNTOUCHED (stays public, no auth)
#   * /home/claude/ocete.ch            -> KEPT as-is for further development
#
# Both ocete.ch and dev.ocete.ch remain publicly reachable in a browser with
# no password: this script never adds basic_auth and refuses to reload the
# edge if validation fails.
#
# Run as root on the host that runs the app stacks AND the edge Caddy:
#
#     sudo bash migrate-ocete-web.sh          # interactive confirmation
#     sudo bash migrate-ocete-web.sh --yes    # non-interactive
#
# Idempotent: safe to re-run. It re-syncs the site, rebuilds, and converges
# the edge config to the intended target.
# ---------------------------------------------------------------------------
set -euo pipefail

# ── Configuration ──────────────────────────────────────────────────────────
SRC_USER="claude"
SRC_DIR="/home/${SRC_USER}/ocete.ch"        # existing marketing checkout

WEB_USER="oct-web"                           # dedicated account (already exists)
WEB_HOME="/home/${WEB_USER}"
APP_DIR="${WEB_HOME}/ocete.ch"               # deploy target
CRED_DIR="${WEB_HOME}/credentials"

WEB_PORT_NUM="8120"                          # host loopback port for the site
NEW_TARGET="127.0.0.1:${WEB_PORT_NUM}"       # what the edge will proxy to
OLD_TARGET="178.105.142.1:8082"              # current hardcoded edge target

EDGE_CADDY="/etc/caddy/Caddyfile"
UNIT_NAME="ocete-web.service"

ASSUME_YES=0
[[ "${1:-}" == "--yes" || "${1:-}" == "-y" ]] && ASSUME_YES=1

# ── Logging helpers ────────────────────────────────────────────────────────
log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ok\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  ! \033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERR\033[0m %s\n' "$*" >&2; exit 1; }

# ── 0. Pre-flight ──────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "must run as root."

for bin in runuser rsync podman podman-compose caddy loginctl systemctl install; do
    command -v "$bin" >/dev/null 2>&1 || die "required command not found: $bin"
done

[[ -d "$SRC_DIR" ]]                 || die "source site not found: $SRC_DIR"
[[ -f "$SRC_DIR/podman-compose.yml" ]] || die "no podman-compose.yml in $SRC_DIR"
[[ -f "$EDGE_CADDY" ]]              || die "edge Caddyfile not found: $EDGE_CADDY"

getent passwd "$WEB_USER" >/dev/null || die \
    "account '$WEB_USER' does not exist. Create it first:
       useradd -m -s /bin/sh -c 'ocete.ch marketing site' $WEB_USER
     and add /etc/subuid + /etc/subgid entries for rootless podman."

WEB_UID="$(id -u "$WEB_USER")"
RUNTIME_DIR="/run/user/${WEB_UID}"

# resolve the real .env behind claude's symlink so we can copy the secrets
SRC_ENV="$(readlink -f "$SRC_DIR/.env" 2>/dev/null || true)"
[[ -n "$SRC_ENV" && -f "$SRC_ENV" ]] || die "cannot resolve source .env ($SRC_DIR/.env)"

# subuid/subgid sanity (rootless podman needs a namespace range)
grep -q "^${WEB_USER}:" /etc/subuid || die "no /etc/subuid entry for $WEB_USER"
grep -q "^${WEB_USER}:" /etc/subgid || die "no /etc/subgid entry for $WEB_USER"

# port not already taken by something else on the host
if ss -ltnH "( sport = :${WEB_PORT_NUM} )" 2>/dev/null | grep -q .; then
    warn "port ${WEB_PORT_NUM} already has a listener — assuming it is a prior run of this instance."
fi

cat <<EOF

  Source site : ${SRC_DIR}   (account: ${SRC_USER}, kept for development)
  Target user : ${WEB_USER}  (uid ${WEB_UID})
  Deploy dir  : ${APP_DIR}
  Site port   : ${NEW_TARGET}  (loopback; edge is the only public entry)
  Edge config : ${EDGE_CADDY}
  Edge change : ocete.ch + www.ocete.ch  ->  ${NEW_TARGET}
                dev.ocete.ch             ->  UNCHANGED (stays public, no auth)

EOF
if [[ $ASSUME_YES -ne 1 ]]; then
    read -r -p "Proceed? [y/N] " ans
    [[ "$ans" == "y" || "$ans" == "Y" ]] || die "aborted by operator."
fi

# ── run a command as the oct-web user with a rootless-podman environment ────
# NOTE: neither `runuser` (without -l) nor `env` changes the working directory,
# so the child inherits the caller's cwd. If the script is launched from
# /home/claude (mode 0750, owned by claude) the oct-web user cannot chdir there
# and podman/crun dies with "cannot chdir to <cwd>: Permission denied" when it
# forks its runtime process. Run from oct-web's own home, which it can access.
as_web() {
    ( cd "$WEB_HOME" && runuser -u "$WEB_USER" -- env \
        HOME="$WEB_HOME" \
        XDG_RUNTIME_DIR="$RUNTIME_DIR" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=${RUNTIME_DIR}/bus" \
        PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
        "$@" )
}

# ── 1. Enable linger so the user's services run at boot without a login ─────
log "Enabling linger for ${WEB_USER} (starts stack on boot)"
loginctl enable-linger "$WEB_USER"
for _ in $(seq 1 30); do [[ -d "$RUNTIME_DIR" ]] && break; sleep 1; done
[[ -d "$RUNTIME_DIR" ]] || die "user runtime dir $RUNTIME_DIR never appeared (linger/user@ manager not up)"
ok "linger on, runtime dir ready ($RUNTIME_DIR)"

# ── 2. Sync the site into the oct-web account ──────────────────────────────
log "Syncing ${SRC_DIR} -> ${APP_DIR}"
mkdir -p "$APP_DIR"
# .env is handled separately (it is a symlink into another account's creds);
# no pgdata/attachments for this static site.
rsync -a --delete --exclude '.env' --exclude 'pgdata' --exclude 'attachments' \
    "$SRC_DIR/" "$APP_DIR/"
ok "site files synced"

# ── 3. Per-account .env with its own loopback port ─────────────────────────
log "Writing ${CRED_DIR}/.env.ocete (own copy of the SMTP secrets)"
mkdir -p "$CRED_DIR"
umask 077
# copy source env, forcing WEB_PORT to the loopback binding
sed -E "s#^WEB_PORT=.*#WEB_PORT=${NEW_TARGET}#" "$SRC_ENV" > "$CRED_DIR/.env.ocete"
grep -q '^WEB_PORT=' "$CRED_DIR/.env.ocete" || \
    printf 'WEB_PORT=%s\n' "$NEW_TARGET" >> "$CRED_DIR/.env.ocete"
umask 022
# link app/.env -> ../credentials/.env.ocete (same layout as the claude account)
ln -sfn "../credentials/.env.ocete" "$APP_DIR/.env"
ok "env staged, WEB_PORT=${NEW_TARGET}"

# ── 4. Ownership: everything under oct-web belongs to oct-web ───────────────
log "Fixing ownership"
chown -R "${WEB_USER}:${WEB_USER}" "$APP_DIR" "$CRED_DIR"
chmod 600 "$CRED_DIR/.env.ocete"
ok "ownership set"

# ── 5. Sanity-check rootless podman for this user ──────────────────────────
log "Verifying rootless podman works for ${WEB_USER}"
if ! as_web podman info >/dev/null 2>&1; then
    warn "podman info failed on first try — running 'podman system migrate'"
    as_web podman system migrate || true
    as_web podman info >/dev/null 2>&1 || die "rootless podman not functional for ${WEB_USER}"
fi
ok "rootless podman OK"

# ── 6. Build the images ahead of boot (keeps the boot-time unit fast) ──────
log "Building images (caddy site + mailer) as ${WEB_USER}"
as_web sh -c "cd '$APP_DIR' && podman-compose build"
ok "images built"

# ── 7. Install + enable the systemd --user unit (loads on boot) ────────────
log "Installing systemd user unit ${UNIT_NAME}"
UNIT_DIR="${WEB_HOME}/.config/systemd/user"
mkdir -p "$UNIT_DIR"
cat > "${UNIT_DIR}/${UNIT_NAME}" <<EOF
[Unit]
Description=ocete.ch marketing site (oct-web, podman-compose)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${APP_DIR}
ExecStart=/usr/bin/podman-compose up -d
ExecStop=/usr/bin/podman-compose down
TimeoutStartSec=600

[Install]
WantedBy=default.target
EOF
chown -R "${WEB_USER}:${WEB_USER}" "${WEB_HOME}/.config"

as_web systemctl --user daemon-reload
as_web systemctl --user enable --now "$UNIT_NAME"
ok "unit enabled and started"

# give the containers a moment, then confirm the site answers on loopback
sleep 3
if as_web sh -c "curl -fsS -o /dev/null http://127.0.0.1:${WEB_PORT_NUM}/" 2>/dev/null; then
    ok "site responds on 127.0.0.1:${WEB_PORT_NUM}"
else
    as_web sh -c "cd '$APP_DIR' && podman-compose ps" || true
    die "site is not answering on 127.0.0.1:${WEB_PORT_NUM} — check 'podman-compose logs' as ${WEB_USER} before touching the edge."
fi

# ── 8. Cut the edge reverse proxy over to the oct-web instance ─────────────
log "Repointing the edge proxy (ocete.ch + www.ocete.ch -> ${NEW_TARGET})"

if grep -q "$OLD_TARGET" "$EDGE_CADDY"; then
    BACKUP="${EDGE_CADDY}.bak.$(date +%Y%m%d-%H%M%S)"
    cp -a "$EDGE_CADDY" "$BACKUP"
    ok "backed up edge config to $BACKUP"

    # Only the two marketing blocks use :8082; dev.ocete.ch uses :8081 and is
    # not matched, so it is left exactly as-is.
    n=$(grep -c "$OLD_TARGET" "$EDGE_CADDY")
    sed -i "s#${OLD_TARGET}#${NEW_TARGET}#g" "$EDGE_CADDY"
    log "  replaced ${n} occurrence(s) of ${OLD_TARGET}"
    [[ "$n" -eq 2 ]] || warn "expected 2 replacements (ocete.ch + www.ocete.ch), got ${n} — review $EDGE_CADDY"

    if caddy validate --config "$EDGE_CADDY" >/dev/null 2>&1; then
        systemctl reload caddy
        ok "edge validated and reloaded"
    else
        cp -a "$BACKUP" "$EDGE_CADDY"
        caddy validate --config "$EDGE_CADDY" >/dev/null 2>&1 || true
        die "edge validation FAILED — restored $BACKUP, edge NOT reloaded. Fix manually."
    fi
elif grep -q "$NEW_TARGET" "$EDGE_CADDY"; then
    ok "edge already points at ${NEW_TARGET} — nothing to change"
else
    warn "edge config no longer contains ${OLD_TARGET} nor ${NEW_TARGET}."
    warn "It may have been edited by hand. Ensure ocete.ch/www.ocete.ch proxy to ${NEW_TARGET} and reload caddy yourself."
fi

# guardrail: no password/basic auth was introduced for the public domains
if grep -Eiq 'basic_?auth' "$EDGE_CADDY"; then
    warn "edge config contains a basic_auth directive — verify it does NOT cover ocete.ch or dev.ocete.ch (both must stay password-free)."
else
    ok "no basic_auth in edge config (ocete.ch and dev.ocete.ch stay password-free)"
fi

# ── 9. Verify both domains through the edge ────────────────────────────────
log "Verifying public reachability through the edge (localhost:80, Host header)"
for h in ocete.ch www.ocete.ch dev.ocete.ch; do
    code=$(curl -s -o /dev/null -w '%{http_code}' -H "Host: $h" "http://127.0.0.1:80/" || echo "ERR")
    case "$code" in
        401) warn "  $h -> HTTP 401 (PASSWORD PROMPT!) — investigate, this must be public";;
        000|ERR) warn "  $h -> no response (is the edge up? is the upstream running?)";;
        *) printf '     %-16s -> HTTP %s\n' "$h" "$code";;
    esac
done

cat <<EOF

$(ok "Done.")
  ocete.ch / www.ocete.ch  now served by the ${WEB_USER} account (rootless
  podman, ${NEW_TARGET}), starting automatically on boot via
  'systemctl --user ${UNIT_NAME}' + linger.

  dev.ocete.ch is unchanged and still public with no password.

  The original site at ${SRC_DIR} (account ${SRC_USER}) is left running and
  untouched for further development — it is simply no longer the public
  production instance.

  Handy follow-ups:
    - Watch it:   runuser -u ${WEB_USER} -- env XDG_RUNTIME_DIR=${RUNTIME_DIR} systemctl --user status ${UNIT_NAME}
    - Logs:       runuser -u ${WEB_USER} -- env XDG_RUNTIME_DIR=${RUNTIME_DIR} sh -c 'cd ${APP_DIR} && podman-compose logs -f'
    - Rollback:   restore ${EDGE_CADDY}.bak.* and 'systemctl reload caddy'
EOF
