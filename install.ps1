<#
.SYNOPSIS
    claude-code-bootstrap 入口脚本（智能选源）
.DESCRIPTION
    自动从最快的镜像下载 setup-claude.ps1 并执行。
    顺序：Gitee（国内）→ GitHub（国外）→ 失败报错。
.NOTES
    用户只需要这一条命令：
    iwr https://raw.githubusercontent.com/ErgeAIA/claude-code-bootstrap/main/install.ps1 | iex

    指定安装模式（需先下载再执行）：
    iwr https://raw.githubusercontent.com/ErgeAIA/claude-code-bootstrap/main/install.ps1 -OutFile install.ps1; ./install.ps1 -InstallMode Full
#>

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding           = [System.Text.Encoding]::UTF8
$ErrorActionPreference    = 'Stop'
$ProgressPreference       = 'SilentlyContinue'

# ============================================================
#  管理员权限检测与自动提升
# ============================================================
# Claude Code 部署涉及 winget 安装、写 PATH、写 Program Files 等操作，
# 没有管理员权限会失败。检测到非管理员进程时，自动用 UAC 弹窗提升并重启。
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)
if (-not $isAdmin) {
    Write-Host ''
    Write-Host '  [INFO] 当前进程非管理员权限，需要 UAC 提升' -ForegroundColor Yellow
    Write-Host '        即将弹出 UAC 对话框，请点击"是"授权' -ForegroundColor Yellow
    Write-Host ''
    $pwshCmdCheck = if (Get-Command 'pwsh.exe' -ErrorAction SilentlyContinue) { 'pwsh.exe' } else { 'powershell.exe' }
    $scriptPath = if ($MyInvocation.MyCommand.Path) {
        $MyInvocation.MyCommand.Path
    } else {
        # 通过 iwr | iex 调用时无 MyCommand.Path，需要把临时脚本落地后再提升
        $tmpForUac = Join-Path $env:TEMP "install-uac-$([guid]::NewGuid()).ps1"
        $utf8NoBomUac = [System.Text.UTF8Encoding]::new($false)
        [System.IO.File]::WriteAllText($tmpForUac, ($MyInvocation.MyCommand.Definition), $utf8NoBomUac)
        $tmpForUac
    }
    try {
        $proc = Start-Process -FilePath $pwshCmdCheck -ArgumentList @(
            '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass',
            '-File', $scriptPath
        ) + $args -Verb RunAs -Wait -PassThru
        exit $proc.ExitCode
    } catch [System.ComponentModel.Win32Exception] {
        Write-Host ''
        Write-Host '  [ERROR] UAC 提升被拒绝，需要管理员权限才能继续' -ForegroundColor Red
        Write-Host '  请右键 PowerShell 选择"以管理员身份运行"后重试' -ForegroundColor Yellow
        Write-Host ''
        exit 1
    } finally {
        if ($scriptPath -ne $MyInvocation.MyCommand.Path -and (Test-Path $scriptPath)) {
            Remove-Item $scriptPath -Force -ErrorAction SilentlyContinue
        }
    }
}

# ============================================================
#  镜像源（按优先级排序）
# ============================================================
$SOURCES = @(
    @{
        Name = 'Gitee（国内推荐）'
        Url  = 'https://gitee.com/ErgeAIA/claude-code-bootstrap/raw/main/setup-claude.ps1'
    },
    @{
        Name = 'GitHub（国外推荐）'
        Url  = 'https://raw.githubusercontent.com/ErgeAIA/claude-code-bootstrap/main/setup-claude.ps1'
    }
)

$TIMEOUT_SEC = 10
$tmpScript   = Join-Path $env:TEMP "setup-claude-$([guid]::NewGuid()).ps1"

Write-Host ''
Write-Host '  claude-code-bootstrap 入口' -ForegroundColor Cyan
Write-Host '  ===========================' -ForegroundColor Cyan
Write-Host '  正在选择最快镜像...' -ForegroundColor Gray
Write-Host ''

$downloaded = $false
foreach ($src in $SOURCES) {
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        Write-Host "  [ ] 尝试: $($src.Name)" -ForegroundColor Gray -NoNewline
        try {
            $content = (Invoke-WebRequest -Uri $src.Url -TimeoutSec $TIMEOUT_SEC -UseBasicParsing -ErrorAction Stop).Content
            # trust-on-first-use: 脚本内容随版本变化，无法 pin 固定哈希
            # 安全依赖 HTTPS 传输层保护 + 仓库完整性
            if ($content -and $content.Length -gt 1000 -and $content -match 'CmdletBinding') {
                $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
                [System.IO.File]::WriteAllText($tmpScript, $content, $utf8NoBom)
                Write-Host "`r  [OK] $($src.Name)" -ForegroundColor Green
                $downloaded = $true
                break
            }
            if ($attempt -lt 3) {
                Write-Host "`r  [RETRY] $($src.Name)（内容校验失败）" -ForegroundColor Yellow
                Start-Sleep -Seconds 2
                continue
            }
            Write-Host "`r  [FAIL] $($src.Name)（内容校验失败）" -ForegroundColor Yellow
        } catch {
            if ($attempt -lt 3) {
                Write-Host "`r  [RETRY] $($src.Name)（超时/网络）" -ForegroundColor Yellow
                Start-Sleep -Seconds 2
                continue
            }
            Write-Host "`r  [FAIL] $($src.Name)（超时/网络）" -ForegroundColor Yellow
        }
    }
    if ($downloaded) { break }
}

if (-not $downloaded) {
    Write-Host ''
    Write-Host '  [ERROR] 所有镜像源均不可达，请检查网络后重试' -ForegroundColor Red
    Write-Host '  备用方式：手动克隆仓库后运行 setup-claude.ps1' -ForegroundColor Yellow
    exit 1
}

Write-Host ''
Write-Host '  开始执行安装...' -ForegroundColor Cyan
Write-Host ''

# 移交到主体脚本（优先 pwsh.exe，回退 powershell.exe）
$pwshCmd = if (Get-Command 'pwsh.exe' -ErrorAction SilentlyContinue) { 'pwsh.exe' } else { 'powershell.exe' }
$exitCode = 0
try {
    & $pwshCmd -NoLogo -NoProfile -ExecutionPolicy Bypass -File $tmpScript @args
    $exitCode = $LASTEXITCODE
} finally {
    Remove-Item $tmpScript -Force -ErrorAction SilentlyContinue
}
exit $exitCode
