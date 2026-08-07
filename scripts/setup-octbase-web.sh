#!/usr/bin/env bash
#
# setup-octbase-web.sh
# ---------------------------------------------------------------------------
# Stand the public octbase.io marketing site up on a fresh fleet host: its own
# unprivileged Linux account (oct-web) running the site as a rootless-podman
# stack that starts on boot, published on loopback only, with an edge vhost
# snippet so the root-managed Caddy fronts it.
#
#   octbase.io + www.octbase.io  ->  127.0.0.1:8120  (oct-web, rootless podman)
#
# 8120 is reserved in ledger/ledger.py (RESERVED_PORTS) precisely so the client
# port allocator never hands it out. Changing SITE_PORT here means changing it
# there too — contract C8, see docs/consistency-register.md.
#
# Run as root on the target host:
#
#     sudo bash setup-octbase-web.sh                     # interactive
#     sudo bash setup-octbase-web.sh --yes               # non-interactive
#     sudo bash setup-octbase-web.sh --src /path/to/checkout
#     sudo bash setup-octbase-web.sh --env-file /root/octbase-web.env
#
# The site *code* is rsynced from a local directory (--src); this script never
# talks to GitHub. Get the checkout onto the host the way the rest of this
# toolkit does — rsync it from the admin machine — then point --src at it.
#
# Idempotent: safe to re-run. A re-run re-syncs the site, rebuilds, and
# converges the unit and the edge snippet. It NEVER overwrites an existing
# .env, so the SMTP secrets survive (pass --env-file to replace them
# deliberately).
#
# Prerequisite: setup-host.yml has run on this host, so the edge Caddyfile and
# its import of the snippet directory exist. This script owns only the oct-web
# account, the site stack, and its own edge snippet.
# ---------------------------------------------------------------------------
set -euo pipefail

# ── Configuration ──────────────────────────────────────────────────────────
WEB_USER="oct-web"                            # dedicated account for the site
WEB_HOME="/home/${WEB_USER}"
APP_DIR="${WEB_HOME}/octbase.io"              # deploy target
CRED_DIR="${WEB_HOME}/credentials"
ENV_FILE="${CRED_DIR}/.env.octbase-web"

SITE_DOMAIN="octbase.io"                      # matches base_domain in group_vars
SITE_PORT="8120"                              # loopback port (reserved in ledger.py)
SITE_TARGET="127.0.0.1:${SITE_PORT}"

COMPOSE_PROJECT="octbase-web"
UNIT_NAME="octbase-web.service"

EDGE_CADDY="/etc/caddy/Caddyfile"
EDGE_SNIPPET_DIR="/etc/octbase/edge"          # edge_snippet_dir in group_vars
EDGE_SNIPPET="${EDGE_SNIPPET_DIR}/octbase-web.caddy"

SRC_DIR="/home/claude/octbase-web"            # default source checkout
SEED_ENV=""                                   # optional --env-file
ASSUME_YES=0

# ── Logging helpers ────────────────────────────────────────────────────────
log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ok\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  ! \033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERR\033[0m %s\n' "$*" >&2; exit 1; }

# ── Arguments ──────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        -y|--yes)   ASSUME_YES=1; shift;;
        --src)      SRC_DIR="${2:?--src needs a directory}"; shift 2;;
        --env-file) SEED_ENV="${2:?--env-file needs a file}"; shift 2;;
        -h|--help)  sed -n '2,35p' "$0"; exit 0;;
        *)          die "unknown argument: $1 (try --help)";;
    esac
done

# ── 0. Pre-flight ──────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "must run as root."

for bin in runuser rsync podman podman-compose caddy loginctl systemctl curl useradd usermod; do
    command -v "$bin" >/dev/null 2>&1 || die "required command not found: $bin"
done

[[ -d "$SRC_DIR" ]] || die "source checkout not found: $SRC_DIR (pass --src)"
[[ -f "$SRC_DIR/podman-compose.yml" ]] || die "no podman-compose.yml in $SRC_DIR — is this the octbase-web checkout?"
[[ -f "$SRC_DIR/Containerfile" ]]      || die "no Containerfile in $SRC_DIR — is this the octbase-web checkout?"
[[ -n "$SEED_ENV" && ! -f "$SEED_ENV" ]] && die "--env-file not found: $SEED_ENV"

# The edge Caddyfile and its snippet directory belong to setup-host.yml. Refuse
# to half-provision rather than inventing a Caddyfile this script does not own.
[[ -f "$EDGE_CADDY" ]] || die \
    "edge Caddyfile not found: $EDGE_CADDY
     Run the baseline first:  ansible-playbook playbooks/setup-host.yml -e target_host=<host>"
[[ -d "$EDGE_SNIPPET_DIR" ]] || die \
    "edge snippet dir not found: $EDGE_SNIPPET_DIR
     Run the baseline first:  ansible-playbook playbooks/setup-host.yml -e target_host=<host>"
grep -qF "import ${EDGE_SNIPPET_DIR}/" "$EDGE_CADDY" || die \
    "$EDGE_CADDY does not import ${EDGE_SNIPPET_DIR}/*.caddy — a snippet dropped there
     would be ignored. Re-run setup-host.yml, which owns that import line."

# A vhost for these names already written INTO the main Caddyfile (rather than
# as a snippet) would collide with ours — Caddy rejects duplicate site
# addresses, and we would only find out at validate time after touching the
# live config. Catch it before writing anything.
if grep -Eq "^[[:space:]]*(https?://)?(www\.)?${SITE_DOMAIN//./\\.}[[:space:]]*(,|\{)" "$EDGE_CADDY"; then
    die "$EDGE_CADDY already declares a vhost for ${SITE_DOMAIN} directly.
     This script serves that name from ${EDGE_SNIPPET}. Remove the inline block
     first, or this host is not a fresh install — see docs/platform-overview.md §2."
fi

cat <<EOF

  Source      : ${SRC_DIR}   (rsynced; never fetched from git)
  Target user : ${WEB_USER}$(getent passwd "$WEB_USER" >/dev/null && echo "  (exists)" || echo "  (WILL BE CREATED)")
  Deploy dir  : ${APP_DIR}
  Site port   : ${SITE_TARGET}  (loopback; the edge is the only public entry)
  Edge vhost  : ${SITE_DOMAIN} + www.${SITE_DOMAIN}  ->  ${SITE_TARGET}
  Edge snippet: ${EDGE_SNIPPET}
  Env file    : ${ENV_FILE}$( [[ -n "$SEED_ENV" ]] && echo "  (seeded from ${SEED_ENV})" )

EOF
if [[ $ASSUME_YES -ne 1 ]]; then
    read -r -p "Proceed? [y/N] " ans
    [[ "$ans" == "y" || "$ans" == "Y" ]] || die "aborted by operator."
fi

# ── 1. The oct-web account ─────────────────────────────────────────────────
# Locked password and /bin/sh: the account exists to own a stack, not to be
# logged into — the same stance setup-host.yml's sshd template takes toward
# `oct-*` accounts. Nothing here seeds authorized_keys or an sshd AllowUsers
# entry; if an operator ever needs to reach this account directly, that is a
# deliberate, separate change.
if getent passwd "$WEB_USER" >/dev/null; then
    ok "account ${WEB_USER} already exists"
else
    log "Creating account ${WEB_USER}"
    useradd -m -s /bin/sh -c "${SITE_DOMAIN} marketing site" "$WEB_USER"
    passwd -l "$WEB_USER" >/dev/null
    ok "account created (password locked)"
fi

WEB_UID="$(id -u "$WEB_USER")"
RUNTIME_DIR="/run/user/${WEB_UID}"

# Rootless podman needs a subordinate uid/gid range. usermod picks a free one.
for kind in subuid subgid; do
    if grep -q "^${WEB_USER}:" "/etc/${kind}"; then
        ok "/etc/${kind} entry present"
    else
        log "Adding /etc/${kind} range for ${WEB_USER}"
        usermod "--add-${kind}s" 100000-165535 "$WEB_USER" 2>/dev/null \
            || die "could not add a ${kind} range for ${WEB_USER} — add one by hand."
        ok "/etc/${kind} range added"
    fi
done

# ── 2. Linger, so the user's stack starts at boot without a login ──────────
log "Enabling linger for ${WEB_USER}"
loginctl enable-linger "$WEB_USER"
for _ in $(seq 1 30); do [[ -d "$RUNTIME_DIR" ]] && break; sleep 1; done
[[ -d "$RUNTIME_DIR" ]] || die "user runtime dir $RUNTIME_DIR never appeared (linger/user@ manager not up)"
ok "linger on, runtime dir ready ($RUNTIME_DIR)"

# ── run a command as oct-web with a working rootless-podman environment ────
# NOTE: neither `runuser` (without -l) nor `env` changes the working directory,
# so the child inherits the caller's cwd. Launched from e.g. /home/claude (0750,
# owned by claude) the oct-web user cannot chdir there and podman/crun dies with
# "cannot chdir to <cwd>: Permission denied" when it forks its runtime process.
# Run from oct-web's own home, which it can always read.
as_web() {
    ( cd "$WEB_HOME" && runuser -u "$WEB_USER" -- env \
        HOME="$WEB_HOME" \
        XDG_RUNTIME_DIR="$RUNTIME_DIR" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=${RUNTIME_DIR}/bus" \
        PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
        "$@" )
}

# ── 3. Sync the site into the account ──────────────────────────────────────
log "Syncing ${SRC_DIR} -> ${APP_DIR}"
mkdir -p "$APP_DIR"
# .env is this script's to own (below); .git has no business on a deploy target.
# Excluded paths are also protected from --delete, so a re-run keeps the .env.
rsync -a --delete --exclude '.env' --exclude '.git' "$SRC_DIR/" "$APP_DIR/"
ok "site files synced"

# ── 4. Environment file ────────────────────────────────────────────────────
# Precedence: an explicit --env-file replaces it; otherwise an existing .env is
# kept as-is (its SMTP secrets are the only copy on the host); otherwise seed a
# blank one from the checkout's .env.example.
set_env_key() {   # set_env_key <file> <key> <value>
    local f="$1" k="$2" v="$3"
    if grep -q "^${k}=" "$f"; then
        sed -i -E "s#^${k}=.*#${k}=${v}#" "$f"
    else
        printf '%s=%s\n' "$k" "$v" >> "$f"
    fi
}

mkdir -p "$CRED_DIR"
umask 077
if [[ -n "$SEED_ENV" ]]; then
    log "Writing ${ENV_FILE} from ${SEED_ENV}"
    cp -- "$SEED_ENV" "$ENV_FILE"
elif [[ -f "$ENV_FILE" ]]; then
    log "Keeping existing ${ENV_FILE} (secrets preserved)"
else
    log "Seeding ${ENV_FILE} from the checkout's .env.example"
    [[ -f "$SRC_DIR/.env.example" ]] \
        || die "no .env.example in $SRC_DIR and no existing $ENV_FILE — pass --env-file."
    cp -- "$SRC_DIR/.env.example" "$ENV_FILE"
fi

# Platform-managed settings, re-applied on every run (the port binding and the
# compose project name are ours to decide, not the operator's).
set_env_key "$ENV_FILE" WEB_PORT "$SITE_TARGET"
set_env_key "$ENV_FILE" COMPOSE_PROJECT_NAME "$COMPOSE_PROJECT"
umask 022

# app/.env -> ../credentials/.env.octbase-web, the layout used elsewhere on the host
ln -sfn "../credentials/.env.octbase-web" "$APP_DIR/.env"

if ! grep -q '^WEB_SMTP_HOST=.\+' "$ENV_FILE"; then
    warn "WEB_SMTP_HOST is empty in ${ENV_FILE} — the site will serve, but the"
    warn "contact form cannot relay mail. Fill the WEB_SMTP_* / WEB_MAIL_* keys"
    warn "and re-run, or pass --env-file."
fi
ok "env staged, WEB_PORT=${SITE_TARGET}"

# ── 5. Ownership ───────────────────────────────────────────────────────────
log "Fixing ownership"
chown -R "${WEB_USER}:${WEB_USER}" "$APP_DIR" "$CRED_DIR"
chmod 700 "$CRED_DIR"
chmod 600 "$ENV_FILE"
ok "ownership set"

# ── 6. Sanity-check rootless podman for this user ──────────────────────────
log "Verifying rootless podman works for ${WEB_USER}"
if ! as_web podman info >/dev/null 2>&1; then
    warn "podman info failed on first try — running 'podman system migrate'"
    as_web podman system migrate || true
    as_web podman info >/dev/null 2>&1 || die "rootless podman not functional for ${WEB_USER}"
fi
ok "rootless podman OK"

# ── 7. Build the images ahead of boot (keeps the boot-time unit fast) ──────
log "Building images (caddy site + mailer) as ${WEB_USER}"
as_web sh -c "cd '$APP_DIR' && podman-compose build"
ok "images built"

# ── 8. Install + enable the systemd --user unit ────────────────────────────
log "Installing systemd user unit ${UNIT_NAME}"
UNIT_DIR="${WEB_HOME}/.config/systemd/user"
mkdir -p "$UNIT_DIR"
cat > "${UNIT_DIR}/${UNIT_NAME}" <<EOF
[Unit]
Description=${SITE_DOMAIN} marketing site (${WEB_USER}, podman-compose)
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
# `enable --now` would be a no-op on a re-run: the RemainAfterExit oneshot is
# still "active" from the previous run, so the freshly built image would never
# be deployed. `restart` runs ExecStop (compose down) + ExecStart (compose up)
# even then, and plain-starts the unit on the first run.
as_web systemctl --user enable "$UNIT_NAME"
as_web systemctl --user restart "$UNIT_NAME"
ok "unit enabled and (re)started"

# Confirm the site answers on loopback BEFORE pointing the edge at it.
sleep 3
if as_web sh -c "curl -fsS -o /dev/null http://${SITE_TARGET}/" 2>/dev/null; then
    ok "site responds on ${SITE_TARGET}"
else
    as_web sh -c "cd '$APP_DIR' && podman-compose ps" || true
    die "site is not answering on ${SITE_TARGET} — check 'podman-compose logs' as ${WEB_USER} before touching the edge."
fi

# ── 9. Edge vhost snippet ──────────────────────────────────────────────────
# One snippet in ${EDGE_SNIPPET_DIR}, picked up by the Caddyfile's import — the
# same mechanism create-instance.yml uses for client vhosts. The main Caddyfile
# is never edited here.
log "Writing edge snippet ${EDGE_SNIPPET}"

SNIPPET_BACKUP=""
if [[ -f "$EDGE_SNIPPET" ]]; then
    SNIPPET_BACKUP="${EDGE_SNIPPET}.bak.$$"
    cp -a "$EDGE_SNIPPET" "$SNIPPET_BACKUP"
fi

cat > "$EDGE_SNIPPET" <<EOF
# Managed by octbase-service / scripts/setup-octbase-web.sh — do not edit by hand.
# Edge vhost for the public ${SITE_DOMAIN} marketing site (${WEB_USER} account).
# Imported via:  import ${EDGE_SNIPPET_DIR}/*.caddy
${SITE_DOMAIN}, www.${SITE_DOMAIN} {
	# Without a \`log\` block Caddy puts this vhost in the server's skip_hosts,
	# leaving the platform with no edge access log for it at all. No query
	# filter here (unlike the client vhosts): a static marketing site carries
	# no tokens or OAuth codes in its URLs.
	log {
		output file /var/log/caddy/access.log
		format console
	}

	encode gzip
	reverse_proxy ${SITE_TARGET}
}
EOF

if caddy validate --config "$EDGE_CADDY" >/dev/null 2>&1; then
    systemctl reload caddy
    ok "edge validated and reloaded"
else
    if [[ -n "$SNIPPET_BACKUP" ]]; then
        mv -f "$SNIPPET_BACKUP" "$EDGE_SNIPPET"
    else
        rm -f "$EDGE_SNIPPET"
    fi
    die "edge validation FAILED — snippet reverted, edge NOT reloaded. Run
     'caddy validate --config ${EDGE_CADDY}' to see why."
fi
[[ -n "$SNIPPET_BACKUP" ]] && rm -f "$SNIPPET_BACKUP"

# Guardrail: the marketing site is public by definition and must never end up
# behind a password.
if grep -Eiq 'basic_?auth' "$EDGE_SNIPPET"; then
    warn "the snippet contains a basic_auth directive — ${SITE_DOMAIN} must stay password-free."
else
    ok "no basic_auth in the snippet (${SITE_DOMAIN} stays password-free)"
fi

# ── 10. Verify through the edge ────────────────────────────────────────────
log "Verifying reachability through the edge (localhost:80, Host header)"
for h in "$SITE_DOMAIN" "www.${SITE_DOMAIN}"; do
    # NB: no "|| echo ERR" inside the substitution — a failing curl still prints
    # its -w output, which would yield "000ERR" and match no case.
    code=$(curl -s -o /dev/null -w '%{http_code}' -H "Host: $h" "http://127.0.0.1:80/") || code=000
    case "$code" in
        401) warn "  $h -> HTTP 401 (PASSWORD PROMPT!) — investigate, this must be public";;
        000) warn "  $h -> no response (is the edge up?)";;
        *)   printf '     %-20s -> HTTP %s\n' "$h" "$code";;
    esac
done

cat <<EOF

$(ok "Done.")
  ${SITE_DOMAIN} / www.${SITE_DOMAIN} are served by the ${WEB_USER} account
  (rootless podman, ${SITE_TARGET}), starting automatically on boot via
  '${UNIT_NAME}' + linger.

  DNS is a manual step this script does not touch: point ${SITE_DOMAIN} and
  www.${SITE_DOMAIN} at this host, then let Caddy obtain the certificates.

  Handy follow-ups:
    - Status: runuser -u ${WEB_USER} -- env XDG_RUNTIME_DIR=${RUNTIME_DIR} systemctl --user status ${UNIT_NAME}
    - Logs:   runuser -u ${WEB_USER} -- env XDG_RUNTIME_DIR=${RUNTIME_DIR} sh -c 'cd ${APP_DIR} && podman-compose logs -f'
    - Update: re-run this script (re-syncs, rebuilds, keeps the .env)
    - Remove: rm ${EDGE_SNIPPET} && systemctl reload caddy
EOF
