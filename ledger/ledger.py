#!/usr/bin/env python3
"""ledger.py — CLI for the Octbase client ledger (ledger/clients/*.yml).

The ledger is the single source of truth for the client base; the Ansible
playbooks read these files directly. This tool only creates/validates/lists —
it never talks to the server.

Commands:
  new NAME [options]   scaffold a client file with the next free port block
  list                 print the client table
  validate             check names, editions, add-on rules, port collisions
  next-ports           print the next free frontend/api/postgres triplet
"""

import argparse
import datetime
import re
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    sys.exit("PyYAML required (comes with Ansible): pip install pyyaml")

CLIENTS_DIR = Path(__file__).resolve().parent / "clients"

# Max 28 chars: the Linux account is "oct-<name>" and useradd caps
# usernames at 32 characters.
NAME_RE = re.compile(r"^[a-z][a-z0-9-]{1,27}$")
# "demo" is deliberately not reserved: the public demo is ledger-managed
# since 2026-07-11 (clients/demo.yml, migrated via migrate-instance.yml).
RESERVED_NAMES = {"www", "dev", "mail", "api", "octbase", "admin"}
EDITIONS = {"team", "business", "enterprise"}
STATUSES = {"active", "suspended", "removed"}
# Ports already used by the dev/demo/marketing stacks on the host
# (8025/8026 are the dev/demo Mailpit UI ports of the dev overlay).
RESERVED_PORTS = {5432, 5433, 8000, 8001, 8025, 8026, 8080, 8081, 8082, 8083}
PORT_BASE = 8110   # first client block; blocks advance in steps of 10
PORT_STEP = 10


def load_clients():
    clients = {}
    for f in sorted(CLIENTS_DIR.glob("*.yml")):
        with open(f) as fh:
            clients[f.stem] = yaml.safe_load(fh) or {}
    return clients


def used_ports(clients):
    ports = set(RESERVED_PORTS)
    for c in clients.values():
        ports.update((c.get("ports") or {}).values())
    return ports


def next_port_block(clients):
    taken = used_ports(clients)
    base = PORT_BASE
    while any(p in taken for p in (base, base + 1, base + 2)):
        base += PORT_STEP
    return {"frontend": base, "api": base + 1, "postgres": base + 2}


def cmd_new(args):
    if not NAME_RE.match(args.name) or args.name in RESERVED_NAMES:
        sys.exit(f"invalid or reserved name: {args.name!r}")
    path = CLIENTS_DIR / f"{args.name}.yml"
    if path.exists():
        sys.exit(f"{path} already exists")
    if args.jira_import and args.edition == "team":
        sys.exit("the jira_import add-on cannot be booked for the team edition")
    clients = load_clients()
    ports = next_port_block(clients)
    entry = {
        "name": args.name,
        "display_name": args.display or args.name,
        "contact": args.contact or "",
        "edition": args.edition,
        "jira_import": bool(args.jira_import),
        "max_users": args.max_users,
        "registered": datetime.date.today().isoformat(),
        "status": "active",
        "app_version": args.app_version,
        "ports": ports,
        "notes": "",
    }
    if not args.app_version:
        del entry["app_version"]  # fall back to group_vars octbase_version
    with open(path, "w") as fh:
        yaml.safe_dump(entry, fh, sort_keys=False)
    print(f"wrote {path}")
    print(f"ports: frontend={ports['frontend']} api={ports['api']} "
          f"postgres={ports['postgres']}")
    print("next: git add/commit, then "
          f"ansible-playbook playbooks/create-instance.yml -e client={args.name}")


def cmd_list(_args):
    clients = load_clients()
    if not clients:
        print("no clients in the ledger")
        return
    hdr = ("NAME", "EDITION", "JIRA", "SEATS", "STATUS", "REGISTERED", "FRONTEND", "DISPLAY NAME")
    rows = [hdr]
    for name, c in clients.items():
        rows.append((
            name,
            str(c.get("edition", "?")),
            "yes" if c.get("jira_import") else "-",
            str(c.get("max_users", "?")),
            str(c.get("status", "?")),
            str(c.get("registered", "?")),
            str((c.get("ports") or {}).get("frontend", "?")),
            str(c.get("display_name", "")),
        ))
    widths = [max(len(r[i]) for r in rows) for i in range(len(hdr))]
    for i, r in enumerate(rows):
        print("  ".join(v.ljust(widths[j]) for j, v in enumerate(r)).rstrip())
        if i == 0:
            print("  ".join("-" * w for w in widths))


def cmd_validate(_args):
    clients = load_clients()
    errors, warnings = [], []
    seen_ports = {}
    for name, c in clients.items():
        where = f"clients/{name}.yml"
        if c.get("name") != name:
            errors.append(f"{where}: 'name' ({c.get('name')!r}) must equal the file name")
        if not NAME_RE.match(name) or name in RESERVED_NAMES:
            errors.append(f"{where}: invalid or reserved client name")
        if c.get("edition") not in EDITIONS:
            errors.append(f"{where}: edition must be one of {sorted(EDITIONS)}")
        if c.get("status") not in STATUSES:
            errors.append(f"{where}: status must be one of {sorted(STATUSES)}")
        if not isinstance(c.get("max_users"), int) or c["max_users"] < 1:
            errors.append(f"{where}: max_users must be a positive integer")
        if c.get("jira_import") and c.get("edition") == "team":
            errors.append(f"{where}: the jira_import add-on cannot be booked for team")
        if c.get("jira_import") and c.get("edition") == "enterprise":
            warnings.append(f"{where}: jira_import is redundant — enterprise includes it")
        if "monitor_edge_probe" in c and not isinstance(c["monitor_edge_probe"], bool):
            errors.append(f"{where}: monitor_edge_probe must be true or false")
        ports = c.get("ports") or {}
        if set(ports) != {"frontend", "api", "postgres"}:
            errors.append(f"{where}: ports must define frontend, api and postgres")
        for role, p in ports.items():
            if not isinstance(p, int) or not (1024 < p < 65536):
                errors.append(f"{where}: port {role}={p!r} out of range")
            elif p in RESERVED_PORTS:
                errors.append(f"{where}: port {p} is reserved (dev/demo/marketing stacks)")
            elif p in seen_ports:
                errors.append(f"{where}: port {p} collides with {seen_ports[p]}")
            else:
                seen_ports[p] = where
    for w in warnings:
        print(f"WARN  {w}")
    for e in errors:
        print(f"ERROR {e}")
    if errors:
        sys.exit(1)
    print(f"OK — {len(clients)} client(s), no errors")


def cmd_next_ports(_args):
    p = next_port_block(load_clients())
    print(f"frontend={p['frontend']} api={p['api']} postgres={p['postgres']}")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    p_new = sub.add_parser("new", help="scaffold a new client file")
    p_new.add_argument("name")
    p_new.add_argument("--display", help="display name (company)")
    p_new.add_argument("--contact", help="contact email")
    p_new.add_argument("--edition", choices=sorted(EDITIONS), required=True)
    p_new.add_argument("--jira-import", action="store_true",
                       help="book the Jira-CSV-import add-on (business only)")
    p_new.add_argument("--max-users", type=int, default=25)
    p_new.add_argument("--app-version", default=None)
    p_new.set_defaults(func=cmd_new)

    sub.add_parser("list", help="print the client table").set_defaults(func=cmd_list)
    sub.add_parser("validate", help="validate all ledger entries").set_defaults(func=cmd_validate)
    sub.add_parser("next-ports", help="next free port block").set_defaults(func=cmd_next_ports)

    args = ap.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
