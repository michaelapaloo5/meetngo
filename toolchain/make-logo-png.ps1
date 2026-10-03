# Makes a brand logo usable as an overlay.
#
#   powershell -File toolchain/make-logo-png.ps1 -Source 1790985428070.jpg -Out meet_n_go_logo.png
#   powershell -File toolchain/make-logo-png.ps1 -Source 1790985646251.jpg -Out meet_n_go_logo_driver.png
#
# ## Why this exists
#
# The supplied logos are flattened JPGs: a white page with a mark and a wordmark
# on it, plus very faint gold smudges that were presumably on the design and got
# baked into the white. The splash draws a car that drives in, stops, drops the
# logo, and drives away -- so the logo has to move across the screen. A white
# rectangle travelling with it would be visible on every frame and the animation
# would look broken.
#
# The smudges are why this is not a plain "make white transparent": they are pale
# gold, not white, so a binary white-key would either keep a halo of them or eat
# the logo's own anti-aliased edges along with them.
#
# ## How the alpha is derived
#
#     alpha = 255 - min(r, g, b)
#
# Pure white gives 0. The logo's gold (#E8A400-ish, min channel 0) gives 255. A
# pixel one step off white gives 1, which is what removes a hard halo: there is no
# binary decision anywhere, so there is no edge to see. It is also the correct
# unpremultiplied alpha for an anti-aliased gold shape on white, so the wordmark's
# soft edges stay soft instead of getting a fringe.
#
# The smudges end up almost transparent (min channel around 227, alpha around 28)
# and effectively vanish, which is the right outcome -- they were background
# texture on a white page, and there is no longer a page.

param(
    [Parameter(Mandatory = $true)][string]$Source,
    [Parameter(Mandatory = $true)][string]$Out,
    [int]$Width = 640
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$repo = Split-Path -Parent $PSScriptRoot
$srcPath = Join-Path $repo $Source
if (-not (Test-Path $srcPath)) {
    throw "logo not found: $srcPath"
}

$outDir = Join-Path $repo 'packages\mng_core\assets\brand'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$outPath = Join-Path $outDir $Out

$src = [System.Drawing.Image]::FromFile($srcPath)
try {
    # Held in a variable rather than written inline: `[double]$src.Width` inside
    # a parenthesised expression does not parse cleanly in PowerShell 5.1, and
    # the error it produces points at the wrong token.
    $ratio = $Width / [double]$src.Width
    $height = [int][Math]::Round($src.Height * $ratio)

    # The parenthesised form, not `New-Object Type $a, $b, $c`: with a comma-separated
    # argument list PowerShell tries to bind the three values as one array and
    # fails with "Argument types do not match", which says nothing about the image.
    $bmp = New-Object System.Drawing.Bitmap(
        $Width,
        $height,
        [System.Drawing.Imaging.PixelFormat]::Format32bppArgb
    )
    try {
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        try {
            # `InterpolationMode` matters more than the size here: a default
            # downscale of a 1400px logo to 640px leaves a faint one-pixel fringe
            # on the gold, which is exactly the artefact the alpha work is for.
            $g.InterpolationMode =
                [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $g.PixelOffsetMode =
                [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
            $g.Clear([System.Drawing.Color]::White)
            $g.DrawImage($src, 0, 0, $Width, $height)
        }
        finally { $g.Dispose() }

        $rect = New-Object System.Drawing.Rectangle(0, 0, $Width, $height)
        $data = $bmp.LockBits($rect,
            [System.Drawing.Imaging.ImageLockMode]::ReadWrite,
            [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        try {
            # Through `Marshal`, not by indexing `Scan0`.
            #
            # `Scan0` is an `IntPtr`, and PowerShell cannot index one: `$bytes[$i]`
            # raises "Argument types do not match", which is an error about the
            # reflection call rather than about the image, so it reads like the
            # bitmap constructor and cost a couple of rounds of guessing. Copying
            # the whole buffer out and back is also one bulk move instead of
            # 491,520 marshalled index operations.
            $length = [Math]::Abs($data.Stride) * $height
            $bytes = New-Object byte[] $length
            [System.Runtime.InteropServices.Marshal]::Copy(
                $data.Scan0, $bytes, 0, $length)

            $stride = $data.Stride
            for ($y = 0; $y -lt $height; $y++) {
                $row = $y * $stride
                for ($x = 0; $x -lt $Width; $x++) {
                    $i = $row + $x * 4
                    # BGRA in memory, which is why the alpha byte is index +3.
                    $b = $bytes[$i]
                    $green = $bytes[$i + 1]
                    $r = $bytes[$i + 2]
                    $min = [Math]::Min($r, [Math]::Min($green, $b))
                    $bytes[$i + 3] = [byte](255 - $min)
                }
            }

            [System.Runtime.InteropServices.Marshal]::Copy(
                $bytes, 0, $data.Scan0, $length)
        }
        finally { $bmp.UnlockBits($data) }

        $bmp.Save($outPath, [System.Drawing.Imaging.ImageFormat]::Png)
    }
    finally { $bmp.Dispose() }
}
finally { $src.Dispose() }

$info = Get-Item $outPath
"wrote $($info.FullName)  $($info.Length) bytes  ${Width}x${height}"