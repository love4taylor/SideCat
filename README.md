# sidecat

sidecat 是面向 Debian 和 Arch Linux 的 mihomo 单网口旁路由部署工具，同时提供可选的 Smart/LightGBM 模型训练脚本。

部署脚本使用 iptables TProxy、策略路由和 DNS REDIRECT 接管局域网客户端以及旁路由本机的公网 IPv4 TCP/UDP 流量。私网、回环、链路本地、组播和保留地址保持直连。

```text
局域网客户端 --+
                +--> Linux 单网口旁路由 --> TProxy / DNS REDIRECT --> mihomo --> Internet
旁路由本机 -----+                         fwmark 0xcc/0xff
```

> [!IMPORTANT]
> 本方案只支持 Debian/Arch Linux、systemd、IPv4、单个 LAN 逻辑接口和 iptables。当前不支持 IPv6、原生 nftables 规则集、多 LAN 接口、多独立策略路由域或多个 mihomo 实例。

## 功能

- 透明代理局域网客户端的 TCP/UDP 流量。
- 透明代理旁路由本机产生的 TCP/UDP 流量。
- 将局域网与本机的传统 TCP/UDP 53 端口 DNS 请求重定向到 mihomo。
- 使用精确的 `0xcc/0xff` fwmark 和路由表 `204`。
- 使用 `routing-mark: 255` 放行 mihomo 自身出站连接，避免代理回环。
- 在安装副本中关闭 TUN，避免 TUN 与 TProxy 重复接管。
- 只维护自己的 `MIHOMO_*` 规则链，不清空 Docker、系统或用户规则。
- 为未被 TProxy 接管的转发流量提供受限的 MASQUERADE 回程兜底。
- 提供三档 Linux TCP 优化，并在卸载时恢复首次安装前的参数。
- 管理 mihomo、策略路由和 iptables 三个 systemd 服务。
- 支持旁路由本机连接的 mihomo `PROCESS-NAME` 规则。

## 准备工作

目标主机需要满足以下条件：

- Debian 或 Arch Linux，并使用 systemd。
- 一个已经配置固定 IPv4 地址的 LAN 接口，物理接口或 `bond0` 等逻辑接口均可。
- root 或 `sudo` 权限。
- 与目标主机架构匹配的 mihomo Linux 二进制。
- 一份可用的 mihomo 配置文件。

安装脚本会自动选择包管理器：

- Debian 使用 APT 安装 `ca-certificates`、`iproute2`、`iptables`、`kmod`、`procps`、`conntrack` 和 `tcpdump`。
- Arch Linux 使用 pacman 安装 `ca-certificates`、`iproute2`、`iptables`、`kmod`、`procps-ng`、`conntrack-tools` 和 `tcpdump`。

Arch Linux 的 `iptables` 包可以使用 nft 后端，但必须提供 iptables 兼容命令。sidecat 不创建或清空原生 nftables 规则集。

将二进制和配置文件放在脚本所在目录，或在安装命令中传入其他路径：

```text
sidecat/
|-- deploy-mihomo.sh
|-- mihomo
`-- config.yaml
```

确保脚本和二进制可执行：

```bash
chmod +x ./deploy-mihomo.sh ./mihomo
```

## 配置要求

配置文件至少需要提供与安装参数一致的 TProxy 和 DNS 监听端口：

```yaml
tproxy-port: 7894

dns:
  listen: 0.0.0.0:1053
  enhanced-mode: redir-host

tun:
  enable: false
```

`tun` 块可以省略。如果存在，必须使用块式 YAML。安装时会执行以下规范化：

- 把 `tun` 块直属的 `enable` 设置为唯一的 `false`。
- 把顶层 `routing-mark` 设置为唯一的 `255`。
- 拒绝多个顶层 `tun` 块和 `tun: { ... }` 内联映射。
- 在启动 mihomo 前执行配置检查。

配置文件通常包含订阅地址、节点凭据或控制器密钥，请只向可信用户开放。如果启用了 `external-controller: 0.0.0.0:9090`，请配置强随机 `secret`，并在防火墙中限制控制器端口的访问来源。

## 安装

下面的示例使用 `bond0`、`172.16.0.0/16` 和旁路由地址 `172.16.215.83`：

```bash
sudo ./deploy-mihomo.sh install \
  --iface bond0 \
  --lan-cidr 172.16.0.0/16 \
  --router-ip 172.16.215.83 \
  --mihomo ./mihomo \
  --config ./config.yaml \
  --network-optim-level balanced
```

可用参数：

| 参数 | 说明 | 默认值 |
| --- | --- | --- |
| `--iface IFACE` | LAN 接口；未提供时根据默认路由检测 | 自动检测 |
| `--lan-cidr CIDR` | LAN IPv4 网段 | 自动检测 |
| `--router-ip IP` | 旁路由在 LAN 接口上的固定 IPv4 地址 | 自动检测 |
| `--debian-ip IP` | `--router-ip` 的兼容参数名 | 自动检测 |
| `--mihomo PATH` | mihomo 二进制路径 | `./mihomo` |
| `--config PATH` | mihomo 配置路径 | `./config.yaml` |
| `--tproxy-port PORT` | TProxy 监听端口 | `7894` |
| `--dns-port PORT` | mihomo DNS 监听端口 | `1053` |
| `--network-optim-level LEVEL` | `conservative`、`balanced` 或 `aggressive` | `balanced` |

安装前脚本会检查接口、IPv4 地址、CIDR、端口、二进制和配置文件。安装过程会备份现有 mihomo、systemd、路由和 iptables 状态，然后安装依赖、生成服务并依次重启策略路由、mihomo 和 iptables 服务。

安装完成后，将局域网客户端的默认网关和 DNS 都设置为旁路由的固定 LAN 地址，再让客户端重新获取 DHCP 租约或重新连接网络。

## 常用命令

```bash
# 查看 systemd、策略路由、监听端口、iptables 和 TCP 优化状态
sudo ./deploy-mihomo.sh status

# 备份现有 mihomo、systemd、路由和 iptables 状态
sudo ./deploy-mihomo.sh backup

# 删除 sidecat 创建的服务、规则和 sysctl，并恢复 TCP 参数
sudo ./deploy-mihomo.sh uninstall
```

备份文件保存在 `/root/mihomo-backup/mihomo-*.tar.gz`。

卸载会保留以下内容：

- `/etc/mihomo/config.yaml`
- `/usr/local/bin/mihomo`

## 安装内容

| 路径 | 用途 |
| --- | --- |
| `/usr/local/bin/mihomo` | mihomo 二进制 |
| `/etc/mihomo/config.yaml` | 规范化后的运行配置 |
| `/usr/local/sbin/mihomo-iptables` | TProxy、DNS、转发和 SNAT 规则管理 |
| `/etc/default/mihomo-iptables` | 接口、地址、端口和 mark 参数 |
| `/etc/systemd/system/mihomo.service` | mihomo 服务 |
| `/etc/systemd/system/mihomo-routing.service` | fwmark 策略路由 |
| `/etc/systemd/system/mihomo-iptables.service` | iptables 生命周期 |
| `/etc/sysctl.d/99-mihomo.conf` | 转发、反向路径检查和 TCP 参数 |
| `/etc/modules-load.d/mihomo-tproxy.conf` | TProxy 和 CUBIC 模块 |
| `/var/lib/mihomo-deploy/network-optim-backup.conf` | 首次安装前的 TCP 参数备份 |

## 网络优化档位

默认使用 `balanced`。三档只调整 TCP Fast Open、ECN、socket 缓冲区、TCP 缓冲区、`tcp_notsent_lowat` 和 CUBIC HyStart，不会切换 BBR 或修改拥塞控制算法。

| 档位 | 适用场景 |
| --- | --- |
| `conservative` | 内存较小，或希望尽量接近系统默认行为 |
| `balanced` | 通用旁路由，默认推荐 |
| `aggressive` | 高吞吐、大内存且已经完成压力验证的环境 |

首次安装会保存原始内核参数。重复安装不会覆盖这份备份；卸载时只有全部参数恢复成功才会删除备份文件。

## PROCESS-NAME 规则

mihomo 服务拥有读取本机进程 socket 和可执行文件信息所需的 `CAP_SYS_PTRACE` 与 `CAP_DAC_READ_SEARCH`。因此，`PROCESS-NAME` 可以匹配旁路由本机应用产生的连接。

局域网客户端经过 TProxy 送到旁路由时，不会携带客户端设备上的进程信息。sidecat 无法使用 `PROCESS-NAME` 匹配其他电脑、手机或游戏机上的应用；这些流量应使用域名、IP、端口、规则集等条件匹配。

## 运行验证

安装后检查三个服务：

```bash
sudo systemctl --no-pager --full status \
  mihomo.service \
  mihomo-routing.service \
  mihomo-iptables.service
```

检查策略路由：

```bash
ip rule show
ip route show table 204
```

正确的策略规则应只有一条：

```text
fwmark 0xcc/0xff lookup 204
```

表 `204` 应包含：

```text
local 0.0.0.0/0 dev lo
```

检查 iptables 跳转：

```bash
sudo iptables -t mangle -S OUTPUT | grep MIHOMO_OUTPUT
sudo iptables -t mangle -S PREROUTING | grep MIHOMO
sudo iptables -t nat -S OUTPUT | grep MIHOMO_DNS
sudo iptables -t nat -S POSTROUTING | grep MIHOMO_POSTROUTING
```

检查本机公网出口、DNS 和规则计数器：

```bash
curl -4 https://ipinfo.io/ip
dig example.com
sudo /usr/local/sbin/mihomo-iptables status
```

`curl` 和 `dig` 不是部署脚本的必装依赖。Debian 的 `dig` 由 `dnsutils` 提供，Arch Linux 的 `dig` 由 `bind` 提供。

> [!NOTE]
> 停止、卸载或重启相关服务会短暂中断代理。请在允许中断业务时执行生命周期测试。

## 可选：训练 Smart 模型

`smart-trainer/` 可以从本地 CSV 数据生成 mihomo Smart/LightGBM 模型。训练环境需要 Python 3.11，以及支持 GPU/OpenCL 的 LightGBM 运行环境。

创建虚拟环境并安装依赖：

```bash
cd smart-trainer
python3 -m venv .venv
source .venv/bin/activate
python -m pip install --upgrade pip
python -m pip install -r requirements.txt
```

将包含 30 个特征列和目标列 `weight` 的数据保存为 `smart_weight_data.csv`，然后运行：

```bash
python train_flexible.py
```

成功后会在当前目录生成 `Model.bin`。如果 CSV 缺少特征、包含非数值数据、`weight` 无效，或者 GPU LightGBM 不可用，训练会失败并显示原因。

## 故障排查

### 本机流量没有进入 mihomo

依次确认：

1. `/etc/mihomo/config.yaml` 只有一个顶层 `routing-mark: 255`。
2. mangle OUTPUT 命中 `MIHOMO_OUTPUT`。
3. 公网 TCP/UDP 获得 `0xcc/0xff`。
4. `ip rule` 中只有一条正确的表 `204` 规则。
5. 表 `204` 包含 `local 0.0.0.0/0 dev lo`。
6. `lo` 上同时存在 `MIHOMO_DIVERT` 和 `MIHOMO_TPROXY`。

私网目标按设计保持直连，请使用公网地址验证透明代理。

### POSTROUTING 指向空链

检查父链跳转和自定义链：

```bash
sudo iptables -t nat -S POSTROUTING | grep MIHOMO_POSTROUTING
sudo iptables -t nat -S MIHOMO_POSTROUTING
```

如果 POSTROUTING 仍指向空链，通常是旧版本停止时没有删除完全匹配的父链跳转。重新部署当前脚本后，再执行一次服务重启和规则检查。

### 局域网 DNS 正常，但旁路由本机 DNS 失败

确认 nat OUTPUT 包含 TCP/UDP 53 到 `MIHOMO_DNS` 的跳转，同时 mangle OUTPUT 对 TCP/UDP 53 直接返回。本机 DNS 应走 REDIRECT，不应先获得 TProxy mark。

### mihomo CPU 占用高或连接回环

检查：

- `/etc/mihomo/config.yaml` 是否包含唯一的 `routing-mark: 255`。
- mangle OUTPUT 和 `MIHOMO_DNS` 是否放行 `0xff/0xff`。
- 策略路由是否错误使用了 `0xcc/0xcc`。
- `ip rule` 中是否残留重复的旧规则。

### TCP 参数无法恢复

检查 `/var/lib/mihomo-deploy/network-optim-backup.conf` 是否存在。恢复失败时脚本会保留该文件；不要用猜测的默认值覆盖它，应先根据报错恢复失败的具体参数，再重新执行卸载。
