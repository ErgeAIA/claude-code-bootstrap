<#
.SYNOPSIS
    编译 Claude Code Bootstrap GUI（MinGW-w64 + windres）。
.EXAMPLE
    pwsh -NoProfile -File gui/build.ps1
.EXAMPLE
    pwsh -NoProfile -File gui/build.ps1 -Cxx D:\env\mingw64\bin\g++.exe -Clean
#>
[CmdletBinding()]
param(
    [string]$Cxx,
    [string]$Windres,
    [switch]$Clean
)

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$src = Join-Path $here 'src'
$dist = Join-Path $here 'dist'

function Resolve-Tool {
    param([string]$Name, [string[]]$Hints, [string]$Explicit)
    if ($Explicit) {
        if (-not (Test-Path $Explicit)) { throw "指定的工具不存在：$Explicit" }
        return $Explicit
    }
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($h in $Hints) {
        if (Test-Path $h) { return $h }
    }
    return $null
}

if ($Clean -and (Test-Path $dist)) { Remove-Item $dist -Recurse -Force }
New-Item -ItemType Directory -Force -Path $dist | Out-Null

if (-not $Cxx) {
    $Cxx = Resolve-Tool 'g++' @(
        'D:\env\mingw64\bin\g++.exe',
        'C:\msys64\mingw64\bin\g++.exe',
        'C:\mingw64\bin\g++.exe'
    )
}
if (-not $Cxx) { throw '找不到 g++。请安装 MinGW-w64，或用 -Cxx 指定路径。' }

if (-not $Windres) {
    $sibling = Join-Path (Split-Path $Cxx -Parent) 'windres.exe'
    if (Test-Path $sibling) { $Windres = $sibling }
    else { $Windres = Resolve-Tool 'windres' @() }
}
if (-not $Windres) { throw '找不到 windres。请安装 MinGW-w64，或用 -Windres 指定路径。' }

$ico = Join-Path $src 'app.ico'
if (-not (Test-Path $ico)) {
    Write-Host '图标缺失，正在生成...'
    & (Join-Path $here 'make-icon.ps1')
}

Push-Location $src
try {
    & $Windres -O coff -i 'app.rc' -o (Join-Path $dist 'app.res') --include-dir $src
    if ($LASTEXITCODE -ne 0) { throw 'windres 编译资源失败' }
} finally {
    Pop-Location
}

$exe = Join-Path $dist 'ClaudeBootstrap.exe'
$flags = @(
    '-std=c++17', '-O2', '-s', '-municode', '-mwindows', '-DUNICODE', '-D_UNICODE',
    '-Wall', '-Wextra', '-I', $src,
    (Join-Path $src 'main.cpp'),
    (Join-Path $src 'util.cpp'),
    (Join-Path $dist 'app.res'),
    '-o', $exe, '-static',
    '-lgdi32', '-luser32', '-lshell32', '-lole32', '-loleaut32', '-lcomctl32',
    '-lmsimg32', '-ldwmapi', '-luxtheme', '-lwinhttp', '-lshlwapi', '-ladvapi32'
)
& $Cxx @flags
if ($LASTEXITCODE -ne 0) { throw 'g++ 编译失败' }

$size = (Get-Item $exe).Length
Write-Host ("Build OK: {0} ({1:N0} KB)" -f $exe, ($size / 1KB))