# 实测报告 / Test Report

本文件记录 **kali-relay 0.1.0** 的实际测试环境、命令与输出摘要。
所有结论均来自可重复执行的 [tests/acceptance.sh](../tests/acceptance.sh)。

- 测试时间：2026-11-01
- 结论：**核心功能全部通过**（`PASS=17 FAIL=0 SKIP=0`，另有 2 项已文档化的已知差异，见第 6 节）

## 1. 结论摘要

| # | 验收项（对应需求第七节） | 结论 | 关键证据 |
| --- | --- | --- | --- |
| 7.1 | TCP 单端口 `nc -zv 127.0.0.1 <port>` vs 直连 | ✅ 一致 | 开放/关闭端口两侧状态相同 |
| 7.2 | TCP 多端口 `nmap -sT 127.0.0.1` vs 直连 | ✅ 一致 | 开放端口集合 `22,80,443,8080` 完全相同 |
| 7.3 | SYN 扫描 `nmap -sS 127.0.0.1` | ⚠️ 已知限制 | raw SYN 报文停留在 `lo`，不会离开容器；等价结论用 `nmap -sT` |
| 7.4 | UDP 扫描 `nmap -sU 127.0.0.1` | ⚠️ 部分等价 | UDP 数据面可正常收发（`nc -u` 回显一致）；`nmap -sU` 的端口状态判定不可靠 |
| 7.5 | ICMP `ping 127.0.0.1` | ✅ 一致 | 两侧均 0% 丢包，RTT 与直连同量级 |
| 7.6 | 宿主机 `127.0.0.1:18080` 隔离 | ✅ 通过 | 容器内 `curl` 失败，宿主机 `curl` 成功 |
| 7.7 | 宿主机本地服务不受影响 | ✅ 通过 | 对照组 `curl http://127.0.0.1:18080/` 返回 200 |
| 7.8 | 容器内 DNS | ✅ 可用 | `getent hosts deb.debian.org` 解析成功 |
| 7.9 | 常驻与规则持久性 | ✅ 通过 | 连续多次 `docker exec` 正常，规则链保持 |
| 7.10 | `-Update` 更新流程 | ✅ 通过 | `docker pull` → `--no-cache` 重建（49s）→ 重建容器 → 规则恢复 |
| 7.11 | 隐私扫描 | ✅ 通过 | 17 个文件，0 处命中（第 8 节） |
| 7.12 | `iptables-save` 与 conntrack | ✅ 已记录 | 第 7、8 节原始输出 |

## 2. 测试环境

| 项目 | 值 |
| --- | --- |
| 宿主机 | Windows 11（10.0.26300） |
| Docker 引擎 | Docker Engine 28.5.2（`28.5.2+dfsg4`），运行在 WSL2 的 Kali 分发版内 |
| 内核 | `6.6.87.2-microsoft-standard-WSL2`（x86_64） |
| Docker Compose | v2.40.3-3 |
| 基础镜像 | `kalilinux/kali-rolling@sha256:ea20024e16833dab1a5337f5998602f3b81f8a38f3b0995dda272c83a1b0c1b9` |
| 项目镜像 | `kali-relay:latest`，约 211 MB（210,976,560 字节） |
| 测试靶机 | 独立容器 `relay-test-target`，固定网段 `172.28.0.0/24` 内的 `172.28.0.10` |

说明：

- 该机器**未安装 Docker Desktop**，Docker 引擎直接运行在 WSL2 的 Kali 中；容器使用真实 Linux 内核与 netfilter，
  与 Docker Desktop（同样是 Linux 虚拟机）下的容器语义一致。
- `start-relay.ps1` 分别用两种方式验证：
  1. Windows 侧的 `docker` CLI（连接远端 daemon）——验证脚本的参数解析、容器生命周期、镜像构建；
  2. WSL2 内的 PowerShell 7.6.9 + 原生 `docker` CLI——验证 `-Status`/`-Cmd` 的完整输出（见第 4 节）。
- 靶机用独立容器模拟"远端服务器"，它与 relay 容器同处一个固定网段，DNAT 语义与真实远端一致；
  本机对公网 443 的部分域名被阻断，故不使用公网真实主机做可重复断言。

## 3. 测试方法

```bash
# 1) 构建并常驻启动（目标为本地靶机）
pwsh ./start-relay.ps1 -t 172.28.0.10

# 2) 靶机会自动创建在 172.28.0.10，然后逐项对比
bash tests/acceptance.sh --fixture
```

验收脚本对每一项做"容器内访问 `127.0.0.1`"与"直接访问 `<TARGET_IP>`"的同组对比，
不一致会记为 `FAIL`；已被证实无法等价的项记为 `INFO` 并附原因。

## 4. 逐项结果（原始输出摘要）

### 7.1 TCP 单端口

```text
$ docker exec kali-relay nc -zv -w 3 127.0.0.1 80
localhost [127.0.0.1] 80 (http) open
$ docker exec kali-relay nc -zv -w 3 172.28.0.10 80
relay-test-target.kali-relay-net [172.28.0.10] 80 (http) open

$ docker exec kali-relay nc -zv -w 3 127.0.0.1 9999
localhost [127.0.0.1] 9999 (?) : Connection refused
$ docker exec kali-relay nc -zv -w 3 172.28.0.10 9999
172.28.0.10 [172.28.0.10] 9999 (?) : Connection refused
```

### 7.2 TCP 多端口（nmap -sT）

```text
$ docker exec kali-relay nmap -sT -Pn -p 22,80,443,8080,9999 127.0.0.1
PORT     STATE  SERVICE
22/tcp   open   ssh
80/tcp   open   http
443/tcp  open   https
8080/tcp open   http-proxy
9999/tcp closed abyss

$ docker exec kali-relay nmap -sT -Pn -p 22,80,443,8080,9999 172.28.0.10
PORT     STATE  SERVICE
22/tcp   open   ssh
80/tcp   open   http
443/tcp  open   https
8080/tcp open   http-proxy
9999/tcp closed abyss
```

### 7.3 SYN 扫描（已知限制）

```text
$ docker exec kali-relay nmap -sS -Pn -p 22,80,443,8080 127.0.0.1
PORT     STATE    SERVICE
22/tcp   filtered ssh
80/tcp   filtered http
443/tcp  filtered https
8080/tcp filtered http-proxy

$ docker exec kali-relay nmap -sS -Pn -p 22,80,443,8080 172.28.0.10
PORT     STATE  SERVICE
22/tcp   open   ssh
80/tcp   open   http
443/tcp  open   https
8080/tcp open   http-proxy
```

原因（实测定位，非猜测）：

```text
$ docker exec kali-relay nmap -sS -Pn -p 80 127.0.0.1     # 扫描前后对比链路计数器
   nat 规则 DNAT 计数 +2          ← 报文确实命中了 DNAT
   nat POSTROUTING MASQUERADE +2  ← 也完成了 SNAT
   lo  RX 包数 +2                 ← 但从 lo 发出
   eth0 TX 包数 不变              ← 没有从 eth0 发出
```

`nmap -sS` 使用原始套接字直接构造报文，内核在 netfilter 之前已按目的地址 `127.0.0.1`
选定 `lo` 路由；DNAT 改写目的地址后不会为这类报文重新选路，因此 SYN 停留在 `lo` 上被丢弃。
（`iptables` 不允许在 `nat/OUTPUT` 使用 `SNAT`，实测返回 `RULE_INSERT failed (Invalid argument)`，
所以无法在选路前把源地址改掉。）

**替代方案**：`nmap -sT`（connect 扫描，结果与直连完全一致），或直接对 `<TARGET_IP>` 做 `-sS`。

### 7.4 UDP（部分等价）

数据面等价——UDP 双向正常：

```text
$ docker exec kali-relay sh -c "echo hello-udp | nc -u -w 2 127.0.0.1 161"
udp-relay-ok
$ docker exec kali-relay sh -c "echo hello-udp | nc -u -w 2 172.28.0.10 161"
udp-relay-ok
```

但 `nmap -sU` 的**端口状态判定**不可靠（同样是原始套接字探测 + 依赖 ICMP 端口不可达回传）：

```text
$ docker exec kali-relay nmap -sU -Pn -p 161,162 127.0.0.1
161/udp open|filtered snmp
162/udp open|filtered snmptrap

$ docker exec kali-relay nmap -sU -Pn -p 161,162 172.28.0.10
161/udp open   snmp
162/udp closed snmptrap
```

**结论**：UDP 业务可用；UDP 端口扫描的状态判定请以直连目标为准。

### 7.5 ICMP

```text
$ docker exec kali-relay sh -c "ping -c 2 -W 2 127.0.0.1"
2 packets transmitted, 2 received, 0% packet loss
rtt min/avg/max/mdev = 0.071/0.076/0.081/0.005 ms

$ docker exec kali-relay sh -c "ping -c 2 -W 2 172.28.0.10"
2 packets transmitted, 2 received, 0% packet loss
rtt min/avg/max/mdev = 0.043/0.110/0.177/0.067 ms
```

`ping 127.0.0.1` 实际 ping 的是目标主机（回包来自目标），因此延迟是到目标的 RTT，而不是 0.0x ms 的本机回环延迟。

### 7.6 / 7.7 宿主机回环隔离

```text
== 6. 隔离验证：宿主机 127.0.0.1:18080 不应被容器访问
  PASS 宿主机自身可访问 127.0.0.1:18080（对照组）
  PASS 容器无法访问宿主机 127.0.0.1:18080（隔离生效）
```

宿主机（Docker 主机）上 `python3 -m http.server 18080 --bind 127.0.0.1`：

- 宿主机 `curl http://127.0.0.1:18080/` → 200（对照组，本地服务未受影响）；
- 容器内 `curl http://127.0.0.1:18080/` → 非 200（失败）。

容器端口属性（不发布端口、非 host 网络）：

```text
$ docker inspect -f 'network={{.HostConfig.NetworkMode}} caps={{.HostConfig.CapAdd}} portbindings={{.HostConfig.PortBindings}}' kali-relay
network=kali-relay-net caps=[CAP_NET_ADMIN CAP_NET_RAW] portbindings=map[]
$ docker port kali-relay          # 空输出 = 未向宿主机发布任何端口
```

### 7.8 DNS

```text
== 7. DNS：容器内域名解析
  PASS 容器内可解析 deb.debian.org
  PASS 配置使用了 Docker 内置 DNS 127.0.0.11
  PASS 规则已对 127.0.0.11 放行（RETURN）

$ docker exec kali-relay getent hosts example.org
2606:4700:10::ac42:9ded example.org
$ docker exec kali-relay curl -s -o /dev/null -w '%{http_code}' https://mirrors.tuna.tsinghua.edu.cn/
200
```

> 调试记录：Docker 内置 DNS 不是"只收不发"的单向监听，它的**回包**是
> "源 `127.0.0.11`、目的 `127.0.0.1`"，同样经过容器的 `net/OUTPUT`。
> 只写 `-d 127.0.0.11 -j RETURN` 时 DNS 查询能发出、回包却被 DNAT/丢弃，
> 表现为"容器内域名解析超时"。因此 nat 与 filter 都需要 `-s 127.0.0.11/32 -j RETURN`。

### 7.9 常驻

```text
== 8. 常驻验证：多次 docker exec + 规则持续生效
  PASS 连续 3 次 docker exec 均正常
  PASS 容器保持运行（running）
  PASS DNAT 规则仍指向 172.28.0.10
```

另外观察到：WSL2 分发版重启导致 Docker 守护进程重启后，容器凭 `--restart unless-stopped`
自动恢复，`entrypoint.sh` 重新下发规则，转发能力自动恢复（无需人工干预）。

### 7.10 `-Update`

```text
[start-relay] 更新模式：docker pull kalilinux/kali-rolling:latest
latest: Pulling from kalilinux/kali-rolling
Digest: sha256:ea20024e16833dab1a5337f5998602f3b81f8a38f3b0995dda272c83a1b0c1b9
Status: Downloaded newer image for kalilinux/kali-rolling:latest   (18s)

[start-relay] 更新模式：--no-cache 重建镜像 kali-relay:latest
Successfully tagged kali-relay:latest                              (49s)

[start-relay] 创建专用 bridge 网络 kali-relay-net
[start-relay] 创建常驻容器 kali-relay -> 172.28.0.10
[start-relay] 转发规则已生效
```

不传 `-Update` 时：

```text
[start-relay] 使用本地已有镜像 kali-relay:latest（未传 -Update，不联网更新）
```

> 实测发现 `docker build --pull` 会在部分镜像源/离线环境下重新校验远端 manifest 并超时，
> 而脚本在此之前已经显式 `docker pull` 过，因此 `-Update` 只使用 `--no-cache`，不再重复 `--pull`。

### 其他脚本行为

```text
$ pwsh ./start-relay.ps1 -Status
  容器 kali-relay    : running
  目标 IP            : 172.28.0.10
  健康状态           : healthy
  端口发布           : 无（未向宿主机映射任何端口）
  nat 规则           : ...（见第 7 节）
  route_localnet     : 1

$ pwsh ./start-relay.ps1 -t 172.28.0.10 -Cmd "nc -zv 127.0.0.1 80; nmap -sT -Pn -p 22,80,8080 --open 127.0.0.1 | tail -6"
localhost [127.0.0.1] 80 (http) open
PORT     STATE SERVICE
22/tcp   open  ssh
80/tcp   open  http
8080/tcp open  http-proxy

$ pwsh ./start-relay.ps1 -t 192.0.2.99
[start-relay] 警告: 现有容器目标 IP 为 172.28.0.10，与本次 -t 192.0.2.99 不一致
目标 IP 不一致，非交互环境下请追加 -Force 以自动重建容器

$ pwsh ./start-relay.ps1 -Stop
[start-relay] 停止并删除容器 kali-relay (当前状态: running)
[start-relay] 容器已删除
```

`docker compose` 路径同样验证通过（`docker compose config` 校验、`up -d` 建网络与容器、`down` 清理）：

```text
$ TARGET_IP=172.28.0.10 docker compose up -d
 Network kali-relay-net  Created
 Container kali-relay    Started
$ docker ps --format '{{.Names}} | {{.Status}}'
kali-relay | Up 6 seconds (healthy)
```

## 5. DNS 与 Docker 内置解析器

Docker 为容器注入 `nameserver 127.0.0.11`，并额外插入两条 `DOCKER_OUTPUT`/`DOCKER_POSTROUTING`
规则把 `127.0.0.11:53` 的查询转发到解析器的真实端口。本项目与这两条规则共存的方式是：

1. 规则链 `KALI-RELAY` 插在 `OUTPUT` 第 1 位，遇到 `127.0.0.11` 立即 `RETURN`（放行给 Docker 自己的规则）；
2. `KALI-RELAY-OUT`（filter）同样对 `127.0.0.11` 双向 `RETURN`；
3. 由于 `RETURN` 只是回到 `OUTPUT` 继续匹配，Docker 的 `DOCKER_OUTPUT` 仍然生效。

## 6. 已知差异汇总

| 项目 | 现象 | 原因 | 替代方案 |
| --- | --- | --- | --- |
| `nmap -sS 127.0.0.1` | 端口显示 `filtered` | raw socket 报文在 DNAT 后仍走 `lo`，不重新选路（第 4.3 节实测） | `nmap -sT`；或对真实 `<TARGET_IP>` 做 `-sS` |
| `nmap -sU 127.0.0.1` | 端口显示 `open\|filtered` | 同上，原始套接字探测 + 依赖 ICMP 回传 | UDP 业务本身可用；端口状态以直连为准 |
| `::1` | 不转发 | 本方案只处理 IPv4 回环 | 使用 `127.0.0.1` |

## 7. 规则快照（容器内 `iptables-save`）

```text
# nat
*nat
:PREROUTING ACCEPT [0:0]
:INPUT ACCEPT [0:0]
:OUTPUT ACCEPT [8:491]
:POSTROUTING ACCEPT [3:200]
:DOCKER_OUTPUT - [0:0]
:DOCKER_POSTROUTING - [0:0]
:KALI-RELAY - [0:0]
:KALI-RELAY-POST - [0:0]
-A OUTPUT -j KALI-RELAY
-A OUTPUT -d 127.0.0.11/32 -j DOCKER_OUTPUT
-A POSTROUTING -j KALI-RELAY-POST
-A POSTROUTING -d 127.0.0.11/32 -j DOCKER_POSTROUTING
-A DOCKER_OUTPUT -d 127.0.0.11/32 -p tcp -m tcp --dport 53 -j DNAT --to-destination 127.0.0.11:46677
-A DOCKER_OUTPUT -d 127.0.0.11/32 -p udp -m udp --dport 53 -j DNAT --to-destination 127.0.0.11:35162
-A DOCKER_POSTROUTING -s 127.0.0.11/32 -p tcp -m tcp --sport 46677 -j SNAT --to-source :53
-A DOCKER_POSTROUTING -s 127.0.0.11/32 -p udp -m udp --sport 35162 -j SNAT --to-source :53
-A KALI-RELAY -s 127.0.0.11/32 -j RETURN
-A KALI-RELAY -d 127.0.0.11/32 -j RETURN
-A KALI-RELAY -d 127.0.0.0/8 -p tcp -j DNAT --to-destination 172.28.0.10
-A KALI-RELAY -d 127.0.0.0/8 -p udp -j DNAT --to-destination 172.28.0.10
-A KALI-RELAY -d 127.0.0.0/8 -p icmp -j DNAT --to-destination 172.28.0.10
-A KALI-RELAY-POST -d 172.28.0.10/32 -j MASQUERADE
COMMIT

# filter
*filter
:INPUT ACCEPT [0:0]
:FORWARD ACCEPT [0:0]
:OUTPUT ACCEPT [67:4076]
:KALI-RELAY-OUT - [0:0]
-A OUTPUT -j KALI-RELAY-OUT
-A KALI-RELAY-OUT -s 127.0.0.11/32 -j RETURN
-A KALI-RELAY-OUT -d 127.0.0.11/32 -j RETURN
-A KALI-RELAY-OUT -d 127.0.0.0/8 -j DROP
COMMIT
```

## 8. conntrack 观察

一次成功的 `127.0.0.1:8080` 连接（`nc -z`）之后：

```text
$ docker exec kali-relay grep dport=8080 /proc/net/nf_conntrack
ipv4 2 tcp 6 9 CLOSE src=127.0.0.1 dst=127.0.0.1 sport=37652 dport=8080 src=172.28.0.10 dst=172.28.0.2 sport=8080 dport=37652 [ASSURED]
ipv4 2 tcp 6 9 CLOSE src=172.28.0.2  dst=172.28.0.10 sport=38790 dport=8080 src=172.28.0.10 dst=172.28.0.2 sport=8080 dport=38790 [ASSURED]
```

解读：

- 原始元组仍是 `127.0.0.1 → 127.0.0.1:8080`（容器内程序看到的目标没变）；
- 回程元组是 `172.28.0.10 ↔ 172.28.0.2`（DNAT + MASQUERADE 后的真实报文）；
- `[ASSURED]` 表示双向都已有流量，NAT 会话是通的。

DNS 会话（`127.0.0.11:53`，未被 DNAT）：

```text
ipv4 2 udp 17 17 src=127.0.0.1 dst=127.0.0.11 sport=50688 dport=53 src=127.0.0.11 dst=127.0.0.1 sport=35162 dport=50688
```

残留的 `[UNREPLIED]` 条目来自 `nmap -sS`/`-sU` 的原始套接字探测（第 4.3、4.4 节的已知限制），
以及探测被封端口时的超时，属预期现象。

## 9. 隐私扫描结果

```text
$ pwsh ./scripts/privacy-scan.ps1

扫描目录 : <项目根目录>
扫描文件 : 17
本机标识 : （运行时会打印当前机器的用户名/主机名，本报告已隐去）
结果: 未发现本机隐私信息或硬编码真实地址。
```

扫描覆盖：Windows 用户路径、Linux 家目录、本机用户名/主机名、真实邮箱、常见密钥前缀、
私钥内容、以及"非文档保留地址 / 非回环 / 非本项目测试网段"的 IPv4 地址。
文档与代码中的示例地址统一为 RFC 5737 保留地址（`192.0.2.0/24`、`198.51.100.0/24`、`203.0.113.0/24`）。

## 10. 未在本环境验证的部分

| 项目 | 说明 |
| --- | --- |
| Windows + Docker Desktop 的原生路径 | 本机未安装 Docker Desktop，脚本用"Windows docker CLI 连接远端 daemon"与"WSL2 内原生 docker CLI"两种方式验证；容器行为与 Desktop 的 Linux 虚拟机一致 |
| 桌面 Windows 的 `docker exec -it` 交互体验 | 非交互环境下脚本自动降级为 `-i`；真交互终端下的 `-it` 属标准 Docker 行为，未在本环境人工验证 |
| 公网真实远端主机 | 本机对部分公网域名/端口受限，改用固定网段内的靶机容器，保证结论可重复 |
| GitHub Actions | 已在 GitHub 上实际运行：`shellcheck`、`PSScriptAnalyzer`、`docker build + 规则冒烟测试` 三个 job 全部通过（run `41276659849`）。首次推送时 CI 暴露了三个真实问题并已修复，见第 12 节。 |

## 11. 复现方式

```bash
# 1) 构建并启动（把 172.28.0.10 换成你的目标或本地靶机）
pwsh ./start-relay.ps1 -t 172.28.0.10

# 2) 一键验收（会在 172.28.0.10 起一个靶机容器）
bash tests/acceptance.sh --fixture

# 3) 隐私扫描
pwsh ./scripts/privacy-scan.ps1
```

## 12. CI 首次运行发现并修复的问题

`ci.yml` 第一次在 GitHub 上跑就红了，暴露了三个真实问题（全部已修复，最后 run `41276659849` 全绿）：

| 问题 | 现象 | 根因 | 修复 |
| --- | --- | --- | --- |
| shellcheck 失败 | CI 用默认严重度（含 info），本地只用过 `-S warning` | `tests/acceptance.sh` 里有未使用函数、多处 `A && B \|\| C`、trap 调用的 `cleanup` 被判为未使用 | 删除死代码；`A && B \|\| C` 全部改为显式 `if/else`；对 `cleanup` 加 `SC2329` 注释（`0fa723a`） |
| DNAT 断言失败 | 冒烟测试报"规则不对" | `iptables -S` 输出的是长选项 `--to-destination`，而 `iptables-save` 才输出 `to:`；断言照抄了后者 | 改用 `--to-destination <IP>` 匹配（`bfd90d5`） |
| `route_localnet` 断言失败 | 规则明明正确却仍 exit 1 | `docker exec ... test "$(cat /proc/...)"` 中的 `$(...)` 在 **runner 主机**上展开，读到的是宿主的值 | 改为在容器内执行：`docker exec kali-relay sh -c 'test "$(cat ...)" = "1"'`（`1d1d8d1`） |

这三次失败也是"实测优先"的副产品：如果只写不跑，`ci.yml` 会一直红着。
