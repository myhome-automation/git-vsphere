# Ansible — issues & fixes

`ansible/` directory layout, inventory groups, vault, and common pitfalls
hit during this build.

---

## A1. `group_vars/` not loaded ⇒ everything undefined

**Symptom:** `'k8s_version' is undefined`, `'vip' is undefined`,
`'keepalived_password' is undefined` — even though
`ansible/group_vars/all/vars.yml` is present and has all of them.

**Root cause:** Ansible auto-loads `group_vars/` only from two locations:
- `<inventory_dir>/group_vars/`
- `<playbook_dir>/group_vars/`

Our `group_vars/` was at `ansible/group_vars/` — neither matches
`ansible/inventory/` nor `ansible/playbooks/`.

**Fix:** symlink:
```bash
ln -sfn ../group_vars ansible/inventory/group_vars
```

Verify:
```bash
cd ansible
ansible -i inventory/hosts.ini --vault-password-file=.vault_pass \
  -m debug -a 'msg="{{ vip }}"' lb1
# -> "msg": "192.168.1.50"
```

The symlink is checked into git (`ansible/inventory/group_vars ->
../group_vars`). On a fresh checkout it's recreated automatically.

---

## A2. Vault password file path

`ansible.cfg` has `vault_password_file = .vault_pass`. The path is
relative to `ansible.cfg`'s location (so `ansible/.vault_pass`). When
running ansible from the repo root, the relative resolution sometimes
breaks.

**Fix:** always run ansible from the `ansible/` directory:
```bash
cd ansible/
ansible-playbook -i inventory/hosts.ini --vault-password-file=.vault_pass \
  playbooks/site.yml
```

The `--vault-password-file=.vault_pass` explicit flag is redundant but
defensive — works even if cwd assumptions break.

---

## A3. Inventory groups must match what playbooks use

Playbooks declare `hosts: k8s_masters` / `hosts: k8s_workers` /
`hosts: dns_dhcp`. Inventory must define those exact group names.

Current (correct) inventory layout:
```ini
[k8s_masters]
kmaster1 ansible_host=192.168.1.186
...

[k8s_workers]
kworker1 ansible_host=192.168.1.182
...

[dns_dhcp]
dns1 ansible_host=192.168.1.185

[loadbalancers]
lb1 ansible_host=192.168.1.188

[vault]
vault-server ansible_host=192.168.1.202

[cluster:children]
k8s_masters
k8s_workers
dns_dhcp
loadbalancers

[everyone:children]
cluster
vault
```

Common mistake: typing `[kube_masters]` (kebab style) but playbooks say
`k8s_masters`. Ansible silently runs the play against 0 hosts.

---

## A4. `hosts: all` vs `hosts: cluster`

`hosts: all` is the magic "every host in inventory" group. Once
vault-server is in inventory (for bootstrap-users.yml + dns.yml), `all`
includes it.

For k8s cluster setup we don't want to touch vault-server. So `base.yml`
uses `hosts: cluster` (excludes vault) and `bootstrap-users.yml` and the
NM resolver play in `dns.yml` use `hosts: everyone` (includes vault).

---

## A5. ESXi has no bash — `ssh root@esxi 'bash -s'` fails 127

Driver scripts that push work onto ESXi must use `sh -s` (busybox ash)
and stick to POSIX:

- No `declare -a`, no `<<<` here-strings, no `disown`.
- `mapfile` / `readarray` absent.
- `wait` in a subshell only waits on subshell's children — fine inside
  the subshell, useless in the parent.
- `tr` and `python` may be missing (varies by ESXi build).

`terraform/clone-from-vault.sh` is the canonical example: a bash driver
on the packer host that pipes a POSIX sh script to `ssh root@esxi 'sh -s'`.

---

## A6. Collection version mismatch warnings

```
[WARNING]: Collection community.general does not support Ansible version 2.14.18
[WARNING]: Collection ansible.posix does not support Ansible version 2.14.18
```

The system ansible-core (2.14.18 on this host) is older than what the
installed collections target. Tasks still work in practice.

Suppress warnings or pin a newer ansible-core:
```bash
pip install --user --upgrade ansible-core
# or
ansible-galaxy collection install --force community.general:6.6.0  # last 2.14-compat
```

---

## A7. `cmd | while ... & done` subshell wait gotcha

POSIX sh quirk that bit `clone-from-vault.sh`:
```sh
echo "$LIST" | while read x; do
  do_thing "$x" &
done
wait      # waits on PARENT shell's bg procs — there are none
```

The background `do_thing` processes belong to the subshell created for
the pipe's right-hand side. `wait` in the script's main shell returns
immediately.

**Fix:** avoid the pipe — use a for-loop, or write the list to a
temporary file and read with `while read … < /tmp/list`:
```sh
for x in $LIST; do do_thing "$x" & done
wait
```

---

## A8. Common debugging knobs

```bash
# limit to one host
ansible-playbook ... --limit kmaster1

# only certain plays via tags
ansible-playbook ... --tags base
ansible-playbook ... --tags dns,lb,k8s
ansible-playbook ... --skip-tags update    # skip the slow `dnf update`

# step through tasks
ansible-playbook ... --step

# verbose
ansible-playbook ... -vvv

# check what variables a host resolves to
ansible -m debug -a 'var=hostvars[inventory_hostname]' lb1
```
