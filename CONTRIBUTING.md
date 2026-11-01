# 贡献指南 / Contributing

感谢你愿意改进 **kali-relay**。本文说明提交问题与代码的方式。

## 目录

- [行为准则](#行为准则)
- [报告问题](#报告问题)
- [提交代码](#提交代码)
- [代码风格](#代码风格)
- [提交信息规范](#提交信息规范)
- [测试要求](#测试要求)

## 行为准则

参与本项目即表示你同意遵守 [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md)。

## 报告问题

1. 先搜索已有的 [Issues](../../issues)，避免重复。
2. 使用 `bug_report.md` 或 `feature_request.md` 模板。
3. 请提供：
   - 操作系统与 Docker 版本（`docker version`）
   - 复现步骤与**实际输出 / 期望输出**
   - 相关日志：`docker logs kali-relay --tail 100`
   - 规则快照：`docker exec kali-relay iptables-save`

> **隐私提醒**：提交内容前请删除真实 IP、主机名、内网地址、用户名、路径、token 等信息。
> 示例请使用 RFC 5737 文档保留地址（`192.0.2.0/24`、`198.51.100.0/24`、`203.0.113.0/24`）。

## 提交代码

1. Fork 仓库并从 `main` 拉出特性分支：`feat/short-description`、`fix/short-description`。
2. 修改后确认：
   - `entrypoint.sh` 通过 `shellcheck entrypoint.sh`；
   - `start-relay.ps1` 通过 `Invoke-ScriptAnalyzer -Path ./start-relay.ps1`；
   - `docker compose config` 能正常解析；
   - 本地按 [README 的验收方法](README.md) 至少跑通 TCP / 隔离两项。
3. 提交 PR，填写 `.github/PULL_REQUEST_TEMPLATE.md`。
4. PR 描述里写清：改了什么、为什么改、如何验证。

## 代码风格

| 对象 | 约定 |
| --- | --- |
| Shell | `#!/usr/bin/env bash` + `set -Eeuo pipefail`，变量加引号，通过 shellcheck |
| PowerShell | 兼容 Windows PowerShell 5.1 与 PowerShell 7+；`[CmdletBinding()]` + 参数校验；通过 PSScriptAnalyzer |
| YAML | 2 空格缩进，键名小写，中英文之间留空格 |
| Markdown | 一个文件一个一级标题；行内代码用反引号；示例统一使用文档保留地址 |

## 提交信息规范

采用 [Conventional Commits](https://www.conventionalcommits.org/)：

```
<type>(<scope>): <subject>

[optional body]

[optional footer]
```

常见 `type`：

| type | 用途 |
| --- | --- |
| `feat` | 新功能 |
| `fix` | 缺陷修复 |
| `docs` | 仅文档 |
| `refactor` | 重构（不改变行为） |
| `perf` | 性能优化 |
| `test` | 测试相关 |
| `build` | 构建 / 依赖 |
| `ci` | CI 配置 |
| `chore` | 杂项 |

示例：

```
feat(entrypoint): 保留 127.0.0.11:53 以恢复容器内 DNS

BREAKING CHANGE: 不再支持把目标设为 127.0.0.1
```

## 测试要求

提交 PR 时请说明你实际执行过的命令与输出摘要。任何"仅改代码未验证"的 PR 都可能被要求补充验证。

安全相关问题请不要开公开 Issue，按 [SECURITY.md](SECURITY.md) 的方式私下报告。
