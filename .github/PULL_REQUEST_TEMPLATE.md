## 变更说明

<!-- 这个 PR 做了什么、为什么做 -->

## 关联 Issue

<!-- Closes #123 -->

## 变更类型

- [ ] 修复缺陷（fix）
- [ ] 新功能（feat）
- [ ] 文档（docs）
- [ ] 重构 / 性能（refactor / perf）
- [ ] 构建 / CI（build / ci）

## 如何验证

<!-- 贴出你实际执行的命令与关键输出，不要只写"已测试" -->

```text
1. docker build -t kali-relay:latest .
2. .\start-relay.ps1 -t 198.51.100.10 -Cmd "nc -zv 127.0.0.1 443"
3. ...
```

## 检查清单

- [ ] `shellcheck entrypoint.sh` 通过
- [ ] `Invoke-ScriptAnalyzer -Path ./start-relay.ps1` 通过（如有条件）
- [ ] `docker compose config` 可解析
- [ ] 已在本地跑通 TCP 转发与宿主机回环隔离两项验证
- [ ] 文档已同步更新（README / CHANGELOG）
- [ ] 未提交任何真实 IP、内网地址、路径、凭据等隐私信息
- [ ] 未引入 `network_mode: host` 或 `ports` 端口发布

## 备注

<!-- 破坏性变更、迁移说明等 -->
