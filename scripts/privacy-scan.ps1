#Requires -Version 5.1
<#
.SYNOPSIS
    发布前的敏感信息扫描（本机路径、用户名、主机名、邮箱、token、非文档保留地址）。

.DESCRIPTION
    扫描仓库内所有文本文件，命中下列任一模式即视为需要处理：
      * Windows 用户目录路径（如 C:\Users\<name>）
      * Linux 家目录路径（如 /home/<name>）
      * 当前机器的用户名 / 主机名
      * 真实邮箱（you@example.com 之类的占位符除外）
      * 常见密钥前缀（sk-、ghp_、github_pat_、AKIA、xox?-）
      * 非"文档保留地址 / 回环地址 / 本项目测试网段"的 IPv4 地址

    发现即返回退出码 1，可直接用于 CI 或 pre-commit。

.EXAMPLE
    pwsh ./scripts/privacy-scan.ps1

.EXAMPLE
    pwsh ./scripts/privacy-scan.ps1 -Path . -Verbose
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
    Justification = '这是面向终端的扫描报告输出，彩色提示是刻意设计')]
[CmdletBinding()]
param(
    [string]$Path = (Split-Path -Parent $PSScriptRoot)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path -LiteralPath $Path).Path

# 允许出现的 IPv4 网段（RFC 5737 文档保留地址 + 回环 + 本项目 Docker 测试网段）
$allowedIpv4Patterns = @(
    '^127\.'                      # 回环
    '^0\.0\.0\.0$'                # 未指定
    '^255\.255\.255\.255$'        # 广播
    '^192\.0\.2\.'                # TEST-NET-1
    '^198\.51\.100\.'             # TEST-NET-2
    '^203\.0\.113\.'              # TEST-NET-3
    '^172\.28\.'                  # kali-relay-net（本项目固定测试网段，非用户内网）
)

$allowedEmails = @('you@example.com', 'example.com', 'example.org', 'example.net')

$textExtensions = @(
    '.md', '.ps1', '.psm1', '.psd1', '.sh', '.bash', '.yml', '.yaml',
    '.json', '.txt', '.conf', '.cfg', '.ini', '.env', '.toml', '.xml'
)

# 需要跳过的路径（相对仓库根）
$skipRelative = @(
    '.git', 'node_modules', '__pycache__', '.venv', 'venv', 'dist', 'build',
    'scripts/privacy-scan.ps1'   # 本文件自身包含模式串，不参与扫描
    '方案.txt'                    # 本地需求草稿，已在 .gitignore 中排除，不属于仓库内容
)

$checks = @(
    @{ Name = 'Windows 用户路径'; Pattern = 'C:\\+Users\\+[^\\\s"''`]+' }
    @{ Name = 'Linux 家目录路径'; Pattern = '/home/[A-Za-z0-9._-]+' }
    @{ Name = '常见密钥前缀'; Pattern = '(sk-[A-Za-z0-9]{20,}|ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16}|xox[baprs]-[A-Za-z0-9-]{10,})' }
    @{ Name = '私钥内容'; Pattern = 'BEGIN (RSA|OPENSSH|EC|PGP) PRIVATE KEY' }
    @{ Name = '真实邮箱'; Pattern = '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' }
    @{ Name = 'IPv4 地址'; Pattern = '\b(?:\d{1,3}\.){3}\d{1,3}\b' }
)

function Test-PathSkipped {
    param([string]$FullPath)

    $relative = $FullPath.Substring($repoRoot.Length).TrimStart('\', '/').Replace('\', '/')
    foreach ($skip in $skipRelative) {
        $skipNorm = $skip.Replace('\', '/')
        if ($relative -eq $skipNorm -or $relative.StartsWith("$skipNorm/")) { return $true }
    }
    return $false
}

function Test-AllowedIpv4 {
    param([string]$Ip)

    $octets = $Ip.Split('.')
    foreach ($o in $octets) {
        if ([int]$o -gt 255) { return $true }   # 形如 999.1.1.1，不是 IP
    }
    foreach ($p in $allowedIpv4Patterns) {
        if ($Ip -match $p) { return $true }
    }
    return $false
}

$findings = New-Object System.Collections.Generic.List[object]
$scanned = 0

$identityTokens = @()
if ($env:USERNAME) { $identityTokens += $env:USERNAME }
if ($env:COMPUTERNAME) { $identityTokens += $env:COMPUTERNAME }
$identityTokens = $identityTokens | Where-Object { $_ -and $_.Length -ge 4 } | Select-Object -Unique

$files = Get-ChildItem -LiteralPath $repoRoot -Recurse -File -Force -ErrorAction SilentlyContinue |
    Where-Object { -not (Test-PathSkipped $_.FullName) }

foreach ($file in $files) {
    $ext = $file.Extension.ToLowerInvariant()
    $isSpecial = $file.Name -in @('Dockerfile', 'Makefile', '.gitignore', '.dockerignore', '.gitattributes')
    if (-not $isSpecial -and $textExtensions -notcontains $ext) { continue }

    $scanned++
    $lineNo = 0
    foreach ($line in (Get-Content -LiteralPath $file.FullName -ErrorAction SilentlyContinue)) {
        $lineNo++
        foreach ($check in $checks) {
            foreach ($m in [regex]::Matches($line, $check.Pattern)) {
                $value = $m.Value
                $isAllowed = $false

                if ($check.Name -eq 'IPv4 地址' -and (Test-AllowedIpv4 $value)) { $isAllowed = $true }
                if ($check.Name -eq 'IPv4 地址') {
                    # 形如 "6.6.87.2-microsoft-standard-WSL2" 的内核/软件版本号，不是 IP
                    $tail = $line.Substring($m.Index + $m.Length)
                    if ($tail -match '^-[A-Za-z]') { $isAllowed = $true }
                }
                if ($check.Name -eq '真实邮箱') {
                    $domain = ($value -split '@')[-1]
                    if ($allowedEmails -contains $domain -or $value -like '*@example.com') { $isAllowed = $true }
                }

                if (-not $isAllowed) {
                    $findings.Add([pscustomobject]@{
                            File    = $file.FullName.Substring($repoRoot.Length).TrimStart('\', '/')
                            Line    = $lineNo
                            Rule    = $check.Name
                            Matched = $value
                        })
                }
            }
        }

        foreach ($token in $identityTokens) {
            if ($line -match "\b$([regex]::Escape($token))\b") {
                $findings.Add([pscustomobject]@{
                        File    = $file.FullName.Substring($repoRoot.Length).TrimStart('\', '/')
                        Line    = $lineNo
                        Rule    = '本机用户名/主机名'
                        Matched = $token
                    })
            }
        }
    }
}

Write-Host ''
Write-Host "扫描目录 : $repoRoot"
Write-Host "扫描文件 : $scanned"
Write-Host ("本机标识 : {0}" -f ($(if ($identityTokens) { $identityTokens -join ', ' } else { '(无)' })))
Write-Host ''

if ($findings.Count -eq 0) {
    Write-Host '结果: 未发现本机隐私信息或硬编码真实地址。' -ForegroundColor Green
    exit 0
}

Write-Host ("结果: 发现 {0} 处需要复核的内容" -f $findings.Count) -ForegroundColor Yellow
$findings | Format-Table -AutoSize Rule, File, Line, Matched | Out-String -Width 200 | Write-Host
Write-Host '处理建议：把真实地址/路径/邮箱改成占位符或 RFC 5737 文档保留地址（192.0.2.0/24、198.51.100.0/24、203.0.113.0/24）。' -ForegroundColor Yellow
exit 1
