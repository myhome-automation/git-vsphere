# Internal DNS (`myhomelab.com`) on the LB pair — issues & fixes

Internal DNS is served by **dnsmasq on both lb1 (192.168.1.188) and lb2
(192.168.1.185)** as an HA pair. Authoritative for `myhomelab.com`;
forwards everything else to 8.8.8.8 / 8.8.4.4. All clients query the
keepalived VIP `192.168.1.50` — only the current VIP holder answers.

Configured by `ansible/playbooks/dns.yml`. The legacy `dns_dhcp.yml`
(retired 2026-05-17 when the old dns1 VM was re-purposed as lb2) has
been deleted.

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

## D2. `cannot set --bind-interfaces and --bind-dynamic`

**Symptom:** after switching to the HA pair setup, dnsmasq refuses to
start with this error.

**Root cause:** Rocky 9's `/etc/dnsmasq.conf` (the package default) has
`bind-interfaces` uncommented. Our `/etc/dnsmasq.d/myhomelab.conf` sets
`bind-dynamic` (required for VIP failover). The two options are
mutually exclusive.

**Fix:** comment out `bind-interfaces` in the package default — the
play does this with a `lineinfile` task that regex-matches
`^bind-interfaces` and replaces with `#bind-interfaces`.

---

## D3. Reverse lookups (PTR records) — auto-generated

dnsmasq automatically creates PTR records for every A record it learns
(from `/etc/hosts`, `addn-hosts`, etc.). The combination of:
- `expand-hosts` — append `domain=` to bare names
- `local=/myhomelab.com/` — claim authority for that domain
- `addn-hosts=...` — load forward entries

gives you both forward and reverse for free:
```
$ dig @192.168.1.50 kmaster1.myhomelab.com +short
192.168.1.186
$ dig @192.168.1.50 -x 192.168.1.186 +short
kmaster1.myhomelab.com.
```

No separate reverse-zone file needed.

---

## D4. Making every host query the VIP (HA-friendly resolver)

`dns.yml` runs a final play on `everyone` (cluster + vault) that sets
NetworkManager's per-connection `ipv4.dns` to `<VIP> <lb1-IP> <lb2-IP>`
in that order:

```
search myhomelab.com
nameserver 192.168.1.50      # keepalived VIP — answered by whichever LB owns it
nameserver 192.168.1.188     # lb1 direct (fallback during VIP transit)
nameserver 192.168.1.185     # lb2 direct (fallback)
```

`ipv4.ignore-auto-dns yes` is critical — without it, DHCP-provided DNS
from the home router would clobber our manually-set DNS at every
NetworkManager refresh.

Why the direct IPs are listed as fallbacks: there's a ~3 s window
during VRRP failover where neither LB owns the VIP (old MASTER lost
priority, new MASTER hasn't yet performed gratuitous ARP). Listing both
direct IPs lets glibc's resolver fall through to them.

---

## D5. HA dnsmasq with `bind-dynamic` + VIP

Each LB's `/etc/dnsmasq.d/myhomelab.conf` declares:
```
listen-address=127.0.0.1,<this-LB's-primary-IP>,192.168.1.50
bind-dynamic
```

With `bind-dynamic`, dnsmasq listens only on the listed addresses that
**currently exist** on the host's interfaces:
- lb1 has VIP → dnsmasq there binds 127.0.0.1, 192.168.1.188, 192.168.1.50
- lb2 doesn't have VIP → dnsmasq there binds 127.0.0.1, 192.168.1.185 only

When keepalived moves the VIP to lb2, dnsmasq on lb2 dynamically picks
up the new address and starts answering on it. The total failover
window (VRRP detection + ARP + dnsmasq rebind) is ~3-4 seconds.

**Test it:**
```bash
# Verify VIP is on lb1
ssh ansible@lb1 'ip -4 addr show ens192 | grep 192.168.1.50'
# Force failover
ssh ansible@lb1 'sudo systemctl stop keepalived'
# VIP should appear on lb2 within ~3s and DNS via VIP should still answer
sleep 4
dig @192.168.1.50 kmaster1.myhomelab.com +short
# Restore
ssh ansible@lb1 'sudo systemctl start keepalived'
```

---

## D6. Firewalld

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

## D7. Quick troubleshooting

From any cluster host:
```bash
# resolver config
cat /etc/resolv.conf                       # should show 192.168.1.50 first
nmcli connection show <conn>  | grep dns   # NM-stored config

# probe
dig +short kmaster2.myhomelab.com
dig +short -x 192.168.1.189

# direct probe (bypassing /etc/resolv.conf, picks specific LB)
dig @192.168.1.50  vault.myhomelab.com     # via VIP (active LB)
dig @192.168.1.188 vault.myhomelab.com     # direct to lb1
dig @192.168.1.185 vault.myhomelab.com     # direct to lb2
```

On either LB:
```bash
sudo systemctl status dnsmasq keepalived
sudo tail -f /var/log/dnsmasq.log     # log-queries shows every lookup
sudo ss -ulnp | grep :53              # confirm bound on the right IPs (VIP only on MASTER)
ip -4 addr show ens192 | grep 192.168.1.50   # is this LB the VIP holder right now?
```
