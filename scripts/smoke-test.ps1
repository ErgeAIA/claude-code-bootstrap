<#
.SYNOPSIS
    settings.json 合并逻辑冒烟测试（不依赖 Pester）
.DESCRIPTION
    通过 AST 从 setup-claude.ps1 提取真实的 Merge-Hooks / Merge-Permissions /
    Get-HookCommand / Get-MatcherCommands 函数执行断言，验证合并语义：
    permissions allow/deny 并集去重、defaultMode 用户优先、hooks 按 command 去重。
    直接使用源码函数（无复制），避免测试与实现漂移。
.EXAMPLE
    pwsh -NoProfile -File scripts/smoke-test.ps1
#>

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$src = [System.IO.File]::ReadAllText((Join-Path $root 'setup-claude.ps1'), $utf8NoBom)

$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseInput($src, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) {
    $errors | ForEach-Object { Write-Host "  [PARSE] $($_.Message)" }
    throw 'setup-claude.ps1 解析失败'
}

$funcNames = @('Get-HookCommand', 'Get-MatcherCommands', 'Merge-Hooks', 'Merge-Permissions')
$defs = $ast.FindAll(
    { param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in $funcNames },
    $true
)
if ($defs.Count -ne $funcNames.Count) {
    throw "函数提取不完整：找到 $($defs.Count)/$($funcNames.Count)"
}
foreach ($d in $defs) { Invoke-Expression $d.Extent.Text }

$script:pass = 0
$script:fail = 0
function Assert-Equal {
    param($Name, $Actual, $Expected)
    $a = $Actual | ConvertTo-Json -Compress
    $e = $Expected | ConvertTo-Json -Compress
    if ($a -ceq $e) {
        $script:pass++
        Write-Host "  [PASS] $Name" -ForegroundColor Green
    } else {
        $script:fail++
        Write-Host "  [FAIL] $Name" -ForegroundColor Red
        Write-Host "         expected: $e"
        Write-Host "         actual:   $a"
    }
}

Write-Host '合并逻辑冒烟测试' -ForegroundColor Cyan
Write-Host ''

# ── Merge-Permissions：并集去重 / defaultMode 用户优先 / 其他字段保留 ──
$ours = @{
    'allow'       = @('Bash(uv run*)')
    'deny'        = @('Read(./.env)')
    'defaultMode' = 'bypassPermissions'
}
$theirs = @{
    'allow'       = @('Bash(cargo check*)', 'Bash(uv run*)')
    'deny'        = @('Read(./secrets/**)')
    'defaultMode' = 'ask'
    'ccmManaged'  = $true
}
$merged = Merge-Permissions -Ours $ours -Theirs $theirs
Assert-Equal 'permissions: allow 并集去重' (@($merged['allow']) | Sort-Object) (@('Bash(cargo check*)', 'Bash(uv run*)') | Sort-Object)
Assert-Equal 'permissions: deny 并集去重' (@($merged['deny']) | Sort-Object) (@('Read(./.env)', 'Read(./secrets/**)') | Sort-Object)
Assert-Equal 'permissions: defaultMode 用户优先' $merged['defaultMode'] 'ask'
Assert-Equal 'permissions: 用户其他字段保留' $merged['ccmManaged'] $true

# ── Merge-Hooks：用户已有同 command → 不重复追加 ──
$oursHooks = @{
    'PreToolUse' = @(
        @{ 'matcher' = 'Bash'; 'hooks' = @(@{ 'command' = 'uv run --script ~/.claude/hooks/block_dangerous.py' }) }
    )
}
$theirsHooks = @{
    'PreToolUse' = @(
        @{ 'matcher' = 'Bash'; 'hooks' = @(@{ 'command' = 'uv run --script ~/.claude/hooks/block_dangerous.py' }) },
        @{ 'matcher' = 'Read'; 'hooks' = @(@{ 'command' = 'uv run --script ~/.claude/hooks/my_read.py' }) }
    )
}
$mergedHooks = Merge-Hooks -Ours $oursHooks -Theirs $theirsHooks
$bashMatcher = @($mergedHooks['PreToolUse'] | Where-Object { $_['matcher'] -eq 'Bash' })
Assert-Equal 'hooks: 同 command 去重（Bash matcher 仍 1 个 hook）' @(Get-MatcherCommands $bashMatcher[0]).Count 1
Assert-Equal 'hooks: 用户 matcher 保留（Read 仍在）' @($mergedHooks['PreToolUse']).Count 2

# ── Merge-Hooks：用户无该事件 → 直接用我们的 ──
$theirsOtherEvents = @{ 'SessionStart' = @(@{ 'hooks' = @(@{ 'command' = 'my_start.py' }) }) }
$mergedNew = Merge-Hooks -Ours @{ 'Stop' = @(@{ 'hooks' = @(@{ 'command' = 'verify.py' }) }) } -Theirs $theirsOtherEvents
Assert-Equal 'hooks: 新事件追加' @($mergedNew['Stop']).Count 1
Assert-Equal 'hooks: 用户事件不受影响' @($mergedNew['SessionStart']).Count 1

Write-Host ''
if ($script:fail -eq 0) {
    Write-Host "  [OK] 全部 $($script:pass) 项通过" -ForegroundColor Green
    exit 0
} else {
    Write-Host "  [FAIL] $($script:fail)/$($script:pass + $script:fail) 项未通过" -ForegroundColor Red
    exit 1
}
