#!/usr/bin/env bash
#
# Debian 单网口旁路由：
# mihomo + redir-host DNS + iptables TProxy + Docker 共存 + 对称回程兜底
#
# 用法：
#   sudo ./deploy-mihomo-sr.sh install \
#     --iface enp2s0 \
#     --lan-cidr 172.16.0.0/16 \
#     --debian-ip 172.16.215.83 \
#     --mihomo ./mihomo \
#     --config ./config.yaml
#
# 可选命令：
#   sudo ./deploy-mihomo-sr.sh status
#   sudo ./deploy-mihomo-sr.sh backup
#   sudo ./deploy-mihomo-sr.sh uninstall
#
# 注意：
# - 不会清空 iptables / nftables 规则；
# - 不会清空 Docker 的规则；
# - uninstall 仅删除本脚本创建的服务、规则和 sysctl 配置；
# - uninstall 不删除 /etc/mihomo/config.yaml，也不删除 mihomo 二进制。

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ACTION="${1:-install}"
shift || true

LAN_IF=""
LAN_CIDR=""
DEBIAN_IP=""
MIHOMO_BIN="$SCRIPT_DIR/mihomo"
MIHOMO_CONFIG="$SCRIPT_DIR/config.yaml"

TPROXY_PORT="7894"
DNS_PORT="1053"
MARK="0x1"
ROUTE_TABLE="100"

MIHOMO_DIR="/etc/mihomo"
MIHOMO_BIN_DST="/usr/local/bin/mihomo"
IPTABLES_SCRIPT="/usr/local/sbin/mihomo-iptables"
ROUTING_SERVICE="/etc/systemd/system/mihomo-routing.service"
IPTABLES_SERVICE="/etc/systemd/system/mihomo-iptables.service"
MIHOMO_SERVICE="/etc/systemd/system/mihomo.service"
SYSCTL_FILE="/etc/sysctl.d/99-mihomo-sr.conf"
MODULES_FILE="/etc/modules-load.d/mihomo-tproxy.conf"
BACKUP_DIR="/root/mihomo-sr-backup"

usage() {
    cat <<EOF
用法：
  sudo $0 install [选项]
  sudo $0 status
  sudo $0 backup
  sudo $0 uninstall

install 选项：
  --iface IFACE          LAN 实体网卡，例如 enp2s0
  --lan-cidr CIDR        LAN 网段，例如 172.16.0.0/16
  --debian-ip IP         Debian 固定 LAN IP，例如 172.16.215.83
  --mihomo PATH          mihomo 二进制路径，默认：./mihomo
  --config PATH          mihomo config.yaml 路径，默认：./config.yaml
  --tproxy-port PORT     默认：7894
  --dns-port PORT        默认：1053

示例：
  sudo $0 install \\
    --iface enp2s0 \\
    --lan-cidr 172.16.0.0/16 \\
    --debian-ip 172.16.215.83 \\
    --mihomo ./mihomo \\
    --config ./config.yaml
EOF
}

log() {
    echo -e "\033[1;32m[MIHOMO]\033[0m $*"
}

warn() {
    echo -e "\033[1;33m[WARNING]\033[0m $*" >&2
}

die() {
    echo -e "\033[1;31m[ERROR]\033[0m $*" >&2
    exit 1
}

require_root() {
    [[ "${EUID}" -eq 0 ]] || die "请使用 sudo 或 root 运行。"
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

backup_current() {
    local stamp
    stamp="$(date +%Y%m%d-%H%M%S)"
    local target="${BACKUP_DIR}/${stamp}"

    mkdir -p "$target"

    log "备份当前配置到：$target"

    for path in \
        /etc/mihomo \
        /usr/local/bin/mihomo \
        /usr/local/sbin/mihomo-iptables \
        /etc/systemd/system/mihomo.service \
        /etc/systemd/system/mihomo-routing.service \
        /etc/systemd/system/mihomo-iptables.service \
        /etc/sysctl.d/99-mihomo-sr.conf \
        /etc/modules-load.d/mihomo-tproxy.conf
    do
        if [[ -e "$path" ]]; then
            cp -a --parents "$path" "$target/"
        fi
    done

    if command_exists iptables-save; then
        iptables-save > "${target}/iptables-save.txt" || true
    fi

    if command_exists ip; then
        ip rule show > "${target}/ip-rule.txt" || true
        ip route show table 100 > "${target}/ip-route-table-100.txt" || true
    fi

    tar -C "$BACKUP_DIR" -czf "${BACKUP_DIR}/mihomo-sr-${stamp}.tar.gz" "$stamp"

    log "备份完成：${BACKUP_DIR}/mihomo-sr-${stamp}.tar.gz"
}

detect_network() {
    if [[ -z "$LAN_IF" ]]; then
        LAN_IF="$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')"
    fi

    [[ -n "$LAN_IF" ]] || die "无法自动识别默认网卡，请手动指定 --iface。"

    if [[ -z "$DEBIAN_IP" ]]; then
        DEBIAN_IP="$(
            ip -4 -o addr show dev "$LAN_IF" scope global \
            | awk '{split($4, a, "/"); print a[1]; exit}'
        )"
    fi

    [[ -n "$DEBIAN_IP" ]] || die "无法自动识别 $LAN_IF 的 IPv4 地址，请手动指定 --debian-ip。"

    if [[ -z "$LAN_CIDR" ]]; then
        LAN_CIDR="$(
            ip -4 route show dev "$LAN_IF" scope link proto kernel \
            | awk '$1 ~ /^[0-9]+\./ {print $1; exit}'
        )"
    fi

    [[ -n "$LAN_CIDR" ]] || die "无法自动识别 LAN 网段，请手动指定 --lan-cidr。"
}

check_input() {
    [[ -x "$MIHOMO_BIN" ]] || die "找不到可执行 mihomo 二进制：$MIHOMO_BIN"
    [[ -f "$MIHOMO_CONFIG" ]] || die "找不到 mihomo 配置文件：$MIHOMO_CONFIG"

    [[ "$TPROXY_PORT" =~ ^[0-9]+$ ]] || die "无效的 TProxy 端口。"
    [[ "$DNS_PORT" =~ ^[0-9]+$ ]] || die "无效的 DNS 端口。"

    ip link show "$LAN_IF" >/dev/null 2>&1 || die "网卡不存在：$LAN_IF"

    log "网络参数："
    log "  LAN 网卡       : $LAN_IF"
    log "  LAN 网段       : $LAN_CIDR"
    log "  Debian LAN IP  : $DEBIAN_IP"
    log "  TProxy 端口    : $TPROXY_PORT"
    log "  mihomo DNS端口 : $DNS_PORT"
}

install_packages() {
    log "安装依赖包……"

    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y \
        ca-certificates \
        iproute2 \
        iptables \
        kmod \
        conntrack \
        tcpdump

    command_exists iptables || die "iptables 安装失败。"
    command_exists ip || die "iproute2 安装失败。"
}

install_mihomo() {
    log "安装 mihomo 和配置文件……"

    mkdir -p "$MIHOMO_DIR"

    install -m 0755 "$MIHOMO_BIN" "$MIHOMO_BIN_DST"
    install -m 0644 "$MIHOMO_CONFIG" "${MIHOMO_DIR}/config.yaml"

    "$MIHOMO_BIN_DST" -v || true

    if ! grep -qE '^[[:space:]]*tproxy-port:[[:space:]]*'"$TPROXY_PORT"'([[:space:]]|$)' \
        "${MIHOMO_DIR}/config.yaml"; then
        warn "config.yaml 中未检测到 tproxy-port: ${TPROXY_PORT}。请确认配置与脚本端口一致。"
    fi

    if ! grep -qE '^[[:space:]]*enhanced-mode:[[:space:]]*redir-host([[:space:]]|$)' \
        "${MIHOMO_DIR}/config.yaml"; then
        warn "config.yaml 中未检测到 enhanced-mode: redir-host。请确认你确实要使用 redir-host。"
    fi

    if ! grep -qE '^[[:space:]]*listen:[[:space:]]*.*:'"$DNS_PORT"'([[:space:]]|$)' \
        "${MIHOMO_DIR}/config.yaml"; then
        warn "config.yaml 中未检测到 DNS listen 的 :${DNS_PORT}。请确认配置与脚本端口一致。"
    fi
}

write_mihomo_service() {
    log "创建 mihomo systemd 服务……"

    cat > "$MIHOMO_SERVICE" <<'EOF'
[Unit]
Description=mihomo Daemon
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
LimitNPROC=500
LimitNOFILE=1000000
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE CAP_SYS_TIME CAP_SYS_PTRACE CAP_DAC_READ_SEARCH CAP_DAC_OVERRIDE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE CAP_SYS_TIME CAP_SYS_PTRACE CAP_DAC_READ_SEARCH CAP_DAC_OVERRIDE
ExecStartPre=/usr/bin/sleep 1
ExecStart=/usr/local/bin/mihomo -d /etc/mihomo
ExecReload=/bin/kill -HUP $MAINPID
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
}

write_sysctl() {
    log "启用转发，关闭 ICMP Redirect 和 rp_filter……"

    cat > "$SYSCTL_FILE" <<EOF
# mihomo-sr

net.ipv4.ip_forward=1

# 单网口旁路由避免严格反向路径检查。
net.ipv4.conf.all.rp_filter=0
net.ipv4.conf.default.rp_filter=0
net.ipv4.conf.${LAN_IF}.rp_filter=0

# 避免 Linux 向客户端发送 ICMP Redirect，
# 否则客户端可能绕过 Debian 直接把主路由当作网关。
net.ipv4.conf.all.send_redirects=0
net.ipv4.conf.default.send_redirects=0
net.ipv4.conf.${LAN_IF}.send_redirects=0

net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.default.accept_redirects=0
net.ipv4.conf.${LAN_IF}.accept_redirects=0
EOF

    sysctl --system
}

write_modules() {
    log "配置 TProxy 内核模块……"

    cat > "$MODULES_FILE" <<'EOF'
xt_socket
xt_TPROXY
nf_tproxy_ipv4
EOF

    modprobe xt_socket
    modprobe xt_TPROXY
    modprobe nf_tproxy_ipv4
}

write_routing_service() {
    log "创建 TProxy 策略路由服务……"

    cat > "$ROUTING_SERVICE" <<EOF
[Unit]
Description=Policy routing for mihomo TProxy
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot

# 若规则已经存在则不重复添加。
# 兼容输出为 lookup 100 或 lookup mihomo 的系统。
ExecStart=/bin/sh -c '/usr/sbin/ip -o rule show | grep -qE "fwmark 0x1(/0x1)? .*lookup (100|mihomo)" || /usr/sbin/ip rule add fwmark ${MARK}/${MARK} lookup ${ROUTE_TABLE} priority 100'

# replace 可重复运行：不存在则创建，存在则更新。
ExecStart=/usr/sbin/ip route replace local 0.0.0.0/0 dev lo table ${ROUTE_TABLE}

RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
}

write_iptables_script() {
    log "创建 iptables 规则管理脚本……"

    cat > "$IPTABLES_SCRIPT" <<EOF
#!/usr/bin/env bash
#
# 由 deploy-mihomo-sr.sh 自动生成。
# 仅管理 MIHOMO_* 链；不清空 Docker 或系统已有 iptables 规则。

set -Eeuo pipefail

IPT="\$(command -v iptables)"

LAN_IF="${LAN_IF}"
LAN_CIDR="${LAN_CIDR}"
DEBIAN_IP="${DEBIAN_IP}"

TPROXY_PORT="${TPROXY_PORT}"
DNS_PORT="${DNS_PORT}"
MARK="${MARK}"

chain_create() {
    local table="\$1"
    local chain="\$2"
    "\$IPT" -t "\$table" -N "\$chain" 2>/dev/null || true
}

delete_all() {
    local table="\$1"
    local chain="\$2"
    shift 2

    while "\$IPT" -t "\$table" -C "\$chain" "\$@" 2>/dev/null; do
        "\$IPT" -t "\$table" -D "\$chain" "\$@"
    done
}

chain_remove() {
    local table="\$1"
    local chain="\$2"

    "\$IPT" -t "\$table" -F "\$chain" 2>/dev/null || true
    "\$IPT" -t "\$table" -X "\$chain" 2>/dev/null || true
}

start_rules() {
    # -------------------------
    # mangle: TProxy
    # -------------------------
    chain_create mangle MIHOMO_DIVERT
    chain_create mangle MIHOMO_TPROXY

    "\$IPT" -t mangle -F MIHOMO_DIVERT
    "\$IPT" -t mangle -F MIHOMO_TPROXY

    # 已经被透明 socket 接收的 TCP 包：
    # 打 mark 后走策略路由，避免二次透明代理。
    "\$IPT" -t mangle -A MIHOMO_DIVERT \\
        -j MARK --set-xmark "\${MARK}/\${MARK}"
    "\$IPT" -t mangle -A MIHOMO_DIVERT -j ACCEPT

    # 不处理源自 Debian 自己的异常入站流量。
    "\$IPT" -t mangle -A MIHOMO_TPROXY -s "\$DEBIAN_IP" -j RETURN

    # 不代理回环、私网、链路本地、组播、保留地址。
    "\$IPT" -t mangle -A MIHOMO_TPROXY -d 0.0.0.0/8 -j RETURN
    "\$IPT" -t mangle -A MIHOMO_TPROXY -d 10.0.0.0/8 -j RETURN
    "\$IPT" -t mangle -A MIHOMO_TPROXY -d 127.0.0.0/8 -j RETURN
    "\$IPT" -t mangle -A MIHOMO_TPROXY -d 169.254.0.0/16 -j RETURN
    "\$IPT" -t mangle -A MIHOMO_TPROXY -d 172.16.0.0/12 -j RETURN
    "\$IPT" -t mangle -A MIHOMO_TPROXY -d 192.168.0.0/16 -j RETURN
    "\$IPT" -t mangle -A MIHOMO_TPROXY -d 224.0.0.0/4 -j RETURN
    "\$IPT" -t mangle -A MIHOMO_TPROXY -d 240.0.0.0/4 -j RETURN

    # 传统 DNS 交给 nat PREROUTING 的 REDIRECT，
    # 不走 TProxy。
    "\$IPT" -t mangle -A MIHOMO_TPROXY -p udp --dport 53 -j RETURN
    "\$IPT" -t mangle -A MIHOMO_TPROXY -p tcp --dport 53 -j RETURN

    # TCP / UDP 送入 mihomo 的 tproxy-port。
    "\$IPT" -t mangle -A MIHOMO_TPROXY -p tcp \\
        -j TPROXY --on-ip 127.0.0.1 --on-port "\$TPROXY_PORT" \\
        --tproxy-mark "\${MARK}/\${MARK}"

    "\$IPT" -t mangle -A MIHOMO_TPROXY -p udp \\
        -j TPROXY --on-ip 127.0.0.1 --on-port "\$TPROXY_PORT" \\
        --tproxy-mark "\${MARK}/\${MARK}"

    # 先移除旧跳转，防止 systemd restart 后重复。
    delete_all mangle PREROUTING -i "\$LAN_IF" -p tcp -m socket --transparent -j MIHOMO_DIVERT
    delete_all mangle PREROUTING -i "\$LAN_IF" -j MIHOMO_TPROXY

    # TPROXY 先插入，再把 DIVERT 插入第 1 条，
    # 最终顺序为：DIVERT -> TPROXY。
    "\$IPT" -t mangle -I PREROUTING 1 -i "\$LAN_IF" -j MIHOMO_TPROXY
    "\$IPT" -t mangle -I PREROUTING 1 -i "\$LAN_IF" -p tcp -m socket --transparent -j MIHOMO_DIVERT

    # -------------------------
    # nat: DNS Redirect
    # -------------------------
    chain_create nat MIHOMO_DNS
    "\$IPT" -t nat -F MIHOMO_DNS

    "\$IPT" -t nat -A MIHOMO_DNS -p udp --dport 53 \\
        -j REDIRECT --to-ports "\$DNS_PORT"
    "\$IPT" -t nat -A MIHOMO_DNS -p tcp --dport 53 \\
        -j REDIRECT --to-ports "\$DNS_PORT"

    delete_all nat PREROUTING -i "\$LAN_IF" ! -s "\$DEBIAN_IP" -p udp --dport 53 -j MIHOMO_DNS
    delete_all nat PREROUTING -i "\$LAN_IF" ! -s "\$DEBIAN_IP" -p tcp --dport 53 -j MIHOMO_DNS

    "\$IPT" -t nat -I PREROUTING 1 -i "\$LAN_IF" ! -s "\$DEBIAN_IP" -p udp --dport 53 -j MIHOMO_DNS
    "\$IPT" -t nat -I PREROUTING 1 -i "\$LAN_IF" ! -s "\$DEBIAN_IP" -p tcp --dport 53 -j MIHOMO_DNS

    # -------------------------
    # nat: MASQUERADE
    # -------------------------
    # 对真正经过 Linux 转发、又未被 mihomo TProxy 接管的公网流量做 SNAT。
    #
    # 作用：
    #   客户端 -> Debian -> 主路由 -> 公网
    #   公网 -> 主路由 -> Debian -> 客户端
    #
    # 主路由因此会把回包先交给 Debian，
    # 避免直接回客户端造成非对称路由。
    chain_create nat MIHOMO_POSTROUTING
    "\$IPT" -t nat -F MIHOMO_POSTROUTING

    # 私网 / 本地网络通信不做 NAT。
    "\$IPT" -t nat -A MIHOMO_POSTROUTING -s "\$DEBIAN_IP" -j RETURN
    "\$IPT" -t nat -A MIHOMO_POSTROUTING -d 0.0.0.0/8 -j RETURN
    "\$IPT" -t nat -A MIHOMO_POSTROUTING -d 10.0.0.0/8 -j RETURN
    "\$IPT" -t nat -A MIHOMO_POSTROUTING -d 127.0.0.0/8 -j RETURN
    "\$IPT" -t nat -A MIHOMO_POSTROUTING -d 169.254.0.0/16 -j RETURN
    "\$IPT" -t nat -A MIHOMO_POSTROUTING -d 172.16.0.0/12 -j RETURN
    "\$IPT" -t nat -A MIHOMO_POSTROUTING -d 192.168.0.0/16 -j RETURN
    "\$IPT" -t nat -A MIHOMO_POSTROUTING -d 224.0.0.0/4 -j RETURN
    "\$IPT" -t nat -A MIHOMO_POSTROUTING -d 240.0.0.0/4 -j RETURN

    "\$IPT" -t nat -A MIHOMO_POSTROUTING -j MASQUERADE

    delete_all nat POSTROUTING -o "\$LAN_IF" -s "\$LAN_CIDR" -j MIHOMO_POSTROUTING
    "\$IPT" -t nat -I POSTROUTING 1 -o "\$LAN_IF" -s "\$LAN_CIDR" -j MIHOMO_POSTROUTING

    # -------------------------
    # filter: Docker 共存
    # -------------------------
    chain_create filter MIHOMO_FORWARD
    "\$IPT" -t filter -F MIHOMO_FORWARD

    "\$IPT" -t filter -A MIHOMO_FORWARD \\
        -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

    # 单网口旁路由：入、出接口都可能是 LAN_IF。
    "\$IPT" -t filter -A MIHOMO_FORWARD \\
        -i "\$LAN_IF" -o "\$LAN_IF" -s "\$LAN_CIDR" -j ACCEPT

    if "\$IPT" -t filter -L DOCKER-USER >/dev/null 2>&1; then
        delete_all filter DOCKER-USER -j MIHOMO_FORWARD
        "\$IPT" -t filter -I DOCKER-USER 1 -j MIHOMO_FORWARD
    else
        delete_all filter FORWARD -j MIHOMO_FORWARD
        "\$IPT" -t filter -I FORWARD 1 -j MIHOMO_FORWARD
    fi

    echo "mihomo iptables rules installed."
}

stop_rules() {
    delete_all mangle PREROUTING -i "\$LAN_IF" -p tcp -m socket --transparent -j MIHOMO_DIVERT
    delete_all mangle PREROUTING -i "\$LAN_IF" -j MIHOMO_TPROXY

    delete_all nat PREROUTING -i "\$LAN_IF" ! -s "\$DEBIAN_IP" -p udp --dport 53 -j MIHOMO_DNS
    delete_all nat PREROUTING -i "\$LAN_IF" ! -s "\$DEBIAN_IP" -p tcp --dport 53 -j MIHOMO_DNS

    delete_all nat POSTROUTING -o "\$LAN_IF" -s "\$LAN_CIDR" ! -s "\$DEBIAN_IP" -j MIHOMO_POSTROUTING

    delete_all filter DOCKER-USER -j MIHOMO_FORWARD
    delete_all filter FORWARD -j MIHOMO_FORWARD

    chain_remove mangle MIHOMO_DIVERT
    chain_remove mangle MIHOMO_TPROXY
    chain_remove nat MIHOMO_DNS
    chain_remove nat MIHOMO_POSTROUTING
    chain_remove filter MIHOMO_FORWARD

    echo "mihomo iptables rules removed."
}

status_rules() {
    echo "===== mangle / MIHOMO_TPROXY ====="
    "\$IPT" -t mangle -L MIHOMO_TPROXY -n -v 2>/dev/null || true
    echo

    echo "===== nat / MIHOMO_DNS ====="
    "\$IPT" -t nat -L MIHOMO_DNS -n -v 2>/dev/null || true
    echo

    echo "===== nat / MIHOMO_POSTROUTING ====="
    "\$IPT" -t nat -L MIHOMO_POSTROUTING -n -v 2>/dev/null || true
    echo

    echo "===== filter / DOCKER-USER ====="
    "\$IPT" -t filter -L DOCKER-USER -n -v 2>/dev/null || true
}

case "\${1:-}" in
    start)
        start_rules
        ;;
    stop)
        stop_rules
        ;;
    restart)
        stop_rules
        start_rules
        ;;
    status)
        status_rules
        ;;
    *)
        echo "Usage: \$0 {start|stop|restart|status}"
        exit 1
        ;;
esac
EOF

    chmod 0755 "$IPTABLES_SCRIPT"
    bash -n "$IPTABLES_SCRIPT"
}

write_iptables_service() {
    log "创建 iptables systemd 服务……"

    cat > "$IPTABLES_SERVICE" <<'EOF'
[Unit]
Description=iptables TProxy, DNS redirect and SNAT rules for mihomo
After=network-online.target mihomo-routing.service mihomo.service docker.service
Wants=network-online.target
Requires=mihomo-routing.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/mihomo-iptables start
ExecReload=/usr/local/sbin/mihomo-iptables restart
ExecStop=/usr/local/sbin/mihomo-iptables stop
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
}

start_services() {
    log "加载 systemd 服务并启动……"

    systemctl daemon-reload

    systemctl enable mihomo-routing.service
    systemctl enable mihomo.service
    systemctl enable mihomo-iptables.service

    systemctl restart mihomo-routing.service
    systemctl restart mihomo.service
    systemctl restart mihomo-iptables.service
}

show_status() {
    echo
    echo "===== systemd ====="
    systemctl --no-pager --full status \
        mihomo-routing.service \
        mihomo.service \
        mihomo-iptables.service || true

    echo
    echo "===== IPv4 forwarding ====="
    sysctl net.ipv4.ip_forward || true

    echo
    echo "===== Policy routing ====="
    ip rule show || true
    ip route show table "$ROUTE_TABLE" || true

    echo
    echo "===== mihomo listeners ====="
    ss -lntup | grep -E ":(${TPROXY_PORT}|${DNS_PORT})\\b" || true

    echo
    echo "===== iptables ====="
    if [[ -x "$IPTABLES_SCRIPT" ]]; then
        "$IPTABLES_SCRIPT" status || true
    fi
}

uninstall_all() {
    log "停止并删除本脚本创建的规则与服务……"

    systemctl disable --now mihomo-iptables.service 2>/dev/null || true
    "$IPTABLES_SCRIPT" stop 2>/dev/null || true

    systemctl disable --now mihomo-routing.service 2>/dev/null || true
    systemctl disable --now mihomo.service 2>/dev/null || true

    ip rule del fwmark "${MARK}/${MARK}" lookup "$ROUTE_TABLE" priority 100 2>/dev/null || true
    ip route flush table "$ROUTE_TABLE" 2>/dev/null || true

    rm -f \
        "$ROUTING_SERVICE" \
        "$IPTABLES_SERVICE" \
        "$MIHOMO_SERVICE" \
        "$SYSCTL_FILE" \
        "$MODULES_FILE" \
        "$IPTABLES_SCRIPT"

    systemctl daemon-reload

    log "已移除部署脚本创建的内容。"
    log "保留：$MIHOMO_DIR 和 $MIHOMO_BIN_DST"
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --iface)
                LAN_IF="${2:?--iface 缺少参数}"
                shift 2
                ;;
            --lan-cidr)
                LAN_CIDR="${2:?--lan-cidr 缺少参数}"
                shift 2
                ;;
            --debian-ip)
                DEBIAN_IP="${2:?--debian-ip 缺少参数}"
                shift 2
                ;;
            --mihomo)
                MIHOMO_BIN="${2:?--mihomo 缺少参数}"
                shift 2
                ;;
            --config)
                MIHOMO_CONFIG="${2:?--config 缺少参数}"
                shift 2
                ;;
            --tproxy-port)
                TPROXY_PORT="${2:?--tproxy-port 缺少参数}"
                shift 2
                ;;
            --dns-port)
                DNS_PORT="${2:?--dns-port 缺少参数}"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "未知参数：$1"
                ;;
        esac
    done
}

main() {
    require_root

    case "$ACTION" in
        install)
            parse_args "$@"
            detect_network
            check_input
            backup_current
            install_packages
            install_mihomo
            write_mihomo_service
            write_sysctl
            write_modules
            write_routing_service
            write_iptables_script
            write_iptables_service
            start_services

            echo
            log "部署完成。"
            show_status

            echo
            echo "下一步："
            echo "1. 主路由 DHCP 网关和 DNS 均下发为：${DEBIAN_IP}"
            echo "2. 客户端重新获取 DHCP 租约或重连 Wi-Fi。"
            echo "3. 客户端访问网站后，在 Debian 执行："
            echo "   sudo ${IPTABLES_SCRIPT} status"
            ;;
        status)
            show_status
            ;;
        backup)
            backup_current
            ;;
        uninstall)
            uninstall_all
            ;;
        -h|--help|help)
            usage
            ;;
        *)
            usage
            die "未知操作：$ACTION"
            ;;
    esac
}

main "$@"
