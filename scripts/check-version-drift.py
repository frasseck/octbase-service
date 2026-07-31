#!/usr/bin/env python3
"""check-version-drift.py — this repo's version stamps vs the app repo's releases.

The version surface of this repo is exactly four kinds of value: the fleet
default `octbase_version` in inventory/group_vars/all/main.yml, and one
`app_version` per ledger client. Each one selects the app repo tag a playbook
deploys (C13) and is stamped into the instance's OCTBASE_APP_VERSION (C4).

Nothing failed when a release was cut and a stamp did not follow, because
trailing is legitimate — a platform may deliberately pin an older release
(register D3, D10, D18, D23, D25, §2.7). This script measures the distance
instead of leaving it to a human checklist step:

  OK    the stamp is on the newest tag
  WARN  the stamp trails the newest tag by N releases — a pin, not an error
  FAIL  the stamp names a version with no tag (C13), is ahead of every tag,
        or has no dated CHANGELOG.md entry (C4)

Read-only: it clones nothing, writes nothing, and never talks to a client
host. Exit status is 0 unless a FAIL was found (a WARN keeps it 0 on purpose —
an error people learn to ignore stops being an error).

Usage:
  scripts/check-version-drift.py [--app-repo PATH]
"""

import argparse
import re
import subprocess
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    sys.exit("PyYAML required (comes with Ansible): pip install pyyaml")

REPO = Path(__file__).resolve().parent.parent
GROUP_VARS = REPO / "inventory" / "group_vars" / "all" / "main.yml"
CLIENTS_DIR = REPO / "ledger" / "clients"
DEFAULT_APP_REPO = Path.home() / "dev.ocete.ch"

# Tags this platform deploys are plain "vX.Y.Z" — that is what create-instance
# asserts on, so anything else (release candidates, v0 prototypes with suffixes)
# is not a deployable release and is ignored when ranking.
TAG_RE = re.compile(r"^v(\d+)\.(\d+)\.(\d+)$")
# A dated release heading: "## v1.0.10 — 2026-07-27" (em dash) or "- 2026-07-27".
CHANGELOG_RE = re.compile(r"^##\s+v?(\d+\.\d+\.\d+)\s*[—–-]\s*(\d{4}-\d{2}-\d{2})", re.M)


def group_vars():
    with open(GROUP_VARS) as fh:
        return yaml.safe_load(fh) or {}


def stamps(gv):
    """Every version stamp in this repo, in report order: (label, version, note)."""
    out = [("octbase_version (group_vars)", str(gv.get("octbase_version") or ""), "")]
    for f in sorted(CLIENTS_DIR.glob("*.yml")):
        c = yaml.safe_load(f.read_text()) or {}
        status = c.get("status", "active")
        if status == "removed":          # historical record, deploys nothing
            continue
        version = c.get("app_version")
        note = "" if version else "no app_version key — inherits octbase_version"
        out.append((f"app_version ({f.name}, {status})",
                    str(version or gv.get("octbase_version") or ""), note))
    return out


def remote_tags(repo_url):
    """Deployable tags of the app repo, newest first. Empty on any failure."""
    try:
        p = subprocess.run(["git", "ls-remote", "--tags", repo_url],
                           capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.TimeoutExpired) as e:
        return [], f"git ls-remote failed ({e})"
    if p.returncode != 0:
        last = (p.stderr.strip().splitlines() or ["no output"])[-1]
        return [], f"git ls-remote failed: {last}"
    names = {ref.rsplit("/", 1)[-1].removesuffix("^{}")
             for _, _, ref in (l.partition("\t") for l in p.stdout.splitlines()) if ref}
    return sort_tags(names), ""


def local_tags(app_repo):
    p = subprocess.run(["git", "-C", str(app_repo), "tag", "-l"],
                       capture_output=True, text=True)
    if p.returncode != 0:
        return [], f"git tag -l failed in {app_repo}"
    return sort_tags(p.stdout.split()), ""


def sort_tags(names):
    tags = [(TAG_RE.match(n).groups(), n) for n in names if TAG_RE.match(n)]
    return [n for _, n in sorted(tags, key=lambda t: tuple(map(int, t[0])), reverse=True)]


def changelog_dates(app_repo):
    """{version: date} from the app repo's CHANGELOG.md release headings."""
    path = Path(app_repo) / "CHANGELOG.md"
    if not path.exists():
        return None
    return {m.group(1): m.group(2) for m in CHANGELOG_RE.finditer(path.read_text())}


def check(version, tags, dates):
    """(status, detail) for one stamp against the tag list and changelog."""
    if not version:
        return "FAIL", "no version set"
    tag = f"v{version}"
    key = tuple(map(int, version.split("."))) if re.fullmatch(r"\d+\.\d+\.\d+", version) else None
    if key is None:
        return "FAIL", f"{version!r} is not a X.Y.Z version"
    if tag not in tags:
        newest_key = tuple(map(int, TAG_RE.match(tags[0]).groups())) if tags else None
        if newest_key and key > newest_key:
            return "FAIL", f"ahead of every tag — newest is {tags[0]} (C13)"
        return "FAIL", f"no tag {tag} in the app repo (C13)"

    behind = tags.index(tag)
    if dates is None:
        c4 = "changelog not checked"
    elif version in dates:
        c4 = f"changelog {dates[version]}"
    else:
        return "FAIL", f"tag {tag} exists but has no dated CHANGELOG.md entry (C4)"

    if behind == 0:
        return "OK", f"newest release · {c4}"
    plural = "release" if behind == 1 else "releases"
    return "WARN", f"{behind} {plural} behind newest {tags[0]} · {c4}"


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0],
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--app-repo", type=Path, default=DEFAULT_APP_REPO,
                    help=f"app repo checkout, for CHANGELOG.md (default: {DEFAULT_APP_REPO})")
    args = ap.parse_args()

    gv = group_vars()
    repo_url = gv.get("octbase_repo", "")

    # The remote is the deploy source (C13), so its tags are the authority —
    # a local checkout can be arbitrarily stale. Fall back to the checkout only
    # if the remote is unreachable, and say which one was used.
    tags, err = remote_tags(repo_url) if repo_url else ([], "no octbase_repo in group_vars")
    source = f"git ls-remote {repo_url}"
    if not tags:
        if not args.app_repo.exists():
            sys.exit(f"cannot resolve app repo tags: {err}; no checkout at {args.app_repo}")
        tags, err2 = local_tags(args.app_repo)
        source = f"git tag -l in {args.app_repo} (remote unreachable: {err})"
        if not tags:
            sys.exit(f"cannot resolve app repo tags: {err2 or err}")

    dates = changelog_dates(args.app_repo)
    changelog = str(args.app_repo / "CHANGELOG.md") if dates is not None \
        else f"NOT CHECKED — no CHANGELOG.md under {args.app_repo} (pass --app-repo)"

    print("Version stamps vs app repo releases")
    print(f"  tags       {source}")
    print(f"  newest     {tags[0]}  ({len(tags)} deployable tags)")
    print(f"  changelog  {changelog}\n")

    results = []
    for label, version, note in stamps(gv):
        status, detail = check(version, tags, dates)
        results.append(status)
        print(f"  {status:<5} {label:<38} {version or '-':<9} {detail}")
        if note:
            print(f"        {'':<38} {'':<9} {note}")

    fails, warns = results.count("FAIL"), results.count("WARN")
    print(f"\n  {len(results)} stamps: {results.count('OK')} on the newest release, "
          f"{warns} trailing (WARN), {fails} failing")
    if warns and not fails:
        print("  Trailing is a pin, not a defect — bumping it is the rollout decision "
              "(README 'Which version an instance runs').")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
