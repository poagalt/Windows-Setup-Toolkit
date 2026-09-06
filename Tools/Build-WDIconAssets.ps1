# Rebuilds Assets\*.png from the vendors' own vector art. Needs Chrome and the
# network, so it is run when a mark changes rather than on any launch path.
[CmdletBinding()]
param(
    [string]$OutDir,
    [int]$Long = 1024,
    [int]$Super = 4,
    [string]$ChromePath,
    [string]$WorkDir
)

$ErrorActionPreference = 'Stop'

if (-not $OutDir) { $OutDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'Assets' }
if (-not $WorkDir) { $WorkDir = Join-Path $env:TEMP ("wd-icon-assets-" + [Guid]::NewGuid().ToString('N').Substring(0, 8)) }
New-Item -ItemType Directory -Force -Path $OutDir, $WorkDir | Out-Null

if (-not $ChromePath) {
    foreach ($c in @(
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
        "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
        "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe"
    )) { if (Test-Path -LiteralPath $c) { $ChromePath = $c; break } }
}
if (-not $ChromePath) { throw 'No Chrome or Edge found. Pass -ChromePath.' }

Add-Type -AssemblyName PresentationCore, PresentationFramework, WindowsBase, System.Drawing

# Wikimedia refuses an anonymous agent and answers 429 rather than 403, which
# reads as rate limiting and sends you off adding sleeps that do not help.
$UA = 'WinSetupToolkit-icon-asset-build/1.0 (+https://github.com/poagalt/Windows-Setup-Toolkit)'

# Each mark, where it comes from, and which elements of it are the mark. Keep is
# for sources that publish more than the mark in one file.
$marks = @(
    @{ Key  = 'edge'
       Url  = 'https://upload.wikimedia.org/wikipedia/commons/9/98/Microsoft_Edge_logo_%282019%29.svg'
       Keep = $null }
    @{ Key  = 'onedrive'
       Url  = 'https://upload.wikimedia.org/wikipedia/commons/e/e7/Microsoft_OneDrive_Icon_%282025_-_present%29.svg'
       Keep = $null }
    @{ Key  = 'copilot'
       Url  = 'https://upload.wikimedia.org/wikipedia/en/a/aa/Microsoft_Copilot_Icon.svg'
       Keep = $null }
    @{ Key  = 'mcafee'
       Url  = 'https://upload.wikimedia.org/wikipedia/commons/c/cf/McAfee_logo.svg'
       Keep = @('polygon6863', 'polygon6865') }   # the shield; the rest is the word
)

function Invoke-Renderer {
    param([string[]]$RendererArgs, [int]$TimeoutSec = 120)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $ChromePath
    $psi.Arguments = ($RendererArgs | ForEach-Object { if ($_ -match '[ &]') { '"' + $_ + '"' } else { $_ } }) -join ' '
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $so = $p.StandardOutput.ReadToEndAsync()
    $se = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($TimeoutSec * 1000)) { try { $p.Kill() } catch { } }
    @{ Out = $so.Result; Err = $se.Result }
}

function Get-BaseArgs {
    @(
        '--headless=new', '--disable-gpu', '--no-sandbox', '--no-first-run',
        '--no-default-browser-check', '--disable-extensions', '--disable-lcd-text',
        '--allow-file-access-from-files', '--hide-scrollbars',
        "--user-data-dir=$(Join-Path $WorkDir 'profile')"
    )
}

function Get-SvgBody {
    param([string]$Path)
    $t = Get-Content -LiteralPath $Path -Raw
    $t = [regex]::Replace($t, '<\?xml[^>]*\?>', '')
    $t = [regex]::Replace($t, '<!DOCTYPE[^>]*>', '')
    $t.Trim()
}

function Measure-Ink {
    # Screen rects mapped back through the viewBox rather than getBBox: getBBox
    # is local to the element and ignores every transform above it, and three of
    # these four put their geometry inside a scaled group.
    param([string]$SvgPath, [string[]]$Keep)
    $body = Get-SvgBody $SvgPath
    $keepJson = 'null'
    if ($Keep) { $keepJson = '[' + (($Keep | ForEach-Object { "'" + $_ + "'" }) -join ',') + ']' }
    $html = @"
<!doctype html><meta charset="utf-8"><body style="margin:0">
$body
<pre id="out"></pre>
<script>
var keep = $keepJson;
var svg = document.querySelector('svg');
var sr = svg.getBoundingClientRect();
var vb = svg.viewBox.baseVal;
var hasVb = vb && vb.width > 0 && vb.height > 0;
function toUser(r) {
  if (!hasVb) { return { x: r.left - sr.left, y: r.top - sr.top, w: r.width, h: r.height }; }
  var sx = vb.width / sr.width, sy = vb.height / sr.height;
  return { x: vb.x + (r.left - sr.left) * sx, y: vb.y + (r.top - sr.top) * sy,
           w: r.width * sx, h: r.height * sy };
}
var x1 = 1e9, y1 = 1e9, x2 = -1e9, y2 = -1e9;
var all = svg.querySelectorAll('path,polygon,polyline,circle,ellipse,rect');
for (var i = 0; i < all.length; i++) {
  var e = all[i];
  if (keep && keep.indexOf(e.id) < 0) { continue; }
  var r = e.getBoundingClientRect();
  if (r.width <= 0 || r.height <= 0) { continue; }
  var u = toUser(r);
  if (u.x < x1) { x1 = u.x; }
  if (u.y < y1) { y1 = u.y; }
  if (u.x + u.w > x2) { x2 = u.x + u.w; }
  if (u.y + u.h > y2) { y2 = u.y + u.h; }
}
document.getElementById('out').textContent =
  '###INK###' + JSON.stringify({ x: x1, y: y1, w: x2 - x1, h: y2 - y1 }) + '###END###';
</script></body>
"@
    $tmp = Join-Path $WorkDir ('ink-' + [IO.Path]::GetFileNameWithoutExtension($SvgPath) + '.html')
    [IO.File]::WriteAllText($tmp, $html, (New-Object Text.UTF8Encoding $false))
    $r = Invoke-Renderer (@(Get-BaseArgs) + @('--dump-dom', '--virtual-time-budget=4000',
                                              ('file:///' + ($tmp -replace '\\', '/'))))
    $m = [regex]::Match($r.Out, '###INK###(.*?)###END###', 'Singleline')
    if (-not $m.Success) { throw "Could not measure '$SvgPath'. The renderer said: $($r.Err)" }
    $m.Groups[1].Value | ConvertFrom-Json
}

function Export-Png {
    param([string]$SvgPath, [string]$OutPng, $Vb, [int]$PixW, [int]$PixH, [string[]]$Keep)
    $body = Get-SvgBody $SvgPath
    $m = [regex]::Match($body, '<svg\b[^>]*>')
    $tag = $m.Value
    foreach ($a in 'width', 'height', 'viewBox', 'preserveAspectRatio') {
        $tag = [regex]::Replace($tag, "\s$a\s*=\s*`"[^`"]*`"", '', 'IgnoreCase')
        $tag = [regex]::Replace($tag, "\s$a\s*=\s*'[^']*'", '', 'IgnoreCase')
    }
    $tag = $tag -replace '>\s*$', (" width=`"$PixW`" height=`"$PixH`" viewBox=`"$($Vb.X) $($Vb.Y) $($Vb.W) $($Vb.H)`" preserveAspectRatio=`"xMidYMid meet`">")
    $body = $body.Remove($m.Index, $m.Length).Insert($m.Index, $tag)

    $strip = ''
    if ($Keep) {
        $list = ($Keep | ForEach-Object { "'" + $_ + "'" }) -join ','
        $strip = @"
<script>
var keep = [$list];
var all = document.querySelector('svg').querySelectorAll('path,polygon,polyline,circle,ellipse,rect');
for (var i = all.length - 1; i >= 0; i--) {
  if (keep.indexOf(all[i].id) < 0) { all[i].parentNode.removeChild(all[i]); }
}
</script>
"@
    }
    $html = "<!doctype html><meta charset=`"utf-8`">`n" +
            "<style>html,body{margin:0;padding:0;background:transparent}svg{display:block}</style>`n" +
            "<body>`n$body`n$strip`n</body>"
    $tmp = Join-Path $WorkDir ('render-' + [IO.Path]::GetFileNameWithoutExtension($OutPng) + '.html')
    [IO.File]::WriteAllText($tmp, $html, (New-Object Text.UTF8Encoding $false))
    if (Test-Path -LiteralPath $OutPng) { Remove-Item -LiteralPath $OutPng -Force }
    $r = Invoke-Renderer (@(Get-BaseArgs) + @(
        '--default-background-color=00000000', '--force-device-scale-factor=1',
        "--window-size=$PixW,$PixH", "--screenshot=$OutPng", '--virtual-time-budget=4000',
        ('file:///' + ($tmp -replace '\\', '/'))))
    if (-not (Test-Path -LiteralPath $OutPng)) { throw "Render failed for '$OutPng'. The renderer said: $($r.Err)" }
}

function Get-AlphaBounds {
    param([string]$Path)
    $bm = New-Object System.Drawing.Bitmap $Path
    try {
        $rect = New-Object System.Drawing.Rectangle 0, 0, $bm.Width, $bm.Height
        $d = $bm.LockBits($rect, 'ReadOnly', 'Format32bppArgb')
        $buf = New-Object 'byte[]' ($d.Stride * $bm.Height)
        [Runtime.InteropServices.Marshal]::Copy($d.Scan0, $buf, 0, $buf.Length)
        $bm.UnlockBits($d)
        $x1 = $bm.Width; $y1 = $bm.Height; $x2 = -1; $y2 = -1
        for ($y = 0; $y -lt $bm.Height; $y++) {
            $row = $y * $d.Stride
            for ($x = 0; $x -lt $bm.Width; $x++) {
                if ($buf[$row + $x * 4 + 3] -ne 0) {
                    if ($x -lt $x1) { $x1 = $x }
                    if ($x -gt $x2) { $x2 = $x }
                    if ($y -lt $y1) { $y1 = $y }
                    if ($y -gt $y2) { $y2 = $y }
                }
            }
        }
        if ($x2 -lt 0) { throw "'$Path' rendered empty." }
        New-Object Windows.Int32Rect $x1, $y1, ($x2 - $x1 + 1), ($y2 - $y1 + 1)
    } finally { $bm.Dispose() }
}

function Export-Resampled {
    param([string]$InPath, [string]$OutPath, $Crop, [int]$W, [int]$H)
    $src = New-Object Windows.Media.Imaging.BitmapImage
    $src.BeginInit()
    $src.UriSource = New-Object Uri $InPath
    $src.CacheOption = [Windows.Media.Imaging.BitmapCacheOption]::OnLoad
    $src.CreateOptions = [Windows.Media.Imaging.BitmapCreateOptions]::PreservePixelFormat
    $src.EndInit()
    $cropped = New-Object Windows.Media.Imaging.CroppedBitmap $src, $Crop
    $dv = New-Object Windows.Media.DrawingVisual
    [Windows.Media.RenderOptions]::SetBitmapScalingMode($dv, [Windows.Media.BitmapScalingMode]::HighQuality)
    $dc = $dv.RenderOpen()
    $dc.DrawImage($cropped, (New-Object Windows.Rect 0, 0, $W, $H))
    $dc.Close()
    $rtb = New-Object Windows.Media.Imaging.RenderTargetBitmap $W, $H, 96, 96, ([Windows.Media.PixelFormats]::Pbgra32)
    $rtb.Render($dv)
    $enc = New-Object Windows.Media.Imaging.PngBitmapEncoder
    $enc.Interlace = [Windows.Media.Imaging.PngInterlaceOption]::Off
    $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($rtb))
    $fs = [IO.File]::Create($OutPath)
    try { $enc.Save($fs) } finally { $fs.Close() }
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$svgDir = Join-Path $WorkDir 'svg'
New-Item -ItemType Directory -Force -Path $svgDir | Out-Null

"Renderer: $ChromePath"
"Work:     $WorkDir"
""

foreach ($mark in $marks) {
    $svg = Join-Path $svgDir "$($mark.Key).svg"
    Invoke-WebRequest -Uri $mark.Url -OutFile $svg -UseBasicParsing -TimeoutSec 60 -Headers @{ 'User-Agent' = $UA }

    $ink = Measure-Ink $svg $mark.Keep
    # A hair of margin so the outermost antialiased pixel is not clipped; the
    # trim below takes it straight back off.
    $pad = 0.01 * [Math]::Max($ink.w, $ink.h)
    $vb = @{ X = $ink.x - $pad; Y = $ink.y - $pad; W = $ink.w + 2 * $pad; H = $ink.h + 2 * $pad }

    $big = $Long * $Super
    if ($vb.W -ge $vb.H) { $pw = $big; $ph = [int][Math]::Round($big * $vb.H / $vb.W) }
    else                 { $ph = $big; $pw = [int][Math]::Round($big * $vb.W / $vb.H) }

    $raw = Join-Path $WorkDir "raw-$($mark.Key).png"
    Export-Png $svg $raw $vb $pw $ph $mark.Keep

    $crop = Get-AlphaBounds $raw
    if ($crop.Width -ge $crop.Height) { $fw = $Long; $fh = [int][Math]::Round($Long * $crop.Height / $crop.Width) }
    else                              { $fh = $Long; $fw = [int][Math]::Round($Long * $crop.Width / $crop.Height) }

    $final = Join-Path $OutDir "$($mark.Key).png"
    Export-Resampled $raw $final $crop $fw $fh
    "  {0,-10} ink {1,8:n2}x{2,-8:n2} -> {3}x{4}  {5,9:n0} bytes" -f `
        $mark.Key, $ink.w, $ink.h, $fw, $fh, (Get-Item $final).Length
}

""
"Wrote to $OutDir"
"Rebuild the icon and look at it before committing - the marks are the one"
"thing here that no test can tell you is wrong."
