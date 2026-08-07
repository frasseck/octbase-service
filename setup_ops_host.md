# `setup-ops-host.yml` — design notes

**Status:** playbook written (`playbooks/setup-ops-host.yml`). Working note,
not a `docs/` document — fold the parts worth keeping into the README /
`docs/fleet-concept.md`, then delete this file.
**Written:** 2026-08-07 · **Author:** Claude (session with Lars)

---

## 1. The model: two machines

|  | `prod01` | `dev01` |
|---|---|---|
| Role | Pure fleet server — client stacks and nothing else | Fleet server **plus** the `claude` development account |
| Address | `prod01.octbase.io` → `179.237.101.62` | `178.105.142.1` |
| Ledger clients | New clients land here by default | `beyags`, `demo` |
| Provisioned by | `setup-host.yml` | `setup-host.yml` **+ `setup-ops-host.yml`** |

Both are ordinary members of `octbase_hosts`. `dev01` is not a second class of
machine and not a disposable one: it runs real ledger clients, so
`install-monitoring.yml` and `install-backup.yml` must sweep it exactly as they
sweep `prod01`. The only thing that distinguishes it is one extra account.

## 2. Decisions taken

1. **A delta playbook, not a second baseline.** `setup-ops-host.yml` holds only
   the difference and runs *after* `setup-host.yml` — the same pattern as
   `install-monitoring.yml` / `install-backup.yml`. One baseline, one place to
   change it, no second provisioning path to keep in step.
2. **The baseline owns the account.** `claude` is created by
   `setup-host.yml -e admin_users='lfrasseck claude'`, which gives it its uid,
   home, shell, sudo drop-in, SSH key and `AllowUsers` entry — and rebuilds
   that allow-list from `admin_users` on *every* run. An account created by the
   delta playbook instead would therefore lose its SSH access the next time the
   baseline ran, silently. So the delta **asserts** the account exists and adds
   only what the baseline has no reason to know about: linger, and a check that
   a subordinate id range exists for rootless podman.
3. **The delta does not guess subordinate id ranges.** Overlapping ranges give
   two accounts the same namespace ids. `useradd` allocates them correctly when
   the baseline creates the account, so the normal path needs nothing; when the
   entry is missing the playbook stops and prints the `usermod` command rather
   than picking numbers itself.
4. **Nothing is checked out on the target.** The servers never talk to GitHub —
   deploys rsync from the admin machine. Repositories, tooling and any
   development stack on `dev01` are a human's first login, by hand. The
   account's own `.env` lives in `~/credentials` on the box and must never
   enter this repo.
5. **`dev01` takes ledger clients like any other host.** Its clients are
   ledger-managed, monitored and backed up on the same terms as `prod01`'s.
   Placement is the ledger's `host:` field; `default_client_host` is `prod01`,
   so putting a client on `dev01` is an explicit choice.

## 3. Run order

The baseline first, the delta second:

```bash
ansible-playbook playbooks/setup-host.yml -e target_host=dev01 \
    -e setup_user=<account> -e admin_users='lfrasseck claude' \
    -e install_workstation_extras=true -e host_fqdn=dev01.octbase.io
ansible-playbook playbooks/setup-ops-host.yml -e target_host=dev01
```

`install_workstation_extras=true` is what gives the host the browser, Go, Node
and `gh` toolchain the development account exists for; on `prod01` it stays
off, which is the other visible difference between the two machines.

Then, as for any fleet host: `install-monitoring.yml`, `install-backup.yml`.

## 4. Repo changes that landed with the split

- `inventory/hosts.yml` — the single `prod` entry became `prod01` and `dev01`.
  Both already answer SSH on 1012 with no `setup-host.yml` run on record, so
  the port is hand-recorded in each entry; **delete those two lines after the
  first baseline run**, which writes `ansible_user` + `ansible_port` between its
  own markers directly under the host key, where a hand-written duplicate would
  override the managed one.
- `inventory/group_vars/all/main.yml` — `default_client_host: prod` → `prod01`.
- `ledger/clients/*.yml` — `beyags` and `demo` moved to `host: dev01`, which is
  where both have always run; `educaswiss` (offboarded, never provisioned)
  follows the rename to `prod01`.
- `playbooks/create-instance.yml` — gained a ledger dialog: a client with no
  ledger entry is interviewed and scaffolded via `ledger.py new` before
  anything is provisioned. The host question offers exactly the inventory
  names, so the two-machine model is visible at onboarding time.

## 5. Open items

1. **`dev01.octbase.io` has no public A record.** It resolves only through the
   host's own `/etc/hosts`, so the inventory has to carry the bare address.
   Create the record and the entry can use the name.
2. **`prod01` serves nothing yet.** SSH answers on 1012, but 80/443 are closed
   and no client is placed there. It is provisioned-and-empty; whether the
   baseline has actually been run against it is not recorded in this repo.
3. **Quota enforcement.** `setup-host.yml` writes `usrquota` into `fstab` and
   needs one reboot to activate. Until then `create-instance.yml` warns that
   client disk usage is monitored but not enforced.

## 6. Not in scope (agreed)

Repository checkouts on either target · Claude Code installation · bringing up
any development stack · DNS changes · anything that provisions a client, which
is `create-instance.yml`'s job and the ledger's.
