# Draws an Android launcher icon from a brand logo.
#
#   powershell -File toolchain/make-launcher-icons.ps1 `
#       -Logo packages/mng_core/assets/brand/meet_n_go_logo.png -App apps/rider
#
# ## Why the emblem and not the whole logo
#
# The supplied logos are a mark plus a wordmark plus, on the driver one, a
# background watermark. At 48x48 -- the mdpi icon, and the size most launchers
# actually draw -- the wordmark is about four pixels tall and renders as a grey
# smudge. So this crops the *first band of opaque content*, which is the circular
# mark, and throws the type away.
#
# The band is found rather than hardcoded, so replacing the logo does not mean
# editing this file and hoping the crop still lands on the mark.
#
# ## Why the art is inset to 64%
#
# There is no adaptive icon in either app, so Android treats these as legacy
# icons: Samsung's launcher masks them into its own squircle or circle and adds
# its own background. An emblem that filled the canvas would have its arrow
# clipped off by that mask. Centred at 64% it survives the tightest common mask
# with room to spare.
#
# ## Why white
#
# The mark is gold. On a gold tile it disappears -- which is exactly the bug the
# splash had, where the logo, the car and the background were all the same gold
# and the one thing the animation existed to show was the one thing you could not
# see. White is also what the logo's own artwork was drawn on.

param(
    [Parameter(Mandatory = $true)][string]$Logo,
    [Parameter(Mandatory = $true)][string]$App,
    [double]$Inset = 0.64
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$repo = Split-Path -Parent $PSScriptRoot
$logoPath = Join-Path $repo $Logo
if (-not (Test-Path $logoPath)) {
    throw "logo not found: $logoPath"
}

# The launcher icon sizes Android expects, in pixels, per density bucket.
$densities = [ordered]@{
    'mdpi'    = 48
    'hdpi'    = 72
    'xhdpi'   = 96
    'xxhdpi'  = 144
    'xxxhdpi' = 192
}

# --- find the emblem -------------------------------------------------------
# The first contiguous run of rows containing opaque pixels. Everything above it
# is the margin, so it is the mark and nothing else.
$src = [System.Drawing.Bitmap]::new($logoPath)
try {
    $alphaCut = 140
    $bandStart = -1
    for ($y = 0; $y -lt $src.Height -and $bandStart -lt 0; $y++) {
        $opaque = 0
        for ($x = 0; $x -lt $src.Width; $x += 2) {
            if ($src.GetPixel($x, $y).A -gt $alphaCut) { $opaque++ }
        }
        if ($opaque -gt 3) { $bandStart = $y }
    }
    if ($bandStart -lt 0) {
        throw 'no opaque content found in the logo'
    }

    $bandEnd = $bandStart
    $minX = $src.Width
    $maxX = -1
    $inBand = $true
    for ($y = $bandStart; $y -lt $src.Height -and $inBand; $y++) {
        $opaque = 0
        for ($x = 0; $x -lt $src.Width; $x += 2) {
            if ($src.GetPixel($x, $y).A -gt $alphaCut) { $opaque++ }
        }
        if ($opaque -le 3) {
            $inBand = $false
        }
        else {
            $bandEnd = $y
            for ($x = 0; $x -lt $src.Width; $x++) {
                if ($src.GetPixel($x, $y).A -gt $alphaCut) {
                    if ($x -lt $minX) { $minX = $x }
                    if ($x -gt $maxX) { $maxX = $x }
                }
            }
        }
    }

    $markW = $maxX - $minX + 1
    $markH = $bandEnd - $bandStart + 1
    $side = [int][Math]::Ceiling([Math]::Max($markW, $markH) * 1.06)
    $cx = ($minX + $maxX) / 2.0
    $cy = ($bandStart + $bandEnd) / 2.0
    $cropX = [int][Math]::Round($cx - $side / 2.0)
    $cropY = [int][Math]::Round($cy - $side / 2.0)

    # Clamped rather than allowed to run off the edge: a crop rect that starts
    # negative throws in `Clone`, and the error blames the image.
    $cropX = [Math]::Max(0, [Math]::Min($cropX, $src.Width - $side))
    $cropY = [Math]::Max(0, [Math]::Min($cropY, $src.Height - $side))

    "emblem: rows $bandStart..$bandEnd, x $minX..$maxX " +
        "(${markW}x${markH}); crop ${side}x${side} at $cropX,$cropY"
}
finally { $src.Dispose() }

# --- draw each density -----------------------------------------------------
foreach ($entry in $densities.GetEnumerator()) {
    $density = $entry.Key
    $size = [int]$entry.Value

    $dir = Join-Path $repo "$App\android\app\src\main\res\mipmap-$density"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null

    # Read the crop again per density: `Clone` shares the source's handle, and
    # reusing one clone across five output sizes makes the last one win.
    $logoBitmap = [System.Drawing.Bitmap]::new($logoPath)
    try {
        $cropRect = New-Object System.Drawing.Rectangle $cropX, $cropY, $side, $side
        $mark = $logoBitmap.Clone($cropRect, $logoBitmap.PixelFormat)
        try {
            # Fit the mark's *larger* dimension to the inset. Scaling to the
            # width instead would push the taller edge through the tile on any
            # logo that is taller than it is wide, and this one is 175x160.
            $fit = $size * $Inset
            $drawW = [int][Math]::Round($fit * $mark.Width / [double]$side)
            $drawH = [int][Math]::Round($fit * $mark.Height / [double]$side)
            $dx = [int][Math]::Round(($size - $drawW) / 2.0)
            $dy = [int][Math]::Round(($size - $drawH) / 2.0)

            # 32-bit ARGB: the mark is transparent gold and must stay that way.
            $bmp = New-Object System.Drawing.Bitmap(
                $size, $size,
                [System.Drawing.Imaging.PixelFormat]::Format32bppArgb
            )
            try {
                $g = [System.Drawing.Graphics]::FromImage($bmp)
                try {
                    $g.InterpolationMode =
                        [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                    $g.PixelOffsetMode =
                        [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
                    $g.SmoothingMode =
                        [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
                    $g.CompositingQuality =
                        [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
                    $g.Clear([System.Drawing.Color]::White)
                    $g.DrawImage($mark, $dx, $dy, $drawW, $drawH)
                }
                finally { $g.Dispose() }

                $out = Join-Path $dir 'ic_launcher.png'
                $bmp.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)
            }
            finally { $bmp.Dispose() }
            "  ${density}: ${size}x${size}  mark ${drawW}x${drawH} at $dx,$dy"
        }
        finally { $mark.Dispose() }
    }
    finally { $logoBitmap.Dispose() }
}

"wrote icons into $App"
