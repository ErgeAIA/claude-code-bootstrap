<#
.SYNOPSIS
    claude-code-bootstrap 入口脚本（智能选源）
.DESCRIPTION
    自动从最快的镜像下载 setup-claude.ps1 并执行。
    顺序：Gitee（国内）→ GitHub（国外）→ 失败报错。
.NOTES
    用户只需要这一条命令：
    iwr https://raw.githubusercontent.com/ErgeAIA/claude-code-bootstrap/main/install.ps1 | iex
#>

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding           = [System.Text.Encoding]::UTF8
$ErrorActionPreference    = 'Stop'
$ProgressPreference       = 'SilentlyContinue'

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
    Write-Host "  [ ] 尝试: $($src.Name)" -ForegroundColor Gray -NoNewline
    try {
        $content = (Invoke-WebRequest -Uri $src.Url -TimeoutSec $TIMEOUT_SEC -UseBasicParsing -ErrorAction Stop).Content
        # trust-on-first-use: 脚本内容随版本变化，无法 pin 固定哈希
        # 安全依赖 HTTPS 传输层保护 + 仓库完整性
        if ($content -and $content.Length -gt 100) {
            Set-Content -Path $tmpScript -Value $content -Encoding UTF8 -Force
            Write-Host "`r  [OK] $($src.Name)" -ForegroundColor Green
            $downloaded = $true
            break
        }
        Write-Host "`r  [FAIL] $($src.Name)（内容为空）" -ForegroundColor Yellow
    } catch {
        Write-Host "`r  [FAIL] $($src.Name)（超时/网络）" -ForegroundColor Yellow
    }
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
try {
    & $pwshCmd -NoLogo -NoProfile -ExecutionPolicy Bypass -File $tmpScript @args
} finally {
    Remove-Item $tmpScript -Force -ErrorAction SilentlyContinue
}
exit $LASTEXITCODE
