# Mihomo Side Router AI Maintenance Contract

本文件是本目录的 AI 维护契约。修改 `deploy-mihomo.sh` 前必须完整阅读；不要只根据某一条 iptables 命令做局部推断。这个脚本同时管理 mihomo 配置、systemd、策略路由、TProxy、DNS 重定向、单网口转发、Docker 共存和卸载清理，局部改动可能破坏其他路径。

## Scope

- 本文件重点约束 `deploy-mihomo.sh` 和它生成的系统文件。

- `config.yaml` 是部署输入；脚本复制它并在安装副本中强制关闭 TUN、规范化 `routing-mark`。

- Linux TCP 优化参数移植自 Zephyr `network_optim.rs` 的 Linux 分支，固定参考提交为 `e3de103dd6d05785e5f7e93bb4ea9dcce1a636b3`。不要把 macOS 或 Windows 分支移入本脚本。

- `mihomo` 是目标 Debian 使用的二进制，不要在 macOS 上假定它可以执行。

- `smart-trainer/` 与旁路由部署无关。处理 mihomo 部署任务时不要顺手修改它。

- 只有用户明确要求训练器或上游 Smart/LightGBM 同步时才修改 `smart-trainer/`；其 Go/Python 文件共享一个严格的数据契约，不能只更新其中一个。

- 除非用户明确要求，不要提交 Git、重写历史、删除用户配置或改动代理策略内容。

## Source Of Truth

`deploy-mihomo.sh` 是唯一长期维护的部署源。以下文件均由它生成，不能只修改生成物而不回写生成器：

- `/usr/local/sbin/mihomo-iptables`

- `/etc/default/mihomo-iptables`

- `/etc/systemd/system/mihomo.service`

- `/etc/systemd/system/mihomo-routing.service`

- `/etc/systemd/system/mihomo-iptables.service`

- `/etc/sysctl.d/99-mihomo.conf`

- `/etc/modules-load.d/mihomo-tproxy.conf`

- `/etc/mihomo/config.yaml`

如果为了救援临时修改了 Debian 上的生成物，必须把同一修复同步回 `deploy-mihomo.sh`，否则下一次安装会覆盖临时修复。

## Smart Trainer Synchronization Contract

`smart-trainer/transform.go` 跟随 `vernesong/mihomo` 的 `Alpha` 分支：

```text
component/smart/lightgbm/transform.go
```

当前同步基线提交为 `4e0e8d846e2f03d4238433d3b2ed3e24901693b4`。同步上游时必须同时审计并更新：

- `smart-trainer/transform.go`
- `smart-trainer/go_parser.py`
- `smart-trainer/train_flexible.py`

当前特征契约固定为连续索引 `0..29`：

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

变换契约：

- `StandardScaler`：索引 `2,3,4,5,6,7,8,9,10,11,12,13,23,24`。
- `RobustScaler`：索引 `0,1`。
- 其他 14 个特征必须列入 `untransformed_features`。
- 模型尾部协议仍为 `[transforms]`、`[order]`、`[definitions]` 和 `[/transforms]`。
- Go 端只读取模型最后 16384 字节，Python 生成的完整 transforms block 必须小于该窗口。

同步规则：

1. `transform.go` 应与固定上游文件经 `gofmt` 后逐字一致，不在本地版本中加入只服务训练脚本的私有改动。
2. `expectedCount` 必须使用 `MaxFeatureSize`，不能重新硬编码 `21` 或 `30`。
3. `ApplyTransforms` 必须先复制输出，再把工作切片放回 `sync.Pool`；先 Put 后 copy 会产生并发数据竞态。
4. 保留上游 `IsCompatibleWith`，由调用方检查模型内的 feature order 是否与运行时默认顺序一致。
5. `go_parser.py` 必须失败关闭：解析结果必须恰好为连续索引 `0..29` 且名称唯一，禁止静默回退到旧的硬编码 21 特征顺序。
6. `train_flexible.py` 必须从 Go 文件解析顺序，检查 CSV 包含全部 30 个特征和 `weight`，并按同一顺序训练和写入 metadata。
7. Python 中的 scaler 特征名称、Go 注释中的 scaler 索引和模型尾部 `*_features` 必须三方一致。
8. 除非用户明确要求，不修改模型目标、LightGBM 超参数、GPU/CPU 策略或 CSV 采集口径。

每次同步至少验证：

```bash
gofmt -w smart-trainer/transform.go
python3 -m py_compile \
  smart-trainer/go_parser.py \
  smart-trainer/train_flexible.py
```

还必须执行跨语言契约测试：解析 Go 默认顺序得到 30 个连续唯一特征；StandardScaler 索引等于 `2..13,23,24`；RobustScaler 索引等于 `0,1`；生成 metadata 后重新解析 `[order]` 和 definitions，确认参数数量与索引数量一致。若环境没有完整 mihomo Go 模块，不能声称 `transform.go` 已独立编译，只能报告 `gofmt`、上游逐字比较和 Python 契约测试结果。

## Supported Topology

这个脚本只支持下面的明确模型：

- Debian/Linux，IPv4。

- 单个 LAN 逻辑接口；接口可以是物理接口，也可以是 `bond0` 一类逻辑接口。

- Debian 是单网口旁路由，客户端把网关和 DNS 都指向 Debian。

- LAN 客户端 TCP/UDP 使用 iptables TPROXY。

- mihomo TUN 必须禁用，不能与本脚本的 iptables TProxy、DNS REDIRECT 和策略路由同时接管流量。

- Debian 本机产生的公网 TCP/UDP 也透明进入 mihomo。

- 传统 TCP/UDP 53 端口通过 REDIRECT 进入 mihomo DNS。

- 私网、回环、链路本地、组播和保留目标保持直连。

- 未被 TPROXY 接管、仍需正常转发的公网流量使用 MASQUERADE 保证对称回程。

- 与 Docker 规则共存，不清空 Docker 或系统规则。

- Linux TCP 优化提供 `conservative`、`balanced`、`aggressive` 三档，默认 `balanced`，并保存首次安装前的内核值供卸载恢复。

当前不支持：IPv6、原生 nftables 规则集、多 LAN 接口、多独立策略路由域、同时管理多个 mihomo 实例。不要在没有重新设计和目标机实测的情况下声称支持这些场景。

## Coupled Constants

以下值彼此耦合，不得只改一处：

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

含义：

- `MARK/MARK_MASK` 即 `0xcc/0xff`，是需要送入 TProxy 的精确 fwmark。

- `BYPASS_MARK` 即 `0xff`，是 mihomo 自身出站 socket 的绕行标记。

- 安装后的 `/etc/mihomo/config.yaml` 必须包含唯一的顶层 `routing-mark: 255`。

- 路由规则必须是 `fwmark 0xcc/0xff lookup 204 priority 100`。

- 表 204 必须包含 `local 0.0.0.0/0 dev lo`。

绝对不要把策略规则恢复成 `0xcc/0xcc`。掩码 `0xcc` 只检查对应的置位位，而 `0xff` 同样包含这些位，因此 mihomo 的绕行标记 `0xff` 也会错误匹配该规则，造成自身出站被送回本机路由表并产生回环。必须使用完整掩码 `/0xff` 做精确匹配。

如果更换任一 mark，必须同时审计：

- `routing-mark`

- `MIHOMO_OUTPUT` 的绕行规则

- `MIHOMO_DNS` 的绕行规则

- `MARK --set-xmark`

- `TPROXY --tproxy-mark`

- `ip rule` 的启动、停止和卸载逻辑

- 旧规则迁移与清理逻辑

## Packet Paths

### LAN Client TCP/UDP

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

`MIHOMO_DIVERT` 必须在同一接口的 `MIHOMO_TPROXY` 跳转之前，避免已建立透明 TCP 连接再次执行 TPROXY。

### Debian Local TCP/UDP

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

仅在 OUTPUT 打 mark 不够。必须同时保留 `lo` 上的 PREROUTING 跳转，否则本机流量虽然被策略路由到回环接口，却不会进入 TPROXY。

`MIHOMO_TPROXY` 中针对 `DEBIAN_IP` 的源地址排除必须允许已经带 `MARK/MARK_MASK` 的本机重路由包通过。不要恢复为无条件 `-s "$DEBIAN_IP" -j RETURN`，否则本机透明代理会全部失效。

### DNS

LAN DNS：

```text
LAN client :53
  -> mangle PREROUTING does not TPROXY DNS
  -> nat PREROUTING
  -> MIHOMO_DNS
  -> REDIRECT to DNS_PORT
```

本机 DNS：

```text
local process :53
  -> MIHOMO_OUTPUT returns without TProxy mark
  -> nat OUTPUT
  -> MIHOMO_DNS
  -> REDIRECT to DNS_PORT
```

mihomo 自己的 DNS/出站连接带 `0xff`；`MIHOMO_DNS` 必须先检查 `0xff/0xff` 并返回，否则会发生 DNS 回环。

### Forwarding Fallback

`MIHOMO_POSTROUTING` 只处理源自 `LAN_CIDR`、从 `LAN_IF` 发出的转发流量。它排除 Debian 自身源地址及私网/本地目标，最后才执行 MASQUERADE。不要把 MASQUERADE 无条件挂到整个 POSTROUTING。

## Netfilter Ordering Invariants

生成脚本只拥有以下自定义链：

- `mangle/MIHOMO_DIVERT`

- `mangle/MIHOMO_TPROXY`

- `mangle/MIHOMO_OUTPUT`

- `nat/MIHOMO_DNS`

- `nat/MIHOMO_POSTROUTING`

- `filter/MIHOMO_FORWARD`

禁止使用以下破坏性操作：

```text
iptables -F
iptables -X
iptables-restore with a full replacement ruleset
nft flush ruleset
清空 DOCKER-USER
把 FORWARD policy 改成 ACCEPT
```

脚本只能清空或删除自己命名为 `MIHOMO_*` 的链，并只能删除自己精确创建的父链跳转。

同一接口的 PREROUTING 最终顺序必须是：

```text
MIHOMO_DIVERT
MIHOMO_TPROXY
```

DNS 的 nat PREROUTING/OUTPUT 跳转要足够靠前，以免先被其他通用 DNS NAT 规则截获。mangle OUTPUT 当前尊重已有规则并将 `MIHOMO_OUTPUT` 追加到 OUTPUT；如果要改成插入第 1 条，必须先评估与其他本机 fwmark、VPN、Docker 和策略路由的冲突。

## Start/Stop Symmetry

这是最容易被 AI 局部修改后破坏的约束。

每个父链跳转必须有三份完全一致的参数：

1. `start_rules` 插入前的 `delete_all`。
2. `start_rules` 的 `iptables -I` 或 `iptables -A`。
3. `stop_rules` 的 `delete_all`。

iptables 的 `-C` 和 `-D` 按完整规则规格匹配。哪怕只多一个 `! -s`、不同的 mask、不同的接口或不同的模块顺序，也可能无法删除。

历史 bug：POSTROUTING 启动时创建的是：

```text
-o LAN_IF -s LAN_CIDR -j MIHOMO_POSTROUTING
```

但停止时曾错误增加：

```text
! -s DEBIAN_IP
```

结果是父链跳转无法删除，`MIHOMO_POSTROUTING` 被清空后又因为仍被引用而无法 `-X`，最终残留空链。不要重新引入这个差异。

新增父链跳转时，必须同时添加上述三处；删除或改变跳转时也必须同时修改三处。修改完成后逐字符比较生成脚本，而不是凭肉眼认为“逻辑等价”。

`chain_remove` 不应吞掉仍被引用导致的删除错误。停止失败必须暴露出来，不能虚假报告成功。

## Policy Routing Lifecycle

`mihomo-routing.service` 拥有以下资源：

- `fwmark 0xcc/0xff lookup 204 priority 100`

- 兼容迁移时需要删除的旧规则 `fwmark 0xcc/0xcc lookup 204 priority 100`

- 表 204 的 local default route

启动时必须循环删除所有新旧同规格规则，再只添加一条正确规则，避免重复规则或旧掩码残留。停止时必须删除新旧规则并 flush 表 204。

`mihomo-iptables.service` 依赖并排在 `mihomo-routing.service` 之后。不要让 TProxy 规则在策略路由不存在时长期保持 active。

卸载必须同时清理：

- 新旧策略规则的所有重复项

- 表 204

- `/etc/iproute2/rt_tables` 中脚本写入的 `204 mihomo`

- 所有父链跳转

- 所有 `MIHOMO_*` 链

- 三个 systemd unit

- sysctl 和 modules-load 文件

卸载按设计保留 `/etc/mihomo/config.yaml` 和 `/usr/local/bin/mihomo`，除非用户明确要求删除。

## mihomo Configuration Invariants

安装必须在启动服务之前确认：

- 如果存在顶层块式 `tun:`，其直属 `enable` 必须被规范化为唯一的 `false`；缺少该键时显式补上。没有 `tun:` 时保持 mihomo 默认禁用。

- 重复顶层 `tun:` 或 `tun: { ... }` 内联映射必须拒绝自动修改，不能用宽泛的 `sed`/`grep` 误改 DNS、NTP、sniffer、health-check 等其他 `enable`。

- 顶层 `tproxy-port` 与 `TPROXY_PORT` 一致。

- DNS `enhanced-mode` 是 `redir-host`。

- DNS `listen` 端口与 `DNS_PORT` 一致。

- 顶层只有一个有效 `routing-mark: 255`。

- `/usr/local/bin/mihomo -t -d /etc/mihomo` 返回成功。

systemd 的 `ExecStartPre` 也必须再次执行配置测试，防止部署后手工改坏配置仍被启动。

mihomo 服务只需要以下 capabilities：

```text
CAP_NET_ADMIN
CAP_NET_RAW
CAP_NET_BIND_SERVICE
```

不要无理由恢复 `CAP_SYS_PTRACE`、`CAP_SYS_TIME`、`CAP_DAC_OVERRIDE`、`CAP_DAC_READ_SEARCH` 等高权限。

## Linux TCP Optimization Invariants

本功能只移植 Zephyr `network_optim.rs` 在 Linux 上实际实现的项目：

- `net.ipv4.tcp_fastopen`
- `net.ipv4.tcp_ecn`
- `net.core.rmem_max`
- `net.core.wmem_max`
- `net.ipv4.tcp_rmem`
- `net.ipv4.tcp_wmem`
- `net.ipv4.tcp_notsent_lowat`
- `/sys/module/tcp_cubic/parameters/hystart_detect=2`

上游没有设置 BBR、`default_qdisc` 或 `tcp_congestion_control`，因此不要以“补全网络优化”为理由擅自添加这些设置。CUBIC HyStart 调优不等于强制把拥塞控制算法改成 CUBIC。

三档参数必须保持为：

| 参数 | conservative | balanced | aggressive |
| --- | ---: | ---: | ---: |
| `tcp_fastopen` | 1 | 3 | 3 |
| `tcp_ecn` | 2 | 1 | 1 |
| `rmem_max` | 8388608 | 16777216 | 33554432 |
| `wmem_max` | 16777216 | 33554432 | 67108864 |
| `tcp_rmem` | `4096 131072 8388608` | `4096 262144 16777216` | `4096 524288 33554432` |
| `tcp_wmem` | `4096 131072 16777216` | `4096 262144 33554432` | `4096 524288 67108864` |
| `tcp_notsent_lowat` | 65536 | 131072 | 262144 |

生命周期要求：

1. `write_modules` 必须先加载 `tcp_cubic`，再由 `write_sysctl` 备份和应用参数。
2. `/var/lib/mihomo-deploy/network-optim-backup.conf` 只在不存在时创建，重复安装不能覆盖首次安装前的原值。
3. 备份只允许上述 7 个 sysctl 键和 `sys.module.tcp_cubic.hystart_detect`；恢复时必须使用严格白名单和纯数字/空白验证，防止备份文件变成命令注入入口。
4. 所有持久 sysctl 写入脚本已有的 `/etc/sysctl.d/99-mihomo.conf`，不要另建 `99-zephyr-tcp-tuning.conf`，避免同一脚本拥有两个互相覆盖的 sysctl 文件。
5. `mihomo-routing.service` 每次启动都重新写入 `hystart_detect=2`，因为 sysfs 模块参数不会由 sysctl 文件持久化。
6. 卸载必须先删除 `99-mihomo.conf`，再从首次备份恢复运行中的 TCP 参数；全部恢复成功后才删除备份。任何恢复失败都要保留备份并报警。
7. `status` 必须显示全部 7 个 sysctl 和当前 `hystart_detect`，不能只用配置文件存在来判断已应用。

默认使用 `balanced`，与上游默认 `OptimLevel::Balanced` 一致。改变默认档位属于行为变化，必须由用户明确要求。CLI `--network-optim-level` 只能接受三个固定值。

## Docker And Existing Firewall Rules

- 如果 `DOCKER-USER` 存在，把 `MIHOMO_FORWARD` 跳转插入该链。

- 如果 `DOCKER-USER` 不存在，才回退到 `FORWARD`。

- `stop_rules` 必须同时尝试从两处删除，以处理 Docker 在部署后启动或停止的情况。

- 不要删除、重排或重建 Docker 创建的链。

- 不要用“为了简单”作为清空整张 filter/nat/mangle 表的理由。

## Input And Environment Validation

安装前必须拒绝：

- 不存在或不可执行的 mihomo 二进制。

- 不存在的配置文件。

- `0`、大于 `65535` 或非数字端口。

- 相同的 TProxy 和 DNS 端口。

- 非法 IPv4 或 CIDR。

- 不属于 `LAN_CIDR` 的 `DEBIAN_IP`。

- 不存在的 `LAN_IF`。

- 没有实际配置在 `LAN_IF` 上的 `DEBIAN_IP`。

脚本启用了 `set -Eeuo pipefail`。编写 pipeline 时不要让下游命令提前退出并使上游收到 SIGPIPE；例如探测命令中避免 `awk '... { print; exit }'`，应消费完整输入或显式处理 pipeline 状态。

## Change Procedure For AI Agents

任何修改都按以下顺序进行：

1. 完整阅读本文件和 `deploy-mihomo.sh`，确认用户要求属于支持拓扑。
2. 说明准备修改的包路径和不变量；不要先动手再猜测。
3. 只做与请求相关的最小修改，保留用户和 Docker 的现有规则。
4. 如果修改生成脚本，检查外层 heredoc 的变量转义。外层安装变量应在生成时展开；生成脚本运行时变量必须写成 `\$VAR` 或 `\${VAR}`。
5. 修改 YAML 时只操作明确的顶层块及其直属键；严禁全局替换所有 `enable`。
6. 对每个父链跳转检查 start-delete、start-add、stop-delete 三处完全一致。
7. 对 mark 修改检查 mihomo 配置、iptables、策略路由和旧规则迁移。
8. 对 systemd 修改检查启动顺序、停止顺序、幂等 restart 和 uninstall。
9. 修改 Linux TCP 参数时核对三档完整矩阵、首次备份、卸载恢复、HyStart 开机重设和状态输出；不要只改 sysctl 文件。
10. 先验证外层脚本，再实际生成临时 `mihomo-iptables` 验证内层脚本。
11. 明确区分“源脚本已修改”和“目标 Debian 已重新部署”；不要声称本地修改已经自动同步到 home-nuc。
12. 不要承诺绝对无 bug；如果没有在目标 Debian 加载真实规则，必须说明运行验证仍待完成。

## Required Static Verification

至少执行：

```bash
bash -n deploy-mihomo.sh
```

还必须通过加载函数或等价测试，让脚本用示例参数生成临时规则脚本，再执行：

```bash
bash -n /tmp/mihomo-iptables-test
```

生成参数至少覆盖当前实际形态：

```text
LAN_IF=bond0
LAN_CIDR=172.16.0.0/16
DEBIAN_IP=172.16.215.83
TPROXY_PORT=7894
DNS_PORT=1053
```

静态检查至少断言：

- TUN 规范化测试覆盖 `enable: true`、`enable: false`、缺少 `enable`、完全没有 `tun:`、重复 `enable`，并确认不会修改块外的其他 `enable`。

- 重复顶层 `tun:` 和内联 `tun: { ... }` 必须拒绝处理。

- 所有父链跳转的 start-delete 与 stop-delete 各出现一次。

- POSTROUTING 三处规格完全一致。

- TProxy 与 DIVERT 在 LAN_IF 和 lo 上都存在。

- `MIHOMO_OUTPUT` 同时有 bypass、目标排除、DNS 排除、TCP mark、UDP mark。

- `MIHOMO_DNS` 的 bypass 位于 REDIRECT 之前。

- 策略规则使用 `0xcc/0xff`，不是 `0xcc/0xcc`。

- systemd 启动前测试 mihomo 配置。

- 外层卸载逻辑删除 `rt_tables` 条目。

- 三个 TCP 优化档位逐项匹配固定参数矩阵，非法档位被拒绝。

- 首次备份不会被第二次安装覆盖，恢复只接受白名单键和数字值。

- `write_modules` 在 `write_sysctl` 之前执行，`tcp_cubic` 被加入 modules-load。

- `mihomo-routing.service` 每次启动设置 `hystart_detect=2`。

- 卸载删除持久 sysctl 后恢复备份，恢复失败时不会删除备份文件。

如果环境有 ShellCheck，运行它，但不要为了通过 ShellCheck 机械改变具有 netfilter 语义的参数顺序。

## Required Debian Runtime Verification

重新部署后检查：

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

正确策略规则应只有一条：

```text
fwmark 0xcc/0xff lookup 204
```

本机验证：

```bash
curl -4 https://ipinfo.io/ip
dig example.com
/usr/local/sbin/mihomo-iptables status
```

生命周期验证会短暂中断代理，只在用户允许时执行：

```bash
/usr/local/sbin/mihomo-iptables stop

iptables -t nat -S POSTROUTING | grep MIHOMO_POSTROUTING
iptables -t nat -S MIHOMO_POSTROUTING

systemctl restart mihomo-routing.service
systemctl restart mihomo.service
systemctl restart mihomo-iptables.service
```

停止后两个检查都应无结果或报告链不存在。重新启动后每个父链跳转只能有一条，不能随 restart 增长。

## Troubleshooting Signals

### POSTROUTING points to an empty MIHOMO_POSTROUTING

这通常意味着 stop 的删除规格与 start 的添加规格不同。先对比完整 `iptables -t nat -S POSTROUTING`，不要直接归因于 Docker。

### Local traffic does not enter mihomo

依次检查：

1. `/etc/mihomo/config.yaml` 是否为 `routing-mark: 255`。
2. OUTPUT 是否命中 `MIHOMO_OUTPUT`。
3. TCP/UDP 是否获得 `0xcc/0xff`。
4. 是否只有一条正确的 policy rule。
5. 表 204 是否有 local default route。
6. lo 上是否有 MIHOMO_DIVERT 和 MIHOMO_TPROXY。
7. 私网目标按设计不会代理，不要用私网地址测试公网透明代理。

### TUN unexpectedly creates routes or captures traffic

检查安装后的 `/etc/mihomo/config.yaml`，顶层 `tun:` 下必须是 `enable: false`。不要只修改源 `config.yaml` 后假定已部署副本同步；重新安装或明确同步生成物。TUN 表、规则或接口仍存在时，先确认是否来自旧 mihomo 进程或其他服务，再清理对应所有者的资源，不要清空整个系统规则集。

### Linux TCP optimization cannot be reverted

检查 `/var/lib/mihomo-deploy/network-optim-backup.conf` 是否存在、权限是否为 root `0600`、键是否属于白名单且值只包含数字和空白。恢复失败时不要删除或覆盖该文件，也不要用猜测的“默认值”替代原值。确认问题后针对失败键手工恢复，再重新执行卸载清理。

### mihomo CPU high or connections loop

优先检查 bypass，而不是增加 RETURN 猜测性规则：

- mihomo 配置是否带 `routing-mark: 255`。

- mangle OUTPUT 和 nat DNS 是否精确放行 `0xff/0xff`。

- policy rule 是否错误使用了 `/0xcc`。

- 是否存在旧的重复 policy rule。

### DNS works for LAN but not Debian itself

检查 nat OUTPUT 的 TCP/UDP 53 跳转，以及 MIHOMO_OUTPUT 是否在 mangle 阶段对 53 端口 RETURN。不要把本机 DNS 直接打 TProxy mark。

## Final Review Questions

交付任何相关修改前，AI 必须能够明确回答：

- LAN TCP、LAN UDP、本机 TCP、本机 UDP、本机 DNS 各走哪条路径？

- mihomo 自身的 TCP/UDP/DNS 为什么不会回环？

- 为什么 TUN 必须关闭，脚本如何保证只修改 `tun.enable` 而不碰其他 `enable`？

- 当前 TCP 优化使用哪一档、7 个 sysctl 分别是多少、原值保存在哪里、卸载失败时备份为什么仍会保留？

- 每条新父链跳转在哪里添加、在哪里预清理、在哪里停止删除？

- restart 两次后为什么不会重复？

- stop/uninstall 后为什么不会残留空链？

- Docker 规则为什么不会被清空或覆盖？

- 哪些结论只经过静态验证，哪些已经在目标 Debian 实测？

如果无法回答，不要继续修改防火墙或策略路由代码。
