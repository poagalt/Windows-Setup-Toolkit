<#
    Writes the application icon to WinSetupToolkit.ico, beside the launcher.

    This adds no artwork. The icon is already generated - New-WDIconBytes
    composes it from the four marks in Assets\, and Get-WDAppIconBytes is what
    the window itself wears. All this does is put those same bytes on disk,
    because a shortcut's IconLocation needs a path, and nothing in Explorer or
    the Start menu can see an icon a running process built for itself.

    The file belongs in the repo rather than somewhere central for two reasons:
    the folder can then be copied to another machine and still have its icon,
    and an icon kept anywhere else goes stale the moment the marks change with
    nothing to notice.

    Do not put it under %LOCALAPPDATA% or anywhere below %USERPROFILE%\AppData.
    A shortcut records its icon path as an environment-variable string, and the
    shell does not resolve %USERPROFILE%\AppData\... when it draws icons - every
    icon in such a folder comes out blank, including known-good ones.

        .\Tools\Write-WDIconFile.ps1                     # -> .\WinSetupToolkit.ico
        .\Tools\Write-WDIconFile.ps1 -Path C:\some\where.ico
        .\Tools\Write-WDIconFile.ps1 -Theme light
#>
[CmdletBinding()]
param(
    [string]$Path,
    [ValidateSet('', 'dark', 'light')]
    [string]$Theme = ''
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
if (-not $Path) {
    $Path = Join-Path $root 'WinSetupToolkit.ico'
}

Import-Module (Join-Path $root 'Modules\WD.UI.psm1') -Force

$bytes = Get-WDAppIconBytes -Theme $Theme
if (-not $bytes) {
    throw "Get-WDAppIconBytes produced nothing - the icon could not be built. Assets\ is probably missing or unreadable."
}

$dir = Split-Path -Parent $Path
if ($dir -and -not (Test-Path $dir)) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
}
[IO.File]::WriteAllBytes($Path, $bytes)

# Report what actually landed, rather than trusting the write.
$frames = [BitConverter]::ToUInt16($bytes, 4)
$sizes = @()
for ($i = 0; $i -lt $frames; $i++) {
    $w = $bytes[6 + 16 * $i]
    if ($w -eq 0) { $sizes += 256 } else { $sizes += $w }
}
"{0}  ({1:N1} KiB, {2} sizes: {3})" -f $Path, ((Get-Item $Path).Length / 1KB), $frames, ($sizes -join ' ')

# Explorer caches icons by path and does not look again on its own, so a
# regenerated file under the same name stays invisible until something says so.
try {
    if (-not ('WDIconFile.Shell' -as [type])) {
        Add-Type -Namespace WDIconFile -Name Shell -MemberDefinition @'
[DllImport("shell32.dll")] public static extern void SHChangeNotify(int e, uint f, IntPtr a, IntPtr b);
'@
    }
    [WDIconFile.Shell]::SHChangeNotify(0x08000000, 0, [IntPtr]::Zero, [IntPtr]::Zero)
} catch {
    Write-Verbose "could not refresh the icon cache: $($_.Exception.Message)"
}
