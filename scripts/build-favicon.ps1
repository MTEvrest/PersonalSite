param(
    [Parameter(Mandatory = $true)]
    [string]$SourcePath,

    [string]$OutputDirectory = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Drawing
Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @"
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

public static class AlphaCropper
{
    public static Rectangle FindBounds(Bitmap bitmap)
    {
        var rect = new Rectangle(0, 0, bitmap.Width, bitmap.Height);
        var data = bitmap.LockBits(rect, ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        try
        {
            var bytes = new byte[Math.Abs(data.Stride) * bitmap.Height];
            Marshal.Copy(data.Scan0, bytes, 0, bytes.Length);

            int minX = bitmap.Width;
            int minY = bitmap.Height;
            int maxX = -1;
            int maxY = -1;

            for (int y = 0; y < bitmap.Height; y++)
            {
                int row = y * Math.Abs(data.Stride);
                for (int x = 0; x < bitmap.Width; x++)
                {
                    if (bytes[row + (x * 4) + 3] <= 8) continue;
                    if (x < minX) minX = x;
                    if (x > maxX) maxX = x;
                    if (y < minY) minY = y;
                    if (y > maxY) maxY = y;
                }
            }

            if (maxX < minX || maxY < minY) return rect;
            return Rectangle.FromLTRB(minX, minY, maxX + 1, maxY + 1);
        }
        finally
        {
            bitmap.UnlockBits(data);
        }
    }
}
"@

function New-ResizedPngBytes {
    param(
        [System.Drawing.Bitmap]$Source,
        [int]$Size
    )

    $bitmap = [System.Drawing.Bitmap]::new($Size, $Size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $stream = [System.IO.MemoryStream]::new()

    try {
        $graphics.Clear([System.Drawing.Color]::Transparent)
        $graphics.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceCopy
        $graphics.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
        $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
        $graphics.DrawImage($Source, [System.Drawing.Rectangle]::new(0, 0, $Size, $Size))
        $bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
        return $stream.ToArray()
    }
    finally {
        $stream.Dispose()
        $graphics.Dispose()
        $bitmap.Dispose()
    }
}

$resolvedSource = (Resolve-Path -LiteralPath $SourcePath).Path
$resolvedOutput = (Resolve-Path -LiteralPath $OutputDirectory).Path
$source = [System.Drawing.Bitmap]::FromFile($resolvedSource)
$master = [System.Drawing.Bitmap]::new(512, 512, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$graphics = [System.Drawing.Graphics]::FromImage($master)

try {
    $bounds = [AlphaCropper]::FindBounds($source)
    $graphics.Clear([System.Drawing.ColorTranslator]::FromHtml("#2457E6"))
    $graphics.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
    $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality

    $targetMax = 360.0
    $scale = [Math]::Min($targetMax / $bounds.Width, $targetMax / $bounds.Height)
    $targetWidth = [int][Math]::Round($bounds.Width * $scale)
    $targetHeight = [int][Math]::Round($bounds.Height * $scale)
    $targetX = [int][Math]::Round((512 - $targetWidth) / 2)
    $targetY = [int][Math]::Round((512 - $targetHeight) / 2)

    $graphics.DrawImage(
        $source,
        [System.Drawing.Rectangle]::new($targetX, $targetY, $targetWidth, $targetHeight),
        $bounds,
        [System.Drawing.GraphicsUnit]::Pixel
    )

    $pngPath = Join-Path $resolvedOutput "favicon.png"
    $icoPath = Join-Path $resolvedOutput "favicon.ico"
    $master.Save($pngPath, [System.Drawing.Imaging.ImageFormat]::Png)

    $sizes = @(16, 32, 48, 64, 128, 256)
    $images = @($sizes | ForEach-Object { New-ResizedPngBytes -Source $master -Size $_ })
    $stream = [System.IO.File]::Open($icoPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)
    $writer = [System.IO.BinaryWriter]::new($stream)

    try {
        $writer.Write([uint16]0)
        $writer.Write([uint16]1)
        $writer.Write([uint16]$sizes.Count)

        $offset = 6 + (16 * $sizes.Count)
        for ($index = 0; $index -lt $sizes.Count; $index++) {
            $size = $sizes[$index]
            $writer.Write([byte]$(if ($size -eq 256) { 0 } else { $size }))
            $writer.Write([byte]$(if ($size -eq 256) { 0 } else { $size }))
            $writer.Write([byte]0)
            $writer.Write([byte]0)
            $writer.Write([uint16]1)
            $writer.Write([uint16]32)
            $writer.Write([uint32]$images[$index].Length)
            $writer.Write([uint32]$offset)
            $offset += $images[$index].Length
        }

        foreach ($image in $images) {
            $writer.Write($image)
        }
    }
    finally {
        $writer.Dispose()
        $stream.Dispose()
    }

    [PSCustomObject]@{
        SourceBounds = $bounds
        Png = $pngPath
        Ico = $icoPath
        Sizes = ($sizes -join ", ")
    }
}
finally {
    $graphics.Dispose()
    $master.Dispose()
    $source.Dispose()
}
