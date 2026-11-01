# syntax=docker/dockerfile:1
#
# kali-relay — 把容器内的 127.0.0.1 透明转发到指定远端服务器
#
# 基础镜像标签可通过构建参数 KALI_BASE_TAG 选择（默认 latest）。
# 只有在显式执行 `.\start-relay.ps1 -Update` 时，start-relay.ps1 才会先
# `docker pull` 最新基础镜像再用 --no-cache 重建；默认一律使用本地已有镜像。

ARG KALI_BASE_TAG=latest
FROM kalilinux/kali-rolling:${KALI_BASE_TAG}

LABEL org.opencontainers.image.title="kali-relay" \
      org.opencontainers.image.description="Kali container whose loopback (127.0.0.1) is transparently DNAT-ed to a remote target host, same port" \
      org.opencontainers.image.version="0.1.0" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.source="https://github.com/null3302/kali-isolated-relay"

ENV DEBIAN_FRONTEND=noninteractive \
    TARGET_IP="" \
    LANG=C.UTF-8

# 镜像内自带常用工具，避免在容器里临时联网安装。
# 说明：netcat-traditional 提供 `nc -zv`；iputils-ping 提供 ping；conntrack 用于排查。
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        iptables \
        iproute2 \
        conntrack \
        iputils-ping \
        netcat-traditional \
        curl \
        socat \
        dnsutils \
        nmap \
        ca-certificates \
        procps \
        less \
        tcpdump \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh

WORKDIR /root

# entrypoint 只负责配置转发规则并常驻，不执行任何用户命令；
# 用户命令一律通过 `docker exec` / `start-relay.ps1 -Cmd` 进入。
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

# 保持容器常驻：entrypoint 配置完规则后固定 exec tail -f /dev/null，
# 这里的 CMD 仅为可读性保留，实际不会被当作入口点执行。
CMD ["tail", "-f", "/dev/null"]
