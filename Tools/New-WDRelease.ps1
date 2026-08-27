<#
    Builds the release artefact and everything that has to agree with it.

    Three outputs, and the second two are derived from the first so they cannot
    disagree about the bytes:

      WinSetupToolkit-<version>.zip   what people download
      SHA256SUMS.txt                  the hash, so a download can be checked
      winget\*.yaml                   the package manifest, which embeds the
                                      same hash and the release URL

    THE ZIP UNPACKS TO A FOLDER NAMED WinSetupToolkit, not to the current
    directory. That is not tidiness: the answer file generator copies "the
    WinSetupToolkit folder" off the installation medium by that exact name
    (WD.Unattend's specialize command), so a zip that scattered its contents
    would break the auto-debloat-after-setup path for anybody who unpacked it
    onto a stick.

    Imports nothing from the toolkit, for the same reason the snapshot tools do
    not: a build script that depends on the thing it is packaging cannot be
    trusted to package a broken one.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^\d+\.\d+\.\d+$')][string]$Version,
    [string]$Repo   = 'poagalt/Windows-Setup-Toolkit',
    [string]$Source = '',
    [string]$OutDir = ''
)

$ErrorActionPreference = 'Stop'

# RESOLVED HERE, NOT IN THE PARAM DEFAULTS: $PSScriptRoot is empty when a param
# block's defaults are evaluated under `powershell -File`, and the failure names
# neither the variable nor the reason.
$here = $PSScriptRoot
if (-not $here) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $Source) { $Source = Split-Path -Parent $here }
if (-not $OutDir) { $OutDir = Join-Path $Source 'dist' }
$name = 'WinSetupToolkit'
$tag  = "v$Version"

# What ships. Named explicitly rather than as an exclude list: a new internal
# document should not become a public one because nobody remembered to exclude
# it, which is the failure mode an exclude list has.
$include = @(
    'WinSetupToolkit.ps1'
    'Run-WinSetupToolkit.cmd'
    'WinSetupToolkit.ico'
    'README.md'
    'LICENSE'
    'Modules'
    'Manifest'
    'Assets'
    'Tools'
)

Write-Host "Building $name $Version" -ForegroundColor Cyan

# --- assemble under a folder of the right name ------------------------------
$staging = Join-Path ([IO.Path]::GetTempPath()) ("wst-build-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
$payload = Join-Path $staging $name
$null = New-Item -ItemType Directory -Force -Path $payload

$missing = @()
foreach ($item in $include) {
    $from = Join-Path $Source $item
    if (-not (Test-Path -LiteralPath $from)) { $missing += $item; continue }
    Copy-Item -LiteralPath $from -Destination $payload -Recurse -Force
}
if ($missing.Count) {
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
    throw "Not in the source tree: $($missing -join ', ')"
}

# profile_saves has to EXIST and be EMPTY. The unattend path writes a chosen
# selection into it and reads it back on the target machine, so the folder is
# part of the layout - but shipping somebody's saved selections is not.
$null = New-Item -ItemType Directory -Force -Path (Join-Path $payload 'profile_saves')
Set-Content -LiteralPath (Join-Path $payload 'profile_saves\.gitkeep') -Value '' -Encoding ASCII

# --- refuse to ship a tree that does not pass its own gate ------------------
# Cheap, and the one check worth making here: a .cmd with LF endings launches
# nothing, and a module without a BOM is read as ANSI by PowerShell 5.1.
$problems = @()
foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $payload 'Modules') -Filter '*.psm1') +
                @(Get-Item (Join-Path $payload 'WinSetupToolkit.ps1'))) {
    $b = [IO.File]::ReadAllBytes($f.FullName)
    if (-not ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)) {
        $problems += "$($f.Name) has no UTF-8 BOM"
    }
    $err = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$err)
    if ($err) { $problems += "$($f.Name) does not parse: $($err[0].Message)" }
}
foreach ($f in @(Get-ChildItem -LiteralPath $payload -Filter '*.cmd')) {
    $b  = [IO.File]::ReadAllBytes($f.FullName)
    $cr = @($b | Where-Object { $_ -eq 13 }).Count
    $lf = @($b | Where-Object { $_ -eq 10 }).Count
    if ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) {
        $problems += "$($f.Name) has a BOM, so cmd.exe reads its first line as '<BOM>@echo'"
    }
    if ($lf -eq 0 -or $cr -ne $lf) { $problems += "$($f.Name) is not CRLF ($cr CR to $lf LF)" }
}
if ($problems.Count) {
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
    throw ("Refusing to build:`n  " + ($problems -join "`n  "))
}
Write-Host "  payload checks passed" -ForegroundColor Green

# --- the zip ----------------------------------------------------------------
$null = New-Item -ItemType Directory -Force -Path $OutDir
$zip  = Join-Path $OutDir "$name-$Version.zip"
if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
Add-Type -AssemblyName System.IO.Compression.FileSystem

# ENTRY BY ENTRY, WITH FORWARD SLASHES. NOT CreateFromDirectory: on .NET
# Framework that writes Path.DirectorySeparatorChar - a BACKSLASH on Windows -
# and the zip spec requires forward slashes (APPNOTE 4.4.17.1). Explorer and
# Expand-Archive cope; 7-Zip and unzip on macOS or Linux read the whole path as
# one filename and unpack a flat folder of unusable names.
$archive = [IO.Compression.ZipFile]::Open($zip, 'Create')
try {
    foreach ($file in @(Get-ChildItem -LiteralPath $staging -Recurse -File -Force)) {
        $rel = $file.FullName.Substring($staging.Length).TrimStart('\', '/').Replace('\', '/')
        $null = [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $file.FullName, $rel, 'Optimal')
    }
} finally {
    $archive.Dispose()
}
Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue

# Proved rather than assumed, because the separator is invisible until somebody
# on another platform unpacks it.
$check = [IO.Compression.ZipFile]::OpenRead($zip)
try {
    $wrong = @($check.Entries | Where-Object { $_.FullName -like '*\*' })
    if ($wrong.Count) { throw "$($wrong.Count) zip entries use backslash separators" }
    if (-not @($check.Entries | Where-Object { $_.FullName -eq "$name/Run-$name.cmd" }).Count) {
        throw "the zip does not contain $name/Run-$name.cmd"
    }
} finally {
    $check.Dispose()
}

$hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToUpperInvariant()
$size = [Math]::Round((Get-Item $zip).Length / 1MB, 2)
Write-Host ("  {0}  {1} MB" -f (Split-Path -Leaf $zip), $size) -ForegroundColor Green
Write-Host "  SHA256 $hash"

# --- SHA256SUMS, in the format sha256sum -c reads ---------------------------
$sums = Join-Path $OutDir 'SHA256SUMS.txt'
Set-Content -LiteralPath $sums -Encoding ASCII -Value @(
    "$($hash.ToLowerInvariant())  $name-$Version.zip"
)

# --- the winget manifest ----------------------------------------------------
# Three files, which is what winget's 1.6 schema requires. The installer type is
# 'zip' with a nested portable, because this is a folder of scripts rather than
# an installer - so winget unpacks it and puts the launcher on the path.
$url  = "https://github.com/$Repo/releases/download/$tag/$name-$Version.zip"
$pkg  = 'Poag.WindowsSetupToolkit'
$wing = Join-Path $OutDir 'winget'
$null = New-Item -ItemType Directory -Force -Path $wing

Set-Content -LiteralPath (Join-Path $wing "$pkg.yaml") -Encoding UTF8 -Value @"
# yaml-language-server: `$schema=https://aka.ms/winget-manifest.version.1.6.0.schema.json
PackageIdentifier: $pkg
PackageVersion: $Version
DefaultLocale: en-US
ManifestType: version
ManifestVersion: 1.6.0
"@

Set-Content -LiteralPath (Join-Path $wing "$pkg.locale.en-US.yaml") -Encoding UTF8 -Value @"
# yaml-language-server: `$schema=https://aka.ms/winget-manifest.defaultLocale.1.6.0.schema.json
PackageIdentifier: $pkg
PackageVersion: $Version
PackageLocale: en-US
Publisher: Nathan Poag
PublisherUrl: https://github.com/$($Repo.Split('/')[0])
PackageName: Windows Setup Toolkit
PackageUrl: https://github.com/$Repo
License: PolyForm Noncommercial 1.0.0
LicenseUrl: https://github.com/$Repo/blob/main/LICENSE
ShortDescription: Debloat and set up a fresh Windows installation, reversibly.
Description: |-
  Removes preinstalled software and telemetry from a fresh Windows installation
  on hardware from any manufacturer, and generates an autounattend.xml that can
  complete Windows Setup and run the same selection before the first sign-in.
  Every change is journalled and reversible: each run leaves a rollback script,
  a per-option revert page, and a searchable document naming which option could
  have caused a given symptom. Free for personal use.
Tags:
- debloat
- privacy
- telemetry
- unattend
- windows
ManifestType: defaultLocale
ManifestVersion: 1.6.0
"@

Set-Content -LiteralPath (Join-Path $wing "$pkg.installer.yaml") -Encoding UTF8 -Value @"
# yaml-language-server: `$schema=https://aka.ms/winget-manifest.installer.1.6.0.schema.json
PackageIdentifier: $pkg
PackageVersion: $Version
MinimumOSVersion: 10.0.19041.0
InstallerType: zip
Installers:
- Architecture: neutral
  InstallerUrl: $url
  InstallerSha256: $hash
  NestedInstallerType: portable
  NestedInstallerFiles:
  - RelativeFilePath: $name\Run-$name.cmd
    PortableCommandAlias: winsetuptoolkit
ManifestType: installer
ManifestVersion: 1.6.0
"@

Write-Host ''
Write-Host "Wrote to $OutDir" -ForegroundColor Cyan
Write-Host "  $name-$Version.zip"
Write-Host '  SHA256SUMS.txt'
Write-Host "  winget\$pkg.*.yaml  (3 files)"
Write-Host ''
Write-Host 'Next:' -ForegroundColor Cyan
Write-Host "  git tag -a $tag -m ""Windows Setup Toolkit $Version"" && git push origin $tag"
Write-Host "  gh release create $tag ""$zip"" ""$sums"" --title ""Windows Setup Toolkit $Version"" --notes-file <notes>"
Write-Host "  winget validate --manifest ""$wing"""
Write-Host '  then open a PR against microsoft/winget-pkgs with the winget folder'
