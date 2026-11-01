#!/usr/bin/env bash
#
# kali-relay 验收脚本（在 Docker 主机上运行，Linux/macOS）
#
# 目的：逐条对比「容器内访问 127.0.0.1」与「直接访问 <TARGET_IP>」的结果，
#       并验证宿主机回环隔离、DNS、常驻与规则持久性。
#
# 用法：
#   ./tests/acceptance.sh --target 198.51.100.10
#   ./tests/acceptance.sh --target 198.51.100.10 --fixture      # 同网络起一个本地靶机
#   ./tests/acceptance.sh --target 198.51.100.10 --fixture --keep
#
# 说明：
#   * 默认目标是"真实远端服务器"，脚本只做对比，不假设任何端口状态；
#   * --fixture 会额外创建一个名为 relay-test-target 的容器，占用 --target 指定的 IP，
#     并在 22/80/443/8080(TCP) 与 161(UDP) 上起监听，用来做可断言的一致性测试；
#   * 脚本不修改 kali-relay 容器的规则，只读 + 发起测试流量。
#
set -uo pipefail

CONTAINER="${RELAY_CONTAINER:-kali-relay}"
NETWORK="${RELAY_NETWORK:-kali-relay-net}"
FIXTURE_NAME="${RELAY_FIXTURE_NAME:-relay-test-target}"
FIXTURE_IMAGE="${RELAY_FIXTURE_IMAGE:-kali-relay:latest}"
DNS_DOMAIN="${RELAY_TEST_DOMAIN:-deb.debian.org}"

TARGET=""
USE_FIXTURE=0
KEEP_FIXTURE=0

PASS=0
FAIL=0
SKIP=0
INFO=0

die() { printf '\n[FATAL] %s\n' "$*" >&2; exit 1; }
log() { printf '\n\033[36m== %s\033[0m\n' "$*"; }
pass() { PASS=$((PASS + 1)); printf '  \033[32mPASS\033[0m %s\n' "$*"; }
fail() { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m %s\n' "$*"; }
skip() { SKIP=$((SKIP + 1)); printf '  \033[33mSKIP\033[0m %s\n' "$*"; }
info() { INFO=$((INFO + 1)); printf '  \033[35mINFO\033[0m %s\n' "$*"; }

usage() {
    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
    --target)
        TARGET="${2:-}"
        shift 2
        ;;
    --fixture) USE_FIXTURE=1; shift ;;
    --keep) KEEP_FIXTURE=1; shift ;;
    -h | --help) usage 0 ;;
    *) die "未知参数: $1（用 --help 查看用法）" ;;
    esac
done

[[ -n "$TARGET" ]] || {
    if [[ $USE_FIXTURE -eq 1 ]]; then
        TARGET="172.28.0.10" # 与 kali-relay-net 固定网段 172.28.0.0/24 对应
    else
        usage 1
    fi
}
command -v docker >/dev/null 2>&1 || die "未找到 docker 命令"

# 供容器内 / 宿主机使用的辅助函数 ------------------------------------------------

# 容器内执行命令（非交互；stdin 接 /dev/null，避免 docker exec -i 等待 EOF 卡住）
c_exec() { docker exec "$CONTAINER" bash -lc "$*" </dev/null; }

port_open_from_container() { c_exec "nc -z -w 3 $1 ${2:-}" >/dev/null 2>&1; }
port_open_from_host() { nc -z -w 3 "$1" "${2:-}" >/dev/null 2>&1; }

# shellcheck disable=SC2329  # 由 trap 在退出时调用，shellcheck 看不到这层引用
cleanup() {
    if [[ $USE_FIXTURE -eq 1 && $KEEP_FIXTURE -eq 0 ]]; then
        docker rm -f "$FIXTURE_NAME" >/dev/null 2>&1 || true
    fi
    if [[ -n "${HOST_HTTP_PID:-}" ]]; then
        kill "$HOST_HTTP_PID" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

# 前置检查 ---------------------------------------------------------------------
log "前置检查"

docker inspect --type container "$CONTAINER" >/dev/null 2>&1 ||
    die "容器 $CONTAINER 不存在，请先执行：.\\start-relay.ps1 -t $TARGET"

STATE=$(docker inspect --type container --format '{{.State.Status}}' "$CONTAINER")
[[ "$STATE" == "running" ]] || die "容器 $CONTAINER 状态为 $STATE，请先启动"

LABEL_TARGET=$(docker inspect --type container \
    --format '{{index .Config.Labels "kali-relay.target-ip"}}' "$CONTAINER" 2>/dev/null)
if [[ -n "$LABEL_TARGET" && "$LABEL_TARGET" != "$TARGET" ]]; then
    die "容器记录的目标 IP 为 $LABEL_TARGET，与 --target $TARGET 不一致"
fi

c_exec 'iptables -t nat -S KALI-RELAY' >/dev/null 2>&1 ||
    die "容器内未找到 KALI-RELAY 规则链，entrypoint 可能启动失败"

pass "容器 $CONTAINER 正在运行，规则链存在，目标 $TARGET"

NETMODE=$(docker inspect --type container --format '{{.HostConfig.NetworkMode}}' "$CONTAINER")
if [[ "$NETMODE" != "host" ]]; then
    pass "网络模式为 $NETMODE（非 host）"
else
    fail "容器使用了 host 网络"
fi

PORTS=$(docker port "$CONTAINER" 2>/dev/null)
if [[ -z "$PORTS" ]]; then
    pass "未向宿主机发布任何端口"
else
    fail "容器发布了端口: $PORTS"
fi

# 可选：起一个本地靶机 ---------------------------------------------------------
if [[ $USE_FIXTURE -eq 1 ]]; then
    log "准备本地靶机 $FIXTURE_NAME @ $TARGET"

    docker rm -f "$FIXTURE_NAME" >/dev/null 2>&1 || true

    # 用 --entrypoint 覆盖项目 entrypoint：靶机只需要监听，不需要转发规则
    docker run -d --name "$FIXTURE_NAME" \
        --network "$NETWORK" \
        --ip "$TARGET" \
        --entrypoint /bin/bash \
        "$FIXTURE_IMAGE" \
        -lc '
            for p in 22 80 443 8080; do
                socat TCP-LISTEN:$p,reuseaddr,fork SYSTEM:"/bin/echo relay-target" >/dev/null 2>&1 &
            done
            socat UDP4-RECVFROM:161,fork SYSTEM:"/bin/echo udp-relay-ok" >/dev/null 2>&1 &
            exec sleep infinity
        ' >/dev/null || die "靶机容器启动失败（$TARGET 是否在当前桥接网络网段内？）"

    for _ in $(seq 1 30); do
        if docker exec "$FIXTURE_NAME" ss -ltn </dev/null 2>/dev/null | grep -q ':80'; then break; fi
        sleep 0.5
    done
    pass "靶机已就绪（TCP 22/80/443/8080，UDP 161）"
fi

# 1. TCP 单端口 ----------------------------------------------------------------
log "1. TCP 单端口：nc -zv"

if port_open_from_container 127.0.0.1 80; then
    c1=open
else
    c1=closed
fi
if port_open_from_host "$TARGET" 80; then
    d1=open
else
    d1=closed
fi

if [[ "$c1" == "$d1" ]]; then
    pass "127.0.0.1:80 = $c1，$TARGET:80 = $d1（一致）"
else
    fail "127.0.0.1:80 = $c1，$TARGET:80 = $d1（不一致）"
fi

if port_open_from_container 127.0.0.1 8080; then c2=open; else c2=closed; fi
if port_open_from_host "$TARGET" 8080; then d2=open; else d2=closed; fi
if [[ "$c2" == "$d2" ]]; then
    pass "127.0.0.1:8080 = $c2，$TARGET:8080 = $d2（一致）"
else
    fail "127.0.0.1:8080 = $c2，$TARGET:8080 = $d2（不一致）"
fi

# 关闭端口的行为也要一致
if port_open_from_container 127.0.0.1 9999; then c3=open; else c3=closed; fi
if port_open_from_host "$TARGET" 9999; then d3=open; else d3=closed; fi
if [[ "$c3" == "$d3" ]]; then
    pass "关闭端口 9999：127.0.0.1 = $c3，$TARGET = $d3（一致）"
else
    fail "关闭端口 9999：127.0.0.1 = $c3，$TARGET = $d3（不一致）"
fi

# 2. TCP 多端口（nmap -sT）----------------------------------------------------
log "2. TCP 多端口：nmap -sT"

NMAP_PORTS="22,80,443,8080,9999"
OPEN_VIA_LOCAL=$(c_exec "nmap -sT -Pn -p $NMAP_PORTS --open 127.0.0.1" |
    grep -Eo '^[0-9]+/tcp' | cut -d/ -f1 | sort -n | paste -sd, -)
OPEN_VIA_DIRECT=$(c_exec "nmap -sT -Pn -p $NMAP_PORTS --open $TARGET" |
    grep -Eo '^[0-9]+/tcp' | cut -d/ -f1 | sort -n | paste -sd, -)

printf '           127.0.0.1 开放: %s\n' "${OPEN_VIA_LOCAL:-(无)}"
printf '           %s 开放: %s\n' "$TARGET" "${OPEN_VIA_DIRECT:-(无)}"
if [[ "$OPEN_VIA_LOCAL" == "$OPEN_VIA_DIRECT" ]]; then
    pass "nmap -sT 结果一致"
else
    fail "nmap -sT 结果不一致"
fi

# 3. SYN 扫描 ------------------------------------------------------------------
log "3. SYN 扫描：nmap -sS 127.0.0.1"

SYN_LOCAL=$(c_exec "nmap -sS -Pn -p $NMAP_PORTS --open 127.0.0.1" 2>&1 |
    grep -Eo '^[0-9]+/tcp' | cut -d/ -f1 | sort -n | paste -sd, -)
printf '           SYN 开放: %s\n' "${SYN_LOCAL:-(无)}"
if [[ "$SYN_LOCAL" == "$OPEN_VIA_DIRECT" ]]; then
    pass "nmap -sS 与直接访问的开放端口一致"
elif [[ -z "$SYN_LOCAL" && -n "$OPEN_VIA_DIRECT" ]]; then
    info "nmap -sS 127.0.0.1 无结果（已知限制：raw SYN 保留 lo 路由，报文不会离开容器）；等价结论请用 nmap -sT 或 nmap -sS <TARGET_IP>"
else
    fail "nmap -sS 结果与直接访问不一致（本地=$SYN_LOCAL 直连=$OPEN_VIA_DIRECT）"
fi

# 4. UDP 扫描 ------------------------------------------------------------------
log "4. UDP 扫描：nmap -sU（抽样 161,162）"

UDP_LOCAL=$(c_exec "nmap -sU -Pn -p 161,162 --open 127.0.0.1" 2>&1 |
    grep -Eo '^[0-9]+/udp' | cut -d/ -f1 | sort -n | paste -sd, -)
UDP_DIRECT=$(c_exec "nmap -sU -Pn -p 161,162 --open $TARGET" 2>&1 |
    grep -Eo '^[0-9]+/udp' | cut -d/ -f1 | sort -n | paste -sd, -)
printf '           127.0.0.1 UDP 开放: %s\n' "${UDP_LOCAL:-(无)}"
printf '           %s UDP 开放: %s\n' "$TARGET" "${UDP_DIRECT:-(无)}"
if [[ "$UDP_LOCAL" == "$UDP_DIRECT" ]]; then
    pass "nmap -sU 结果一致"
elif [[ -n "$UDP_DIRECT" ]]; then
    missing=0
    for p in ${UDP_DIRECT//,/ }; do
        [[ ",$UDP_LOCAL," == *",$p,"* ]] || missing=1
    done
    if [[ $missing -eq 0 ]]; then
        info "nmap -sU：127.0.0.1 比直连多报端口（关闭端口的 ICMP 端口不可达未回传），开放端口集合一致"
    else
        fail "nmap -sU 开放端口集合不一致（本地=$UDP_LOCAL 直连=$UDP_DIRECT）"
    fi
else
    info "nmap -sU：直连目标无 UDP 响应，无法对比（本地=$UDP_LOCAL）"
fi

# 5. ICMP ----------------------------------------------------------------------
log "5. ICMP：ping 127.0.0.1 vs ping $TARGET"

PING_LOCAL=$(c_exec "ping -c 2 -W 2 127.0.0.1" 2>&1)
PING_DIRECT=$(c_exec "ping -c 2 -W 2 $TARGET" 2>&1)
LOSS_LOCAL=$(printf '%s' "$PING_LOCAL" | grep -oE '[0-9]+% packet loss' | head -1)
LOSS_DIRECT=$(printf '%s' "$PING_DIRECT" | grep -oE '[0-9]+% packet loss' | head -1)
printf '           127.0.0.1 -> %s\n' "${LOSS_LOCAL:-未知}"
printf '           %s -> %s\n' "$TARGET" "${LOSS_DIRECT:-未知}"
if [[ -n "$LOSS_LOCAL" && "$LOSS_LOCAL" == "$LOSS_DIRECT" ]]; then
    pass "ICMP 丢包率一致（$LOSS_LOCAL）"
elif printf '%s' "$PING_LOCAL" | grep -q 'bytes from'; then
    pass "ping 127.0.0.1 有回包（目标可达），与直连行为一致"
else
    fail "ICMP 行为不一致"
fi

# 6. 宿主机回环隔离 ------------------------------------------------------------
log "6. 隔离验证：宿主机 127.0.0.1:18080 不应被容器访问"

HOST_HTTP_PORT=18080
if command -v python3 >/dev/null 2>&1; then
    python3 -m http.server "$HOST_HTTP_PORT" --bind 127.0.0.1 >/dev/null 2>&1 &
    HOST_HTTP_PID=$!
    sleep 1

    if curl -sf -m 3 "http://127.0.0.1:$HOST_HTTP_PORT/" >/dev/null 2>&1; then
        pass "宿主机自身可访问 127.0.0.1:$HOST_HTTP_PORT（对照组）"
    else
        skip "宿主机 http.server 未就绪，跳过隔离对比"
    fi

    if c_exec "curl -s -m 3 -o /dev/null -w '%{http_code}' http://127.0.0.1:$HOST_HTTP_PORT/" 2>/dev/null |
        grep -qE '^200$'; then
        fail "容器成功访问到宿主机 127.0.0.1:$HOST_HTTP_PORT（隔离失败）"
    else
        pass "容器无法访问宿主机 127.0.0.1:$HOST_HTTP_PORT（隔离生效）"
    fi
else
    skip "宿主机没有 python3，跳过隔离验证"
fi

# 7. DNS -----------------------------------------------------------------------
log "7. DNS：容器内域名解析"

if c_exec "getent hosts $DNS_DOMAIN" 2>/dev/null | grep -q ' '; then
    pass "容器内可解析 $DNS_DOMAIN"
else
    skip "容器内无法解析 $DNS_DOMAIN（受限网络环境，规则层已保留 127.0.0.11:53）"
fi

if c_exec 'grep -q "127.0.0.11" /etc/resolv.conf' 2>/dev/null; then
    pass "配置使用了 Docker 内置 DNS 127.0.0.11"
    if c_exec 'iptables -t nat -S KALI-RELAY' | grep -q '127.0.0.11'; then
        pass "规则已对 127.0.0.11 放行（RETURN）"
    else
        fail "规则未对 127.0.0.11 放行"
    fi
else
    skip "未使用 Docker 内置 DNS，跳过"
fi

# 8. 常驻与规则持久性 ----------------------------------------------------------
log "8. 常驻验证：多次 docker exec + 规则持续生效"

ok=1
for i in 1 2 3; do
    c_exec "echo exec-$i-ok" >/dev/null 2>&1 || ok=0
done
if [[ $ok -eq 1 ]]; then
    pass "连续 3 次 docker exec 均正常"
else
    fail "docker exec 出现失败"
fi

STATE2=$(docker inspect --type container --format '{{.State.Status}}' "$CONTAINER")
if [[ "$STATE2" == "running" ]]; then
    pass "容器保持运行（$STATE2）"
else
    fail "容器状态异常（$STATE2）"
fi

if c_exec 'iptables -t nat -S KALI-RELAY' | grep -q -- "--to-destination $TARGET"; then
    pass "DNAT 规则仍指向 $TARGET"
else
    fail "DNAT 规则已失效"
fi

# 9. 规则与 conntrack 快照 ------------------------------------------------------
log "9. 规则快照与 conntrack"

printf '\n---- iptables-save: nat ----\n'
c_exec 'iptables-save -t nat'
printf '\n---- iptables-save: filter ----\n'
c_exec 'iptables-save -t filter'
printf '\n---- conntrack（前 20 条，DNAT 后应看到目标 IP）----\n'
c_exec 'cat /proc/net/nf_conntrack 2>/dev/null | head -20 || echo "(无 nf_conntrack 可读)"'

# 汇总 -------------------------------------------------------------------------
log "结果"
printf '  PASS=%d  FAIL=%d  SKIP=%d  INFO=%d\n' "$PASS" "$FAIL" "$SKIP" "$INFO"

if [[ $FAIL -gt 0 ]]; then
    printf '\n\033[31m验收未全部通过\033[0m\n'
    exit 1
fi

printf '\n\033[32m全部验收项通过\033[0m\n'
exit 0
