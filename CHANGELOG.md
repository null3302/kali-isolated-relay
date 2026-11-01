# Changelog

本文件遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/) 格式，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [Unreleased]

## [0.1.0] - 2026-11-01

### Added

- 新增 `Dockerfile`：基于 `kalilinux/kali-rolling`，支持 `KALI_BASE_TAG` 构建参数选择基础镜像标签，
  预装 `iptables`、`iproute2`、`nmap`、`iputils-ping`、`netcat-traditional`、`curl`、`socat`、`dnsutils`、
  `conntrack`、`tcpdump` 等工具。
- 新增 `entrypoint.sh`：开启 `net.ipv4.conf.all.route_localnet`，在 `nat/OUTPUT` 建立
  `127.0.0.0/8 → TARGET_IP`（端口 1:1）透明 DNAT，保留 `127.0.0.11:53` 以维持容器内 DNS，
  并在 `filter/OUTPUT` 增加"漏网 127/8 流量一律丢弃"兜底规则；配置完成后 `exec tail -f /dev/null` 常驻。
- 新增 `start-relay.ps1`：一站式管理容器生命周期（首次构建、常驻启动、单条命令执行、交互 shell、
  状态查看、停止清理、目标 IP 变更检测、`-Update` 显式更新基础镜像）。
- 新增 `docker-compose.yml`：独立 bridge 网络、`cap_add: [NET_ADMIN, NET_RAW]`、
  `sysctls` 开启 `route_localnet`，不发布端口、不使用 host 网络。
- 新增 `README.md`：架构说明、快速开始、配置项、更新策略、安全边界、能力与限制。
- 新增开源规范文件：`LICENSE`（MIT）、`.gitignore`、`.dockerignore`、`.gitattributes`、
  `CONTRIBUTING.md`、`CODE_OF_CONDUCT.md`、`SECURITY.md`、`.github/` 下 Issue/PR 模板与 CI 工作流。
- 新增 `tests/acceptance.sh`：可重复执行的验收脚本，对比"容器内访问 `127.0.0.1`"与"直接访问目标 IP"。
- 新增 `scripts/privacy-scan.ps1`：发布前的敏感信息扫描。

### Security

- 默认不向宿主机发布任何端口，容器使用独立 bridge 网络与独立 loopback，宿主机 `127.0.0.1` 上的服务
  不会暴露给容器。
- 默认不联网更新基础镜像，只有显式 `-Update` 才会执行 `docker pull` 与 `--no-cache` 重建。

[Unreleased]: https://github.com/null3302/kali-isolated-relay/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/null3302/kali-isolated-relay/releases/tag/v0.1.0
