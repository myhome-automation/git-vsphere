# Internal DNS (`myhomelab.com`) on lb1 — issues & fixes

Internal DNS is served by **dnsmasq on lb1** (192.168.1.188). Authoritative
for `myhomelab.com`; forwards everything else to 8.8.8.8 / 8.8.4.4.

Configured by `ansible/playbooks/dns.yml`. Previously `dns_dhcp.yml` ran
on dns1 — that role has been retired; dns1 VM is unused (deletion candidate).

---

## D1. `dnsmasq: bad option at line 1 of /etc/dnsmasq.d/myhomelab.hosts`

**Symptom:** dnsmasq.service won't start. `dnsmasq --test` reports the
above. The "hosts" file is well-formed (IP + FQDN + alias per line).

**Root cause:** Rocky 9's `/etc/dnsmasq.conf` has
```
conf-dir=/etc/dnsmasq.d,.rpmnew,.rpmsave,.rpmorig
```
which makes dnsmasq parse **every** file in `/etc/dnsmasq.d/` as a config
file (unless extension matches one of the skip patterns). Dropping a
hosts-format file there → bad option.

**Fix:** put the hosts file OUTSIDE `/etc/dnsmasq.d/`:
```yaml
- file:
    path: /etc/dnsmasq.hosts.d
    state: directory
- copy:
    dest: /etc/dnsmasq.hosts.d/myhomelab.hosts
    content: |
      192.168.1.186 kmaster1.myhomelab.com kmaster1
      ...
```

And reference it from the config:
```
addn-hosts=/etc/dnsmasq.hosts.d/myhomelab.hosts
```

---

## D2. Reverse lookups (PTR records) — auto-generated

dnsmasq automatically creates PTR records for every A record it learns
(from `/etc/hosts`, `addn-hosts`, etc.). The combination of:
- `expand-hosts` — append `domain=` to bare names
- `local=/myhomelab.com/` — claim authority for that domain
- `addn-hosts=...` — load forward entries

gives you both forward and reverse for free:
```
$ dig @192.168.1.188 kmaster1.myhomelab.com +short
192.168.1.186
$ dig @192.168.1.188 -x 192.168.1.186 +short
kmaster1.myhomelab.com.
```

No separate reverse-zone file needed.

---

## D3. Making every host use lb1 as primary resolver

NetworkManager owns `/etc/resolv.conf` on Rocky 9. `dns.yml` runs a play
on `everyone` (cluster + vault) that:

```yaml
- name: get primary NM connection name
  shell: >
    nmcli -t -f NAME,DEVICE connection show --active |
    awk -F: -v iface="{{ ansible_default_ipv4.interface }}" '$2==iface {print $1; exit}'
  register: nm_conn

- command: >
    nmcli connection modify "{{ nm_conn.stdout }}"
    ipv4.dns "192.168.1.188 8.8.8.8"
    ipv4.dns-search myhomelab.com
    ipv4.ignore-auto-dns yes

- command: nmcli connection up "{{ nm_conn.stdout }}"
```

`ipv4.ignore-auto-dns yes` is critical — without it, DHCP-provided DNS
from the home router would clobber our manually-set DNS at every
NetworkManager refresh.

`ipv4.dns-search myhomelab.com` means short names work:
```
$ ping kmaster1
PING kmaster1.myhomelab.com (192.168.1.186)
```

---

## D4. dnsmasq listens only on lb1's primary IP + loopback

Config has:
```
listen-address=127.0.0.1,192.168.1.188
bind-interfaces
```

So dnsmasq won't bind to other addresses (e.g., the VIP 192.168.1.50,
which keepalived owns). This means:
- Direct queries to `192.168.1.188:53` work ✓
- Direct queries to `192.168.1.50:53` (the VIP) do NOT — VIP is owned
  by keepalived but no service listens on it
- All cluster hosts use `192.168.1.188` directly (correct)

If you ever want DNS reachable via the VIP too, add the VIP to
`listen-address=` and ensure dnsmasq starts AFTER keepalived (the VIP must
exist as a routable address before bind).

---

## D5. Firewalld

The play opens 53/tcp + 53/udp:
```yaml
- firewalld:
    port: "{{ item }}"
    permanent: true
    immediate: true
    state: enabled
  loop:
    - 53/tcp
    - 53/udp
```

UDP is for normal queries; TCP for responses >512 bytes (DNSSEC, large
records) and zone transfers (not used here but standard).

---

## D6. Quick troubleshooting

From any cluster host:
```bash
# resolver config
cat /etc/resolv.conf                       # should show 192.168.1.188 first
nmcli connection show <conn>  | grep dns   # NM-stored config

# probe
dig +short kmaster2.myhomelab.com
dig +short -x 192.168.1.189

# direct probe (bypassing /etc/resolv.conf)
dig @192.168.1.188 vault.myhomelab.com
```

On lb1:
```bash
sudo systemctl status dnsmasq
sudo tail -f /var/log/dnsmasq.log     # log-queries shows every lookup
sudo ss -ulnp | grep :53              # confirm bound on the right IP
```
