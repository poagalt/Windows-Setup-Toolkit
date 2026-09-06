# A Start menu shortcut carrying the name, the icon, and the AppUserModelID.
# Start menu search draws the FILE name and the icon that .lnk points at,
# neither of which is in the repo - so a rename is not complete until this has
# run.
# Not part of install.ps1: a Start menu entry is a change to the machine, and
# that script promises there have been none.
[CmdletBinding()]
param(
    # What the Start menu will call it. The file name is the search result.
    [string]$Name = 'Windows Setup Toolkit',
    # A desktop shortcut as well as the Start menu one.
    [switch]$Desktop,
    # Rebuild WinSetupToolkit.ico first. The icon is committed, so this is only
    # wanted after the marks in Assets\ change.
    [switch]$RebuildIcon,
    # Remove the shortcuts instead of writing them.
    [switch]$Remove,
    # Leave shortcuts from earlier names alone. They are broken by definition,
    # so the default is to clear them out.
    [switch]$KeepStale,
    [ValidateSet('', 'dark', 'light')]
    [string]$Theme = ''
)

$ErrorActionPreference = 'Stop'

$root     = Split-Path -Parent $PSScriptRoot
$launcher = Join-Path $root 'Run-WinSetupToolkit.cmd'
$iconPath = Join-Path $root 'WinSetupToolkit.ico'

# File names this project used to have. Every marker carries its extension
# deliberately: the repo folder may still be called WinDebloat, so a bare stem
# would match the shortcut just written.
$staleMarkers = @('Run-WinDebloat.cmd', 'WinDebloat.ico', 'WinDebloat.ps1', 'Undo-WinDebloat.ps1')

$startMenu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
$desktopDir = [Environment]::GetFolderPath('Desktop')

$targets = @(Join-Path $startMenu "$Name.lnk")
if ($Desktop) { $targets += (Join-Path $desktopDir "$Name.lnk") }

function Write-Step { param([string]$Text) Write-Host "  $Text" }

Write-Host ''
Write-Host $Name -ForegroundColor Cyan
Write-Host ''

# Read rather than assumed: this deletes files in somebody's Start menu, so each
# one has to prove it is a broken shortcut of ours.
if (-not $KeepStale) {
    $searchDirs = @(
        $startMenu,
        (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'),
        $desktopDir,
        (Join-Path $env:PUBLIC 'Desktop')
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique

    $shell = $null
    try { $shell = New-Object -ComObject WScript.Shell } catch {
        Write-Step 'WScript.Shell is unavailable, so no old shortcut could be inspected.'
    }

    if ($shell) {
        foreach ($dir in $searchDirs) {
            $lnks = @(Get-ChildItem -LiteralPath $dir -Filter '*.lnk' -Recurse -ErrorAction SilentlyContinue)
            foreach ($lnk in $lnks) {
                if ($targets -contains $lnk.FullName) { continue }
                $sc = $null
                try { $sc = $shell.CreateShortcut($lnk.FullName) } catch { continue }
                $blob = @([string]$sc.TargetPath, [string]$sc.Arguments, [string]$sc.IconLocation) -join ' '
                $hit = ''
                foreach ($m in $staleMarkers) {
                    if ($blob -like "*$m*") { $hit = $m; break }
                }
                if (-not $hit) { continue }
                try {
                    Remove-Item -LiteralPath $lnk.FullName -Force
                    Write-Step "Removed  $($lnk.FullName)  (it named $hit, which this project no longer has)"
                } catch {
                    Write-Step "Could not remove $($lnk.FullName): $($_.Exception.Message)"
                }
            }
        }
    }
}

if ($Remove) {
    foreach ($t in $targets) {
        if (Test-Path -LiteralPath $t) {
            Remove-Item -LiteralPath $t -Force
            Write-Step "Removed  $t"
        } else {
            Write-Step "Not there $t"
        }
    }
    Write-Host ''
    Write-Host '  The folder itself is untouched. Nothing else on this machine was changed.' -ForegroundColor Cyan
    Write-Host ''
    return
}

if (-not (Test-Path -LiteralPath $launcher)) {
    throw "The launcher is missing: $launcher. Run this from inside the toolkit folder."
}

# The icon has to exist as a file - a missing icon path is not a fallback, it is
# nothing to draw. It also must not live under %USERPROFILE%\AppData, which the
# shell does not expand when drawing one.
if ($RebuildIcon -or -not (Test-Path -LiteralPath $iconPath)) {
    $why = if ($RebuildIcon) { 'Rebuilding' } else { 'No icon file yet, building' }
    Write-Step "$why $iconPath"
    & (Join-Path $PSScriptRoot 'Write-WDIconFile.ps1') -Path $iconPath -Theme $Theme | ForEach-Object {
        Write-Step $_
    }
}
if (-not (Test-Path -LiteralPath $iconPath)) {
    throw "The icon could not be written to $iconPath, so the shortcut would draw blank."
}

Import-Module (Join-Path $root 'Modules\WD.Core.psm1') -Force -DisableNameChecking
$appId = Get-WDAppUserModelId

foreach ($t in $targets) {
    Set-WDShellShortcut -Path $t `
                        -Target $launcher `
                        -WorkingDirectory $root `
                        -IconPath $iconPath `
                        -Description 'Debloat and customize Windows, revert past changes, or build a Windows Setup answer file.' `
                        -AppUserModelId $appId
}

# The AUMID is invisible in Explorer's property sheet, so reading it back is the
# only way anybody can tell it is there.
Write-Host ''
foreach ($t in $targets) {
    $stamped = Get-WDShortcutAppUserModelId -Path $t
    $ok = if ($stamped -eq $appId) { 'stamped' } else { "NOT STAMPED (read back '$stamped')" }
    Write-Step "$t"
    Write-Step "  target $launcher"
    Write-Step "  icon   $iconPath"
    Write-Step "  app id $appId  [$ok]"
}

Write-Host ''
Write-Host "  Search the Start menu for '$Name'." -ForegroundColor Cyan
Write-Host '  The icon may take a moment to appear - Explorer caches icons by path.'
Write-Host ''
