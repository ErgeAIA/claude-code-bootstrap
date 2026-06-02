<#
.SYNOPSIS
    Claude Code 一键部署脚本（环境检测 + 安装 + hooks 部署）
.DESCRIPTION
    1. 前置环境检测：PowerShell、64 位、Git、UV（自动安装）、Node.js
    2. Claude Code 安装：native (GCS) → winget → npm 三级兜底
    3. 下载 disler 仓库的 6 个 hooks + status_line_v6
    4. 检查用户自写 hooks 就位情况
    5. 统一处理 PATH（任何安装方式都跑）

    通常由 install.ps1 拉取并调用，不建议直接运行。
.PARAMETER InstallTimeout
    native 安装的超时秒数。默认 60 秒
.PARAMETER SkipClaudeInstall
    仅部署 hooks，跳过 Claude Code 安装
.PARAMETER ClaudeVersion
    指定安装版本，'latest' 或具体版本号如 '2.1.153'。默认 latest
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\setup-claude.ps1
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\setup-claude.ps1 -SkipClaudeInstall
#>

[CmdletBinding()]
param(
    [int]$InstallTimeout = 60,
    [switch]$SkipClaudeInstall,
    [ValidatePattern('^(stable|latest|\d+\.\d+\.\d+(-[^\s]+)?)$')]
    [string]$ClaudeVersion = 'latest'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding           = [System.Text.Encoding]::UTF8

# ============================================================
#  常量
# ============================================================
$GCS_BUCKET   = 'https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases'
$REPO_BASE    = 'https://raw.githubusercontent.com/disler/claude-code-hooks-mastery/main/.claude'

$CLAUDE_HOME  = Join-Path $env:USERPROFILE '.claude'
$HOOK_DIR     = Join-Path $CLAUDE_HOME 'hooks'
$SL_DIR       = Join-Path $CLAUDE_HOME 'status_lines'
$LOG_DIR      = Join-Path $CLAUDE_HOME 'logs'

$INSTALL_BASE = Join-Path $env:USERPROFILE '.local\share\claude'
$VERSIONS_DIR = Join-Path $INSTALL_BASE 'versions'
$BIN_DIR      = Join-Path $env:USERPROFILE '.local\bin'
$LINK_PATH    = Join-Path $BIN_DIR 'claude.exe'
$CONFIG_PATH  = Join-Path $env:USERPROFILE '.claude.json'

$DISLER_HOOKS = @(
    'pre_tool_use.py',
    'post_tool_use.py',
    'session_start.py',
    'user_prompt_submit.py',
    'post_tool_use_failure.py',
    'session_end.py'
)
$USER_HOOKS = @(
    'auto_format.py',
    'block_dangerous.py',
    'check_secrets.py',
    'verify_on_stop.py'
)
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

# ============================================================
#  阶段 1：前置环境检测
# ============================================================
function Test-Prerequisites {
    Write-Step '前置环境检测'

    if ($PSVersionTable.PSVersion.Major -lt 5) {
        Write-Err "需要 PowerShell 5.1+，当前 $($PSVersionTable.PSVersion)"
        exit 1
    }
    Write-Ok "PowerShell $($PSVersionTable.PSVersion)"

    if (-not [Environment]::Is64BitOperatingSystem) {
        Write-Err 'Claude Code 不支持 32 位 Windows'
        exit 1
    }
    Write-Ok '64 位 Windows'

    if (Has-Command 'git') {
        $gitVer = (& git --version) -replace 'git version ', ''
        Write-Ok "Git $gitVer"
    } else {
        Write-Warn2 'Git 未安装。verify_on_stop.py / session_start.py 依赖 Git'
        Write-Info '  建议安装：winget install Git.Git'
    }

    if (Has-Command 'uv') {
        $uvVer = (& uv --version) -replace 'uv ', ''
        Write-Ok "UV $uvVer"
    } else {
        Write-Warn2 'UV 未安装，正在自动安装...'
        try {
            Invoke-RestMethod 'https://astral.sh/uv/install.ps1' | Invoke-Expression
            if (Has-Command 'uv') {
                Write-Ok 'UV 安装成功'
            } else {
                Write-Err 'UV 自动安装失败，请手动运行：irm https://astral.sh/uv/install.ps1 | iex'
                exit 1
            }
        } catch {
            Write-Err "UV 自动安装失败：$_"
            exit 1
        }
    }

    if (Has-Command 'node') {
        $nodeVer = (& node --version)
        Write-Ok "Node.js $nodeVer（npm 兜底备用）"
    } else {
        Write-Info 'Node.js 未安装（仅 npm 兜底需要）'
    }
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

        return 
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
    $cfg = 
    if (Test-Path $CONFIG_PATH) {
        try { $cfg = Get-Content -Raw $CONFIG_PATH | ConvertFrom-Json -AsHashtable } catch {}
        if (-not $cfg) { $cfg =  }
    }
    $cfg['installMethod'] = 'native'
    $cfg['autoUpdates']   = $false
    if (-not $cfg.ContainsKey('firstStartTime')) {
        $cfg['firstStartTime'] = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    }
    $cfg | ConvertTo-Json -Depth 10 | Set-Content -Path $CONFIG_PATH -Encoding UTF8

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
    Write-Info '方式 3/3：npm 全局（官方已不推荐，仅作兜底）'
    if (-not (Has-Command 'npm')) {
        throw 'npm 未安装。请先安装 Node.js: winget install OpenJS.NodeJS.LTS'
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
         },
         },
         }
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
            if ($i -eq $MaxRetry) { throw $_ }
            Write-Warn2 "    第 $i 次失败：$_"
            Start-Sleep -Seconds 2
        }
    }
}

function Install-Hooks {
    Write-Step '部署 hooks 与 status_line'

    New-Item -ItemType Directory -Force -Path $HOOK_DIR, $SL_DIR, $LOG_DIR | Out-Null
    Write-Ok "目录就绪：$CLAUDE_HOME"

    Write-Info '  下载 disler 仓库的 6 个 hooks:'
    foreach ($f in $DISLER_HOOKS) {
        $dest = Join-Path $HOOK_DIR $f
        if (Test-Path $dest) {
            Write-Info "    [SKIP] $f（已存在）"
            continue
        }
        Write-Info "    [GET ] $f"
        try {
            Invoke-DownloadFile -Url "$REPO_BASE/hooks/$f" -Dest $dest
            Write-Ok "    $f"
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
            Invoke-DownloadFile -Url "$REPO_BASE/status_lines/$STATUS_LINE" -Dest $slDest
            Write-Ok "  $STATUS_LINE"
        } catch {
            Write-Err "  $STATUS_LINE 下载失败：$_"
        }
    }

    Write-Info ''
    Write-Info '  检查用户自写 hooks（需自行放置到 $HOOK_DIR）：'
    $missing = @()
    foreach ($f in $USER_HOOKS) {
        $p = Join-Path $HOOK_DIR $f
        if (Test-Path $p) {
            Write-Ok "    $f"
        } else {
            Write-Warn2 "    缺失：$f"
            $missing += $f
        }
    }
    if ($missing.Count -gt 0) {
        Write-Warn2 "  请将这 $($missing.Count) 个脚本放到：$HOOK_DIR"
    }
}

# ============================================================
#  阶段 4：完成总结
# ============================================================
function Show-Summary {
    Write-Step '部署完成'

    $hookCount = (Get-ChildItem $HOOK_DIR -Filter *.py -ErrorAction SilentlyContinue).Count
    $slCount   = (Get-ChildItem $SL_DIR -Filter *.py -ErrorAction SilentlyContinue).Count

    Write-Info ''
    Write-Host '  已部署文件：' -ForegroundColor White
    Write-Info "    hooks 目录：$hookCount 个 .py"
    Write-Info "    status_line 目录：$slCount 个 .py"

    Write-Info ''
    Write-Host '  后续步骤：' -ForegroundColor White
    Write-Info '    1. 打开 cc-switch → 编辑通用配置 → 粘贴 settings.json'
    Write-Info '    2. 切换到目标供应商 → 启动 Claude Code 验证'
    Write-Info '    3. 第一次会话观察 status line（应显示上下文窗口进度条）'

    Write-Info ''
    Write-Host '  验证命令：' -ForegroundColor White
    Write-Info '    claude --version'
    Write-Info '    uv --version'

    Write-Host ''
    Write-Host '  [OK] 一切就绪' -ForegroundColor Green
    Write-Host ''
}

# ============================================================
#  主流程
# ============================================================
try {
    Write-Host ''
    Write-Host '  Claude Code 一键部署脚本' -ForegroundColor Cyan
    Write-Host '  =========================' -ForegroundColor Cyan

    Test-Prerequisites
    if (-not $SkipClaudeInstall) { Install-ClaudeCode }
    else { Write-Step 'Claude Code 安装：已跳过（-SkipClaudeInstall）' }
    Install-Hooks
    Show-Summary
} catch {
    Write-Host ''
    Write-Host "  [FATAL] $_" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor Red
    exit 1
}
