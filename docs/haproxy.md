# HAProxy + keepalived on the LB pair — issues & fixes

`lb1` (192.168.1.188) and `lb2` (192.168.1.185) run HAProxy + keepalived
+ dnsmasq as an HA pair. Both fronts the k8s API (TCP 6443 →
kmaster1/2/3) and ingress (HTTP 80, HTTPS 443 → kworker NodePorts).
Stats on 8404 on each. keepalived MASTER (lb1, prio 101) / BACKUP (lb2,
prio 100) owns the VIP `192.168.1.50`.

> Historical note: lb2 was dropped early in the build due to memory
> ceiling. The former dns1 VM (also at .185) was re-purposed as lb2 on
> 2026-05-17 after the GUI strip freed ~10 GB cluster-wide.

---

## H1. HAProxy fails to start — "cannot bind socket (Permission denied)"

**Symptom:**
```
haproxy[51345]: [ALERT] Binding ... for frontend k8s_api: cannot bind
  socket (Permission denied) for [0.0.0.0:6443]
haproxy[51345]: [ALERT] Binding ... for frontend stats: cannot bind
  socket (Permission denied) for [0.0.0.0:8404]
haproxy.service: Failed with result 'exit-code'
```

`haproxy -c -f /etc/haproxy/haproxy.cfg` reports config valid. Service
still won't start. Bind permission failure on ports 6443 and 8404; ports
80 / 443 work fine.

**Root cause:** SELinux's `http_port_t` covers 80, 443, 8080, etc. Ports
6443 and 8404 aren't in that set. The unprivileged haproxy process can't
bind to them.

**Fix:** SELinux boolean that allows haproxy to bind/connect any port:
```yaml
- name: allow haproxy to bind any port (SELinux)
  seboolean:
    name: haproxy_connect_any
    state: true
    persistent: true
```

Or imperatively:
```bash
sudo setsebool -P haproxy_connect_any on
```

After the boolean is set, `systemctl start haproxy` succeeds.

---

## H2. MASTER/BACKUP keepalived pair

Per-host state and priority come from inventory variables, so the same
template generates both configs:

```
# inventory/hosts.ini
lb1 ansible_host=192.168.1.188 keepalived_state=MASTER keepalived_priority=101
lb2 ansible_host=192.168.1.185 keepalived_state=BACKUP keepalived_priority=100

# loadbalancer.yml template renders, on each host:
vrrp_instance VI_1 {
  state {{ keepalived_state }}
  interface {{ ansible_default_ipv4.interface }}
  virtual_router_id 51
  priority {{ keepalived_priority }}
  ...
  virtual_ipaddress { 192.168.1.50 }
}
```

Verify the active VIP holder:
```bash
ssh ansible@lb1 'ip -4 addr show ens192 | grep 192.168.1.50'   # MASTER prints the VIP line
ssh ansible@lb2 'ip -4 addr show ens192 | grep 192.168.1.50'   # BACKUP prints nothing
```

**Failover test** (recovery in ~3 s):
```bash
ssh ansible@lb1 'sudo systemctl stop keepalived'
sleep 4
ssh ansible@lb2 'ip -4 addr show ens192 | grep 192.168.1.50'   # VIP is here now
curl -sk https://192.168.1.50:6443/healthz                     # still 'ok'
ssh ansible@lb1 'sudo systemctl start keepalived'              # VIP returns to MASTER

---

## H3. Interface hardcoded to `eth0` was wrong on vmxnet3

Rocky 9 on VMware vmxnet3 uses `ens192` (PCI slot-based naming), not
`eth0`. The original `loadbalancer.yml` had `interface eth0` in the
keepalived config — keepalived would silently fail to claim the VIP.

**Fix:** auto-detect via ansible facts:
```
interface {{ ansible_default_ipv4.interface }}
```

`ansible_default_ipv4.interface` is populated by `gather_facts: true` and
gives whatever interface holds the default route.

---

## H4. HAProxy backend health checks

The `option tcp-check` in each `backend` block makes HAProxy do TCP
SYN-probe health checks against each server. Without it, HAProxy assumes
all servers are up and routes to dead masters.

Verify checks are passing:
- Browse to `http://192.168.1.188:8404/stats` (HAProxy stats page)
- Look for green rows under `k8s_masters` / `workers_http` / `workers_https`
- Red rows mean check failures — usually firewalld blocking 6443 or 30080
  on the target backend.

---

## H5. Firewalld + VRRP

The play opens `vrrp` protocol via firewalld:
```yaml
- firewalld:
    protocol: vrrp
    permanent: true
    state: enabled
    immediate: true
```

VRRP is protocol 112 (not TCP/UDP). Without this rule, keepalived's
multicast advertisements get dropped — the MASTER and BACKUP can't see
each other, both think they're MASTER, and you get a duplicate-VIP
split-brain.

---

## H6. NodePort backends (30080 / 30443)

HAProxy forwards `:80 -> kworker:30080` and `:443 -> kworker:30443`.
Those NodePorts assume an ingress controller (nginx-ingress / Traefik /
istio-ingressgateway) is exposed on those NodePorts.

If you install ingress-nginx, set its service to NodePort with
nodePort 30080/30443 explicitly, e.g.:
```yaml
service:
  type: NodePort
  nodePorts:
    http: 30080
    https: 30443
```
