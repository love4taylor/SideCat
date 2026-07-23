# Repository Guidelines

## Purpose and Scope

This repository deploys mihomo as a single-interface side router on Debian and
Arch Linux. The deployment script manages mihomo configuration, systemd units,
policy routing, iptables TProxy rules, DNS redirection, fallback forwarding,
Docker coexistence, TCP tuning, and uninstall cleanup. Treat those components
as one system: a local firewall edit can break a different packet path or leave
resources behind during restart or uninstall.

These guidelines apply primarily to `deploy-mihomo.sh` and the files it
generates. The `smart-trainer/` directory has a separate cross-language data
contract described below.

## Documentation Boundaries

- `README.md` is user-facing. Keep it focused on prerequisites, configuration,
  installation, operation, verification, and troubleshooting.
- `AGENTS.md` is maintainer-facing. Keep repository policy, generated-file
  ownership, implementation invariants, synchronization baselines, and release
  checks here.
- Do not put Git hygiene, contributor instructions, upstream synchronization
  details, or automation-specific language in `README.md`.
- Keep documentation claims synchronized with the current source. Distinguish
  static source validation from tests performed on a target Linux host.

## Repository Layout

- `deploy-mihomo.sh`: source of truth for deployment and generated system
  files.
- `config.yaml`: deployment input. The installed copy is normalized before
  mihomo starts.
- `mihomo`: target-host Linux binary. Do not assume it can run on macOS.
- `smart-trainer/`: optional Go/Python Smart/LightGBM model tooling, independent
  of side-router deployment.

Do not modify `smart-trainer/` while working on deployment unless the requested
change explicitly covers the trainer or an upstream Smart synchronization.
Likewise, do not alter deployment behavior while performing trainer-only work.

Do not create commits, rewrite history, delete user configuration, or change
proxy policy content unless the task explicitly requests that action.

## Generated Deployment Artifacts

`deploy-mihomo.sh` is the only durable source for these generated files:

- `/usr/local/sbin/mihomo-iptables`
- `/etc/default/mihomo-iptables`
- `/etc/systemd/system/mihomo.service`
- `/etc/systemd/system/mihomo-routing.service`
- `/etc/systemd/system/mihomo-iptables.service`
- `/etc/sysctl.d/99-mihomo.conf`
- `/etc/modules-load.d/mihomo-tproxy.conf`
- `/etc/mihomo/config.yaml`

Never fix only a generated file. A target-host emergency change must be copied
back into the corresponding generator in `deploy-mihomo.sh`, or the next
installation will overwrite it.

## Supported Deployment Model

The supported topology is deliberately narrow:

- Debian or Arch Linux with systemd and IPv4.
- One logical LAN interface, either a physical device or a device such as
  `bond0`.
- A single-interface side router whose clients use it as both gateway and DNS
  server.
- LAN TCP/UDP interception through the iptables-compatible TProxy interface.
- Router-local public TCP/UDP interception through OUTPUT marking and loopback
  PREROUTING.
- Traditional TCP/UDP port 53 redirection to mihomo DNS.
- Direct handling for private, loopback, link-local, multicast, and reserved
  destinations.
- Restricted MASQUERADE for public forwarding traffic not consumed by TProxy.
- Coexistence with Docker without flushing Docker or system rules.
- One mihomo instance and one policy-routing domain.

TUN must remain disabled because it conflicts with this script's TProxy, DNS
REDIRECT, and policy-routing ownership.

Unsupported without a redesign and target-host testing: IPv6, native nftables
rulesets, multiple LAN interfaces, multiple independent routing domains, or
multiple mihomo instances. Arch's nft-backed `iptables` compatibility frontend
is supported; a separately managed native nftables ruleset is not.

## Deployment Invariants

### Coupled Values

The following defaults form one contract and must be audited together:

```text
TPROXY_PORT=7894
DNS_PORT=1053
MARK=0xcc
MARK_MASK=0xff
BYPASS_MARK=0xff
BYPASS_MARK_DEC=255
ROUTE_TABLE=204
policy rule priority=100
NETWORK_OPTIM_LEVEL=balanced
NETWORK_OPTIM_BACKUP=/var/lib/mihomo-deploy/network-optim-backup.conf
```

The installed configuration must contain one top-level `routing-mark: 255`.
The policy rule must be `fwmark 0xcc/0xff lookup 204 priority 100`, and table
204 must contain `local 0.0.0.0/0 dev lo`.

Never change the policy mask back to `0xcc/0xcc`. That mask tests only the set
bits in `0xcc`, so the mihomo bypass mark `0xff` also matches it and is routed
back to the local table, creating an outbound loop. `/0xff` is the required
exact match.

Any mark change requires a coordinated audit of:

- the installed `routing-mark`;
- bypass rules in `MIHOMO_OUTPUT` and `MIHOMO_DNS`;
- every `MARK --set-xmark` and `TPROXY --tproxy-mark` rule;
- policy-rule start, stop, migration, and uninstall logic.

### Packet Paths

LAN client TCP/UDP:

```text
LAN client
  -> mangle PREROUTING on LAN_IF
  -> MIHOMO_DIVERT for an existing transparent TCP socket, or
  -> MIHOMO_TPROXY
  -> TPROXY to 127.0.0.1:TPROXY_PORT and set 0xcc/0xff
  -> policy rule table 204
  -> local route on lo
  -> mihomo tproxy listener
```

`MIHOMO_DIVERT` must precede `MIHOMO_TPROXY` on the same interface so an
established transparent TCP socket is not TProxied again.

Router-local TCP/UDP:

```text
local process
  -> mangle OUTPUT
  -> MIHOMO_OUTPUT
  -> bypass 0xff and excluded destinations return
  -> public TCP/UDP gets mark 0xcc/0xff
  -> policy rule table 204
  -> local route on lo
  -> mangle PREROUTING on lo
  -> MIHOMO_DIVERT or MIHOMO_TPROXY
  -> mihomo
```

OUTPUT marking alone is insufficient. Keep both loopback PREROUTING jumps or
the rerouted packet never reaches TProxy. The `DEBIAN_IP` source exclusion in
`MIHOMO_TPROXY` must allow router-local packets that already carry
`MARK/MARK_MASK`; an unconditional `-s "$DEBIAN_IP" -j RETURN` breaks local
transparent proxying.

LAN DNS:

```text
LAN client :53
  -> mangle PREROUTING excludes DNS from TProxy
  -> nat PREROUTING
  -> MIHOMO_DNS
  -> REDIRECT to DNS_PORT
```

Router-local DNS:

```text
local process :53
  -> MIHOMO_OUTPUT returns without a TProxy mark
  -> nat OUTPUT
  -> MIHOMO_DNS
  -> REDIRECT to DNS_PORT
```

Mihomo's own DNS and outbound sockets carry `0xff`. `MIHOMO_DNS` must return
on `0xff/0xff` before REDIRECT, or DNS loops back into mihomo.

Forwarding fallback is intentionally narrow. `MIHOMO_POSTROUTING` handles only
traffic sourced from `LAN_CIDR` and emitted through `LAN_IF`; it excludes the
router address and private/local destinations before MASQUERADE. Never attach
an unconditional MASQUERADE rule to all of POSTROUTING.

### Netfilter Ownership and Ordering

The generated helper owns only these chains:

- `mangle/MIHOMO_DIVERT`
- `mangle/MIHOMO_TPROXY`
- `mangle/MIHOMO_OUTPUT`
- `nat/MIHOMO_DNS`
- `nat/MIHOMO_POSTROUTING`
- `filter/MIHOMO_FORWARD`

It may flush or remove only its own `MIHOMO_*` chains and the exact parent jumps
it created. Never use any of the following approaches:

```text
iptables -F
iptables -X
iptables-restore with a full replacement ruleset
nft flush ruleset
flushing DOCKER-USER
changing the FORWARD policy to ACCEPT
```

The final PREROUTING order on each relevant interface must be:

```text
MIHOMO_DIVERT
MIHOMO_TPROXY
```

DNS jumps in nat PREROUTING and OUTPUT must be early enough to precede generic
DNS NAT rules. Mangle OUTPUT currently appends `MIHOMO_OUTPUT` to respect
existing marks. Moving it to position 1 requires an explicit conflict analysis
for other fwmarks, VPNs, Docker, and policy routing.

### Start/Stop Symmetry

Every parent-chain jump requires three byte-for-byte equivalent rule
specifications:

1. `delete_all` before insertion in `start_rules`.
2. The `iptables -I` or `iptables -A` operation in `start_rules`.
3. The matching `delete_all` operation in `stop_rules`.

`iptables -C` and `iptables -D` compare the full rule. An extra source negation,
a different mask, interface, or module order can prevent cleanup.

The POSTROUTING rule must be identical in all three locations:

```text
-o LAN_IF -s LAN_CIDR -j MIHOMO_POSTROUTING
```

Do not reintroduce the historical stop-only `! -s DEBIAN_IP` condition. It left
the parent jump in place, prevented removal of the referenced custom chain, and
produced an empty residual chain. `chain_remove` must expose reference/removal
errors rather than falsely reporting success.

When adding, removing, or changing a parent jump, update all three copies and
compare their rendered arguments character by character. This symmetry makes
restarts idempotent and prevents empty chains after stop or uninstall.

### Policy Routing

`mihomo-routing.service` owns:

- `fwmark 0xcc/0xff lookup 204 priority 100`;
- the obsolete `fwmark 0xcc/0xcc lookup 204 priority 100` rule during migration
  cleanup;
- the local default route in table 204.

Startup must loop-delete every duplicate of both old and current rule forms,
then add exactly one current rule. Stop must remove every old/current rule and
flush table 204. `mihomo-iptables.service` must require and start after
`mihomo-routing.service`; TProxy rules must not remain active without their
policy route.

Uninstall must remove all duplicate policy rules, table 204 state, the script's
`204 mihomo` entry in `/etc/iproute2/rt_tables`, every owned parent jump and
chain, all three systemd units, and the owned sysctl/modules-load files. By
design it preserves `/etc/mihomo/config.yaml` and `/usr/local/bin/mihomo` unless
their removal is explicitly requested.

### Mihomo Configuration

Before starting the service, installation must verify all of the following:

- If a top-level block-style `tun:` exists, its direct `enable` child is
  normalized to exactly one `false`; a missing direct child is added. If no
  `tun:` block exists, mihomo's disabled default is retained.
- Duplicate top-level `tun:` blocks and inline `tun: { ... }` mappings are
  rejected instead of modified.
- Normalization never changes unrelated `enable` keys under DNS, NTP, sniffer,
  health checks, or other sections.
- Top-level `tproxy-port` matches `TPROXY_PORT`.
- DNS `enhanced-mode` is `redir-host`, and the DNS listen port matches
  `DNS_PORT`.
- Exactly one top-level `routing-mark: 255` is present.
- `/usr/local/bin/mihomo -t -d /etc/mihomo` succeeds.

The mihomo unit must repeat the configuration check in `ExecStartPre` so a
later manual configuration error cannot start unnoticed.

### Systemd Capabilities and PROCESS-NAME

The mihomo service capability set is limited to:

```text
CAP_NET_ADMIN
CAP_NET_RAW
CAP_NET_BIND_SERVICE
CAP_SYS_PTRACE
CAP_DAC_READ_SEARCH
```

On Linux, `PROCESS-NAME` resolves a socket UID/inode through
`/proc/<pid>/fd`, then reads `/proc/<pid>/exe`. `CAP_SYS_PTRACE` permits the
cross-UID procfs ptrace access check, while `CAP_DAC_READ_SEARCH` provides the
read-only directory-search and file-read bypass needed for that lookup. Do not
add unrelated `CAP_SYS_TIME` or the broader `CAP_DAC_OVERRIDE`.

Process identification applies only to connections created on the side router.
The router cannot inspect processes on a LAN client, so `PROCESS-NAME` cannot
match applications running on another computer, phone, or console.

### Linux TCP Optimization

The Linux tuning is based only on Zephyr's Linux `network_optim.rs` behavior at
commit `e3de103dd6d05785e5f7e93bb4ea9dcce1a636b3`:

- `net.ipv4.tcp_fastopen`
- `net.ipv4.tcp_ecn`
- `net.core.rmem_max`
- `net.core.wmem_max`
- `net.ipv4.tcp_rmem`
- `net.ipv4.tcp_wmem`
- `net.ipv4.tcp_notsent_lowat`
- `/sys/module/tcp_cubic/parameters/hystart_detect=2`

Do not add BBR, `default_qdisc`, or `tcp_congestion_control` under the label of
completing this port. Tuning CUBIC HyStart does not select CUBIC as the system
congestion-control algorithm.

Keep the profiles exactly as follows:

| Parameter | conservative | balanced | aggressive |
| --- | ---: | ---: | ---: |
| `tcp_fastopen` | 1 | 3 | 3 |
| `tcp_ecn` | 2 | 1 | 1 |
| `rmem_max` | 8388608 | 16777216 | 33554432 |
| `wmem_max` | 16777216 | 33554432 | 67108864 |
| `tcp_rmem` | `4096 131072 8388608` | `4096 262144 16777216` | `4096 524288 33554432` |
| `tcp_wmem` | `4096 131072 16777216` | `4096 262144 33554432` | `4096 524288 67108864` |
| `tcp_notsent_lowat` | 65536 | 131072 | 262144 |

Lifecycle requirements:

1. `write_modules` loads `tcp_cubic` before `write_sysctl` backs up and applies
   values.
2. `/var/lib/mihomo-deploy/network-optim-backup.conf` is created only when it
   does not exist. Reinstallation must not replace the original pre-install
   values.
3. The backup may contain only the seven sysctl keys above and
   `sys.module.tcp_cubic.hystart_detect`. Restore must enforce an exact key
   allowlist and numeric/whitespace-only values to prevent command injection.
4. Persistent sysctl values belong in `/etc/sysctl.d/99-mihomo.conf`. Do not
   introduce a second tuning file such as `99-zephyr-tcp-tuning.conf`.
5. `mihomo-routing.service` reapplies `hystart_detect=2` at every start because
   sysctl does not persist a sysfs module parameter.
6. Uninstall removes `99-mihomo.conf` before restoring runtime values. It
   deletes the backup only after every restore succeeds; any failure preserves
   the backup and reports an error.
7. `status` reports all seven sysctl values and the live HyStart value rather
   than inferring success from a file's presence.

The default remains `balanced`, matching upstream `OptimLevel::Balanced`.
Changing it is a behavior change and requires an explicit request. The CLI
accepts only `conservative`, `balanced`, and `aggressive`.

### Docker Coexistence

- If `DOCKER-USER` exists, insert the `MIHOMO_FORWARD` jump there.
- Fall back to `FORWARD` only when `DOCKER-USER` does not exist.
- `stop_rules` must try to remove the jump from both locations because Docker
  may start or stop after deployment.
- Never remove, reorder, flush, or recreate Docker-owned chains.

### Input and Package Validation

Dependency installation supports Debian APT and Arch Linux pacman only. Keep
APT package names `procps` and `conntrack`; keep Arch package names `procps-ng`
and `conntrack-tools`. Use `pacman -S --needed --noconfirm`, never `pacman -Sy`,
and do not force a full system upgrade from the deployment script.

Resolve the `ip` executable with `command -v ip` during installation and place
the absolute path in `mihomo-routing.service`; do not hard-code either Debian's
`/usr/sbin/ip` or Arch's `/usr/bin/ip`. Creation and uninstall cleanup of
`/etc/iproute2/rt_tables` must share `RT_TABLES_FILE`.

Installation must reject:

- a missing or non-executable mihomo binary;
- a missing configuration file;
- zero, non-numeric, or greater-than-65535 ports;
- identical TProxy and DNS ports;
- invalid IPv4 addresses or CIDRs;
- a `DEBIAN_IP` outside `LAN_CIDR`;
- a nonexistent `LAN_IF`;
- a `DEBIAN_IP` not actually assigned to `LAN_IF`.

The script uses `set -Eeuo pipefail`. Avoid probe pipelines whose downstream
command exits early and gives the producer SIGPIPE, such as
`awk '... { print; exit }'`; consume the full input or handle pipeline status
explicitly.

## Smart Trainer Contract

`smart-trainer/transform.go` tracks
`component/smart/lightgbm/transform.go` from the `Alpha` branch of
`vernesong/mihomo`. The synchronization baseline is commit
`4e0e8d846e2f03d4238433d3b2ed3e24901693b4`.

An upstream synchronization must audit and update together:

- `smart-trainer/transform.go`
- `smart-trainer/go_parser.py`
- `smart-trainer/train_flexible.py`

The feature order is exactly the continuous range `0..29`:

```text
0  success
1  failure
2  connect_time
3  latency
4  upload_mb
5  history_upload_mb
6  maxuploadrate_kb
7  history_maxuploadrate_kb
8  download_mb
9  history_download_mb
10 maxdownloadrate_kb
11 history_maxdownloadrate_kb
12 duration_minutes
13 history_duration_minutes
14 last_used_seconds
15 is_udp
16 is_tcp
17 loss_rate
18 cumul_loss_rate
19 asn_feature
20 country_feature
21 address_feature
22 port_feature
23 traffic_ratio
24 traffic_density
25 connection_type_feature
26 asn_hash
27 host_hash
28 ip_hash
29 geoip_hash
```

Transformation contract:

- `StandardScaler`: indices `2..13,23,24`.
- `RobustScaler`: indices `0,1`.
- The remaining 14 features appear in `untransformed_features`.
- The model tail remains `[transforms]`, `[order]`, `[definitions]`, and
  `[/transforms]`.
- Go reads only the final 16384 bytes of the model. The complete generated
  transforms block must fit within that window.

Synchronization rules:

1. After `gofmt`, `transform.go` must match the pinned upstream file byte for
   byte. Do not add trainer-only private changes to the local Go copy.
2. `expectedCount` uses `MaxFeatureSize`; do not hard-code 21 or 30 again.
3. `ApplyTransforms` copies the output before returning working storage to
   `sync.Pool`. Returning it first creates a concurrent data race.
4. Preserve upstream `IsCompatibleWith` so callers can compare model feature
   order with the runtime default.
5. `go_parser.py` fails closed unless it parses exactly 30 unique names at
   continuous indices `0..29`. It must not fall back to an old 21-feature
   order.
6. `train_flexible.py` derives order from the Go file, requires all 30 CSV
   feature columns plus `weight`, and uses the same order for training and
   metadata.
7. Python scaler names, Go scaler-index comments, and model-tail
   `*_features` remain identical.
8. Do not change the model target, LightGBM hyperparameters, GPU/CPU policy, or
   CSV collection schema unless explicitly requested.

For every synchronization, run:

```bash
gofmt -w smart-trainer/transform.go
python3 -m py_compile \
  smart-trainer/go_parser.py \
  smart-trainer/train_flexible.py
```

Also run a cross-language contract test that parses 30 continuous unique
features from Go, verifies StandardScaler indices `2..13,23,24`, verifies
RobustScaler indices `0,1`, generates metadata, and reparses `[order]` and
definitions to confirm that every parameter count matches its index count.
Without the complete mihomo Go module, report only `gofmt`, byte comparison,
and Python contract-test results; do not claim `transform.go` compiled alone.

## Development Workflow

Before modifying deployment behavior:

1. Read this file and all of `deploy-mihomo.sh`, then confirm the request fits
   the supported topology.
2. Identify every generated path and invariant affected by the change.
3. Make the smallest scoped change and preserve user and Docker rules.
4. For generated shell code, audit outer-heredoc expansion. Installation-time
   variables expand in the outer script; generated-script runtime variables
   must be written as `\$VAR` or `\${VAR}`.
5. For YAML, edit only explicit top-level blocks and their direct children.
6. For parent jumps, compare start pre-delete, start add, and stop delete.
7. For mark changes, inspect config, iptables, policy routing, migration, and
   uninstall together.
8. For systemd changes, inspect ordering, stop behavior, restart idempotency,
   and uninstall.
9. For TCP changes, verify the complete matrix, first-install backup, restore,
   boot-time HyStart write, and status output.
10. Validate the outer deployment script and a generated temporary inner
    `mihomo-iptables` script.

Do not claim that a source change is deployed until the target Linux host has
been reinstalled or explicitly synchronized. If real rules were not loaded on
a target host, state that runtime validation remains pending.

## Required Static Verification

At minimum, syntax-check the deployment source:

```bash
bash -n deploy-mihomo.sh
```

For a deployment change, load the generator functions or use an equivalent
harness to render a temporary helper, then run:

```bash
bash -n /tmp/mihomo-iptables-test
```

Use at least this representative configuration:

```text
LAN_IF=bond0
LAN_CIDR=172.16.0.0/16
DEBIAN_IP=172.16.215.83
TPROXY_PORT=7894
DNS_PORT=1053
```

Static assertions must cover:

- TUN normalization for `enable: true`, `enable: false`, missing `enable`, no
  `tun:` block, and duplicate direct `enable`, while leaving unrelated
  `enable` keys unchanged.
- Rejection of duplicate top-level `tun:` blocks and inline `tun: { ... }`.
- Exactly one start pre-delete and one stop delete for every parent jump.
- Identical POSTROUTING specifications in all three lifecycle locations.
- TProxy and DIVERT jumps on both `LAN_IF` and `lo`.
- Bypass, destination exclusions, DNS exclusions, TCP mark, and UDP mark in
  `MIHOMO_OUTPUT`.
- The `MIHOMO_DNS` bypass before REDIRECT.
- Policy routing with `0xcc/0xff`, not `0xcc/0xcc`.
- Mihomo configuration validation in systemd `ExecStartPre`.
- `rt_tables` cleanup in the outer uninstall path.
- Every value in all three TCP profiles and rejection of an invalid profile.
- First-install backup preservation and strict restore key/value validation.
- `write_modules` before `write_sysctl`, including the `tcp_cubic` modules-load
  entry.
- Boot-time `hystart_detect=2` in `mihomo-routing.service`.
- Removal of persistent sysctl settings before restore, and retention of the
  backup after any restore failure.

Run ShellCheck when available, but do not mechanically reorder arguments whose
netfilter semantics depend on the current full rule specification. For any
edited files, also run `git diff --check` and the language-specific syntax or
contract checks relevant to the change.

## Required Linux Runtime Verification

After redeploying a behavior change on a supported Linux target, check:

```bash
systemctl --no-pager --full status \
  mihomo.service \
  mihomo-routing.service \
  mihomo-iptables.service

ip rule show
ip route show table 204

iptables -t mangle -S OUTPUT | grep MIHOMO_OUTPUT
iptables -t mangle -S PREROUTING | grep MIHOMO
iptables -t nat -S OUTPUT | grep MIHOMO_DNS
iptables -t nat -S POSTROUTING | grep MIHOMO_POSTROUTING

sysctl \
  net.ipv4.tcp_fastopen \
  net.ipv4.tcp_ecn \
  net.core.rmem_max \
  net.core.wmem_max \
  net.ipv4.tcp_rmem \
  net.ipv4.tcp_wmem \
  net.ipv4.tcp_notsent_lowat

cat /sys/module/tcp_cubic/parameters/hystart_detect
```

Exactly one `fwmark 0xcc/0xff lookup 204` rule should remain. Verify local
traffic with:

```bash
curl -4 https://ipinfo.io/ip
dig example.com
/usr/local/sbin/mihomo-iptables status
```

Lifecycle verification interrupts proxy traffic and requires explicit
permission on an active target:

```bash
/usr/local/sbin/mihomo-iptables stop

iptables -t nat -S POSTROUTING | grep MIHOMO_POSTROUTING
iptables -t nat -S MIHOMO_POSTROUTING

systemctl restart mihomo-routing.service
systemctl restart mihomo.service
systemctl restart mihomo-iptables.service
```

After stop, both POSTROUTING checks should return no rule or report that the
chain does not exist. After repeated restarts, every parent jump must still
appear exactly once.

## Troubleshooting Signals

- **POSTROUTING points to an empty `MIHOMO_POSTROUTING`:** compare the full
  parent jump in start pre-delete, start insertion, and stop deletion. Do not
  assume Docker caused it.
- **Router-local traffic misses mihomo:** check the unique `routing-mark: 255`,
  OUTPUT counters, `0xcc/0xff`, the single policy rule, table 204 local route,
  and both loopback PREROUTING jumps. Test a public destination because private
  destinations are intentionally direct.
- **TUN creates routes or captures traffic:** inspect the installed config for
  direct `tun.enable: false`, then identify the owner of any stale interface or
  rule. Never flush the whole ruleset.
- **TCP values cannot be restored:** verify that the root-owned `0600` backup
  contains only allowlisted keys and numeric/whitespace values. Preserve it on
  failure and restore the reported key rather than guessing a default.
- **High mihomo CPU or a connection loop:** inspect `routing-mark: 255`, both
  `0xff/0xff` bypass paths, any erroneous `/0xcc` policy mask, and duplicate
  policy rules before adding speculative RETURN rules.
- **LAN DNS works but router-local DNS fails:** verify the TCP/UDP nat OUTPUT
  jumps and the matching mangle OUTPUT DNS returns. Local DNS uses REDIRECT,
  not a TProxy mark.

## Review Checklist

Before completing a deployment-related change, be able to explain:

- the LAN TCP/UDP, router-local TCP/UDP, and router-local DNS paths;
- why mihomo's own TCP/UDP/DNS does not loop;
- why TUN is disabled and why normalization cannot edit unrelated `enable`
  keys;
- the active TCP profile, all seven sysctl values, backup location, and why a
  failed uninstall preserves the backup;
- where every parent jump is pre-deleted, added, and removed;
- why repeated restarts do not duplicate jumps;
- why stop/uninstall cannot leave referenced empty chains;
- why Docker-owned rules are neither flushed nor replaced;
- which conclusions are static and which were tested on a target Linux host.

Do not merge firewall or policy-routing changes when these questions remain
unanswered.
