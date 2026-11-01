#Requires -Version 5.1
<#
.SYNOPSIS
    kali-relay 生命周期管理与命令入口（Windows / PowerShell）。

.DESCRIPTION
    创建一个常驻 Kali 容器，把容器内的 127.0.0.1 透明 DNAT 到指定远端服务器（端口 1:1）。
    * 首次运行会构建镜像并创建容器；
    * 之后每次运行只做 `docker exec`，无需重复 docker run；
    * 默认绝不联网更新基础镜像，需要最新 Kali 时显式加 -Update。

.PARAMETER T
    远端目标 IPv4 地址（-t）。除 -Status / -Stop / -Update 单独使用外必填。

.PARAMETER Cmd
    在容器内执行的命令（通过 bash -lc 执行）。留空则进入交互式 shell。

.PARAMETER Update
    显式更新：docker pull 最新基础镜像 + --no-cache 重建镜像 + 重建容器。

.PARAMETER Force
    目标 IP 与现有容器不一致时，不询问直接重建容器。

.PARAMETER Rebuild
    仅强制重建镜像（不联网更新基础镜像）。

.PARAMETER Status
    查看容器、网络、镜像与当前生效的 iptables 规则。

.PARAMETER Stop
    停止并清理容器与专用网络（镜像保留，加 -Purge 一并删除）。

.PARAMETER Purge
    与 -Stop 同用：额外删除 kali-relay:latest 镜像。

.PARAMETER KaliBaseTag
    基础镜像标签（对应 Dockerfile 的 KALI_BASE_TAG），默认 latest。

.PARAMETER DockerHost
    高级用法：指定 Docker 端点（如 tcp://127.0.0.1:2375）。默认使用本机 Docker
    （Docker Desktop / 本机 docker CLI）。

.EXAMPLE
    .\start-relay.ps1 -t 198.51.100.10
    首次启动容器并进入交互式 shell。

.EXAMPLE
    .\start-relay.ps1 -t 198.51.100.10 -Cmd "nmap -sT 127.0.0.1"
    在容器内执行单条命令。

.EXAMPLE
    .\start-relay.ps1 -t 198.51.100.10 -Update
    更新 Kali 基础镜像并重建镜像与容器。

.EXAMPLE
    .\start-relay.ps1 -Status
    .\start-relay.ps1 -Stop
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
    Justification = '这是面向终端的运维脚本，彩色进度输出是刻意设计')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
    Justification = '内部辅助函数，破坏性操作由主流程的 -Force / -Stop 参数统一把关')]
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$T,

    [string]$Cmd,

    [switch]$Update,

    [switch]$Force,

    [switch]$Rebuild,

    [switch]$Status,

    [switch]$Stop,

    [switch]$Purge,

    [string]$KaliBaseTag = 'latest',

    [string]$DockerHost
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- 常量 ---
$script:ContainerName = 'kali-relay'
$script:ImageName     = 'kali-relay:latest'
$script:NetworkName   = 'kali-relay-net'
# 固定网段：便于验收脚本稳定取值，也便于排查。若与你的内网/VPN 冲突，改这一处即可。
$script:NetworkSubnet = '172.28.0.0/24'
$script:TargetLabel   = 'kali-relay.target-ip'

# 参数落到 script 作用域，便于函数内引用（也符合 PSScriptAnalyzer 的静态检查）
$script:OptionKaliBaseTag = $KaliBaseTag
$script:OptionRebuild     = [bool]$Rebuild
$script:OptionPurge       = [bool]$Purge
$script:HealthCmd     = 'iptables -t nat -S KALI-RELAY >/dev/null 2>&1'

# ---------------------------------------------------------------- 输出 ---
function Write-Step {
    param([string]$Message)
    Write-Host "[start-relay] $Message" -ForegroundColor Cyan
}

function Write-Ok {
    param([string]$Message)
    Write-Host "[start-relay] $Message" -ForegroundColor Green
}

function Write-Warn2 {
    param([string]$Message)
    Write-Host "[start-relay] 警告: $Message" -ForegroundColor Yellow
}

function Write-Detail {
    param([string]$Message)
    Write-Host "             $Message" -ForegroundColor DarkGray
}

# ---------------------------------------------------------------- Docker ---
if ($DockerHost) {
    $env:DOCKER_HOST = $DockerHost
    Write-Step "使用指定 Docker 端点: $DockerHost"
}

$dockerCmd = Get-Command -Name docker -CommandType Application -ErrorAction SilentlyContinue |
    Select-Object -First 1
if (-not $dockerCmd) {
    throw @'
未找到 docker 命令。请先安装 Docker Desktop for Windows：
  https://docs.docker.com/desktop/setup/install/windows-install/
安装后确认 `docker version` 能同时显示 Client 与 Server。
'@
}
$script:DockerExe = $dockerCmd.Source

function Invoke-DockerText {
    param([Parameter(Mandatory)][string[]]$DockerArgs)

    $out = & $script:DockerExe @DockerArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        $detail = ($out | Out-String).Trim()
        throw ("docker {0} 失败 (exit {1})`n{2}" -f ($DockerArgs -join ' '), $LASTEXITCODE, $detail)
    }
    return (($out | Out-String).Trim())
}

function Invoke-DockerLive {
    param([Parameter(Mandatory)][string[]]$DockerArgs)

    # 逐行写回控制台（而非写入管道），避免污染调用方的返回值
    & $script:DockerExe @DockerArgs 2>&1 | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) {
        throw ("docker {0} 失败 (exit {1})" -f ($DockerArgs -join ' '), $LASTEXITCODE)
    }
}

function Test-DockerDaemon {
    try {
        & $script:DockerExe version --format '{{.Server.Version}}' *> $null
        return ($LASTEXITCODE -eq 0)
    }
    catch {
        return $false
    }
}

function Get-ContainerState {
    $out = & $script:DockerExe inspect --type container --format '{{.State.Status}}' $script:ContainerName 2>$null
    if ($LASTEXITCODE -ne 0) { return 'missing' }
    return (($out | Out-String).Trim())
}

function Get-ContainerTarget {
    # 注意：不要用 -f 拼接 Go 模板，.NET 会把 {{ }} 转义成 { }，docker 收到的是非法模板
    $format = '{{index .Config.Labels "' + $script:TargetLabel + '"}}'
    $out = & $script:DockerExe inspect --type container --format $format $script:ContainerName 2>$null
    if ($LASTEXITCODE -ne 0) { return '' }
    return (($out | Out-String).Trim())
}

function Get-ContainerImageId {
    $out = & $script:DockerExe inspect --type container --format '{{.Image}}' $script:ContainerName 2>$null
    if ($LASTEXITCODE -ne 0) { return '' }
    return (($out | Out-String).Trim())
}

function Test-ImageReady {
    param([string]$Image)
    & $script:DockerExe image inspect $Image *> $null
    return ($LASTEXITCODE -eq 0)
}

function Test-NetworkReady {
    param([string]$Name)
    & $script:DockerExe network inspect $Name *> $null
    return ($LASTEXITCODE -eq 0)
}

function Get-LocalImageId {
    param([string]$Image)
    $out = & $script:DockerExe image inspect --format '{{.Id}}' $Image 2>$null
    if ($LASTEXITCODE -ne 0) { return '' }
    return (($out | Out-String).Trim())
}

# ---------------------------------------------------------------- 校验 ---
function Assert-TargetIp {
    param([string]$Value)

    if (-not $Value) {
        throw "必须通过 -t 指定目标 IP，例如：.\start-relay.ps1 -t 198.51.100.10"
    }

    $parsed = $null
    if (-not [System.Net.IPAddress]::TryParse($Value, [ref]$parsed)) {
        throw "-t 不是合法的 IP 地址: $Value"
    }
    if ($parsed.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
        throw "-t 目前只支持 IPv4 地址: $Value （IPv6 的 ::1 不在本方案范围内）"
    }
    if ($parsed.Equals([System.Net.IPAddress]::Any) -or
        $parsed.Equals([System.Net.IPAddress]::Loopback) -or
        $Value.StartsWith('127.')) {
        throw "-t 不能是回环/未指定地址: $Value （会把容器流量转回自身）"
    }
    return $parsed.ToString()
}

function Test-Interactive {
    return (-not [System.Console]::IsInputRedirected -and -not [System.Console]::IsOutputRedirected)
}

# ---------------------------------------------------------------- 状态 ---
function Show-Status {
    $state = Get-ContainerState
    Write-Host ''
    Write-Host 'kali-relay 状态' -ForegroundColor White

    Write-Host ("  容器 {0,-14}: {1}" -f $script:ContainerName, $state)

    if ($state -ne 'missing') {
        $target = Get-ContainerTarget
        if ($target) { Write-Host ("  目标 IP        : {0}" -f $target) }
        else { Write-Host '  目标 IP        : (容器未记录，可能不是本脚本创建)' }

        $imageName = (& $script:DockerExe inspect --type container --format '{{.Config.Image}}' $script:ContainerName | Out-String).Trim()
        Write-Host ("  镜像           : {0}" -f $imageName)

        if ($state -eq 'running') {
            $health = (& $script:DockerExe inspect --type container --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' $script:ContainerName | Out-String).Trim()
            $startedAt = (& $script:DockerExe inspect --type container --format '{{.State.StartedAt}}' $script:ContainerName | Out-String).Trim()
            Write-Host ("  健康状态       : {0}" -f $health)
            Write-Host ("  启动时间(UTC)  : {0}" -f $startedAt)
            $ports = (& $script:DockerExe port $script:ContainerName 2>$null | Out-String).Trim()
            Write-Host ("  端口发布       : {0}" -f $(if ($ports) { $ports } else { '无（未向宿主机映射任何端口）' }))

            Write-Host "  nat 规则       :"
            $natRules = & $script:DockerExe exec $script:ContainerName iptables -t nat -S KALI-RELAY 2>$null
            if ($LASTEXITCODE -eq 0) {
                foreach ($line in @($natRules)) { if ($line) { Write-Host ("    " + $line) } }
            }
            else {
                Write-Host '    (读取失败)' -ForegroundColor Yellow
            }

            $localnet = & $script:DockerExe exec $script:ContainerName cat /proc/sys/net/ipv4/conf/all/route_localnet 2>$null
            Write-Host ("  route_localnet : {0}" -f (($localnet | Out-String).Trim()))
        }
        else {
            Write-Host '  提示           : 容器已停止，用 .\start-relay.ps1 -t <IP> 启动' -ForegroundColor Yellow
        }
    }

    $netState = if (Test-NetworkReady $script:NetworkName) { '存在' } else { '不存在' }
    Write-Host ("  专用网络       : {0} ({1})" -f $script:NetworkName, $netState)

    if (Test-ImageReady $script:ImageName) { Write-Host ("  镜像           : {0} 已就绪" -f $script:ImageName) }
    else { Write-Host ("  镜像           : {0} 未构建" -f $script:ImageName) }
    Write-Host ''
}

# ---------------------------------------------------------------- 停止 ---
function Invoke-Stop {
    $state = Get-ContainerState
    if ($state -eq 'missing') {
        Write-Step "容器 $($script:ContainerName) 不存在"
    }
    else {
        Write-Step "停止并删除容器 $($script:ContainerName) (当前状态: $state)"
        Invoke-DockerLive @('rm', '-f', $script:ContainerName)
        Write-Ok '容器已删除'
    }

    if (Test-NetworkReady $script:NetworkName) {
        try {
            Invoke-DockerText @('network', 'rm', $script:NetworkName) | Out-Null
            Write-Ok "专用网络 $($script:NetworkName) 已删除"
        }
        catch {
            Write-Warn2 "专用网络 $($script:NetworkName) 仍被占用，稍后可手动删除: docker network rm $($script:NetworkName)"
        }
    }

    if ($script:OptionPurge -and (Test-ImageReady $script:ImageName)) {
        Invoke-DockerText @('image', 'rm', '-f', $script:ImageName) | Out-Null
        Write-Ok "镜像 $($script:ImageName) 已删除"
    }
}

# ---------------------------------------------------------------- 网络 ---
function Initialize-Network {
    if (Test-NetworkReady $script:NetworkName) {
        Write-Step "复用已有专用网络 $($script:NetworkName)"
        return
    }

    Write-Step "创建专用 bridge 网络 $($script:NetworkName)"
    # 附带 compose 标签，使 docker compose 与该网络可以共存复用
    Invoke-DockerText @(
        'network', 'create',
        '--driver', 'bridge',
        '--subnet', $script:NetworkSubnet,
        '--label', 'com.docker.compose.project=kali-relay',
        '--label', 'com.docker.compose.network=relay-net',
        $script:NetworkName
    ) | Out-Null
    Write-Ok '网络已创建'
}

# ---------------------------------------------------------------- 镜像 ---
function Initialize-Image {
    if ($Update) {
        Write-Step "更新模式：docker pull kalilinux/kali-rolling:$script:OptionKaliBaseTag"
        Invoke-DockerLive @('pull', "kalilinux/kali-rolling:$script:OptionKaliBaseTag")
        Write-Step "更新模式：--no-cache 重建镜像 $($script:ImageName)"
        # 上面已经显式 docker pull 过最新基础镜像，这里不再加 --pull：
        # 部分镜像源/离线环境下 --pull 会重新校验远端 manifest 并超时。
        Invoke-DockerLive @(
            'build', '--no-cache',
            '--build-arg', "KALI_BASE_TAG=$script:OptionKaliBaseTag",
            '-t', $script:ImageName, $PSScriptRoot
        )
        Write-Ok '镜像已按最新 Kali 基础镜像重建'
        return $true
    }

    $exists = Test-ImageReady $script:ImageName
    if ($exists -and -not $script:OptionRebuild) {
        Write-Step "使用本地已有镜像 $($script:ImageName)（未传 -Update，不联网更新）"
        return $false
    }

    if ($script:OptionRebuild) { Write-Step "按 -Rebuild 重建镜像 $($script:ImageName)（不联网更新基础镜像）" }
    else { Write-Step "首次构建镜像 $($script:ImageName)（基础镜像标签: $script:OptionKaliBaseTag）" }

    Invoke-DockerLive @(
        'build',
        '--build-arg', "KALI_BASE_TAG=$script:OptionKaliBaseTag",
        '-t', $script:ImageName, $PSScriptRoot
    )
    Write-Ok '镜像构建完成'
    return $true
}

# ---------------------------------------------------------------- 容器 ---
function New-RelayContainer {
    param([Parameter(Mandatory)][string]$TargetIp)

    Write-Step "创建常驻容器 $($script:ContainerName) -> $TargetIp"

    $runArgs = @(
        'run', '-d'
        '--name', $script:ContainerName
        '--hostname', $script:ContainerName
        '--network', $script:NetworkName
        '--cap-add', 'NET_ADMIN'
        '--cap-add', 'NET_RAW'
        '--sysctl', 'net.ipv4.conf.all.route_localnet=1'
        '--sysctl', 'net.ipv4.conf.default.route_localnet=1'
        '-e', "TARGET_IP=$TargetIp"
        '--label', "$($script:TargetLabel)=$TargetIp"
        '--label', 'kali-relay.managed-by=start-relay.ps1'
        '--restart', 'unless-stopped'
        '--health-cmd', $script:HealthCmd
        '--health-interval', '10s'
        '--health-timeout', '3s'
        '--health-retries', '3'
        '--health-start-period', '5s'
        $script:ImageName
    )

    Invoke-DockerText $runArgs | Out-Null
    Write-Ok '容器已创建（未发布任何端口，未使用 host 网络）'
}

function Wait-RelayReady {
    param([int]$TimeoutSeconds = 60)

    Write-Step '等待容器内转发规则就绪'
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $state = Get-ContainerState
        if ($state -ne 'running') {
            $logs = (& $script:DockerExe logs --tail 40 $script:ContainerName 2>&1 | Out-String).Trim()
            throw ("容器未保持运行（状态: {0}）`n容器日志：`n{1}" -f $state, $logs)
        }

        & $script:DockerExe exec $script:ContainerName iptables -t nat -S KALI-RELAY *> $null
        if ($LASTEXITCODE -eq 0) {
            Write-Ok '转发规则已生效'
            return
        }
        Start-Sleep -Milliseconds 500
    }
    throw "等待转发规则就绪超时（${TimeoutSeconds}s）"
}

function Confirm-Recreate {
    param(
        [string]$ExistingTarget,
        [string]$NewTarget
    )

    if (-not $ExistingTarget) {
        Write-Warn2 '现有容器没有记录目标 IP，按目标不一致处理'
        $ExistingTarget = '(未知)'
    }

    if ($Force) {
        Write-Step "目标 IP 由 $ExistingTarget 变更为 $NewTarget，按 -Force 直接重建"
        return $true
    }

    Write-Warn2 "现有容器目标 IP 为 $ExistingTarget，与本次 -t $NewTarget 不一致"
    if (-not (Test-Interactive)) {
        throw "目标 IP 不一致，非交互环境下请追加 -Force 以自动重建容器"
    }

    $answer = Read-Host "是否重建容器并切换到 $NewTarget ? [y/N]"
    return ($answer -match '^(y|yes)$')
}

function Start-ExistingContainer {
    Write-Step "启动已存在的容器 $($script:ContainerName)"
    Invoke-DockerText @('start', $script:ContainerName) | Out-Null
    Write-Ok '容器已启动'
}

# ---------------------------------------------------------------- 执行 ---
function Invoke-InContainer {
    param([string]$CommandLine)

    $interactive = Test-Interactive
    $execArgs = @('exec')
    if ($interactive) { $execArgs += '-it' } else { $execArgs += '-i' }

    if ($CommandLine) {
        $execArgs += @($script:ContainerName, '/bin/bash', '-lc', $CommandLine)
        Write-Step "在容器内执行: $CommandLine"
        & $script:DockerExe @execArgs
        $code = $LASTEXITCODE
        if ($code -ne 0) {
            Write-Warn2 "容器内命令退出码: $code"
        }
        exit $code
    }

    if (-not $interactive) {
        Write-Ok "容器已就绪。当前非交互终端，请使用：docker exec -it $($script:ContainerName) /bin/bash"
        return
    }

    Write-Step '进入容器交互式 shell（输入 exit 退出，容器继续常驻）'
    & $script:DockerExe @execArgs @($script:ContainerName, '/bin/bash')
    exit $LASTEXITCODE
}

# ---------------------------------------------------------------- 主流程 ---

if (-not (Test-DockerDaemon)) {
    throw '无法连接 Docker 守护进程。请确认 Docker Desktop 已启动（`docker version` 能看到 Server 段）。'
}

Write-Step "Docker 客户端: $($script:DockerExe)"
Write-Step ("Docker 服务端: {0}" -f ((& $script:DockerExe version --format '{{.Server.Version}}' | Out-String).Trim()))

if ($Stop) {
    Invoke-Stop
    exit 0
}

if ($Status) {
    Show-Status
    exit 0
}

# -Update 单独使用时，沿用现有容器的目标 IP
$targetIp = $T
$existingState = Get-ContainerState
if (-not $targetIp -and $Update -and $existingState -ne 'missing') {
    $targetIp = Get-ContainerTarget
    if ($targetIp) { Write-Step "-Update 未指定 -t，沿用现有容器目标 IP: $targetIp" }
}

$targetIp = Assert-TargetIp $targetIp

$imageChanged = Initialize-Image
Initialize-Network

$existingState = Get-ContainerState
$recreate = $false

if ($existingState -eq 'missing') {
    $recreate = $true
}
else {
    $existingTarget = Get-ContainerTarget
    if ($existingTarget -ne $targetIp) {
        if (Confirm-Recreate -ExistingTarget $existingTarget -NewTarget $targetIp) { $recreate = $true }
        else { Write-Step '保留现有容器（目标未变更）' }
    }
    elseif ($Force -or $imageChanged) {
        if ($imageChanged) { Write-Step '镜像已重建，容器需要重建以使用新镜像' }
        elseif ($Force) { Write-Step '按 -Force 重建容器' }
        $recreate = $true
    }
    elseif ($existingState -ne 'running') {
        Start-ExistingContainer
    }
    else {
        Write-Step "复用正在运行的容器 $($script:ContainerName)（目标 $targetIp）"
    }
}

if ($recreate) {
    if ($existingState -ne 'missing') {
        Invoke-DockerText @('rm', '-f', $script:ContainerName) | Out-Null
        Write-Step '旧容器已删除'
    }
    New-RelayContainer -TargetIp $targetIp
}

Wait-RelayReady
Invoke-InContainer -CommandLine $Cmd
