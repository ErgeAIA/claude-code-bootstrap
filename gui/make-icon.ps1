<#
.SYNOPSIS
    生成 gui/src/app.ico（256x256，PNG 压缩 ICO）。
.DESCRIPTION
    纯 System.Drawing 绘制，不依赖外部素材。构建脚本会在图标缺失时自动调用。
#>
[CmdletBinding()]
param(
    [string]$Output = (Join-Path $PSScriptRoot 'src\app.ico')
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$size = 256
$bmp = [System.Drawing.Bitmap]::new($size, $size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$g.Clear([System.Drawing.Color]::Transparent)

# 圆角方块
$r = 52
$d = $r * 2
$path = [System.Drawing.Drawing2D.GraphicsPath]::new()
$path.AddArc(0, 0, $d, $d, 180, 90)
$path.AddArc($size - $d, 0, $d, $d, 270, 90)
$path.AddArc($size - $d, $size - $d, $d, $d, 0, 90)
$path.AddArc(0, $size - $d, $d, $d, 90, 90)
$path.CloseFigure()

$topColor = [System.Drawing.Color]::FromArgb(255, 44, 49, 61)
$bottomColor = [System.Drawing.Color]::FromArgb(255, 19, 20, 24)
$bg = [System.Drawing.Drawing2D.LinearGradientBrush]::new(
    [System.Drawing.Point]::new(0, 0),
    [System.Drawing.Point]::new($size, $size),
    $topColor, $bottomColor)
$g.FillPath($bg, $path)

$accent = [System.Drawing.Color]::FromArgb(255, 59, 156, 246)
$border = [System.Drawing.Pen]::new($accent, 6)
$g.DrawPath($border, $path)

# 终端提示符 > 与光标
$font = [System.Drawing.Font]::new('Segoe UI', 118, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
$fmt = [System.Drawing.StringFormat]::new()
$fmt.Alignment = [System.Drawing.StringAlignment]::Center
$fmt.LineAlignment = [System.Drawing.StringAlignment]::Center
$textRect = [System.Drawing.RectangleF]::new(24, 0, 150, 256)
$g.DrawString('>', $font, [System.Drawing.Brushes]::White, $textRect, $fmt)

$barBrush = [System.Drawing.SolidBrush]::new($accent)
$g.FillRectangle($barBrush, 150, 160, 62, 18)

# 保存为 PNG，再封装成 ICO
$ms = [System.IO.MemoryStream]::new()
$bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
$png = $ms.ToArray()

$dir = Split-Path $Output -Parent
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }

$fs = [System.IO.File]::Create($Output)
$bw = [System.IO.BinaryWriter]::new($fs)
$bw.Write([UInt16]0)                 # reserved
$bw.Write([UInt16]1)                 # type: icon
$bw.Write([UInt16]1)                 # image count
$bw.Write([Byte]0)                   # width  (0 = 256)
$bw.Write([Byte]0)                   # height (0 = 256)
$bw.Write([Byte]0)                   # palette colors
$bw.Write([Byte]0)                   # reserved
$bw.Write([UInt16]1)                 # color planes
$bw.Write([UInt16]32)                # bits per pixel
$bw.Write([UInt32]$png.Length)       # payload size
$bw.Write([UInt32]22)                # payload offset
$bw.Write($png)
$bw.Dispose()

$g.Dispose()
$bmp.Dispose()
$bg.Dispose()
$border.Dispose()
$font.Dispose()
$fmt.Dispose()
$barBrush.Dispose()
$path.Dispose()
$ms.Dispose()

Write-Host "Generated $Output (256x256, $($png.Length) byte PNG payload)"