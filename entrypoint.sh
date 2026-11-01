#!/usr/bin/env bash
#
# kali-relay entrypoint
#
# 职责（且只有这些）：
#   1. 校验 TARGET_IP
#   2. 打开 net.ipv4.conf.all.route_localnet
#   3. 在 nat/OUTPUT 上建立透明 DNAT：127.0.0.0/8(除 127.0.0.11) -> TARGET_IP，端口 1:1 不变
#   4. 在 nat/POSTROUTING 上建立回程 SNAT（MASQUERADE），否则源地址仍是 127.0.0.1，出不了本机
#   5. 在 filter/OUTPUT 上建立兜底规则：未被 DNAT 的 127/8 流量一律丢弃
#   6. exec tail -f /dev/null 保持容器常驻
#
# 本脚本**不会**执行用户命令；用户命令一律通过 `docker exec` 进入容器执行。
#
set -Eeuo pipefail

LOG_PREFIX='[kali-relay]'

log() { printf '%s %s\n' "$LOG_PREFIX" "$*"; }
warn() { printf '%s WARN: %s\n' "$LOG_PREFIX" "$*" >&2; }
die() {
    printf '%s ERROR: %s\n' "$LOG_PREFIX" "$*" >&2
    exit 1
}

TARGET_IP="${TARGET_IP:-}"
# Docker 内置 DNS 的固定地址，必须绕开 DNAT，否则容器内无法解析域名。
DOCKER_DNS_ADDR='127.0.0.11'
RELAY_CIDR='127.0.0.0/8'

CHAIN_NAT='KALI-RELAY'
CHAIN_POST='KALI-RELAY-POST'
CHAIN_FILTER='KALI-RELAY-OUT'

# ---------------------------------------------------------------- 参数校验 ---

[[ -n "$TARGET_IP" ]] || die "环境变量 TARGET_IP 未设置（例：docker run -e TARGET_IP=198.51.100.10 ...）"

if [[ ! "$TARGET_IP" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
    die "TARGET_IP 不是合法的 IPv4 地址: $TARGET_IP"
fi

for octet in "${BASH_REMATCH[@]:1}"; do
    if ((octet > 255)); then
        die "TARGET_IP 存在越界八位组: $TARGET_IP"
    fi
done

case "$TARGET_IP" in
127.* | 0.*)
    die "TARGET_IP 不能是 $TARGET_IP：回环/未指定地址会造成转发环路"
    ;;
esac

# ---------------------------------------------------------------- sysctl ---

# 容器内 /proc/sys 通常是只读的，正确做法是启动时用 --sysctl 传入
# （start-relay.ps1 / docker-compose.yml 都已声明）。
# 这里先读后写：已经是期望值就跳过；写不进去只告警，不中断容器启动。
ensure_sysctl() {
    local key="$1" want="$2" path current

    path="/proc/sys/${key//.//}"
    current="$(cat "$path" 2>/dev/null || echo '')"

    if [[ "$current" == "$want" ]]; then
        return 0
    fi

    if printf '%s\n' "$want" >"$path" 2>/dev/null; then
        return 0
    fi

    if command -v sysctl >/dev/null 2>&1 && sysctl -q -w "${key}=${want}" >/dev/null 2>&1; then
        return 0
    fi

    warn "$key 当前为 '${current:-未知}'，写不进去（容器内 /proc/sys 只读）"
    return 1
}

# 说明：把 127/8 当作转发目标时需要 route_localnet=1（否则内核按 martian 丢弃）。
if ! ensure_sysctl net.ipv4.conf.all.route_localnet 1; then
    warn "请在启动容器时加上: --sysctl net.ipv4.conf.all.route_localnet=1"
fi
ensure_sysctl net.ipv4.conf.default.route_localnet 1 || true

# ---------------------------------------------------------------- iptables ---

ipt() { iptables -w 5 "$@"; }

ensure_chain() {
    local table="$1" chain="$2"
    if ipt -t "$table" -n -L "$chain" >/dev/null 2>&1; then
        ipt -t "$table" -F "$chain"
    else
        ipt -t "$table" -N "$chain"
    fi
}

ensure_jump() {
    local table="$1" parent="$2" chain="$3"
    if ! ipt -t "$table" -C "$parent" -j "$chain" >/dev/null 2>&1; then
        ipt -t "$table" -I "$parent" 1 -j "$chain"
    fi
}

# --- nat 表：透明 DNAT（端口 1:1，不改变端口） ---
ensure_chain nat "$CHAIN_NAT"
ensure_jump nat OUTPUT "$CHAIN_NAT"

ipt -t nat -A "$CHAIN_NAT" -s "${DOCKER_DNS_ADDR}/32" -j RETURN
ipt -t nat -A "$CHAIN_NAT" -d "${DOCKER_DNS_ADDR}/32" -j RETURN
ipt -t nat -A "$CHAIN_NAT" -d "$RELAY_CIDR" -p tcp -j DNAT --to-destination "$TARGET_IP"
ipt -t nat -A "$CHAIN_NAT" -d "$RELAY_CIDR" -p udp -j DNAT --to-destination "$TARGET_IP"
ipt -t nat -A "$CHAIN_NAT" -d "$RELAY_CIDR" -p icmp -j DNAT --to-destination "$TARGET_IP"

# --- nat 表：回程 SNAT（关键，不能省） ---
# DNAT 只改目的地址，源地址仍然是 127.0.0.1。源地址为 127/8 的包无法从 eth0 发出、
# 目标主机也无法把回包送回，必须对"去往 TARGET_IP"的报文做 MASQUERADE，
# 让它以容器自身地址出网（目标侧看到的源地址就是容器 IP）。
ensure_chain nat "$CHAIN_POST"
ensure_jump nat POSTROUTING "$CHAIN_POST"
ipt -t nat -A "$CHAIN_POST" -d "$TARGET_IP" -j MASQUERADE

# --- filter 表：兜底隔离（任何漏过 DNAT 的 127/8 流量一律丢弃） ---
ensure_chain filter "$CHAIN_FILTER"
ensure_jump filter OUTPUT "$CHAIN_FILTER"

# 说明：Docker 内置 DNS(127.0.0.11) 的**回包**是"源 127.0.0.11、目的 127.0.0.1"，
# 它由容器网络命名空间内的 dockerd 解析器发出，同样会经过这里的 OUTPUT 规则。
# 两条 -s RETURN 必须保留，否则 DNS 回包会被 DNAT / 丢弃，容器内域名解析全部失败。
ipt -A "$CHAIN_FILTER" -s "${DOCKER_DNS_ADDR}/32" -j RETURN
ipt -A "$CHAIN_FILTER" -d "${DOCKER_DNS_ADDR}/32" -j RETURN
ipt -A "$CHAIN_FILTER" -d "$RELAY_CIDR" -j DROP

# ---------------------------------------------------------------- 启动日志 ---

log "target            : ${TARGET_IP} (port preserved 1:1)"
log "relay scope       : ${RELAY_CIDR} except ${DOCKER_DNS_ADDR}"
log "route_localnet    : $(cat /proc/sys/net/ipv4/conf/all/route_localnet)"
log "nat rules (OUTPUT)  :"
ipt -t nat -S "$CHAIN_NAT" | sed 's/^/    /'
log "nat rules (POSTROUTING) :"
ipt -t nat -S "$CHAIN_POST" | sed 's/^/    /'
log "filter rules      :"
ipt -S "$CHAIN_FILTER" | sed 's/^/    /'
log "container is up; use 'docker exec -it <container> /bin/bash' to work inside it"

exec tail -f /dev/null
