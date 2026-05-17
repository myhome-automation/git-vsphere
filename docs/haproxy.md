# HAProxy on lb1 — issues & fixes

`lb1` (192.168.1.188) runs HAProxy + keepalived. Fronts the k8s API
(TCP 6443 → kmaster1/2/3) and ingress (HTTP 80, HTTPS 443 → kworker
NodePorts). Stats on 8404.

Single-LB mode: `lb2` was dropped due to ESXi memory ceiling
(see [esxi-host.md](esxi-host.md)).

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

## H2. Single-LB keepalived (no peer)

The original `loadbalancer.yml` had a MASTER/BACKUP pair (lb1/lb2). With
lb2 dropped, the play now writes a standalone MASTER config on lb1:

```
vrrp_instance VI_1 {
  state MASTER
  interface {{ ansible_default_ipv4.interface }}
  virtual_router_id 51
  priority 101
  ...
  virtual_ipaddress {
    192.168.1.50      # vip
  }
}
```

keepalived runs happily as a lone MASTER — it just always owns the VIP
with no failover. `journalctl -u keepalived` confirms `VRRP_Instance(VI_1)
Transition to MASTER STATE`.

If lb1 goes down, the VIP goes away and the cluster API endpoint becomes
unreachable until lb1 returns.

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
multicast advertisements get dropped — fine for single-LB (no peer to
advertise to), but required if you ever re-add lb2.

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
