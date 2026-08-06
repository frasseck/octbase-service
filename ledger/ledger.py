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
INVENTORY_FILE = Path(__file__).resolve().parent.parent / "inventory" / "hosts.yml"
# group_vars/all is a DIRECTORY since 2026-07-17 (main.yml + the vault) — this
# pointed at the pre-split all.yml until 2026-07-31, so default_client_host was
# never read and every `new` silently took the alphabetically first host.
GROUP_VARS_FILE = (Path(__file__).resolve().parent.parent
                   / "inventory" / "group_vars" / "all" / "main.yml")

# Max 28 chars: the Linux account is "oct-<name>" and useradd caps
# usernames at 32 characters. Must end in a letter or digit — the name is
# also the subdomain label, and "acme-.octbase.io" is not a valid DNS label.
NAME_RE = re.compile(r"^[a-z][a-z0-9-]{0,26}[a-z0-9]$")
# "demo" is deliberately not reserved: the public demo is ledger-managed
# since 2026-07-11 (clients/demo.yml, migrated via migrate-instance.yml).
RESERVED_NAMES = {"www", "dev", "mail", "api", "octbase", "admin"}
EDITIONS = {"team", "business", "enterprise"}
STATUSES = {"active", "suspended", "removed"}
# The contact is not just a record: create-instance.yml makes it the login of
# the instance's first SUPER_ADMIN, which is the only way into a fresh stack.
# So it has to be a real mailbox that can receive a password reset, and a blank
# one is a provisioning stop rather than a missing nicety. Deliberately a shape
# check, not RFC 5322 — it catches "", "tbd" and "lars at beyags.com", which is
# what actually goes wrong; nothing offline can prove deliverability.
EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")
# Ports already used by the resident (non-ledger) stacks on the host, which
# the allocator must never hand to a client.
#
# 8100/8101/8102 are the dev stack's live frontend/api/postgres — added
# 2026-08-04, having been missing since dev moved onto that block. Latent
# rather than live, because allocation starts at PORT_BASE and only advances,
# so nothing below 8110 could ever have been handed out; but C8 says this set
# mirrors host facts, and it did not. The lower entries are the pre-move
# dev/demo ports (8025/8026 were their Mailpit UIs) — kept, since they cost
# nothing and an old stack could still be revived on them.
#
# 8120 is the oct-web marketing site (scripts/migrate-ocete-web.sh); it sits
# *inside* the client allocation range, which is why it has to be listed.
# 8110-8112 and 8130-8132 are NOT here on purpose: demo and beyags are ledger
# clients, so taken_ports() picks their blocks up from the ledger itself.
RESERVED_PORTS = {
    5432, 5433, 8000, 8001, 8025, 8026, 8080, 8081, 8082, 8083,
    8100, 8101, 8102,   # dev.ocete.ch (resident, not a ledger client)
    8120,               # oct-web marketing site
}
PORT_BASE = 8110   # first client block; blocks advance in steps of 10
PORT_STEP = 10


# systemd resource-control value shapes for the ledger's optional
# resources block (applied as a user-slice drop-in by the playbooks).
RESOURCE_KEYS = {
    "memory_max": re.compile(r"^\d+(\.\d+)?[KMGT]?$"),   # e.g. 2G, 512M
    "cpu_quota": re.compile(r"^\d+%$"),                  # e.g. 200% = 2 cores
    "tasks_max": re.compile(r"^\d+$"),                   # plain count
}


def inventory_hosts():
    """Host names from inventory/hosts.yml (the valid values for `host:`)."""
    try:
        with open(INVENTORY_FILE) as fh:
            inv = yaml.safe_load(fh) or {}
        return set((inv.get("octbase_hosts", {}).get("hosts") or {}).keys())
    except OSError:
        return set()
    except yaml.YAMLError as e:
        # unlike a missing file, a broken one must not silently disable
        # host validation — say what is wrong and stop
        sys.exit(f"cannot parse {INVENTORY_FILE}: {e}")


def default_host():
    """default_client_host from group_vars (fallback: first inventory host).

    The fallback is a broken-repo path, not a normal one: an unreadable
    group_vars is what let the stale path above go unnoticed for two weeks.
    Say so instead of picking a host quietly — placing a client on the wrong
    server is not something to discover after `create-instance.yml` ran.
    """
    try:
        with open(GROUP_VARS_FILE) as fh:
            gv = yaml.safe_load(fh) or {}
        if gv.get("default_client_host"):
            return str(gv["default_client_host"])
        reason = f"no default_client_host in {GROUP_VARS_FILE.name}"
    except OSError as e:
        reason = f"cannot read {GROUP_VARS_FILE}: {e.strerror}"
    except yaml.YAMLError as e:
        # a broken file must not degrade into the pick-a-host fallback
        sys.exit(f"cannot parse {GROUP_VARS_FILE}: {e}")
    hosts = sorted(inventory_hosts())
    fallback = hosts[0] if hosts else "prod"
    print(f"warning: {reason} — defaulting to host '{fallback}'"
          f"{' (first of ' + str(len(hosts)) + ' in the inventory)' if len(hosts) > 1 else ''}; "
          "pass --host to choose explicitly", file=sys.stderr)
    return fallback


def load_clients():
    clients = {}
    for f in sorted(CLIENTS_DIR.glob("*.yml")):
        with open(f) as fh:
            try:
                clients[f.stem] = yaml.safe_load(fh) or {}
            except yaml.YAMLError as e:
                sys.exit(f"cannot parse {f}: {e}")
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
    # Checked here as well as in validate: the scaffold writes status 'active',
    # so accepting a blank contact would mint a file that validate rejects on
    # the very next command.
    contact = (args.contact or "").strip()
    if not EMAIL_RE.match(contact):
        sys.exit(f"--contact must be an email address (got {contact!r}) — it "
                 f"becomes the login of the instance's first SUPER_ADMIN")
    path = CLIENTS_DIR / f"{args.name}.yml"
    if path.exists():
        sys.exit(f"{path} already exists")
    # The add-on is booked by default; team can never have it, so the default
    # backs off there and only an explicit --jira-import is an error.
    jira_import = args.jira_import
    if jira_import is None:
        jira_import = args.edition != "team"
    elif jira_import and args.edition == "team":
        sys.exit("the jira_import add-on cannot be booked for the team edition")
    host = args.host or default_host()
    known_hosts = inventory_hosts()
    if known_hosts and host not in known_hosts:
        sys.exit(f"unknown host {host!r} — must be one of {sorted(known_hosts)} "
                 f"(inventory/hosts.yml)")
    clients = load_clients()
    ports = next_port_block(clients)
    entry = {
        "name": args.name,
        "display_name": args.display or args.name,
        "contact": contact,
        "edition": args.edition,
        "jira_import": jira_import,
        "max_users": args.max_users,
        "registered": datetime.date.today().isoformat(),
        "status": "active",
        "app_version": args.app_version,
        "host": host,
        "disk_quota_gb": args.disk_quota_gb,
        "ports": ports,
        "notes": "",
    }
    if not args.app_version:
        del entry["app_version"]  # fall back to group_vars octbase_version
    with open(path, "w") as fh:
        yaml.safe_dump(entry, fh, sort_keys=False)
    print(f"wrote {path}")
    print(f"host:  {host}")
    print(f"ports: frontend={ports['frontend']} api={ports['api']} "
          f"postgres={ports['postgres']}")
    print("next: git add/commit, then "
          f"ansible-playbook playbooks/create-instance.yml -e client={args.name}")


def cmd_list(_args):
    clients = load_clients()
    if not clients:
        print("no clients in the ledger")
        return
    dflt_host = default_host()
    hdr = ("NAME", "HOST", "EDITION", "JIRA", "SEATS", "DISK", "STATUS", "REGISTERED", "FRONTEND", "DISPLAY NAME")
    rows = [hdr]
    for name, c in clients.items():
        rows.append((
            name,
            str(c.get("host", dflt_host)),
            str(c.get("edition", "?")),
            "yes" if c.get("jira_import") else "-",
            str(c.get("max_users", "?")),
            f"{c['disk_quota_gb']}G" if c.get("disk_quota_gb") else "-",
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
    seen_ports = {}   # port -> (where, host)
    known_hosts = inventory_hosts()
    dflt_host = default_host()
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
        # Only 'active' entries are deployable, and only a FIRST deploy consumes
        # the contact (create-instance writes it as the bootstrap admin's login
        # and never rewrites an existing .env). A suspended or removed client
        # keeps its file as the historical record, so an old entry that predates
        # this rule is not retroactively broken — it is warned about instead.
        contact = str(c.get("contact") or "").strip()
        if c.get("status") == "active":
            if not EMAIL_RE.match(contact):
                errors.append(
                    f"{where}: contact {contact!r} is not an email address — it "
                    f"becomes the login of the instance's first SUPER_ADMIN "
                    f"(create-instance.yml), so an active client needs a real "
                    f"mailbox that can receive a password reset")
        elif contact and not EMAIL_RE.match(contact):
            warnings.append(f"{where}: contact {contact!r} is not an email address")
        if not isinstance(c.get("max_users"), int) or c["max_users"] < 1:
            errors.append(f"{where}: max_users must be a positive integer")
        if not isinstance(c.get("jira_import"), bool):
            errors.append(f"{where}: jira_import must be true or false")
        if c.get("jira_import") and c.get("edition") == "team":
            errors.append(f"{where}: the jira_import add-on cannot be booked for team")
        if "monitor_edge_probe" in c and not isinstance(c["monitor_edge_probe"], bool):
            errors.append(f"{where}: monitor_edge_probe must be true or false")
        host = c.get("host", dflt_host)
        if known_hosts and host not in known_hosts:
            errors.append(f"{where}: host {host!r} is not in inventory/hosts.yml "
                          f"({sorted(known_hosts)})")
        if "disk_quota_gb" in c and (not isinstance(c["disk_quota_gb"], int)
                                     or c["disk_quota_gb"] < 1):
            errors.append(f"{where}: disk_quota_gb must be a positive integer")
        res = c.get("resources") or {}
        if not isinstance(res, dict):
            errors.append(f"{where}: resources must be a mapping")
            res = {}
        for k, v in res.items():
            if k not in RESOURCE_KEYS:
                errors.append(f"{where}: unknown resources key {k!r} "
                              f"(allowed: {sorted(RESOURCE_KEYS)})")
            elif not RESOURCE_KEYS[k].match(str(v)):
                errors.append(f"{where}: resources.{k}={v!r} has an invalid format")
        ports = c.get("ports") or {}
        if set(ports) != {"frontend", "api", "postgres"}:
            errors.append(f"{where}: ports must define frontend, api and postgres")
        for role, p in ports.items():
            if not isinstance(p, int) or not (1024 < p < 65536):
                errors.append(f"{where}: port {role}={p!r} out of range")
            elif p in RESERVED_PORTS:
                errors.append(f"{where}: port {p} is reserved (dev/demo/marketing stacks)")
            elif p in seen_ports:
                other_where, other_host = seen_ports[p]
                # Same-host collision breaks the bind; cross-host “only”
                # breaks free movability between hosts (ports are allocated
                # globally unique on purpose — see docs/fleet-concept.md §1).
                if other_host == host:
                    errors.append(f"{where}: port {p} collides with {other_where} "
                                  f"on host {host!r}")
                else:
                    warnings.append(f"{where}: port {p} reused by {other_where} on "
                                    f"another host — blocks moving either instance")
            else:
                seen_ports[p] = (where, host)
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
    p_new.add_argument("--contact", required=True,
                       help="contact email — also the login of the instance's "
                            "first SUPER_ADMIN, so it must be a real mailbox")
    p_new.add_argument("--edition", choices=sorted(EDITIONS), required=True)
    p_new.add_argument("--jira-import", action=argparse.BooleanOptionalAction,
                       default=None,
                       help="book the Jira-CSV-import add-on (default: booked, "
                            "except for the team edition, which can never have it)")
    p_new.add_argument("--max-users", type=int, default=25)
    p_new.add_argument("--app-version", default=None)
    p_new.add_argument("--host", default=None,
                       help="inventory host to place the instance on "
                            "(default: default_client_host from group_vars)")
    p_new.add_argument("--disk-quota-gb", type=int, default=10,
                       help="disk quota for the client account in GB (default 10)")
    p_new.set_defaults(func=cmd_new)

    sub.add_parser("list", help="print the client table").set_defaults(func=cmd_list)
    sub.add_parser("validate", help="validate all ledger entries").set_defaults(func=cmd_validate)
    sub.add_parser("next-ports", help="next free port block").set_defaults(func=cmd_next_ports)

    args = ap.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
