<#
.SYNOPSIS
    刷新 hooks 和 status_line 的 SHA256 校验和
.DESCRIPTION
    从 disler/claude-code-hooks-mastery 下载最新文件，计算 SHA256，
    同时更新 checksums.txt 和 setup-claude.ps1 中的 $CHECKSUMS 哈希表。
.EXAMPLE
    .\scripts\update-checksums.ps1
.EXAMPLE
    .\scripts\update-checksums.ps1 -DryRun
#>

[CmdletBinding()]
param(
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$REPO_BASES = @(
    'https://gitee.com/disler/claude-code-hooks-mastery/raw/main/.claude',
    'https://raw.githubusercontent.com/disler/claude-code-hooks-mastery/main/.claude'
)
$ROOT_DIR  = Split-Path $PSScriptRoot -Parent

$FILES = @{
    'hooks/pre_tool_use.py'         = 'pre_tool_use.py'
    'hooks/post_tool_use.py'        = 'post_tool_use.py'
    'hooks/session_start.py'        = 'session_start.py'
    'hooks/user_prompt_submit.py'   = 'user_prompt_submit.py'
    'hooks/post_tool_use_failure.py'= 'post_tool_use_failure.py'
    'hooks/session_end.py'          = 'session_end.py'
    'status_lines/status_line_v6.py'= 'status_line_v6.py'
}

# ============================================================
#  下载并计算哈希
# ============================================================
Write-Host ''
Write-Host '  刷新 hooks 校验和' -ForegroundColor Cyan
Write-Host '  ==================' -ForegroundColor Cyan

$newChecksums = [ordered]@{}
foreach ($entry in $FILES.GetEnumerator() | Sort-Object Key) {
    $tmpFile = Join-Path $env:TEMP $entry.Value
    $downloaded = $false
    foreach ($base in $REPO_BASES) {
        $url = "$base/$($entry.Key)"
        Write-Host "  [GET] $($entry.Value) ($($base -match 'gitee' ? 'Gitee' : 'GitHub'))..." -ForegroundColor Gray -NoNewline
        try {
            Invoke-WebRequest -Uri $url -OutFile $tmpFile -TimeoutSec 30 -ErrorAction Stop
            $downloaded = $true
            break
        } catch {
            Write-Host "`r  [RETRY] $($entry.Value) from $($base -match 'gitee' ? 'Gitee' : 'GitHub') failed" -ForegroundColor Yellow
        }
    }
    if (-not $downloaded) {
        Write-Host "`r  [ERR] $($entry.Value): all sources failed" -ForegroundColor Red
        throw "Failed to download $($entry.Value) from any source"
    }
    $hash = (Get-FileHash -Path $tmpFile -Algorithm SHA256).Hash.ToUpper()
    $newChecksums[$entry.Value] = $hash
    Write-Host "`r  [OK]  $($entry.Value): $hash" -ForegroundColor Green
    Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue
}

# ============================================================
#  读取当前 checksums.txt 对比
# ============================================================
$checksumsPath = Join-Path $ROOT_DIR 'checksums.txt'
$oldChecksums = @{}
if (Test-Path $checksumsPath) {
    foreach ($line in Get-Content $checksumsPath) {
        if ($line -match '^([a-zA-Z_0-9]+\.py):([A-F0-9]{64})$') {
            $oldChecksums[$Matches[1]] = $Matches[2]
        }
    }
}

$changed = @()
foreach ($entry in $newChecksums.GetEnumerator()) {
    if (-not $oldChecksums.ContainsKey($entry.Key) -or $oldChecksums[$entry.Key] -ne $entry.Value) {
        $old = if ($oldChecksums.ContainsKey($entry.Key)) { $oldChecksums[$entry.Key] } else { '(new)' }
        $changed += "  $($entry.Key): $old -> $($entry.Value)"
    }
}

if ($changed.Count -eq 0) {
    Write-Host ''
    Write-Host '  无变化，无需更新' -ForegroundColor Green
    exit 0
}

Write-Host ''
Write-Host '  变更项:' -ForegroundColor Yellow
$changed | ForEach-Object { Write-Host $_ -ForegroundColor Yellow }

if ($DryRun) {
    Write-Host ''
    Write-Host '  [DryRun] 未写入文件' -ForegroundColor Yellow
    exit 0
}

# ============================================================
#  更新 checksums.txt
# ============================================================
$lines = @(
    '# SHA256 checksums for downloaded hooks and status_line',
    '# Generated from disler/claude-code-hooks-mastery repository',
    '# Verify with: Get-FileHash -Algorithm SHA256 <file> | Select-Object -ExpandProperty Hash'
)
foreach ($entry in $newChecksums.GetEnumerator()) {
    $lines += "$($entry.Key):$($entry.Value)"
}
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[System.IO.File]::WriteAllText($checksumsPath, ($lines -join "`r`n"), $utf8NoBom)
Write-Host ''
Write-Host '  [OK] checksums.txt 已更新' -ForegroundColor Green

# ============================================================
#  更新 setup-claude.ps1 中的 $CHECKSUMS
# ============================================================
$setupPath = Join-Path $ROOT_DIR 'setup-claude.ps1'
$utf8NoBom3 = [System.Text.UTF8Encoding]::new($false)
$setupContent = [System.IO.File]::ReadAllText($setupPath, $utf8NoBom3)

$checksumsBlock = "@{`n"
foreach ($entry in $newChecksums.GetEnumerator()) {
    $padding = if ($entry.Key.Length -lt 24) { ' ' * (24 - $entry.Key.Length) } else { '' }
    $checksumsBlock += "    '$($entry.Key)'$padding= '$($entry.Value)'`n"
}
# 保留用户自写 hooks 校验和（从现有 $CHECKSUMS 中提取，避免被覆盖）
$userHookFiles = @('auto_format.py', 'block_dangerous.py', 'check_secrets.py', 'verify_on_stop.py')
if ($setupContent -match '(?s)\$CHECKSUMS\s*=\s*@\{.*?\}') {
    $existingBlock = $Matches[0]
    foreach ($uf in $userHookFiles) {
        if ($existingBlock -match "'$uf'\s*=\s*'([A-F0-9]{64})'") {
            $padding = if ($uf.Length -lt 24) { ' ' * (24 - $uf.Length) } else { '' }
            $checksumsBlock += "    '$uf'$padding= '$($Matches[1])'`n"
        }
    }
}
$checksumsBlock += "}"

$setupContent = $setupContent -replace "(?s)\`$CHECKSUMS = @\{.*?\}", "`$CHECKSUMS = $checksumsBlock"
[System.IO.File]::WriteAllText($setupPath, $setupContent, $utf8NoBom3)
Write-Host '  [OK] setup-claude.ps1 $CHECKSUMS 已更新' -ForegroundColor Green

Write-Host ''
Write-Host '  刷新完成。请 review 变更后提交。' -ForegroundColor Cyan
