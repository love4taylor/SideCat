# sidecat

面向 Debian/Linux 单网口旁路由的 mihomo 部署工具，同时包含 Smart/LightGBM 模型训练辅助脚本。

`deploy-mihomo.sh` 使用 iptables TProxy、策略路由和 DNS REDIRECT 接管 LAN 客户端及 Debian 本机符合代理条件的公网 IPv4 TCP/UDP 流量；私网、回环、链路本地、组播和保留目标保持直连。脚本只维护自己的 `MIHOMO_*` 链，并尽量与 Docker 和现有防火墙规则共存。

```text
LAN 客户端 ─┐
            ├─> Debian 单网口旁路由 ─> TProxy / DNS REDIRECT ─> mihomo ─> Internet
Debian 本机 ─┘                         fwmark 0xcc/0xff
```

> [!IMPORTANT]
> 这是明确面向 **Debian、IPv4、单个 LAN 逻辑接口和 iptables** 的部署方案。当前不支持 IPv6、原生 nftables 规则集、多 LAN 接口或同时管理多个 mihomo 实例。

## 功能

- LAN 客户端 TCP/UDP 透明代理。
- Debian 本机 TCP/UDP 透明代理。
- LAN 与本机传统 TCP/UDP 53 端口 DNS 重定向。
- 精确的 `0xcc/0xff` TProxy 标记与表 `204` 策略路由。
- mihomo 出站使用 `routing-mark: 255` 绕过透明代理，避免流量回环。
- 自动禁用已安装配置中的 `tun.enable`，避免 TUN 与 TProxy 重复接管。
- 与 Docker 规则共存，不清空系统、Docker 或用户维护的规则链。
- 为未被 TProxy 接管的转发流量提供受限的 MASQUERADE 回程兜底。
- 提供三档 Linux TCP 优化，并保存首次安装前的内核参数供卸载恢复。
- 生成并管理 mihomo、策略路由和 iptables 三个 systemd 服务。
- 提供 30 特征 Smart/LightGBM 模型训练与 transforms 元数据生成工具。

## 前置条件

- Debian 或兼容的 Linux 发行版，使用 systemd。
- 一个配置了固定 IPv4 地址的 LAN 接口；物理接口和 `bond0` 等逻辑接口均可。
- root 或 `sudo` 权限。
- 与目标机器架构匹配、可执行的 mihomo Linux 二进制。
- 一份满足下述约束的 mihomo 配置文件。

安装脚本会通过 APT 安装 `ca-certificates`、`iproute2`、`iptables`、`kmod`、`procps`、`conntrack` 和 `tcpdump`。

## 准备文件

将本地部署输入放在仓库根目录：

```text
sidecat/
├── deploy-mihomo.sh
├── mihomo
└── config.yaml
```

`mihomo` 和 `config.yaml` 已被 `.gitignore` 排除。不要把包含订阅地址、控制器密钥或节点凭据的真实配置提交到 Git。

确保二进制可执行：

```bash
chmod +x ./mihomo ./deploy-mihomo.sh
```

配置文件至少需要满足：

```yaml
tproxy-port: 7894

dns:
  listen: 0.0.0.0:1053
  enhanced-mode: redir-host

tun:
  enable: false
```

`tun` 块可以不存在；如果存在，必须使用块式 YAML。安装脚本会在复制到 `/etc/mihomo/config.yaml` 后把其直属 `enable` 规范化为 `false`，并把顶层 `routing-mark` 规范化为 `255`。重复的顶层 `tun`、内联 `tun: { ... }` 或重复的 `tun.enable` 会被拒绝，以免误改其他模块的 `enable`。

> [!CAUTION]
> 如果配置启用了 `external-controller: 0.0.0.0:9090`，必须使用强随机 `secret` 并限制该端口的网络访问。不要在示例、日志或 Git 历史中暴露真实密钥。

## 安装

下面示例使用 `bond0`、`172.16.0.0/16` 和 Debian 地址 `172.16.215.83`：

```bash
sudo ./deploy-mihomo.sh install \
  --iface bond0 \
  --lan-cidr 172.16.0.0/16 \
  --debian-ip 172.16.215.83 \
  --mihomo ./mihomo \
  --config ./config.yaml \
  --network-optim-level balanced
```

安装参数：

| 参数 | 说明 | 默认值 |
| --- | --- | --- |
| `--iface IFACE` | LAN 接口；未提供时尝试从默认路由检测 | 自动检测 |
| `--lan-cidr CIDR` | LAN IPv4 网段 | 自动检测 |
| `--debian-ip IP` | Debian 在 LAN 接口上的固定 IPv4 地址 | 自动检测 |
| `--mihomo PATH` | mihomo 二进制路径 | `./mihomo` |
| `--config PATH` | mihomo 配置路径 | `./config.yaml` |
| `--tproxy-port PORT` | TProxy 监听端口 | `7894` |
| `--dns-port PORT` | mihomo DNS 监听端口 | `1053` |
| `--network-optim-level LEVEL` | `conservative`、`balanced` 或 `aggressive` | `balanced` |

安装完成后，将 LAN 客户端的默认网关和 DNS 都指向 Debian 的固定 LAN 地址，然后让客户端重新获取 DHCP 租约或重连网络。

## 日常操作

```bash
# 查看 systemd、策略路由、监听端口、iptables 和 TCP 优化状态
sudo ./deploy-mihomo.sh status

# 备份现有 mihomo、systemd、路由与 iptables 状态
sudo ./deploy-mihomo.sh backup

# 删除本脚本创建的服务、规则和 sysctl，并恢复保存的 TCP 参数
sudo ./deploy-mihomo.sh uninstall
```

备份文件保存在 `/root/mihomo-backup/mihomo-*.tar.gz`。卸载会保留 `/etc/mihomo/config.yaml` 和 `/usr/local/bin/mihomo`，不会删除用户配置或已安装二进制。

## 安装内容

脚本生成并维护：

| 路径 | 用途 |
| --- | --- |
| `/usr/local/bin/mihomo` | 已安装的 mihomo 二进制 |
| `/etc/mihomo/config.yaml` | 已规范化的运行配置 |
| `/usr/local/sbin/mihomo-iptables` | TProxy、DNS、转发与 SNAT 规则管理 |
| `/etc/systemd/system/mihomo.service` | mihomo 服务 |
| `/etc/systemd/system/mihomo-routing.service` | fwmark 策略路由 |
| `/etc/systemd/system/mihomo-iptables.service` | iptables 生命周期 |
| `/etc/sysctl.d/99-mihomo.conf` | 转发、rp_filter 和 TCP 参数 |
| `/etc/modules-load.d/mihomo-tproxy.conf` | TProxy 与 CUBIC 模块 |
| `/var/lib/mihomo-deploy/network-optim-backup.conf` | 首次安装前的 TCP 参数备份 |

systemd 启动顺序为策略路由、mihomo、iptables。mihomo 启动前会再次执行配置检查，防止损坏的配置被加载。

## 网络优化档位

默认 `balanced`。三档只调整 Zephyr Linux 实现实际覆盖的参数：TCP Fast Open、ECN、socket 缓冲区、TCP 缓冲区、`tcp_notsent_lowat` 和 CUBIC HyStart；不会擅自切换 BBR 或拥塞控制算法。

| 档位 | 适用场景 |
| --- | --- |
| `conservative` | 内存较小或希望尽量保持系统默认行为 |
| `balanced` | 通用旁路由，默认推荐 |
| `aggressive` | 高吞吐、大内存且已经验证过的环境 |

首次安装会保存原始参数。重复安装不会覆盖这份备份；只有全部恢复成功后，卸载流程才会删除备份文件。

## 运行验证

安装后先检查服务、策略路由和规则：

```bash
sudo systemctl --no-pager --full status \
  mihomo.service \
  mihomo-routing.service \
  mihomo-iptables.service

ip rule show
ip route show table 204

sudo iptables -t mangle -S OUTPUT | grep MIHOMO_OUTPUT
sudo iptables -t mangle -S PREROUTING | grep MIHOMO
sudo iptables -t nat -S OUTPUT | grep MIHOMO_DNS
sudo iptables -t nat -S POSTROUTING | grep MIHOMO_POSTROUTING
```

正确的策略规则应只有一条，并使用完整掩码：

```text
fwmark 0xcc/0xff lookup 204
```

再测试 Debian 本机出口与 DNS。`curl` 和 `dig` 分别需要 `curl` 与 `dnsutils`，它们不是安装脚本的必装依赖：

```bash
curl -4 https://ipinfo.io/ip
dig example.com
sudo /usr/local/sbin/mihomo-iptables status
```

> [!NOTE]
> `stop`、`uninstall` 和 systemd restart 会短暂中断代理。生命周期测试应在允许中断业务时执行。

## Smart 模型训练

`smart-trainer/` 用于生成 mihomo Smart/LightGBM 模型。当前特征顺序跟随 `vernesong/mihomo` Alpha 分支的 `component/smart/lightgbm/transform.go`，固定同步基线为 `4e0e8d846e2f03d4238433d3b2ed3e24901693b4`。

训练器要求：

- Python 3.11；`requirements.txt` 中的固定依赖版本以该版本为推荐环境。
- CSV 包含连续、唯一的 30 个模型特征以及 `weight`。
- StandardScaler 使用索引 `2..13,23,24`。
- RobustScaler 使用索引 `0,1`。
- 其余 14 个特征保持不变。
- `transform.go`、`go_parser.py` 和 `train_flexible.py` 必须同步更新。
- 当前训练参数使用 LightGBM GPU；环境需要可用的 GPU/OpenCL LightGBM 支持。

创建隔离环境并安装固定依赖：

```bash
cd smart-trainer
python3 -m venv .venv
source .venv/bin/activate
python -m pip install --upgrade pip
python -m pip install -r requirements.txt
```

将训练数据保存为 `smart-trainer/smart_weight_data.csv`，然后运行：

```bash
python train_flexible.py
```

成功后会生成 `smart-trainer/Model.bin`。模型末尾包含 `[transforms]`、`[order]` 和 `[definitions]` 元数据；完整 transforms 块必须小于 Go 端读取窗口 `16384` 字节。训练数据和模型输出均已被 `.gitignore` 排除。

## 项目结构

```text
.
├── AGENTS.md                    # AI/维护者不变量和验证契约
├── deploy-mihomo.sh             # Debian 旁路由部署入口
├── smart-trainer/
│   ├── go_parser.py             # 从 Go 源码解析严格特征顺序
│   ├── requirements.txt         # Python 固定依赖
│   ├── train_flexible.py        # 数据缩放、训练和模型元数据生成
│   └── transform.go             # mihomo Smart transforms 上游同步文件
└── .gitignore                   # 排除本地配置、二进制、数据和模型
```

## 故障排查

### 本机流量没有进入 mihomo

依次确认：

1. `/etc/mihomo/config.yaml` 只有一个顶层 `routing-mark: 255`。
2. mangle OUTPUT 命中 `MIHOMO_OUTPUT`。
3. 公网 TCP/UDP 获得 `0xcc/0xff`。
4. `ip rule` 中只有一条正确的表 `204` 规则。
5. 表 `204` 包含 `local 0.0.0.0/0 dev lo`。
6. `lo` 上同时存在 `MIHOMO_DIVERT` 和 `MIHOMO_TPROXY`。

### POSTROUTING 指向空链

这通常表示旧版本启动和停止时使用了不同的父链规则规格。检查：

```bash
sudo iptables -t nat -S POSTROUTING | grep MIHOMO_POSTROUTING
sudo iptables -t nat -S MIHOMO_POSTROUTING
```

当前脚本会在启动前清理同规格旧跳转，并在停止时使用完全一致的规则删除它。

### DNS 正常转发但 Debian 本机 DNS 失败

确认 nat OUTPUT 包含 `MIHOMO_DNS`，同时 mangle OUTPUT 对 TCP/UDP 53 端口直接返回。本机 DNS 应走 REDIRECT，而不是先获得 TProxy mark。

更完整的网络路径、不变量、静态检查和目标机验证清单见 [`AGENTS.md`](AGENTS.md)。
