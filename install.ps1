<#
    The convenience one-liner:

      irm https://raw.githubusercontent.com/poagalt/Windows-Setup-Toolkit/main/install.ps1 | iex

    WHAT THIS DOES NOT DO IS RUN ANYTHING WITHOUT SHOWING ITS WORK. Piping a URL
    into iex is the least inspectable thing a person can do on Windows, and this
    project's whole argument is that you should be able to read what it does
    before granting it administrator rights. So this downloads the release,
    checks it against the SHA256SUMS published beside it, prints the hash and
    the folder, and then stops - unless -Run says otherwise. The toolkit itself
    is a folder of readable scripts sitting where you were just told, and the
    launcher is the thing that asks for elevation, not this.

    It also refuses to carry on if the hash does not match, rather than warning
    and continuing, because a mismatched download is the one case where
    continuing is never the right answer.
#>
[CmdletBinding()]
param(
    # Which release. Latest by default; pin it if you want a known version.
    [string]$Version = '',
    # Where the folder lands. Under LOCALAPPDATA so no elevation is needed to
    # write it - the launcher elevates itself later, which is the only step
    # that needs to.
    [string]$Destination = (Join-Path $env:LOCALAPPDATA 'WinSetupToolkit'),
    # Launch the toolkit when it is unpacked and verified.
    [switch]$Run,
    [string]$Repo = 'poagalt/Windows-Setup-Toolkit'
)

$ErrorActionPreference = 'Stop'
$name = 'WinSetupToolkit'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Write-Step { param([string]$Text) Write-Host "  $Text" }

Write-Host ''
Write-Host 'Windows Setup Toolkit' -ForegroundColor Cyan
Write-Host ''

# --- which release --------------------------------------------------------
if ($Version) {
    $tag = "v$Version"
} else {
    Write-Step 'Asking GitHub for the latest release...'
    try {
        $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" `
                                 -Headers @{ 'User-Agent' = "$name-installer" } -TimeoutSec 30
        $tag = [string]$rel.tag_name
    } catch {
        throw "Could not reach the GitHub releases API: $($_.Exception.Message)"
    }
    if (-not $tag) { throw 'GitHub returned no release tag.' }
    $Version = $tag.TrimStart('v')
}

$zipName = "$name-$Version.zip"
$base    = "https://github.com/$Repo/releases/download/$tag"
Write-Step "Release  $tag"
Write-Step "From     $base/$zipName"

# --- download the artefact and the sums it is published with ---------------
$work = Join-Path ([IO.Path]::GetTempPath()) ("wst-dl-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Force -Path $work
$zip  = Join-Path $work $zipName

try {
    Invoke-WebRequest -Uri "$base/$zipName" -OutFile $zip -UseBasicParsing -TimeoutSec 300
} catch {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    throw "Download failed: $($_.Exception.Message)"
}

$actual = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()

$expected = ''
try {
    $raw = (Invoke-WebRequest -Uri "$base/SHA256SUMS.txt" -UseBasicParsing -TimeoutSec 60).Content
    # .Content IS A BYTE ARRAY WHENEVER THE SERVER SAYS octet-stream, and GitHub
    # serves every release asset that way whatever its extension. [string] on a
    # byte[] gives the decimal bytes space-separated - "98 50 53 100 ..." - so
    # every line failed the regex below and this reported "no SHA256SUMS.txt"
    # for a release that published one. The one safety check this script exists
    # to perform, silently never happening, on a path where the warning it
    # printed instead looked like an honest answer.
    $sums = if ($raw -is [byte[]]) { [Text.Encoding]::UTF8.GetString($raw) } else { [string]$raw }
    foreach ($line in ($sums -split "`r?`n")) {
        if ($line -match '^\s*([0-9a-fA-F]{64})\s+\*?(.+?)\s*$' -and $Matches[2] -eq $zipName) {
            $expected = $Matches[1].ToLowerInvariant()
        }
    }
} catch { }

Write-Step "SHA256   $actual"

if (-not $expected) {
    # Said plainly rather than passed over. A release with no published sums is
    # not necessarily tampered with, but it cannot be checked either, and the
    # difference matters enough to name.
    Write-Host ''
    Write-Host '  WARNING: this release publishes no SHA256SUMS.txt, so the download' -ForegroundColor Yellow
    Write-Host '  above could not be verified against anything. Compare the hash by hand' -ForegroundColor Yellow
    Write-Host "  against the release page before you run it: https://github.com/$Repo/releases/tag/$tag" -ForegroundColor Yellow
} elseif ($expected -ne $actual) {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host ''
    Write-Host '  CHECKSUM MISMATCH - nothing has been unpacked.' -ForegroundColor Red
    Write-Host "  published $expected" -ForegroundColor Red
    Write-Host "  received  $actual" -ForegroundColor Red
    throw 'The download does not match the published checksum.'
} else {
    Write-Step 'Verified against the published SHA256SUMS.'
}

# --- unpack ----------------------------------------------------------------
# Replaced rather than merged: leaving an older module beside a newer one is how
# a half-upgraded toolkit happens, and every file here is disposable.
$app = Join-Path $Destination 'app'
if (Test-Path -LiteralPath $app) { Remove-Item -LiteralPath $app -Recurse -Force }
$null = New-Item -ItemType Directory -Force -Path $app

Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::ExtractToDirectory($zip, $app)
Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue

$root     = Join-Path $app $name
$launcher = Join-Path $root "Run-$name.cmd"
if (-not (Test-Path -LiteralPath $launcher)) { throw "The release did not contain Run-$name.cmd." }

Write-Step "Unpacked $root"
Write-Host ''

# --- and stop, unless told otherwise ---------------------------------------
if (-not $Run) {
    Write-Host '  Nothing has been changed on this machine. To read it first:' -ForegroundColor Cyan
    Write-Host "    $root"
    Write-Host '  The removal list is plain JSON in Manifest\, one file per category.'
    Write-Host ''
    Write-Host '  To start it (it will ask for administrator rights):' -ForegroundColor Cyan
    Write-Host "    $launcher"
    Write-Host ''
    Write-Host '  Or re-run this with -Run to launch it straight away.'
    Write-Host ''
    return
}

Write-Host '  Starting. The launcher asks for administrator rights itself.' -ForegroundColor Cyan
Write-Host ''
Start-Process -FilePath $launcher -WorkingDirectory $root
