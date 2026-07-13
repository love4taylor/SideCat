#!/usr/bin/env bash
#
# Debian 单网口旁路由：
# mihomo + redir-host DNS + iptables TProxy + 本机透明代理 + Docker 共存 + 对称回程兜底
# 修改本脚本前必须阅读同目录 AGENTS.md 中的包路径、不变量和验证要求。
#
# 用法：
#   sudo ./deploy-mihomo.sh install \
#     --iface enp2s0 \
#     --lan-cidr 172.16.0.0/16 \
#     --debian-ip 172.16.215.83 \
#     --mihomo ./mihomo \
#     --config ./config.yaml
#
# 可选命令：
#   sudo ./deploy-mihomo.sh status
#   sudo ./deploy-mihomo.sh backup
#   sudo ./deploy-mihomo.sh uninstall
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
MARK="0xcc"
MARK_MASK="0xff"
BYPASS_MARK="0xff"
BYPASS_MARK_DEC="255"
ROUTE_TABLE="204"
NETWORK_OPTIM_LEVEL="balanced"

TCP_FASTOPEN=""
TCP_ECN=""
TCP_RMEM_MAX=""
TCP_WMEM_MAX=""
TCP_RMEM=""
TCP_WMEM=""
TCP_NOTSENT_LOWAT=""

MIHOMO_DIR="/etc/mihomo"
MIHOMO_BIN_DST="/usr/local/bin/mihomo"
IPTABLES_SCRIPT="/usr/local/sbin/mihomo-iptables"
IPTABLES_DEFAULT="/etc/default/mihomo-iptables"
ROUTING_SERVICE="/etc/systemd/system/mihomo-routing.service"
IPTABLES_SERVICE="/etc/systemd/system/mihomo-iptables.service"
MIHOMO_SERVICE="/etc/systemd/system/mihomo.service"
SYSCTL_FILE="/etc/sysctl.d/99-mihomo.conf"
MODULES_FILE="/etc/modules-load.d/mihomo-tproxy.conf"
BACKUP_DIR="/root/mihomo-backup"
NETWORK_OPTIM_STATE_DIR="/var/lib/mihomo-deploy"
NETWORK_OPTIM_BACKUP="${NETWORK_OPTIM_STATE_DIR}/network-optim-backup.conf"

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
  --network-optim-level LEVEL
                         Linux TCP 优化档位：conservative、balanced、aggressive
                         默认：balanced

示例：
  sudo $0 install \\
    --iface enp2s0 \\
    --lan-cidr 172.16.0.0/16 \\
    --debian-ip 172.16.215.83 \\
    --mihomo ./mihomo \\
    --config ./config.yaml \\
    --network-optim-level balanced
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

is_ipv4() {
    local address="$1"
    local octet
    local -a octets
    local IFS=.

    read -r -a octets <<< "$address"
    [[ "${#octets[@]}" -eq 4 ]] || return 1

    for octet in "${octets[@]}"; do
        [[ "$octet" =~ ^[0-9]+$ ]] || return 1
        (( 10#$octet <= 255 )) || return 1
    done
}

is_ipv4_cidr() {
    local cidr="$1"
    local address
    local prefix

    [[ "$cidr" == */* ]] || return 1
    address="${cidr%/*}"
    prefix="${cidr##*/}"

    is_ipv4 "$address" || return 1
    [[ "$prefix" =~ ^[0-9]+$ ]] || return 1
    (( 10#$prefix <= 32 ))
}

ipv4_to_integer() {
    local address="$1"
    local first_octet
    local second_octet
    local third_octet
    local fourth_octet
    local IFS=.

    read -r first_octet second_octet third_octet fourth_octet <<< "$address"
    echo $((
        (10#$first_octet << 24) |
        (10#$second_octet << 16) |
        (10#$third_octet << 8) |
        10#$fourth_octet
    ))
}

cidr_contains_ipv4() {
    local cidr="$1"
    local address="$2"
    local network_address="${cidr%/*}"
    local prefix="${cidr##*/}"
    local address_value
    local network_value
    local mask

    address_value="$(ipv4_to_integer "$address")"
    network_value="$(ipv4_to_integer "$network_address")"

    if (( 10#$prefix == 0 )); then
        mask=0
    else
        mask=$(( (0xffffffff << (32 - 10#$prefix)) & 0xffffffff ))
    fi

    (( (address_value & mask) == (network_value & mask) ))
}

is_port() {
    local port="$1"

    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    (( 10#$port >= 1 && 10#$port <= 65535 ))
}

configure_network_optim_profile() {
    case "$NETWORK_OPTIM_LEVEL" in
        conservative)
            TCP_FASTOPEN="1"
            TCP_ECN="2"
            TCP_RMEM_MAX="8388608"
            TCP_WMEM_MAX="16777216"
            TCP_RMEM="4096 131072 8388608"
            TCP_WMEM="4096 131072 16777216"
            TCP_NOTSENT_LOWAT="65536"
            ;;
        balanced)
            TCP_FASTOPEN="3"
            TCP_ECN="1"
            TCP_RMEM_MAX="16777216"
            TCP_WMEM_MAX="33554432"
            TCP_RMEM="4096 262144 16777216"
            TCP_WMEM="4096 262144 33554432"
            TCP_NOTSENT_LOWAT="131072"
            ;;
        aggressive)
            TCP_FASTOPEN="3"
            TCP_ECN="1"
            TCP_RMEM_MAX="33554432"
            TCP_WMEM_MAX="67108864"
            TCP_RMEM="4096 524288 33554432"
            TCP_WMEM="4096 524288 67108864"
            TCP_NOTSENT_LOWAT="262144"
            ;;
        *)
            die "无效的 Linux TCP 优化档位：$NETWORK_OPTIM_LEVEL"
            ;;
    esac
}

backup_network_optim_values() {
    local temporary_backup
    local key
    local value

    if [[ -f "$NETWORK_OPTIM_BACKUP" ]]; then
        log "保留首次安装前的 Linux TCP 参数备份：$NETWORK_OPTIM_BACKUP"
        return
    fi

    mkdir -p "$NETWORK_OPTIM_STATE_DIR"
    temporary_backup="$(mktemp "${NETWORK_OPTIM_BACKUP}.XXXXXX")"
    chmod 0600 "$temporary_backup"

    for key in \
        net.ipv4.tcp_fastopen \
        net.ipv4.tcp_ecn \
        net.core.rmem_max \
        net.core.wmem_max \
        net.ipv4.tcp_rmem \
        net.ipv4.tcp_wmem \
        net.ipv4.tcp_notsent_lowat
    do
        value="$(sysctl -n "$key" 2>/dev/null || true)"
        if [[ "$value" =~ ^[0-9]+([[:space:]]+[0-9]+)*$ ]]; then
            printf '%s=%s\n' "$key" "$value" >> "$temporary_backup"
        else
            warn "无法备份 Linux TCP 参数：$key"
        fi
    done

    if [[ -r /sys/module/tcp_cubic/parameters/hystart_detect ]]; then
        value="$(< /sys/module/tcp_cubic/parameters/hystart_detect)"
        if [[ "$value" =~ ^[0-9]+$ ]]; then
            printf 'sys.module.tcp_cubic.hystart_detect=%s\n' "$value" >> "$temporary_backup"
        fi
    fi

    if [[ -s "$temporary_backup" ]]; then
        install -m 0600 "$temporary_backup" "$NETWORK_OPTIM_BACKUP"
        log "已备份安装前的 Linux TCP 参数：$NETWORK_OPTIM_BACKUP"
    else
        rm -f "$temporary_backup"
        die "未能备份任何 Linux TCP 参数，拒绝继续优化。"
    fi

    rm -f "$temporary_backup"
}

restore_network_optim_values() {
    local key
    local value
    local restore_failed=0

    if [[ ! -f "$NETWORK_OPTIM_BACKUP" ]]; then
        warn "未找到 Linux TCP 参数备份；仅删除持久配置，不修改当前运行值。"
        return
    fi

    while IFS='=' read -r key value; do
        case "$key" in
            net.ipv4.tcp_fastopen|\
            net.ipv4.tcp_ecn|\
            net.core.rmem_max|\
            net.core.wmem_max|\
            net.ipv4.tcp_rmem|\
            net.ipv4.tcp_wmem|\
            net.ipv4.tcp_notsent_lowat)
                if [[ "$value" =~ ^[0-9]+([[:space:]]+[0-9]+)*$ ]]; then
                    sysctl -w "$key=$value" >/dev/null || restore_failed=1
                else
                    warn "忽略无效的 Linux TCP 参数备份：$key"
                    restore_failed=1
                fi
                ;;
            sys.module.tcp_cubic.hystart_detect)
                if [[ "$value" =~ ^[0-9]+$ ]] \
                    && [[ -w /sys/module/tcp_cubic/parameters/hystart_detect ]]; then
                    printf '%s\n' "$value" > /sys/module/tcp_cubic/parameters/hystart_detect \
                        || restore_failed=1
                else
                    warn "无法恢复 tcp_cubic hystart_detect。"
                    restore_failed=1
                fi
                ;;
            "")
                ;;
            *)
                warn "忽略未知的 Linux TCP 参数备份键：$key"
                restore_failed=1
                ;;
        esac
    done < "$NETWORK_OPTIM_BACKUP"

    if [[ "$restore_failed" -eq 0 ]]; then
        rm -f "$NETWORK_OPTIM_BACKUP"
        rmdir "$NETWORK_OPTIM_STATE_DIR" 2>/dev/null || true
        log "已恢复安装前的 Linux TCP 参数。"
    else
        warn "部分 Linux TCP 参数恢复失败，保留备份：$NETWORK_OPTIM_BACKUP"
    fi
}

disable_mihomo_tun() {
    local config_path="$1"
    local tun_blocks
    local temporary_config

    tun_blocks="$(grep -Ec '^tun[[:space:]]*:' "$config_path" || true)"

    if [[ "$tun_blocks" -eq 0 ]]; then
        log "config.yaml 未配置 tun，保持默认禁用。"
        return
    fi

    [[ "$tun_blocks" -eq 1 ]] \
        || die "config.yaml 中检测到多个顶层 tun 配置，拒绝自动修改。"

    grep -qE '^tun[[:space:]]*:[[:space:]]*(#.*)?$' "$config_path" \
        || die "config.yaml 的 tun 必须使用块式 YAML，拒绝修改内联映射。"

    temporary_config="$(mktemp "${config_path}.XXXXXX")"

    if ! awk '
        function indentation(text, stripped) {
            stripped=text
            sub(/^[ ]+/, "", stripped)
            return length(text) - length(stripped)
        }

        function spaces(count, result) {
            result=""
            while (length(result) < count) {
                result=result " "
            }
            return result
        }

        function emit_enable() {
            print spaces(direct_indent > 0 ? direct_indent : 2) "enable: false"
        }

        BEGIN {
            in_tun=0
            direct_indent=-1
            enable_written=0
        }

        /^tun[[:space:]]*:[[:space:]]*(#.*)?$/ {
            in_tun=1
            direct_indent=-1
            enable_written=0
            print
            next
        }

        in_tun && /^[^[:space:]#]/ {
            if (!enable_written) {
                emit_enable()
            }
            in_tun=0
        }

        in_tun && !/^[[:space:]]*($|#)/ {
            current_indent=indentation($0)
            if (direct_indent < 0) {
                direct_indent=current_indent
            }

            if (current_indent == direct_indent && $0 ~ /^[[:space:]]+enable[[:space:]]*:/) {
                if (!enable_written) {
                    trailing_comment=""
                    if (match($0, /[[:space:]]+#[^#]*$/)) {
                        trailing_comment=substr($0, RSTART)
                    }
                    print spaces(direct_indent) "enable: false" trailing_comment
                    enable_written=1
                }
                next
            }
        }

        { print }

        END {
            if (in_tun && !enable_written) {
                emit_enable()
            }
        }
    ' "$config_path" > "$temporary_config"; then
        rm -f "$temporary_config"
        die "无法处理 config.yaml 中的 tun 配置。"
    fi

    install -m 0644 "$temporary_config" "$config_path"
    rm -f "$temporary_config"

    log "已强制设置 config.yaml 的 tun.enable: false。"
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
        /etc/default/mihomo-iptables \
        /etc/systemd/system/mihomo.service \
        /etc/systemd/system/mihomo-routing.service \
        /etc/systemd/system/mihomo-iptables.service \
        /etc/sysctl.d/99-mihomo.conf \
        /etc/modules-load.d/mihomo-tproxy.conf \
        /var/lib/mihomo-deploy
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
        ip route show table "$ROUTE_TABLE" > "${target}/ip-route-table-${ROUTE_TABLE}.txt" || true
    fi

    tar -C "$BACKUP_DIR" -czf "${BACKUP_DIR}/mihomo-${stamp}.tar.gz" "$stamp"

    log "备份完成：${BACKUP_DIR}/mihomo-${stamp}.tar.gz"
}

detect_network() {
    if [[ -z "$LAN_IF" ]]; then
        LAN_IF="$(ip route show default 2>/dev/null | awk '!found && /default/ {print $5; found=1}')"
    fi

    [[ -n "$LAN_IF" ]] || die "无法自动识别默认网卡，请手动指定 --iface。"

    if [[ -z "$DEBIAN_IP" ]]; then
        DEBIAN_IP="$(
            ip -4 -o addr show dev "$LAN_IF" scope global \
            | awk '!found {split($4, address, "/"); print address[1]; found=1}'
        )"
    fi

    [[ -n "$DEBIAN_IP" ]] || die "无法自动识别 $LAN_IF 的 IPv4 地址，请手动指定 --debian-ip。"

    if [[ -z "$LAN_CIDR" ]]; then
        LAN_CIDR="$(
            ip -4 route show dev "$LAN_IF" scope link proto kernel \
            | awk '!found && $1 ~ /^[0-9]+\./ {print $1; found=1}'
        )"
    fi

    [[ -n "$LAN_CIDR" ]] || die "无法自动识别 LAN 网段，请手动指定 --lan-cidr。"
}

check_input() {
    [[ -x "$MIHOMO_BIN" ]] || die "找不到可执行 mihomo 二进制：$MIHOMO_BIN"
    [[ -f "$MIHOMO_CONFIG" ]] || die "找不到 mihomo 配置文件：$MIHOMO_CONFIG"

    is_port "$TPROXY_PORT" || die "无效的 TProxy 端口：$TPROXY_PORT（必须为 1-65535）。"
    is_port "$DNS_PORT" || die "无效的 DNS 端口：$DNS_PORT（必须为 1-65535）。"
    [[ "$TPROXY_PORT" != "$DNS_PORT" ]] || die "TProxy 端口和 DNS 端口不能相同。"
    configure_network_optim_profile

    is_ipv4 "$DEBIAN_IP" || die "无效的 Debian IPv4 地址：$DEBIAN_IP"
    is_ipv4_cidr "$LAN_CIDR" || die "无效的 LAN IPv4 CIDR：$LAN_CIDR"
    cidr_contains_ipv4 "$LAN_CIDR" "$DEBIAN_IP" \
        || die "Debian IPv4 地址 $DEBIAN_IP 不属于 LAN 网段 $LAN_CIDR。"

    ip link show "$LAN_IF" >/dev/null 2>&1 || die "网卡不存在：$LAN_IF"
    ip -4 -o addr show dev "$LAN_IF" scope global \
        | awk -v expected="$DEBIAN_IP" '
            {
                split($4, address, "/")
                if (address[1] == expected) {
                    found=1
                }
            }
            END { exit !found }
        ' \
        || die "$LAN_IF 上未配置 IPv4 地址：$DEBIAN_IP"

    log "网络参数："
    log "  LAN 网卡       : $LAN_IF"
    log "  LAN 网段       : $LAN_CIDR"
    log "  Debian LAN IP  : $DEBIAN_IP"
    log "  TProxy 端口    : $TPROXY_PORT"
    log "  mihomo DNS端口 : $DNS_PORT"
    log "  TCP 优化档位   : $NETWORK_OPTIM_LEVEL"
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
        procps \
        conntrack \
        tcpdump

    command_exists iptables || die "iptables 安装失败。"
    command_exists ip || die "iproute2 安装失败。"
    command_exists sysctl || die "procps/sysctl 安装失败。"
}

install_mihomo() {
    log "安装 mihomo 和配置文件……"

    mkdir -p "$MIHOMO_DIR"

    install -m 0755 "$MIHOMO_BIN" "$MIHOMO_BIN_DST"
    install -m 0644 "$MIHOMO_CONFIG" "${MIHOMO_DIR}/config.yaml"

    # 本脚本使用 iptables TProxy；同时启用 TUN 会产生重复接管和路由冲突。
    disable_mihomo_tun "${MIHOMO_DIR}/config.yaml"

    # mihomo 自身发起的连接必须带独立 mark，避免再次进入本机透明代理。
    sed -i -E '/^routing-mark:[[:space:]]*/d' "${MIHOMO_DIR}/config.yaml"
    printf '\nrouting-mark: %s\n' "$BYPASS_MARK_DEC" >> "${MIHOMO_DIR}/config.yaml"

    "$MIHOMO_BIN_DST" -v

    if ! grep -qE "^tproxy-port:[[:space:]]*['\"]?${TPROXY_PORT}['\"]?([[:space:]]*(#.*)?)?$" \
        "${MIHOMO_DIR}/config.yaml"; then
        die "config.yaml 中未检测到顶层 tproxy-port: ${TPROXY_PORT}。"
    fi

    if ! grep -qE "^[[:space:]]*enhanced-mode:[[:space:]]*['\"]?redir-host['\"]?([[:space:]]*(#.*)?)?$" \
        "${MIHOMO_DIR}/config.yaml"; then
        die "config.yaml 中未检测到 DNS enhanced-mode: redir-host。"
    fi

    if ! grep -qE "^[[:space:]]*listen:[[:space:]]*['\"]?[^[:space:]#]*:${DNS_PORT}['\"]?([[:space:]]*(#.*)?)?$" \
        "${MIHOMO_DIR}/config.yaml"; then
        die "config.yaml 中未检测到 DNS listen 的 :${DNS_PORT}。"
    fi

    "$MIHOMO_BIN_DST" -t -d "$MIHOMO_DIR"
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
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE
ExecStartPre=/usr/local/bin/mihomo -t -d /etc/mihomo
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
    log "配置旁路由内核参数和 Linux TCP 优化（${NETWORK_OPTIM_LEVEL}）……"

    backup_network_optim_values

    cat > "$SYSCTL_FILE" <<EOF
# mihomo
# Linux TCP 参数移植自 Zephyr network_optim.rs，档位：${NETWORK_OPTIM_LEVEL}

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

# Linux TCP performance tuning
net.ipv4.tcp_fastopen=${TCP_FASTOPEN}
net.ipv4.tcp_ecn=${TCP_ECN}
net.core.rmem_max=${TCP_RMEM_MAX}
net.core.wmem_max=${TCP_WMEM_MAX}
net.ipv4.tcp_rmem=${TCP_RMEM}
net.ipv4.tcp_wmem=${TCP_WMEM}
net.ipv4.tcp_notsent_lowat=${TCP_NOTSENT_LOWAT}
EOF

    sysctl --system
    sysctl -p "$SYSCTL_FILE"

    if [[ -w /sys/module/tcp_cubic/parameters/hystart_detect ]]; then
        printf '2\n' > /sys/module/tcp_cubic/parameters/hystart_detect
    else
        warn "tcp_cubic hystart_detect 不可用，跳过 HyStart 调优。"
    fi
}

write_modules() {
    log "配置 TProxy 内核模块……"

    cat > "$MODULES_FILE" <<'EOF'
xt_socket
xt_TPROXY
nf_tproxy_ipv4
tcp_cubic
EOF

    modprobe xt_socket
    modprobe xt_TPROXY
    modprobe nf_tproxy_ipv4
    modprobe tcp_cubic 2>/dev/null || warn "无法加载 tcp_cubic，跳过 HyStart 调优。"
}

write_routing_service() {
    log "创建 TProxy 策略路由服务……"

    mkdir -p /etc/iproute2
    if [[ ! -f /etc/iproute2/rt_tables ]]; then
        if [[ -f /usr/share/iproute2/rt_tables ]]; then
            cp /usr/share/iproute2/rt_tables /etc/iproute2/rt_tables
        else
            cat > /etc/iproute2/rt_tables <<'EOT'
# reserved values
255	local
254	main
253	default
0	unspec
EOT
        fi
    fi
    grep -qE "^${ROUTE_TABLE}\s+mihomo$" /etc/iproute2/rt_tables 2>/dev/null \
        || echo "${ROUTE_TABLE} mihomo" >> /etc/iproute2/rt_tables

    cat > "$ROUTING_SERVICE" <<EOF
[Unit]
Description=Policy routing for mihomo TProxy
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot

# 每次启动先清除同规格规则，再只添加一条，避免旧版掩码或重复规则残留。
ExecStart=/bin/sh -c 'while /usr/sbin/ip rule del fwmark ${MARK}/${MARK_MASK} lookup ${ROUTE_TABLE} priority 100 2>/dev/null; do :; done; while /usr/sbin/ip rule del fwmark ${MARK}/${MARK} lookup ${ROUTE_TABLE} priority 100 2>/dev/null; do :; done; /usr/sbin/ip rule add fwmark ${MARK}/${MARK_MASK} lookup ${ROUTE_TABLE} priority 100'

# replace 可重复运行：不存在则创建，存在则更新。
ExecStart=/usr/sbin/ip route replace local 0.0.0.0/0 dev lo table ${ROUTE_TABLE}

# 每次开机重新应用 Zephyr Linux 分支的 CUBIC HyStart 设置。
ExecStart=/bin/sh -c 'if [ -w /sys/module/tcp_cubic/parameters/hystart_detect ]; then echo 2 > /sys/module/tcp_cubic/parameters/hystart_detect; fi'

ExecStop=/bin/sh -c 'while /usr/sbin/ip rule del fwmark ${MARK}/${MARK_MASK} lookup ${ROUTE_TABLE} priority 100 2>/dev/null; do :; done; while /usr/sbin/ip rule del fwmark ${MARK}/${MARK} lookup ${ROUTE_TABLE} priority 100 2>/dev/null; do :; done'
ExecStop=/usr/sbin/ip route flush table ${ROUTE_TABLE}

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
# 由 deploy-mihomo.sh 自动生成。
# 仅管理 MIHOMO_* 链；不清空 Docker 或系统已有 iptables 规则。

set -Eeuo pipefail

IPTABLES_DEFAULT="${IPTABLES_DEFAULT}"
[[ -r "\$IPTABLES_DEFAULT" ]] \\
    || { echo "Missing configuration: \$IPTABLES_DEFAULT" >&2; exit 1; }

# shellcheck disable=SC1090
source "\$IPTABLES_DEFAULT"

for required_variable in \\
    LAN_IF \\
    LAN_CIDR \\
    DEBIAN_IP \\
    TPROXY_PORT \\
    DNS_PORT \\
    MARK \\
    MARK_MASK \\
    BYPASS_MARK
do
    [[ -n "\${!required_variable:-}" ]] \\
        || { echo "Missing \$required_variable in \$IPTABLES_DEFAULT" >&2; exit 1; }
done
unset required_variable

IPT="\$(command -v iptables)"

chain_create() {
    local table="\$1"
    local chain="\$2"

    if ! "\$IPT" -t "\$table" -S "\$chain" >/dev/null 2>&1; then
        "\$IPT" -t "\$table" -N "\$chain"
    fi
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

    if "\$IPT" -t "\$table" -S "\$chain" >/dev/null 2>&1; then
        "\$IPT" -t "\$table" -F "\$chain"
        "\$IPT" -t "\$table" -X "\$chain"
    fi
}

start_rules() {
    # -------------------------
    # mangle: TProxy
    # -------------------------
    chain_create mangle MIHOMO_DIVERT
    chain_create mangle MIHOMO_TPROXY
    chain_create mangle MIHOMO_OUTPUT

    "\$IPT" -t mangle -F MIHOMO_DIVERT
    "\$IPT" -t mangle -F MIHOMO_TPROXY
    "\$IPT" -t mangle -F MIHOMO_OUTPUT

    # 已经被透明 socket 接收的 TCP 包：
    # 打 mark 后走策略路由，避免二次透明代理。
    "\$IPT" -t mangle -A MIHOMO_DIVERT \\
        -j MARK --set-xmark "\${MARK}/\${MARK_MASK}"
    "\$IPT" -t mangle -A MIHOMO_DIVERT -j ACCEPT

    # LAN 中伪装成 Debian 地址的入站包不处理；本机经 OUTPUT 标记后
    # 重路由到 lo 的包则继续进入 TProxy。
    "\$IPT" -t mangle -A MIHOMO_TPROXY -s "\$DEBIAN_IP" \\
        -m mark ! --mark "\${MARK}/\${MARK_MASK}" -j RETURN

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
        --tproxy-mark "\${MARK}/\${MARK_MASK}"

    "\$IPT" -t mangle -A MIHOMO_TPROXY -p udp \\
        -j TPROXY --on-ip 127.0.0.1 --on-port "\$TPROXY_PORT" \\
        --tproxy-mark "\${MARK}/\${MARK_MASK}"

    # mihomo 自身出站使用 BYPASS_MARK，必须在打透明代理 mark 前放行。
    "\$IPT" -t mangle -A MIHOMO_OUTPUT \\
        -m mark --mark "\${BYPASS_MARK}/\${MARK_MASK}" -j RETURN

    # 本机、私网、链路本地、组播和保留地址保持直连。
    "\$IPT" -t mangle -A MIHOMO_OUTPUT -d 0.0.0.0/8 -j RETURN
    "\$IPT" -t mangle -A MIHOMO_OUTPUT -d 10.0.0.0/8 -j RETURN
    "\$IPT" -t mangle -A MIHOMO_OUTPUT -d 127.0.0.0/8 -j RETURN
    "\$IPT" -t mangle -A MIHOMO_OUTPUT -d 169.254.0.0/16 -j RETURN
    "\$IPT" -t mangle -A MIHOMO_OUTPUT -d 172.16.0.0/12 -j RETURN
    "\$IPT" -t mangle -A MIHOMO_OUTPUT -d 192.168.0.0/16 -j RETURN
    "\$IPT" -t mangle -A MIHOMO_OUTPUT -d 224.0.0.0/4 -j RETURN
    "\$IPT" -t mangle -A MIHOMO_OUTPUT -d 240.0.0.0/4 -j RETURN

    # 本机 DNS 由 nat OUTPUT 重定向，不进入 TProxy。
    "\$IPT" -t mangle -A MIHOMO_OUTPUT -p udp --dport 53 -j RETURN
    "\$IPT" -t mangle -A MIHOMO_OUTPUT -p tcp --dport 53 -j RETURN

    # OUTPUT 中打标会触发策略路由，把本机 TCP/UDP 重路由到 lo，
    # 随后由下面的 PREROUTING(lo) 规则送入 TProxy。
    "\$IPT" -t mangle -A MIHOMO_OUTPUT -p tcp \\
        -j MARK --set-xmark "\${MARK}/\${MARK_MASK}"
    "\$IPT" -t mangle -A MIHOMO_OUTPUT -p udp \\
        -j MARK --set-xmark "\${MARK}/\${MARK_MASK}"

    # 先移除旧跳转，防止 systemd restart 后重复。
    delete_all mangle PREROUTING -i "\$LAN_IF" -p tcp -m socket --transparent -j MIHOMO_DIVERT
    delete_all mangle PREROUTING -i "\$LAN_IF" -j MIHOMO_TPROXY
    delete_all mangle PREROUTING -i lo -p tcp -m socket --transparent -j MIHOMO_DIVERT
    delete_all mangle PREROUTING -i lo -m mark --mark "\${MARK}/\${MARK_MASK}" -j MIHOMO_TPROXY
    delete_all mangle OUTPUT -j MIHOMO_OUTPUT

    # TPROXY 先插入，再把 DIVERT 插入第 1 条，最终顺序为
    # DIVERT -> TPROXY；lo 规则接收本机 OUTPUT 重路由的流量。
    "\$IPT" -t mangle -I PREROUTING 1 -i "\$LAN_IF" -j MIHOMO_TPROXY
    "\$IPT" -t mangle -I PREROUTING 1 -i "\$LAN_IF" -p tcp -m socket --transparent -j MIHOMO_DIVERT
    "\$IPT" -t mangle -I PREROUTING 1 -i lo -m mark --mark "\${MARK}/\${MARK_MASK}" -j MIHOMO_TPROXY
    "\$IPT" -t mangle -I PREROUTING 1 -i lo -p tcp -m socket --transparent -j MIHOMO_DIVERT
    "\$IPT" -t mangle -A OUTPUT -j MIHOMO_OUTPUT

    # -------------------------
    # nat: DNS Redirect
    # -------------------------
    chain_create nat MIHOMO_DNS
    "\$IPT" -t nat -F MIHOMO_DNS

    "\$IPT" -t nat -A MIHOMO_DNS \\
        -m mark --mark "\${BYPASS_MARK}/\${MARK_MASK}" -j RETURN
    "\$IPT" -t nat -A MIHOMO_DNS -p udp --dport 53 \\
        -j REDIRECT --to-ports "\$DNS_PORT"
    "\$IPT" -t nat -A MIHOMO_DNS -p tcp --dport 53 \\
        -j REDIRECT --to-ports "\$DNS_PORT"

    delete_all nat PREROUTING -i "\$LAN_IF" ! -s "\$DEBIAN_IP" -p udp --dport 53 -j MIHOMO_DNS
    delete_all nat PREROUTING -i "\$LAN_IF" ! -s "\$DEBIAN_IP" -p tcp --dport 53 -j MIHOMO_DNS
    delete_all nat OUTPUT -p udp --dport 53 -j MIHOMO_DNS
    delete_all nat OUTPUT -p tcp --dport 53 -j MIHOMO_DNS

    "\$IPT" -t nat -I PREROUTING 1 -i "\$LAN_IF" ! -s "\$DEBIAN_IP" -p udp --dport 53 -j MIHOMO_DNS
    "\$IPT" -t nat -I PREROUTING 1 -i "\$LAN_IF" ! -s "\$DEBIAN_IP" -p tcp --dport 53 -j MIHOMO_DNS
    "\$IPT" -t nat -I OUTPUT 1 -p udp --dport 53 -j MIHOMO_DNS
    "\$IPT" -t nat -I OUTPUT 1 -p tcp --dport 53 -j MIHOMO_DNS

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
    delete_all mangle PREROUTING -i lo -p tcp -m socket --transparent -j MIHOMO_DIVERT
    delete_all mangle PREROUTING -i lo -m mark --mark "\${MARK}/\${MARK_MASK}" -j MIHOMO_TPROXY
    delete_all mangle OUTPUT -j MIHOMO_OUTPUT

    delete_all nat PREROUTING -i "\$LAN_IF" ! -s "\$DEBIAN_IP" -p udp --dport 53 -j MIHOMO_DNS
    delete_all nat PREROUTING -i "\$LAN_IF" ! -s "\$DEBIAN_IP" -p tcp --dport 53 -j MIHOMO_DNS
    delete_all nat OUTPUT -p udp --dport 53 -j MIHOMO_DNS
    delete_all nat OUTPUT -p tcp --dport 53 -j MIHOMO_DNS

    delete_all nat POSTROUTING -o "\$LAN_IF" -s "\$LAN_CIDR" -j MIHOMO_POSTROUTING

    delete_all filter DOCKER-USER -j MIHOMO_FORWARD
    delete_all filter FORWARD -j MIHOMO_FORWARD

    chain_remove mangle MIHOMO_DIVERT
    chain_remove mangle MIHOMO_TPROXY
    chain_remove mangle MIHOMO_OUTPUT
    chain_remove nat MIHOMO_DNS
    chain_remove nat MIHOMO_POSTROUTING
    chain_remove filter MIHOMO_FORWARD

    echo "mihomo iptables rules removed."
}

status_rules() {
    echo "===== mangle / MIHOMO_TPROXY ====="
    "\$IPT" -t mangle -L MIHOMO_TPROXY -n -v 2>/dev/null || true
    echo

    echo "===== mangle / MIHOMO_OUTPUT ====="
    "\$IPT" -t mangle -L MIHOMO_OUTPUT -n -v 2>/dev/null || true
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

write_iptables_defaults() {
    local temporary_defaults

    log "创建 iptables 参数文件……"

    mkdir -p "$(dirname "$IPTABLES_DEFAULT")"
    temporary_defaults="$(mktemp)"

    {
        printf '# 由 deploy-mihomo.sh 自动生成；修改耦合参数后应重新部署。\n'
        printf 'LAN_IF=%q\n' "$LAN_IF"
        printf 'LAN_CIDR=%q\n' "$LAN_CIDR"
        printf 'DEBIAN_IP=%q\n' "$DEBIAN_IP"
        printf 'TPROXY_PORT=%q\n' "$TPROXY_PORT"
        printf 'DNS_PORT=%q\n' "$DNS_PORT"
        printf 'MARK=%q\n' "$MARK"
        printf 'MARK_MASK=%q\n' "$MARK_MASK"
        printf 'BYPASS_MARK=%q\n' "$BYPASS_MARK"
    } > "$temporary_defaults"

    install -m 0644 "$temporary_defaults" "$IPTABLES_DEFAULT"
    rm -f "$temporary_defaults"
}

write_iptables_service() {
    log "创建 iptables systemd 服务……"

    cat > "$IPTABLES_SERVICE" <<'EOF'
[Unit]
Description=iptables TProxy, local traffic, DNS redirect and SNAT rules for mihomo
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
    echo "===== Linux TCP optimization ====="
    if [[ -f "$SYSCTL_FILE" ]]; then
        grep -E '^# Linux TCP 参数移植自 Zephyr' "$SYSCTL_FILE" || true
    fi
    sysctl \
        net.ipv4.tcp_fastopen \
        net.ipv4.tcp_ecn \
        net.core.rmem_max \
        net.core.wmem_max \
        net.ipv4.tcp_rmem \
        net.ipv4.tcp_wmem \
        net.ipv4.tcp_notsent_lowat || true
    if [[ -r /sys/module/tcp_cubic/parameters/hystart_detect ]]; then
        printf 'net.ipv4.tcp_cubic.hystart_detect = '
        command cat /sys/module/tcp_cubic/parameters/hystart_detect
    fi

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

    while ip rule del fwmark "${MARK}/${MARK_MASK}" lookup "$ROUTE_TABLE" priority 100 2>/dev/null; do :; done
    while ip rule del fwmark "${MARK}/${MARK}" lookup "$ROUTE_TABLE" priority 100 2>/dev/null; do :; done
    ip route flush table "$ROUTE_TABLE" 2>/dev/null || true

    if [[ -f /etc/iproute2/rt_tables ]]; then
        sed -i -E "/^${ROUTE_TABLE}[[:space:]]+mihomo([[:space:]]|$)/d" /etc/iproute2/rt_tables
    fi

    rm -f "$SYSCTL_FILE"
    restore_network_optim_values

    rm -f \
        "$ROUTING_SERVICE" \
        "$IPTABLES_SERVICE" \
        "$MIHOMO_SERVICE" \
        "$MODULES_FILE" \
        "$IPTABLES_SCRIPT" \
        "$IPTABLES_DEFAULT"

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
            --network-optim-level)
                NETWORK_OPTIM_LEVEL="${2:?--network-optim-level 缺少参数}"
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
            write_modules
            write_sysctl
            write_routing_service
            write_iptables_defaults
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
