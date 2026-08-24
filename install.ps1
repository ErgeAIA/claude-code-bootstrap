<#
.SYNOPSIS
    claude-code-bootstrap 入口脚本（智能选源）
.DESCRIPTION
    自动从 GitHub 下载 setup-claude.ps1 并执行。
    下载失败自动重试。
.NOTES
    用户只需要这一条命令：
    iwr https://raw.githubusercontent.com/ErgeAIA/claude-code-bootstrap/main/install.ps1 | iex

    指定安装模式（需先下载再执行）：
    iwr https://raw.githubusercontent.com/ErgeAIA/claude-code-bootstrap/main/install.ps1 -OutFile install.ps1; ./install.ps1 -InstallMode Full

    升级 Claude Code（默认 latest，也可指定版本）：
    iwr https://raw.githubusercontent.com/ErgeAIA/claude-code-bootstrap/main/install.ps1 -OutFile install.ps1; ./install.ps1 -Upgrade -ClaudeVersion 2.1.153
#>

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding           = [System.Text.Encoding]::UTF8
$ErrorActionPreference    = 'Stop'
$ProgressPreference       = 'SilentlyContinue'

# 脚本版本（与 CHANGELOG 最新版本保持一致；setup-claude.ps1 中还有一份，发版时两处同步改）
$SCRIPT_VERSION = '1.7.0'

# 命令行直接查询版本号（无需下载 setup-claude.ps1）
if ($args -contains '-Version') {
    Write-Host "ErgeAIA / Claude Code Bootstrap  v$SCRIPT_VERSION"
    exit 0
}

# ============================================================
#  两阶段引导：通过 iwr | iex 调用时，先下载到文件再执行
#  iwr 的 .Content 用系统默认 GBK 解码 UTF-8，中文会乱码
#  用 curl.exe 下载保留原始字节，或用 -OutFile 写原始字节
# ============================================================
if (-not $env:_CC_BOOTSTRAPPED) {
    $env:_CC_BOOTSTRAPPED = '1'
    # 引导下载本脚本（GitHub raw）
    $selfUrls = @(
        'https://raw.githubusercontent.com/ErgeAIA/claude-code-bootstrap/main/install.ps1'
    )
    $tmpSelf = Join-Path $env:TEMP "install-$([guid]::NewGuid()).ps1"

    try {
        $downloaded = $false
        foreach ($url in $selfUrls) {
            try {
                if (Get-Command 'curl.exe' -ErrorAction SilentlyContinue) {
                    & curl.exe -fsSL --retry 2 --retry-delay 1 -o $tmpSelf $url
                } else {
                    Invoke-WebRequest -Uri $url -OutFile $tmpSelf -UseBasicParsing -ErrorAction Stop
                }
                if ((Test-Path $tmpSelf) -and (Get-Item $tmpSelf).Length -gt 1000) {
                    $downloaded = $true
                    break
                }
            } catch { continue }
        }
        if (-not $downloaded) { throw 'All bootstrap mirrors failed' }
        $pwshCmd = if (Get-Command 'pwsh.exe' -ErrorAction SilentlyContinue) { 'pwsh.exe' } else { 'powershell.exe' }
        & $pwshCmd -NoLogo -NoProfile -ExecutionPolicy Bypass -File $tmpSelf @args
        $code = $LASTEXITCODE
    } catch {
        Write-Host "  [ERROR] Bootstrap failed: $_" -ForegroundColor Red
        $code = 1
    } finally {
        if (Test-Path $tmpSelf) { Remove-Item $tmpSelf -Force -ErrorAction SilentlyContinue }
    }
    exit $code
}

# ============================================================
#  下载源
# ============================================================
$SOURCES = @(
    @{
        Name = 'GitHub'
        Url  = 'https://raw.githubusercontent.com/ErgeAIA/claude-code-bootstrap/main/setup-claude.ps1'
    }
)

$TIMEOUT_SEC = 10
$tmpScript   = Join-Path $env:TEMP "setup-claude-$([guid]::NewGuid()).ps1"

Write-Host ''
Write-Host "  ErgeAIA / Claude Code Bootstrap  v$SCRIPT_VERSION" -ForegroundColor Cyan
Write-Host '  正在启动安装程序...' -ForegroundColor Gray
Write-Host ''

$downloaded = $false
foreach ($src in $SOURCES) {
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        Write-Host "  [ ] 尝试: $($src.Name)" -ForegroundColor Gray -NoNewline
        try {
            Invoke-WebRequest -Uri $src.Url -OutFile $tmpScript -TimeoutSec $TIMEOUT_SEC -UseBasicParsing -ErrorAction Stop
            $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
            $content = [System.IO.File]::ReadAllText($tmpScript, $utf8NoBom)
            if ($content -and $content.Length -gt 1000 -and $content -match 'CmdletBinding') {
                Write-Host "`r  [OK] $($src.Name)" -ForegroundColor Green
                $downloaded = $true
                break
            }
            if ($attempt -lt 3) {
                Write-Host "`r  [重试] $($src.Name)（内容校验失败）" -ForegroundColor Yellow
                Start-Sleep -Seconds 2
                continue
            }
            Write-Host "`r  [失败] $($src.Name)（内容校验失败）" -ForegroundColor Yellow
        } catch {
            if ($attempt -lt 3) {
                Write-Host "`r  [重试] $($src.Name)（超时/网络）" -ForegroundColor Yellow
                Start-Sleep -Seconds 2
                continue
            }
            Write-Host "`r  [失败] $($src.Name)（超时/网络）" -ForegroundColor Yellow
        }
    }
    if ($downloaded) { break }
}

if (-not $downloaded) {
    Write-Host ''
    Write-Host '  [ERROR] 所有镜像源不可达，请检查网络' -ForegroundColor Red
    Write-Host '  备用方式：克隆仓库后直接运行 setup-claude.ps1' -ForegroundColor Yellow
    Write-Host ''
    Write-Host '  按回车键退出...' -ForegroundColor Gray
    [void][Console]::ReadLine()
    exit 1
}

Write-Host ''
Write-Host '  开始安装...' -ForegroundColor Cyan
Write-Host ''

# 移交到主体脚本（优先 pwsh.exe，回退 powershell.exe）
$pwshCmd = if (Get-Command 'pwsh.exe' -ErrorAction SilentlyContinue) { 'pwsh.exe' } else { 'powershell.exe' }
$exitCode = 0
try {
    & $pwshCmd -NoLogo -NoProfile -ExecutionPolicy Bypass -File $tmpScript @args
    $exitCode = $LASTEXITCODE
} catch {
    Write-Host ''
    Write-Host "  [FATAL] 子进程异常: $_" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor Red
    $exitCode = 1
} finally {
    Remove-Item $tmpScript -Force -ErrorAction SilentlyContinue
}

$color = if ($exitCode -eq 0) { 'Green' } else { 'Red' }
$msg   = if ($exitCode -eq 0) { '安装完成' } else { "安装异常 (退出码: $exitCode)" }
Write-Host ''
Write-Host "  $msg" -ForegroundColor $color
Write-Host '  按回车键退出...' -ForegroundColor Gray
[void][Console]::ReadLine()
exit $exitCode
