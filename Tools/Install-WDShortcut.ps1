<#
    Puts this program's identity where the shell can see it: a Start menu
    shortcut carrying the application's name, its icon, and its AppUserModelID.

    WHY A SHORTCUT IS THE FIX AND Window.Icon IS NOT. Nothing in Explorer or in
    Start menu search ever runs this program, so nothing there can ask a running
    process what it looks like - the search result draws whatever the .lnk names,
    and a .lnk naming a file that is not there draws a blank page. That is the
    whole of "the icon is missing when I look the program up", and it is why the
    generated icon has to exist as a FILE (Write-WDIconFile.ps1) rather than only
    in the window.

    The name in the search result is the shortcut's FILE NAME, which is also why
    a rename that touches every string in the codebase still leaves the old name
    on screen: the shortcut is on the machine, not in the repo, and nothing keeps
    it in step. This script is that missing step, and it removes shortcuts left
    by earlier names rather than leaving a second, broken entry beside the new one.

    AND IT STAMPS THE AUMID, which is the part that makes the icon an identity
    rather than a picture. A taskbar button is grouped by AppUserModelID; a
    process that declares none is given one derived from its executable, so a WPF
    window hosted by powershell.exe is matched to PowerShell's own Start menu
    entry and wears PowerShell's icon however carefully Window.Icon was set. The
    toolkit declares its own id instead (Set-WDTaskbarIdentity), and stamping the
    same id here is what gives that id something to resolve TO - so the button,
    the pin, the jump list and a toast notifier all agree about which application
    this is. Both halves read the id from one place; see the identity note in
    WD.Core.psm1.

    This is the ordinary answer for any program whose real executable is a host
    rather than itself - the same thing an installer does for a script, a Python
    app, or an Electron build.

        .\Tools\Install-WDShortcut.ps1                  # Start menu
        .\Tools\Install-WDShortcut.ps1 -Desktop         # and the desktop
        .\Tools\Install-WDShortcut.ps1 -RebuildIcon     # regenerate the .ico first
        .\Tools\Install-WDShortcut.ps1 -Remove          # take it all back off
#>
[CmdletBinding()]
param(
    # What the Start menu will call it. The file name IS the search result.
    [string]$Name = 'Windows Setup Toolkit',
    # A desktop shortcut as well as the Start menu one.
    [switch]$Desktop,
    # Rebuild WinSetupToolkit.ico before pointing anything at it. The icon is
    # committed, so this is only wanted after the marks in Assets\ change.
    [switch]$RebuildIcon,
    # Remove the shortcuts instead of writing them.
    [switch]$Remove,
    # Leave shortcuts from earlier names alone. They are broken by definition -
    # they name launcher and icon files this project no longer has - so the
    # default is to clear them out.
    [switch]$KeepStale,
    [ValidateSet('', 'dark', 'light')]
    [string]$Theme = ''
)

$ErrorActionPreference = 'Stop'

$root     = Split-Path -Parent $PSScriptRoot
$launcher = Join-Path $root 'Run-WinSetupToolkit.cmd'
$iconPath = Join-Path $root 'WinSetupToolkit.ico'

# File names this project used to have. A shortcut naming one of these cannot
# work - the file is gone - so it is safe to remove and pointless to keep.
# Every marker carries its extension deliberately: the repo folder itself may
# still be called WinDebloat, and a bare stem would match the live shortcut too.
$staleMarkers = @('Run-WinDebloat.cmd', 'WinDebloat.ico', 'WinDebloat.ps1', 'Undo-WinDebloat.ps1')

$startMenu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
$desktopDir = [Environment]::GetFolderPath('Desktop')

$targets = @(Join-Path $startMenu "$Name.lnk")
if ($Desktop) { $targets += (Join-Path $desktopDir "$Name.lnk") }

function Write-Step { param([string]$Text) Write-Host "  $Text" }

Write-Host ''
Write-Host $Name -ForegroundColor Cyan
Write-Host ''

# --- shortcuts left by earlier names --------------------------------------
# Read rather than assumed: this deletes files in somebody's Start menu, so
# each one has to prove it is a broken shortcut of ours before it goes.
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

# --- the icon has to be a file --------------------------------------------
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

# --- report what landed, rather than trusting the write -------------------
# The AUMID in particular is invisible in Explorer's property sheet, so reading
# it back is the only way anybody can tell it is there.
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
