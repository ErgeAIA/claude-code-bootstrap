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
#  两阶段引导：通过 iwr | iex 调用时，先下载到文件再执行
#  iwr 的 .Content 用系统默认 GBK 解码 UTF-8，中文会乱码
#  用 curl.exe 下载保留原始字节，或用 -OutFile 写原始字节
# ============================================================
if (-not $env:_CC_BOOTSTRAPPED) {
    $env:_CC_BOOTSTRAPPED = '1'
    $selfUrl = 'https://raw.githubusercontent.com/ErgeAIA/claude-code-bootstrap/main/install.ps1'
    $tmpSelf = Join-Path $env:TEMP "install-$([guid]::NewGuid()).ps1"

    try {
        if (Get-Command 'curl.exe' -ErrorAction SilentlyContinue) {
            & curl.exe -fsSL --retry 3 --retry-delay 2 -o $tmpSelf $selfUrl
        } else {
            Invoke-WebRequest -Uri $selfUrl -OutFile $tmpSelf -UseBasicParsing -ErrorAction Stop
        }
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
#  管理员权限检测与自动提升
# ============================================================
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)
if (-not $isAdmin) {
    Write-Host ''
    Write-Host '  [INFO] 当前非管理员，正在请求 UAC 提升...' -ForegroundColor Yellow
    Write-Host '        即将弹出 UAC 对话框，请点击"是"授权' -ForegroundColor Yellow
    Write-Host ''
    $pwshCmdCheck = if (Get-Command 'pwsh.exe' -ErrorAction SilentlyContinue) { 'pwsh.exe' } else { 'powershell.exe' }
    $scriptPath = if ($MyInvocation.MyCommand.Path) {
        $MyInvocation.MyCommand.Path
    } else {
        $tmpForUac = Join-Path $env:TEMP "install-uac-$([guid]::NewGuid()).ps1"
        $utf8NoBomUac = [System.Text.UTF8Encoding]::new($false)
        [System.IO.File]::WriteAllText($tmpForUac, ($MyInvocation.MyCommand.Definition), $utf8NoBomUac)
        $tmpForUac
    }
    try {
        $uacArgs = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath) + @($args)
        $proc = Start-Process -FilePath $pwshCmdCheck -ArgumentList $uacArgs -Verb RunAs -Wait -PassThru
        exit $proc.ExitCode
    } catch [System.ComponentModel.Win32Exception] {
        Write-Host ''
        Write-Host '  [ERROR] UAC 被拒绝，需要管理员权限' -ForegroundColor Red
        Write-Host '  请右键 PowerShell 选择"以管理员身份运行"' -ForegroundColor Yellow
        Write-Host ''
        Write-Host '  按回车键退出...' -ForegroundColor Gray
        [void][Console]::ReadLine()
        exit 1
    } catch {
        Write-Host ''
        Write-Host "  [ERROR] UAC 提升失败: $_" -ForegroundColor Red
        Write-Host ''
        Write-Host '  按回车键退出...' -ForegroundColor Gray
        [void][Console]::ReadLine()
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
        Name = 'Gitee（国内）'
        Url  = 'https://gitee.com/ErgeAIA/claude-code-bootstrap/raw/main/setup-claude.ps1'
    },
    @{
        Name = 'GitHub（国外）'
        Url  = 'https://raw.githubusercontent.com/ErgeAIA/claude-code-bootstrap/main/setup-claude.ps1'
    }
)

$TIMEOUT_SEC = 10
$tmpScript   = Join-Path $env:TEMP "setup-claude-$([guid]::NewGuid()).ps1"

Write-Host ''
Write-Host '  claude-code-bootstrap 一键部署' -ForegroundColor Cyan
Write-Host '  ==============================' -ForegroundColor Cyan
Write-Host '  正在选择最快镜像源...' -ForegroundColor Gray
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
