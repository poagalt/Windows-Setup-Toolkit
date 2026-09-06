# The convenience one-liner: downloads the published release, checks it against
# SHA256SUMS, and unpacks it. Changes nothing else about the machine.
[CmdletBinding()]
param(
    # Which release. Latest by default; pin it for a known version.
    [string]$Version = '',
    # Under LOCALAPPDATA so no elevation is needed to write it - the launcher
    # elevates itself later, which is the only step that needs to.
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
    # .Content is a byte array when the server says octet-stream, and GitHub
    # serves every release asset that way whatever the extension. [string] on a
    # byte[] gives space-separated decimals.
    $sums = if ($raw -is [byte[]]) { [Text.Encoding]::UTF8.GetString($raw) } else { [string]$raw }
    foreach ($line in ($sums -split "`r?`n")) {
        if ($line -match '^\s*([0-9a-fA-F]{64})\s+\*?(.+?)\s*$' -and $Matches[2] -eq $zipName) {
            $expected = $Matches[1].ToLowerInvariant()
        }
    }
} catch { }

Write-Step "SHA256   $actual"

if (-not $expected) {
    # Said plainly rather than passed over: a release with no published sums is
    # not necessarily tampered with, but it cannot be checked either.
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

# Replaced rather than merged: leaving an older module beside a newer one is how
# a half-upgraded toolkit happens.
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
    # Not done for you: a Start menu entry is a change to this machine, and the
    # line above promises there have been none.
    Write-Host '  To put it in the Start menu, with its own icon and identity:' -ForegroundColor Cyan
    Write-Host "    $root\Tools\Install-WDShortcut.ps1"
    Write-Host ''
    return
}

Write-Host '  Starting. The launcher asks for administrator rights itself.' -ForegroundColor Cyan
Write-Host ''
Start-Process -FilePath $launcher -WorkingDirectory $root
