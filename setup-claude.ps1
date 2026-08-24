<#
.SYNOPSIS
    Claude Code 一键部署脚本（环境检测 + 安装 + hooks 部署）
.DESCRIPTION
    1. 前置环境检测：PowerShell、64 位、Git、UV（自动安装）
       Node.js 仅 npm 兜底时自动安装，native/winget 不需要
    2. Claude Code 安装：native (GCS) → winget → npm 三级兜底
    3. 可选：下载 disler 仓库的 6 个 hooks + status_line_v6
    4. 检查用户自写 hooks 就位情况
    5. 统一处理 PATH（任何安装方式都跑）

    通常由 install.ps1 拉取并调用，不建议直接运行。
.PARAMETER InstallTimeout
    native 安装的超时秒数。默认 60 秒
.PARAMETER SkipClaudeInstall
    仅部署 hooks，跳过 Claude Code 安装
.PARAMETER ClaudeVersion
    指定安装版本，'latest' 或具体版本号如 '2.1.153'。默认 latest
.PARAMETER Upgrade
    升级已安装的 Claude Code。默认升级到最新稳定版；结合 -ClaudeVersion 可升级到指定版本。
.PARAMETER InstallMode
    安装模式：Minimal（仅安装软件，默认）或 Full（安装软件 + hooks）
    未指定时交互式提示用户选择
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\setup-claude.ps1
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\setup-claude.ps1 -InstallMode Full
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\setup-claude.ps1 -SkipClaudeInstall
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\setup-claude.ps1 -Upgrade -ClaudeVersion 2.1.153
#>

[CmdletBinding()]
param(
    [int]$InstallTimeout = 60,
    [switch]$SkipClaudeInstall,
    [ValidatePattern('^(stable|latest|\d+\.\d+\.\d+(-[^\s]+)?)$')]
    [string]$ClaudeVersion = 'latest',
    [switch]$Upgrade,
    [ValidateSet('Minimal', 'Full')]
    [string]$InstallMode
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
chcp 65001 | Out-Null
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding           = [System.Text.Encoding]::UTF8

# ============================================================
#  常量
# ============================================================
$GCS_BUCKET    = 'https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases'
$DISLER_REPO   = 'https://raw.githubusercontent.com/disler/claude-code-hooks-mastery/main/.claude'
$USER_REPO     = 'https://raw.githubusercontent.com/ErgeAIA/claude-code-bootstrap/main/hooks'

# SHA256 checksums（与仓库根目录 checksums.txt 同步）
$CHECKSUMS = @{
    # disler hooks
    'pre_tool_use.py'         = '78006866F793CCD394BC52011582CE48707CEEF9D3496E474AB7BCB63365A5DA'
    'post_tool_use.py'        = '6C3F0AA03CABC68670490A7CDAD6FC2364C94B074F9D6E317EA7C8ABE04C9449'
    'session_start.py'        = 'E48E3D8F6D50A14DBBE4635E461C956A55F338D1DCA67ED39CACDBBF336C6DB8'
    'user_prompt_submit.py'   = 'E5EFBCE941746900D9EF88706D865F2693DA721C6046330D954278939EB988A8'
    'post_tool_use_failure.py'= '46BA935B917E7F8EAD0273E968BE09201E51016913F41A6E9E8DB908BE06D822'
    'session_end.py'          = 'F316D341AE6A3A60E3E5A0DDD0DFD3360DA793A31E80B4B7B44C00F755E15426'
    'status_line_v6.py'       = 'B71DEB25E7C2308B1AB134DFE686E4E6A50612AA4FB91C98CA98327B78A19803'
    # 用户 hooks（从本仓库下载）
    'auto_format.py'          = 'BAF7FA4737BAE65C23D42E24CFCE902881ABC3DE43C24F10DE34A3475D50B2C8'
    'block_dangerous.py'      = '769A7996ECD918B2611EA853330B340F8055AEEE3054B5E1F02650E47913A05F'
    'check_secrets.py'        = 'D16970556CF9A8EE230230E9FD6D18002D091C3239FC5658D460DE444F3F3607'
    'verify_on_stop.py'       = '9E4EF09A78183EDC1833CB4794AA90959DFD32382EAF3BCA14DCF63DFD530ED5'
}

$CLAUDE_HOME  = Join-Path $env:USERPROFILE '.claude'
$HOOK_DIR     = Join-Path $CLAUDE_HOME 'hooks'
$SL_DIR       = Join-Path $CLAUDE_HOME 'status_lines'
$LOG_DIR      = Join-Path $CLAUDE_HOME 'logs'

$INSTALL_BASE = Join-Path $env:USERPROFILE '.local\share\claude'
$VERSIONS_DIR = Join-Path $INSTALL_BASE 'versions'
$BIN_DIR      = Join-Path $env:USERPROFILE '.local\bin'
$LINK_PATH    = Join-Path $BIN_DIR 'claude.exe'
$CONFIG_PATH  = Join-Path $env:USERPROFILE '.claude.json'

# hooks 来源映射：文件名 → 下载基础 URL
$HOOK_SOURCES = @{
    'pre_tool_use.py'         = $DISLER_REPO
    'post_tool_use.py'        = $DISLER_REPO
    'session_start.py'        = $DISLER_REPO
    'user_prompt_submit.py'   = $DISLER_REPO
    'post_tool_use_failure.py'= $DISLER_REPO
    'session_end.py'          = $DISLER_REPO
    'auto_format.py'          = $USER_REPO
    'block_dangerous.py'      = $USER_REPO
    'check_secrets.py'        = $USER_REPO
    'verify_on_stop.py'       = $USER_REPO
}
$STATUS_LINE = 'status_line_v6.py'

# ============================================================
#  日志工具
# ============================================================
function Write-Step  { param($M) Write-Host "`n==> $M" -ForegroundColor Cyan }
function Write-Ok    { param($M) Write-Host "  [OK]    $M" -ForegroundColor Green }
function Write-Warn2 { param($M) Write-Host "  [WARN]  $M" -ForegroundColor Yellow }
function Write-Err   { param($M) Write-Host "  [ERROR] $M" -ForegroundColor Red }
function Write-Info  { param($M) Write-Host "  $M" -ForegroundColor Gray }

function Has-Command {
    param([string]$Name)
    return $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

function ConvertFrom-JsonToHashtable {
    param([string]$Json)
    $parsed = $Json | ConvertFrom-Json
    if ($null -eq $parsed) { return $null }
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        return $Json | ConvertFrom-Json -AsHashtable
    }
    # PS 5.1 兼容：手动转换 PSCustomObject → Hashtable
    $ht = [System.Collections.Hashtable]::new()
    foreach ($prop in $parsed.PSObject.Properties) {
        $ht[$prop.Name] = $prop.Value
    }
    return $ht
}

# ============================================================
#  安装模式选择
# ============================================================
function Read-InstallMode {
    Write-Host ''
    Write-Host '  请选择安装模式：' -ForegroundColor White
    Write-Host ''
    Write-Host '    [0] 退出安装' -ForegroundColor Red
    Write-Host ''
    Write-Host '    [1] 仅安装 Claude Code（默认）' -ForegroundColor Green
    Write-Host '        安装 Claude Code 本体 + PATH 配置' -ForegroundColor Gray
    Write-Host '        不下载任何 hooks 或 status_line' -ForegroundColor Gray
    Write-Host ''
    Write-Host '    [2] 完整安装（软件 + hooks）' -ForegroundColor Yellow
    Write-Host '        安装 Claude Code + 从第三方仓库下载 6 个 hooks 和 status_line' -ForegroundColor Gray
    Write-Host '        注意：hooks 来自 disler/claude-code-hooks-mastery，会自动校验 SHA256' -ForegroundColor Gray
    Write-Host ''

    while ($true) {
        Write-Host '  请输入选择 [0/1/2]（默认 1）：' -ForegroundColor Cyan -NoNewline
        $choice = (Read-Host).Trim()
        if ([string]::IsNullOrEmpty($choice)) { $choice = '1' }
        switch ($choice) {
            '0' { Write-Host '  已退出安装' -ForegroundColor Yellow; exit 0 }
            '1' { return 'Minimal' }
            '2' { return 'Full' }
            default { Write-Host '  无效输入，请输入 0、1 或 2' -ForegroundColor Red }
        }
    }
}

# ============================================================
#  现有配置检测（Full 模式写入前报告 + 自动备份）
# ============================================================
function Test-ExistingConfig {
    $hasSettings   = Test-Path (Join-Path $CLAUDE_HOME 'settings.json')
    $hasClaudeJson = Test-Path $CONFIG_PATH
    $hooks  = @(Get-ChildItem $HOOK_DIR -Filter *.py -ErrorAction SilentlyContinue)
    $sls    = @(Get-ChildItem $SL_DIR -Filter *.py -ErrorAction SilentlyContinue)
    $hasHooks       = $hooks.Count -gt 0
    $hasStatusLines = $sls.Count -gt 0

    $found = $false
    Write-Step '检测现有 Claude Code 配置'

    if ($hasSettings) {
        $sz = (Get-Item (Join-Path $CLAUDE_HOME 'settings.json')).Length
        Write-Info "  [FOUND] ~/.claude/settings.json ($sz bytes)"
        $found = $true
    }
    if ($hasClaudeJson) {
        Write-Info '  [FOUND] ~/.claude.json'
        $found = $true
    }
    if ($hasHooks) {
        Write-Info "  [FOUND] ~/.claude/hooks/ ($($hooks.Count) 个 .py)"
        $found = $true
    }
    if ($hasStatusLines) {
        Write-Info "  [FOUND] ~/.claude/status_lines/ ($($sls.Count) 个 .py)"
        $found = $true
    }
    if (-not $found) {
        Write-Info '  [CLEAN] 首次部署，无冲突'
    }
    return $found
}

function Backup-SettingsJson {
    $SETTINGS_PATH = Join-Path $CLAUDE_HOME 'settings.json'
    if (-not (Test-Path $SETTINGS_PATH)) { return $null }

    $BACKUP_DIR = Join-Path $CLAUDE_HOME 'backups'
    New-Item -ItemType Directory -Force -Path $BACKUP_DIR | Out-Null

    $stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backup = Join-Path $BACKUP_DIR "settings.json.$stamp.bak"
    Copy-Item $SETTINGS_PATH $backup -Force
    Write-Ok "  备份到 $backup"

    # 保留最近 10 个备份，清理更早的
    $oldBackups = Get-ChildItem $BACKUP_DIR -Filter 'settings.json.*.bak' |
                  Sort-Object Name -Descending |
                  Select-Object -Skip 10
    foreach ($ob in $oldBackups) {
        Remove-Item $ob.FullName -Force -ErrorAction SilentlyContinue
    }

    return $backup
}

# ============================================================
#  阶段 1：前置环境检测（收集结果 → 打印报告 → 返回是否可继续）
# ============================================================
function Test-Prerequisites {
    Write-Step '环境检测报告'
    Write-Host ''

    $results = [System.Collections.ArrayList]::new()
    $blockers = 0

    # 1. PowerShell 版本
    $psVer = $PSVersionTable.PSVersion
    if ($psVer.Major -lt 5) {
        [void]$results.Add(@{ Name = 'PowerShell'; Value = "$psVer"; Status = 'FAIL'; Note = '需要 5.1+' })
        $blockers++
    } elseif ($psVer.Major -ge 7) {
        [void]$results.Add(@{ Name = 'PowerShell'; Value = "$psVer"; Status = 'OK'; Note = '推荐版本' })
    } else {
        [void]$results.Add(@{ Name = 'PowerShell'; Value = "$psVer"; Status = 'WARN'; Note = '建议升级到 7.x' })
    }

    # 2. 系统架构
    if ([Environment]::Is64BitOperatingSystem) {
        [void]$results.Add(@{ Name = '系统架构'; Value = '64 位'; Status = 'OK'; Note = '' })
    } else {
        [void]$results.Add(@{ Name = '系统架构'; Value = '32 位'; Status = 'FAIL'; Note = '不支持 32 位' })
        $blockers++
    }

    # 3. Git
    if (Has-Command 'git') {
        $gitVer = (& git --version) -replace 'git version ', ''
        [void]$results.Add(@{ Name = 'Git'; Value = $gitVer; Status = 'OK'; Note = '' })
    } else {
        [void]$results.Add(@{ Name = 'Git'; Value = '未安装'; Status = 'WARN'; Note = 'hooks 部分功能需要' })
    }

    # 4. UV（缺失时自动安装）
    if (Has-Command 'uv') {
        $uvVer = (& uv --version) -replace 'uv ', ''
        [void]$results.Add(@{ Name = 'UV'; Value = $uvVer; Status = 'OK'; Note = '' })
    } else {
        [void]$results.Add(@{ Name = 'UV'; Value = '安装中...'; Status = 'AUTO'; Note = '自动安装' })
        try {
            # 用同步子进程执行 UV 安装脚本，避免其内部 exit 终止父进程
            # 用 -Command 而非 -File，因为安装脚本是管道表达式
            $uvProc = Start-Process -FilePath 'powershell.exe' -ArgumentList @(
                '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command',
                'irm https://astral.sh/uv/install.ps1 | iex'
            ) -NoNewWindow -Wait -PassThru -ErrorAction Stop
            # 刷新 PATH 以识别新安装的 uv
            $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
            if (Has-Command 'uv') {
                $uvVer = (& uv --version) -replace 'uv ', ''
                $results[$results.Count - 1] = @{ Name = 'UV'; Value = $uvVer; Status = 'OK'; Note = '自动安装完成' }
            } else {
                $results[$results.Count - 1] = @{ Name = 'UV'; Value = '安装失败'; Status = 'FAIL'; Note = "手动: irm https://astral.sh/uv/install.ps1 | iex (exit $($uvProc.ExitCode))" }
                $blockers++
            }
        } catch {
            $results[$results.Count - 1] = @{ Name = 'UV'; Value = '安装失败'; Status = 'FAIL'; Note = "手动安装 ($_)" }
            $blockers++
        }
    }

    # 5. Node.js（可选）
    if (Has-Command 'node') {
        $nodeVer = (& node --version)
        [void]$results.Add(@{ Name = 'Node.js'; Value = $nodeVer; Status = 'OK'; Note = 'npm 兜底' })
    } else {
        [void]$results.Add(@{ Name = 'Node.js'; Value = '未安装'; Status = 'SKIP'; Note = '仅 npm 兜底需要' })
    }

    # 6. Claude Code（即将安装）
    if (Has-Command 'claude') {
        $claudeVer = (& claude --version 2>$null) -join ''
        [void]$results.Add(@{ Name = 'Claude Code'; Value = $claudeVer; Status = 'OK'; Note = '已安装' })
    } else {
        [void]$results.Add(@{ Name = 'Claude Code'; Value = '未安装'; Status = 'SKIP'; Note = '即将安装' })
    }

    # ── 打印报告 ──
    Write-Host '  ┌────────────────────────────────────────────────────────┐' -ForegroundColor Cyan
    foreach ($r in $results) {
        $icon = switch ($r.Status) {
            'OK'   { '✓' }
            'WARN' { '○' }
            'FAIL' { '✗' }
            'AUTO' { '↓' }
            'SKIP' { '○' }
        }
        $color = switch ($r.Status) {
            'OK'   { 'Green' }
            'WARN' { 'Yellow' }
            'FAIL' { 'Red' }
            'AUTO' { 'Cyan' }
            'SKIP' { 'Gray' }
        }
        $nameCol = $r.Name.PadRight(14)
        $valCol = $r.Value.PadRight(18)
        $notePart = if ($r.Note) { " ($($r.Note))" } else { '' }
        Write-Host "  │  $icon  $nameCol $valCol$notePart" -ForegroundColor $color
    }
    Write-Host '  └────────────────────────────────────────────────────────┘' -ForegroundColor Cyan

    # ── 汇总 ──
    $okCount   = @($results | Where-Object { $_.Status -eq 'OK' }).Count
    $warnCount = @($results | Where-Object { $_.Status -eq 'WARN' }).Count
    $skipCount = @($results | Where-Object { $_.Status -eq 'SKIP' }).Count
    $failCount = @($results | Where-Object { $_.Status -eq 'FAIL' }).Count
    Write-Host ''
    $summaryColor = if ($blockers -gt 0) { 'Red' } else { 'Green' }
    Write-Host "  $okCount 通过 / $warnCount 建议 / $skipCount 可选 / $failCount 阻断" -ForegroundColor $summaryColor

    if ($blockers -gt 0) {
        Write-Host ''
        Write-Err '环境不满足要求，请先修复上述阻断项后重试'
        return $false
    }
    return $true
}

# ============================================================
#  阶段 2a：Claude Code 安装
# ============================================================
function Install-Native {
    Write-Info '方式 1/3：原生二进制（GCS 直连）'

    $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'win32-arm64' } else { 'win32-x64' }
    Write-Info "  架构: $arch"

    New-Item -ItemType Directory -Force -Path $VERSIONS_DIR, $BIN_DIR | Out-Null
    $tmpDir = Join-Path $env:TEMP 'claude-install'
    New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null

    $job = Start-Job -ScriptBlock {
        param($GCS, $arch, $tmpDir, $VERSIONS_DIR, $BIN_DIR, $LINK_PATH, $Target)
        $ProgressPreference = 'SilentlyContinue'

        # 决定目标版本
        if ($Target -eq 'latest' -or $Target -eq 'stable') {
            $version = (Invoke-RestMethod "$GCS/latest" -TimeoutSec 30).ToString().Trim()
        } else {
            $version = $Target
        }

        $manifest = Invoke-RestMethod "$GCS/$version/manifest.json" -TimeoutSec 30
        $checksum = $manifest.platforms.$arch.checksum
        $size     = $manifest.platforms.$arch.size
        if (-not $checksum) { throw "Platform $arch not in manifest" }

        $binaryPath  = Join-Path $tmpDir "claude-$version-$arch.exe"
        $downloadUrl = "$GCS/$version/$arch/claude.exe"
        Invoke-WebRequest -Uri $downloadUrl -OutFile $binaryPath -TimeoutSec 60 -ErrorAction Stop

        if ($size -and ((Get-Item $binaryPath).Length -ne [int64]$size)) {
            throw "Size mismatch: expected $size, got $((Get-Item $binaryPath).Length)"
        }

        $actual = (Get-FileHash -Path $binaryPath -Algorithm SHA256).Hash.ToLower()
        if ($actual -ne $checksum) {
            throw "SHA256 mismatch: expected $checksum, got $actual"
        }

        $finalPath = Join-Path $VERSIONS_DIR "$version.exe"
        Move-Item -Force $binaryPath $finalPath
        Copy-Item -Force $finalPath $LINK_PATH

        return @{ Version = $version }
    } -ArgumentList $GCS_BUCKET, $arch, $tmpDir, $VERSIONS_DIR, $BIN_DIR, $LINK_PATH, $ClaudeVersion

    $finished = Wait-Job $job -Timeout $InstallTimeout
    if ($null -eq $finished) {
        Stop-Job $job -ErrorAction SilentlyContinue
        Remove-Job $job -Force -ErrorAction SilentlyContinue
        throw "Native 安装超时（$InstallTimeout 秒）"
    }

    if ($job.State -eq 'Failed') {
        $reason = $job.ChildJobs[0].JobStateInfo.Reason.Message
        Remove-Job $job -Force
        throw "Native 安装失败：$reason"
    }

    $result = Receive-Job $job
    Remove-Job $job -Force

    # 写 .claude.json 标记 native
    $cfg = @{}
    if (Test-Path $CONFIG_PATH) {
        try {
            $utf8NoBomLocal = [System.Text.UTF8Encoding]::new($false)
            $cfg = ConvertFrom-JsonToHashtable ([System.IO.File]::ReadAllText($CONFIG_PATH, $utf8NoBomLocal))
        } catch {}
    }
    if ($null -eq $cfg) { $cfg = @{} }
    $cfg['installMethod'] = 'native'
    $cfg['autoUpdates']   = $false
    if (-not $cfg.ContainsKey('firstStartTime')) {
        $cfg['firstStartTime'] = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    }
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($CONFIG_PATH, ($cfg | ConvertTo-Json -Depth 10), $utf8NoBom)

    Write-Ok "Native 安装成功 v$($result.Version)"
    return 'native'
}

function Install-Winget {
    Write-Info '方式 2/3：winget'
    if (-not (Has-Command 'winget')) {
        throw 'winget 不可用（需要 Windows 10 1809+ 或手动安装 App Installer）'
    }
    & winget install --id Anthropic.ClaudeCode -e --accept-source-agreements --accept-package-agreements
    if ($LASTEXITCODE -ne 0) { throw "winget 退出码 $LASTEXITCODE" }
    Write-Ok 'winget 安装成功'
    return 'winget'
}

function Install-Npm {
    Write-Info '方式 3/3：npm 全局（仅作兜底）'

    # npm 不可用时，尝试用 winget 自动安装 Node.js LTS
    if (-not (Has-Command 'npm')) {
        Write-Info 'npm 不可用，尝试自动安装 Node.js LTS...'
        if (Has-Command 'winget') {
            & winget install OpenJS.NodeJS.LTS --accept-source-agreements --accept-package-agreements
            if ($LASTEXITCODE -ne 0) { throw "winget 安装 Node.js 失败，退出码 $LASTEXITCODE" }
            # 刷新当前会话 PATH（winget 安装的 Node.js 通常写入 Program Files）
            $nodePaths = @(
                "${env:ProgramFiles}\nodejs",
                "${env:ProgramFiles(x86)}\nodejs"
            )
            foreach ($p in $nodePaths) {
                if ((Test-Path $p) -and $env:Path -notlike "*$p*") {
                    $env:Path = "$p;$env:Path"
                }
            }
            if (-not (Has-Command 'npm')) {
                throw 'Node.js 已安装但 npm 仍不可用，请重启终端后重试'
            }
            Write-Ok 'Node.js LTS 自动安装成功'
        } else {
            throw 'npm 和 winget 均不可用，无法自动安装 Node.js。请手动安装 Node.js LTS 后重试'
        }
    }

    & npm install -g @anthropic-ai/claude-code
    if ($LASTEXITCODE -ne 0) { throw "npm 退出码 $LASTEXITCODE" }
    Write-Ok 'npm 安装成功'
    return 'npm'
}

# ============================================================
#  阶段 2b：PATH 健康检查（任何安装方式都跑）
# ============================================================
function Add-DirToUserPath {
    param(
        [string]$Dir,
        [string]$Reason
    )
    if ([string]::IsNullOrEmpty($Dir) -or -not (Test-Path $Dir)) { return }
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ($userPath -like "*$Dir*") {
        Write-Info "    PATH 已有：$Dir"
        return
    }
    $newPath = "$userPath;$Dir"
    [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
    $env:Path = "$env:Path;$Dir"
    Write-Ok "    PATH 已添加（$Reason）：$Dir"
}

function Ensure-ClaudeOnPath {
    param([string]$InstallMethod)

    Write-Info '  PATH 健康检查...'

    if (Has-Command 'claude') {
        $cmd = (Get-Command 'claude').Source
        Write-Ok "    claude 可执行：$cmd"
        return $true
    }

    switch ($InstallMethod) {
        'native' {
            Add-DirToUserPath -Dir $BIN_DIR -Reason 'native 安装目录'
        }
        'winget' {
            $candidates = @(
                (Join-Path $env:ProgramFiles 'Claude Code'),
                (Join-Path $env:LOCALAPPDATA 'Programs\claude-code'),
                (Join-Path $env:LOCALAPPDATA 'Programs\Claude Code')
            )
            foreach ($d in $candidates) {
                if (Test-Path (Join-Path $d 'claude.exe')) {
                    Add-DirToUserPath -Dir $d -Reason 'winget 安装目录'
                    break
                }
            }
        }
        'npm' {
            if (Has-Command 'npm') {
                $npmPrefix = (& npm config get prefix).Trim()
                if ($npmPrefix -and (Test-Path (Join-Path $npmPrefix 'claude.cmd'))) {
                    Add-DirToUserPath -Dir $npmPrefix -Reason 'npm 全局目录'
                } else {
                    Write-Warn2 "    npm prefix 不含 claude：$npmPrefix"
                }
            }
        }
    }

    # 刷新当前进程 PATH 后再校验
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
                [Environment]::GetEnvironmentVariable('Path', 'User')

    if (Has-Command 'claude') {
        Write-Ok "    PATH 校验通过：$((Get-Command 'claude').Source)"
        return $true
    } else {
        Write-Warn2 "    claude 仍不可见，建议重开 PowerShell"
        return $false
    }
}

function Install-ClaudeCode {
    Write-Step 'Claude Code 安装（三级兜底）'

    if (Has-Command 'claude') {
        $existing = (& claude --version 2>$null) -join ''
        Write-Ok "已检测到 Claude Code: $existing，跳过安装"
        Ensure-ClaudeOnPath -InstallMethod 'native' | Out-Null
        return
    }

    $methods = @(
        @{ Name = 'Native (GCS 直连)'; Action = { Install-Native } },
        @{ Name = 'winget';            Action = { Install-Winget } },
        @{ Name = 'npm';               Action = { Install-Npm } }
    )

    $succeeded = $null
    foreach ($m in $methods) {
        try {
            $succeeded = & $m.Action
            break
        } catch {
            Write-Warn2 "$($m.Name) 失败：$_"
        }
    }

    if (-not $succeeded) {
        Write-Err '三种安装方式全部失败，请手动安装后重试（可加 -SkipClaudeInstall）'
        exit 1
    }

    # 统一做 PATH 处理（无论哪种方式都跑）
    Ensure-ClaudeOnPath -InstallMethod $succeeded | Out-Null
}

function Get-InstalledClaudeVersion {
    $command = if (Test-Path $LINK_PATH) { $LINK_PATH } elseif (Has-Command 'claude') { (Get-Command 'claude').Source } else { $null }
    if (-not $command) { return $null }

    try {
        $version = (& $command --version 2>$null) -join ''
        if ([string]::IsNullOrWhiteSpace($version)) { return $null }
        return $version.Trim()
    } catch {
        return $null
    }
}

function Upgrade-ClaudeCode {
    Write-Step 'Claude Code 升级（原生二进制）'

    $previousVersion = Get-InstalledClaudeVersion
    if ($previousVersion) {
        Write-Info "  当前版本: $previousVersion"
    } else {
        Write-Info '  未检测到现有 Claude Code，将安装目标版本'
    }
    $targetLabel = if ($ClaudeVersion -eq 'latest' -or $ClaudeVersion -eq 'stable') { '最新稳定版' } else { "v$ClaudeVersion" }
    Write-Info "  目标版本: $targetLabel"

    # 指定版本升级必须使用官方原生发行包；winget/npm 无法可靠地锁定目标版本。
    Install-Native | Out-Null
    Ensure-ClaudeOnPath -InstallMethod 'native' | Out-Null

    $currentVersion = Get-InstalledClaudeVersion
    if ($currentVersion) {
        Write-Ok "Claude Code 已升级到 $currentVersion"
    } else {
        Write-Warn2 '升级完成，但当前终端无法读取新版本；请重新打开 PowerShell 后运行 claude --version 确认'
    }
}

# ============================================================
#  阶段 3.4：预填 ~/.claude.json onboarding 标记（仅 hasCompletedOnboarding）
# ============================================================
function Install-ClaudeJson {
    Write-Step '预填 ~/.claude.json onboarding 标记（跳过全局引导）'

    # 读取现有 .claude.json，合并后回写（避免覆盖 installMethod / autoUpdates / projects 等关键字段）
    $cfg = @{}
    if (Test-Path $CONFIG_PATH) {
        try {
            $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
            $raw = [System.IO.File]::ReadAllText($CONFIG_PATH, $utf8NoBom)
            if (-not [string]::IsNullOrWhiteSpace($raw)) {
                $parsed = ConvertFrom-JsonToHashtable $raw
                if ($null -ne $parsed) { $cfg = $parsed }
            }
        } catch {
            Write-Warn2 "  现有 .claude.json 解析失败，将以空对象为基础重新构建：$_"
            $cfg = @{}
        }
    }
    if ($null -eq $cfg) { $cfg = @{} }

    # 仅预填全局 onboarding 标记（刚需、首启向导、零安全风险）
    # hasTrustDialogAccepted / hasCompletedProjectOnboarding 不在脚本处理：
    #   - 前者是工作区信任大门，CVE-2026-33068 后保持默认弹出让用户决策更安全
    #   - 后者需按项目绝对路径写入，反幂等、用户友好度低
    $cfg['hasCompletedOnboarding'] = $true
    Write-Info '    [SET] hasCompletedOnboarding = true（跳过主题选择 / 欢迎向导）'

    # 原子写：先写 .tmp 再 Move-Item，避免崩溃留半截
    $tmp = "$CONFIG_PATH.tmp"
    $json = $cfg | ConvertTo-Json -Depth 10
    try {
        $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
        [System.IO.File]::WriteAllText($tmp, $json, $utf8NoBom)
        Move-Item -Force $tmp $CONFIG_PATH
        Write-Ok "  $CONFIG_PATH"
    } catch {
        if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
        Write-Err "  .claude.json 写入失败：$_"
    }
}

# ============================================================
#  深度合并辅助函数
# ============================================================

# 从 hook 条目中提取 command 字符串（用于去重）
function Get-HookCommand {
    param([hashtable]$HookEntry)
    if ($HookEntry.ContainsKey('command')) { return $HookEntry['command'] }
    return $null
}

# 从 hook matcher 组中提取所有 command（用于去重）
function Get-MatcherCommands {
    param([hashtable]$MatcherEntry)
    $cmds = @()
    if ($MatcherEntry.ContainsKey('hooks')) {
        foreach ($h in $MatcherEntry['hooks']) {
            $c = Get-HookCommand $h
            if ($null -ne $c) { $cmds += $c }
        }
    }
    return $cmds
}

# 合并 hooks：按事件合并，每个事件内用户 hooks 保留 + 我们的 hooks 追加（按 command 去重）
function Merge-Hooks {
    param(
        [hashtable]$Ours,
        [hashtable]$Theirs
    )
    $result = @{}
    # 先复制用户的所有事件
    foreach ($evt in $Theirs.Keys) {
        $result[$evt] = $Theirs[$evt]
    }
    # 遍历我们的 hooks，按事件追加
    foreach ($evt in $Ours.Keys) {
        $ourMatchers = @($Ours[$evt])
        if (-not $result.ContainsKey($evt)) {
            # 用户没有这个事件，直接用我们的
            $result[$evt] = $ourMatchers
            continue
        }
        # 用户已有该事件：收集用户已有的 command 集合
        $userMatcherList = @($result[$evt])
        $existingCmds = @{}
        foreach ($um in $userMatcherList) {
            foreach ($c in (Get-MatcherCommands $um)) {
                $existingCmds[$c] = $true
            }
        }
        # 追加我们的 matcher（按 command 去重）
        foreach ($om in $ourMatchers) {
            $ourCmds = Get-MatcherCommands $om
            $hasNew = $false
            foreach ($oc in $ourCmds) {
                if (-not $existingCmds.ContainsKey($oc)) {
                    $hasNew = $true
                    break
                }
            }
            if ($hasNew) {
                $userMatcherList = @($userMatcherList) + @($om)
                foreach ($oc in $ourCmds) {
                    $existingCmds[$oc] = $true
                }
            }
        }
        $result[$evt] = $userMatcherList
    }
    return $result
}

# 合并 permissions：allow/deny 数组并集去重，defaultMode 用户优先
function Merge-Permissions {
    param(
        [hashtable]$Ours,
        [hashtable]$Theirs
    )
    $result = @{}

    # allow: 并集去重
    $allowSet = [System.Collections.Generic.HashSet[string]]::new()
    if ($Theirs.ContainsKey('allow')) {
        foreach ($a in $Theirs['allow']) { $allowSet.Add($a) | Out-Null }
    }
    if ($Ours.ContainsKey('allow')) {
        foreach ($a in $Ours['allow']) { $allowSet.Add($a) | Out-Null }
    }
    $result['allow'] = @($allowSet)

    # deny: 并集去重
    $denySet = [System.Collections.Generic.HashSet[string]]::new()
    if ($Theirs.ContainsKey('deny')) {
        foreach ($d in $Theirs['deny']) { $denySet.Add($d) | Out-Null }
    }
    if ($Ours.ContainsKey('deny')) {
        foreach ($d in $Ours['deny']) { $denySet.Add($d) | Out-Null }
    }
    $result['deny'] = @($denySet)

    # defaultMode: 用户优先
    if ($Theirs.ContainsKey('defaultMode')) {
        $result['defaultMode'] = $Theirs['defaultMode']
    } elseif ($Ours.ContainsKey('defaultMode')) {
        $result['defaultMode'] = $Ours['defaultMode']
    }

    # skipDangerousModePermissionPrompt: 用户优先
    if ($Theirs.ContainsKey('skipDangerousModePermissionPrompt')) {
        $result['skipDangerousModePermissionPrompt'] = $Theirs['skipDangerousModePermissionPrompt']
    } elseif ($Ours.ContainsKey('skipDangerousModePermissionPrompt')) {
        $result['skipDangerousModePermissionPrompt'] = $Ours['skipDangerousModePermissionPrompt']
    }

    # 保留用户的其他 permissions 字段
    foreach ($key in $Theirs.Keys) {
        if (-not $result.ContainsKey($key)) {
            $result[$key] = $Theirs[$key]
        }
    }

    return $result
}

# ============================================================
#  settings.json 写入策略选择（检测到已有配置时交互）
# ============================================================
function Read-SettingsJsonStrategy {
    $SETTINGS_PATH = Join-Path $CLAUDE_HOME 'settings.json'
    if (-not (Test-Path $SETTINGS_PATH)) {
        return 'fresh'   # 不存在，直接创建
    }

    Write-Host ''
    Write-Host '  ┌─────────────────────────────────────────────────────────┐' -ForegroundColor Yellow
    Write-Host '  │  检测到现有的 ~/.claude/settings.json                    │' -ForegroundColor Yellow
    Write-Host '  │  选择处理策略：                                         │' -ForegroundColor Yellow
    Write-Host '  │                                                         │' -ForegroundColor Yellow
    Write-Host '  │  1. 覆盖  备份后整体替换（最简单，但丢失用户 env/MCP 等）│' -ForegroundColor Yellow
    Write-Host '  │  2. 合并  保留用户 env/permissions，添加 hooks/statusLine│' -ForegroundColor Green
    Write-Host '  │  3. 跳过  仅部署 hooks 文件，不动 settings.json         │' -ForegroundColor Cyan
    Write-Host '  │  4. 取消  保留所有现有配置，退出安装                     │' -ForegroundColor Red
    Write-Host '  └─────────────────────────────────────────────────────────┘' -ForegroundColor Yellow
    Write-Host ''

    $choice = Read-Host '  请选择 [1/2/3/4]（默认 2: 合并）'

    switch ($choice) {
        '1' { return 'overwrite' }
        '2' { return 'merge' }
        '3' { return 'skip' }
        '4' { return 'cancel' }
        default { return 'merge' }
    }
}

# ============================================================
#  阶段 3.5：写入 ~/.claude/settings.json（合并 GeneralConfiguration）
# ============================================================
function Install-SettingsJson {
    param(
        [ValidateSet('fresh', 'overwrite', 'merge', 'skip')]
        [string]$Strategy = 'fresh'
    )

    $SETTINGS_PATH = Join-Path $CLAUDE_HOME 'settings.json'

    # 跳过策略：仅报告，不写入
    if ($Strategy -eq 'skip') {
        Write-Step 'settings.json：已跳过（用户选择）'
        Write-Info '  hooks 文件已部署，但 settings.json 未更新'
        Write-Info '  需手动合并或通过 cc-switch 启用 hooks'
        return
    }

    # 基础配置：插件 + 状态行 + hooks + 权限
    $settings = [ordered]@{
        '$schema'                  = 'https://json.schemastore.org/claude-code-settings.json'
        'enabledPlugins'           = [ordered]@{
            'feature-dev@claude-plugins-official' = $true
        }
        'env'                      = [ordered]@{
            'DISABLE_AUTO_COMPACT'                       = '1'
            'CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC'   = '1'
        }
        'autoConnectIde'           = $true
        'statusLine'               = [ordered]@{
            'type'    = 'command'
            'command' = 'uv run --script ~/.claude/status_lines/status_line_v6.py'
        }
        'hooks'                    = [ordered]@{
            'SessionStart'        = @(
                [ordered]@{
                    'hooks' = @(
                        [ordered]@{
                            'type'    = 'command'
                            'command' = 'uv run --script ~/.claude/hooks/session_start.py --load-context'
                            'timeout' = 15
                        }
                    )
                }
            )
            'UserPromptSubmit'    = @(
                [ordered]@{
                    'hooks' = @(
                        [ordered]@{
                            'type'    = 'command'
                            'command' = 'uv run --script ~/.claude/hooks/user_prompt_submit.py --log-only'
                            'timeout' = 10
                        }
                    )
                }
            )
            'PreToolUse'          = @(
                [ordered]@{
                    'matcher' = 'Bash'
                    'hooks'   = @(
                        [ordered]@{
                            'type'    = 'command'
                            'command' = 'uv run --script ~/.claude/hooks/block_dangerous.py'
                            'timeout' = 15
                        },
                        [ordered]@{
                            'type'    = 'command'
                            'command' = 'uv run --script ~/.claude/hooks/pre_tool_use.py'
                            'timeout' = 10
                        }
                    )
                },
                [ordered]@{
                    'matcher' = 'Read|Edit|MultiEdit|Write'
                    'hooks'   = @(
                        [ordered]@{
                            'type'    = 'command'
                            'command' = 'uv run --script ~/.claude/hooks/pre_tool_use.py'
                            'timeout' = 10
                        }
                    )
                }
            )
            'PostToolUse'         = @(
                [ordered]@{
                    'matcher' = 'Write|Edit|MultiEdit'
                    'hooks'   = @(
                        [ordered]@{
                            'type'    = 'command'
                            'command' = 'uv run --script ~/.claude/hooks/auto_format.py'
                            'timeout' = 30
                        },
                        [ordered]@{
                            'type'    = 'command'
                            'command' = 'uv run --script ~/.claude/hooks/check_secrets.py'
                            'timeout' = 15
                        },
                        [ordered]@{
                            'type'    = 'command'
                            'command' = 'uv run --script ~/.claude/hooks/post_tool_use.py'
                            'timeout' = 10
                        }
                    )
                }
            )
            'PostToolUseFailure'  = @(
                [ordered]@{
                    'hooks' = @(
                        [ordered]@{
                            'type'    = 'command'
                            'command' = 'uv run --script ~/.claude/hooks/post_tool_use_failure.py'
                            'timeout' = 10
                        }
                    )
                }
            )
            'Stop'                = @(
                [ordered]@{
                    'hooks' = @(
                        [ordered]@{
                            'type'    = 'command'
                            'command' = 'uv run --script ~/.claude/hooks/verify_on_stop.py'
                            'timeout' = 120
                        }
                    )
                }
            )
            'SessionEnd'          = @(
                [ordered]@{
                    'hooks' = @(
                        [ordered]@{
                            'type'    = 'command'
                            'command' = 'uv run --script ~/.claude/hooks/session_end.py'
                            'timeout' = 10
                        }
                    )
                }
            )
        }
        'permissions'              = [ordered]@{
            'allow'                              = @(
                'Bash(cargo check*)', 'Bash(cargo build*)', 'Bash(cargo test*)',
                'Bash(cargo fmt*)', 'Bash(cargo tauri*)',
                'Bash(npm run*)', 'Bash(pnpm*)', 'Bash(bun*)',
                'Bash(uv run*)', 'Bash(uv pip*)', 'Bash(ruff*)',
                'Bash(rg*)', 'Bash(fd*)',
                'Bash(git status*)', 'Bash(git diff*)', 'Bash(git log*)',
                'Bash(git add*)', 'Bash(git commit*)', 'Bash(git push*)',
                'Bash(git pull*)', 'Bash(git checkout*)', 'Bash(git branch*)'
            )
            'deny'                               = @(
                'Read(./.env)', 'Read(./.env.*)', 'Read(./secrets/**)',
                'Read(**/id_rsa)', 'Read(**/id_ed25519)',
                'Bash(curl http://*)'
            )
            'defaultMode'                        = 'bypassPermissions'
            'skipDangerousModePermissionPrompt'  = $true
        }
    }

    # 根据策略决定写入方式
    $stepLabel = switch ($Strategy) {
        'fresh'     { '生成 ~/.claude/settings.json（启用 hooks）' }
        'overwrite' { '覆盖 ~/.claude/settings.json（备份已完成）' }
        'merge'     { '合并 ~/.claude/settings.json（保留用户配置 + 添加 hooks）' }
    }
    Write-Step $stepLabel

    if ($Strategy -eq 'merge') {
        $existing = @{}
        if (Test-Path $SETTINGS_PATH) {
            try {
                $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
                $raw = [System.IO.File]::ReadAllText($SETTINGS_PATH, $utf8NoBom)
                if (-not [string]::IsNullOrWhiteSpace($raw)) {
                    $parsed = ConvertFrom-JsonToHashtable $raw
                    if ($null -ne $parsed) { $existing = $parsed }
                }
            } catch {
                Write-Warn2 "  现有 settings.json 解析失败，将整体覆盖：$_"
            }
        }

        # ── 深度合并各字段 ──

        # 1. enabledPlugins: 双方合并，用户的开关优先
        if ($settings.Keys -contains 'enabledPlugins' -and $existing.ContainsKey('enabledPlugins')) {
            foreach ($pk in $settings['enabledPlugins'].Keys) {
                if (-not $existing['enabledPlugins'].ContainsKey($pk)) {
                    $existing['enabledPlugins'][$pk] = $settings['enabledPlugins'][$pk]
                }
            }
            $settings['enabledPlugins'] = $existing['enabledPlugins']
        }

        # 2. env: 用户优先（保护 API key / base URL），缺失 key 用我们补
        if ($existing.ContainsKey('env') -and $settings.Keys -contains 'env') {
            foreach ($ek in $settings['env'].Keys) {
                if (-not $existing['env'].ContainsKey($ek)) {
                    $existing['env'][$ek] = $settings['env'][$ek]
                }
            }
            $settings['env'] = $existing['env']
        }

        # 3. hooks: 按事件合并，每个事件内的 hooks 列表追加我们的（按 command 去重）
        if ($settings.Keys -contains 'hooks' -and $existing.ContainsKey('hooks')) {
            $settings['hooks'] = Merge-Hooks -Ours $settings['hooks'] -Theirs $existing['hooks']
        }

        # 4. permissions: allow/deny 数组并集去重，defaultMode 用户优先
        if ($settings.Keys -contains 'permissions' -and $existing.ContainsKey('permissions')) {
            $settings['permissions'] = Merge-Permissions -Ours $settings['permissions'] -Theirs $existing['permissions']
        }

        # 5. statusLine: 项目优先（统一 status_line_v6）
        # （已在 $settings 中，无需额外处理）

        # 6. autoConnectIde: 项目优先
        # （已在 $settings 中，无需额外处理）

        # 7. 保留用户的其他字段（如 ccmManaged, ccmProvider, $schema 等）
        foreach ($key in $existing.Keys) {
            if ($settings.Keys -notcontains $key) {
                $settings[$key] = $existing[$key]
            }
        }
        Write-Info '  深度合并：env 用户优先 / hooks 按事件追加去重 / permissions 并集 / 其他字段保留'
    }

    try {
        # 确保目录存在
        $settingsDir = Split-Path $SETTINGS_PATH -Parent
        if (-not (Test-Path $settingsDir)) { New-Item -ItemType Directory -Force -Path $settingsDir | Out-Null }

        $json = $settings | ConvertTo-Json -Depth 10
        # 原子写：先 .tmp 再 Move-Item
        $tmp = "$SETTINGS_PATH.tmp"
        $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
        [System.IO.File]::WriteAllText($tmp, $json, $utf8NoBom)
        Move-Item -Force $tmp $SETTINGS_PATH
        Write-Ok "  $SETTINGS_PATH"
        $label = if ($Strategy -eq 'merge') { '合并' } else { '写入' }
        Write-Info "  已${label}：enabledPlugins + env + statusLine + 7 个 hooks 事件 + permissions"
    } catch {
        if (Test-Path "$SETTINGS_PATH.tmp") { Remove-Item "$SETTINGS_PATH.tmp" -Force -ErrorAction SilentlyContinue }
        Write-Err "  settings.json 写入失败：$_"
    }
}

# ============================================================
#  阶段 3：hooks 与 status_line 部署
# ============================================================
function Invoke-DownloadFile {
    param(
        [string]$Url,
        [string]$Dest,
        [int]$MaxRetry = 3
    )
    for ($i = 1; $i -le $MaxRetry; $i++) {
        try {
            Invoke-WebRequest -Uri $Url -OutFile $Dest -TimeoutSec 30 -ErrorAction Stop
            if ((Test-Path $Dest) -and (Get-Item $Dest).Length -gt 0) {
                return $true
            }
            throw '下载文件为空'
        } catch {
            if ($i -eq $MaxRetry) {
                throw "下载失败（重试 $MaxRetry 次）：$Url — $_"
            }
            Write-Warn2 "    重试 $i/$MaxRetry：$_"
            Start-Sleep -Seconds 2
        }
    }
}

function Install-Hooks {
    Write-Step '部署 hooks 与 status_line'

    New-Item -ItemType Directory -Force -Path $HOOK_DIR, $SL_DIR, $LOG_DIR | Out-Null
    Write-Ok "目录就绪：$CLAUDE_HOME"

    Write-Info "  下载 hooks（$($HOOK_SOURCES.Count) 个）:"
    foreach ($entry in $HOOK_SOURCES.GetEnumerator()) {
        $f = $entry.Key
        $base = $entry.Value
        $dest = Join-Path $HOOK_DIR $f
        if (Test-Path $dest) {
            Write-Info "    [SKIP] $f（已存在）"
            continue
        }
        Write-Info "    [GET ] $f"
        try {
            $url = "$base/$f"
            Invoke-DownloadFile -Url $url -Dest $dest
            # SHA256 校验
            if ($CHECKSUMS.ContainsKey($f)) {
                $actual = (Get-FileHash -Path $dest -Algorithm SHA256).Hash.ToUpper()
                $expected = $CHECKSUMS[$f].ToUpper()
                if ($actual -ne $expected) {
                    Remove-Item $dest -Force -ErrorAction SilentlyContinue
                    throw "SHA256 mismatch: expected $expected, got $actual"
                }
                Write-Ok "    $f (SHA256 verified)"
            } else {
                Write-Warn2 "    $f (no checksum - skip verification)"
            }
        } catch {
            Write-Err "    $f 下载失败：$_"
        }
    }

    $slDest = Join-Path $SL_DIR $STATUS_LINE
    if (Test-Path $slDest) {
        Write-Info "  [SKIP] $STATUS_LINE（已存在）"
    } else {
        Write-Info "  [GET ] $STATUS_LINE"
        try {
            $slUrl = "$DISLER_REPO/status_lines/$STATUS_LINE"
            Invoke-DownloadFile -Url $slUrl -Dest $slDest
            # SHA256 校验
            if ($CHECKSUMS.ContainsKey($STATUS_LINE)) {
                $actual = (Get-FileHash -Path $slDest -Algorithm SHA256).Hash.ToUpper()
                $expected = $CHECKSUMS[$STATUS_LINE].ToUpper()
                if ($actual -ne $expected) {
                    Remove-Item $slDest -Force -ErrorAction SilentlyContinue
                    throw "SHA256 mismatch: expected $expected, got $actual"
                }
                Write-Ok "  $STATUS_LINE (SHA256 verified)"
            } else {
                Write-Warn2 "  $STATUS_LINE (no checksum - skip verification)"
            }
        } catch {
            Write-Err "  $STATUS_LINE 下载失败：$_"
        }
    }
}

# ============================================================
#  阶段 4：完成总结
# ============================================================
function Show-Summary {
    Write-Step '部署完成'

    if ($InstallMode -eq 'Full') {
        $hookCount = (Get-ChildItem $HOOK_DIR -Filter *.py -ErrorAction SilentlyContinue).Count
        $slCount   = (Get-ChildItem $SL_DIR -Filter *.py -ErrorAction SilentlyContinue).Count
        $settingsExists = Test-Path (Join-Path $CLAUDE_HOME 'settings.json')
        $onboardingDone = $false
        if (Test-Path $CONFIG_PATH) {
            try {
                $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
                $cfgRaw = [System.IO.File]::ReadAllText($CONFIG_PATH, $utf8NoBom)
                $cfgObj = $cfgRaw | ConvertFrom-Json
                $onboardingDone = [bool]$cfgObj.hasCompletedOnboarding
            } catch {}
        }

        Write-Info ''
        Write-Host '  已部署文件：' -ForegroundColor White
        Write-Info "    hooks 目录：$hookCount 个 .py（含 4 个用户自写）"
        Write-Info "    status_line 目录：$slCount 个 .py"
        Write-Info "    settings.json：$(if ($settingsExists) { '已生成 ✓' } else { '未生成（跳过）' })"
        if ($settingsExists -and $settingsStrategy -eq 'merge') {
            Write-Info '      策略：合并（保留用户 env + 项目 hooks）'
        } elseif ($settingsExists -and $settingsStrategy -eq 'overwrite') {
            Write-Info '      策略：覆盖（备份在 ~/.claude/backups/）'
        }
        Write-Info "    ~/.claude.json: hasCompletedOnboarding = $(if ($onboardingDone) { 'true ✓' } else { 'false ✗' })"
    } else {
        Write-Info ''
        Write-Host '  已部署文件：' -ForegroundColor White
        Write-Info '    Claude Code 本体（hooks 未安装）'
    }

    Write-Info ''
    Write-Host '  后续步骤：' -ForegroundColor White
    Write-Info '    1. 打开 cc-switch 切换到任意供应商（hooks 已自动启用）'
    Write-Info '    2. 启动 Claude Code 验证：第一次会话应看到 status line 进度条'
    if ($InstallMode -eq 'Full') {
        Write-Info '    3. 测试：写一个 .py 文件，应自动 ruff format'
    } else {
        Write-Info '    3. 如需 hooks，运行：.\setup-claude.ps1 -InstallMode Full -SkipClaudeInstall'
    }

    Write-Info ''
    Write-Host '  验证命令：' -ForegroundColor White
    Write-Info '    claude --version'
    Write-Info '    uv --version'
    if ($InstallMode -eq 'Full') {
        Write-Info "    cat $((Join-Path $CLAUDE_HOME 'settings.json')) | ConvertFrom-Json"
    }

    Write-Host ''
    Write-Host '  [OK] 一切就绪' -ForegroundColor Green
    Write-Host ''
}

# ============================================================
#  主流程
# ============================================================
try {
    $esc = [char]27
    # OKLCH 校色色板（来源：Microsoft.PowerShell_profile.ps1）
    Write-Host ''
    Write-Host "$esc[38;2;59;156;246m                                          ████  ███   ████  ███    ██  ██  ██$esc[0m"   # cyberBlue
    Write-Host "$esc[38;2;0;188;197m                                          █     █  █  █     █  █  █  █ ██ █  █$esc[0m" # neonCyan
    Write-Host "$esc[38;2;193;137;252m                                          ███   ███   █ ██  ███   ███  ██ ███$esc[0m"  # electricPurple
    Write-Host "$esc[38;2;251;108;160m                                          █     █ █   █  █  █     █  █ ██ █  █$esc[0m" # neonPink
    Write-Host "$esc[38;2;183;184;64m                                          ████  █  █  ████  ████  █  █ ██ █  █$esc[0m" # neonYellow
    Write-Host ''
    Write-Host "$esc[38;2;219;215;205m                                          Claude Code Bootstrap  v1.6.0$esc[0m"        # neonWhite
    Write-Host "$esc[38;2;230;152;37m                                          by 宝藏二哥AIA$esc[0m"                  # fluorescentOrange

    # 升级不依赖 Git、UV、Node.js，也不应触发其自动安装。
    if ($Upgrade) {
        if ($SkipClaudeInstall) {
            throw '-Upgrade 与 -SkipClaudeInstall 不能同时使用'
        }
        if (-not [Environment]::Is64BitOperatingSystem) {
            throw 'Claude Code 升级仅支持 64 位 Windows'
        }

        Upgrade-ClaudeCode
        Write-Host ''
        Write-Host '  [OK] 升级完成' -ForegroundColor Green
        Write-Host ''
        exit 0
    }

    # 先检测环境，再选择安装模式
    try {
        $prereqOk = Test-Prerequisites
    } catch {
        Write-Err "环境检测失败: $_"
        Write-Host $_.ScriptStackTrace -ForegroundColor Red
        $prereqOk = $false
    }
    if (-not $prereqOk) {
        Write-Host ''
        Write-Host '  按回车键退出...' -ForegroundColor Gray
        [void][Console]::ReadLine()
        exit 1
    }

    # 确定安装模式
    if (-not $InstallMode) {
        $InstallMode = Read-InstallMode
    }
    Write-Host ''
    Write-Host "  安装模式：$InstallMode" -ForegroundColor $(if ($InstallMode -eq 'Full') { 'Yellow' } else { 'Green' })

    # 防御性初始化
    $settingsStrategy = 'fresh'

    # 检测现有配置（报告给用户，返回是否有冲突）
    $hasExisting = Test-ExistingConfig

    if (-not $SkipClaudeInstall) { Install-ClaudeCode }
    else { Write-Step 'Claude Code 安装：已跳过（-SkipClaudeInstall）' }

    if ($InstallMode -eq 'Full') {
        # 写入 settings.json 前自动备份
        Backup-SettingsJson

        # 检测策略（已有配置时交互选择，全新环境直接创建）
        $settingsStrategy = Read-SettingsJsonStrategy
        if ($settingsStrategy -eq 'cancel') {
            Write-Host ''
            Write-Host '  [CANCEL] 用户取消安装，所有现有配置保持不变' -ForegroundColor Yellow
            Write-Host ''
            exit 0
        }

        Install-Hooks
        Install-ClaudeJson
        Install-SettingsJson -Strategy $settingsStrategy
    } else {
        Write-Step 'hooks 部署：已跳过（Minimal 模式）'
        Write-Info '  如需后续安装 hooks，可重新运行并选择 Full 模式：'
        Write-Info '    .\setup-claude.ps1 -InstallMode Full -SkipClaudeInstall'
    }

    Show-Summary
} catch {
    Write-Host ''
    Write-Host "  [FATAL] $_" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor Red
    Write-Host ''
    Write-Host '  Press Enter to exit...' -ForegroundColor Gray
    [void][Console]::ReadLine()
    exit 1
}
