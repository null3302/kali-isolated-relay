---
name: Feature request
about: 提出新功能或改进建议
title: "[Feature] "
labels: ["enhancement"]
assignees: ""
---

## 需求背景

<!-- 你在什么场景下需要它？ -->

## 期望的方案

<!-- 你希望怎么用？给出命令示例，IP 请使用 198.51.100.10 之类的文档保留地址 -->

```powershell
.\start-relay.ps1 -t 198.51.100.10 -Cmd "..."
```

## 备选方案

## 影响面

- [ ] 需要改 Dockerfile
- [ ] 需要改 entrypoint.sh（iptables 规则）
- [ ] 需要改 start-relay.ps1 参数
- [ ] 需要改文档 / CI

## 补充信息

<!-- 是否与安全边界相关？是否会影响"不发布端口 / 不使用 host 网络"的约束？ -->
