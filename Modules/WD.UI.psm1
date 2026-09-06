Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing -ErrorAction SilentlyContinue

function Get-WDPalette {
    param([string]$Theme)

    $dark = $false
    if ($Theme -eq 'dark')  { $dark = $true }
    elseif ($Theme -eq 'light') { $dark = $false }
    else {
        try {
            $v = Get-ItemProperty 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name AppsUseLightTheme -ErrorAction Stop
            $dark = ($v.AppsUseLightTheme -eq 0)
        } catch { }
    }

    if ($dark) {
        # ScrollThumb sits between Line and Muted: a bar this narrow must be
        # findable without being the loudest thing on the page.
        # Text is a light gray, not white: pure white on a near-black page is
        # ~17:1, past readable and into glare, and #BA leaves Sub a visible step
        # below.
        @{ Dark=$true; Bg='#FF1F1F1F'; Panel='#FF2B2B2B'; Card='#FF303030'; CardSel='#FF37475A'
           Text='#FFBABABA'; Sub='#FF9A9A9A'; Line='#FF454545'; Accent='#FF4CA6FF'
           Ok='#FF5FD07F'; Warn='#FFE8B44A'; Bad='#FFF06C6C'; Muted='#FF9E9E9E'; RowHover='#FF3A3A3A'
           # Something standing in the way, which is neither a success nor this
           # run going wrong. A hue of its own rather than a shade of Warn,
           # because a paler yellow reads as "a bit refused".
           Obstruct='#FFB08CE8'
           ScrollThumb='#FF5A5A5A'; ScrollThumbHover='#FF8C8C8C'
           BtnBg='#FF3C3C3C'; BtnBorder='#FF5E5E5E'; BtnTint='#26FFFFFF'; FieldBg='#FF262626'
           # The one filled button on each page: Preview, the only way into an
           # apply. #10243A on #4CA6FF is about 8.7:1, which this needs because
           # it is pressed without being read twice.
           GoBg='#FF4CA6FF'; GoText='#FF10243A'; GoBorder='#FF7CC0FF'
           T1='#FF5FD07F'; T2='#FF4CA6FF'; T3='#FFE8B44A'; T4='#FFF06C6C' }
    } else {
        @{ Dark=$false; Bg='#FFF5F5F5'; Panel='#FFFFFFFF'; Card='#FFFAFAFA'; CardSel='#FFE4EEF8'
           Text='#FF141414'; Sub='#FF555555'; Line='#FFD8D8D8'; Accent='#FF0F6CBD'
           Ok='#FF1A7F37'; Warn='#FF8A5A00'; Bad='#FFC03030'; Muted='#FF6B6B6B'; RowHover='#FFEDEDED'
           Obstruct='#FF6B3FA0'
           ScrollThumb='#FFBFBFBF'; ScrollThumbHover='#FF8A8A8A'
           BtnBg='#FFF0F0F0'; BtnBorder='#FFACACAC'; BtnTint='#1A000000'; FieldBg='#FFFFFFFF'
           # White on #0F6CBD is about 5.9:1. The light accent is dark enough to
           # carry white where the dark theme's is not.
           GoBg='#FF0F6CBD'; GoText='#FFFFFFFF'; GoBorder='#FF0F6CBD'
           T1='#FF1A7F37'; T2='#FF0F6CBD'; T3='#FF8A5A00'; T4='#FFC03030' }
    }
}

# MessageBox is a Win32 dialog and takes its colours from the system, so on a
# dark page every warning opened as a white rectangle. There is no fixing it in
# place - its window is created and destroyed inside one blocking call.
$script:WDDialogTheme = $null
$script:WDDialogOwner = $null

# A runspace starts empty, so every one has to load the toolkit for itself.
# These were bare literals and no two agreed; one omitted WD.Preflight for its
# whole life and the guard swallowed it.
$script:WDRunspaceModules = @{
    # An apply, a preview, or a revert. Everything but WD.Unattend, which writes
    # a file for another machine.
    Run     = @('WD.Core','WD.Detect','WD.Actions','WD.Preflight','WD.Custom','WD.Persist','WD.Discover','WD.Revert','WD.Engine')
    # The startup scan. No Preflight: it builds no session, so it never reaches
    # the tool sweep.
    Scan    = @('WD.Core','WD.Detect','WD.Actions','WD.Custom','WD.Persist','WD.Discover','WD.Revert','WD.Engine')
    # The already-satisfied probe, one answer per item.
    Probe   = @('WD.Core','WD.Detect','WD.Actions','WD.Custom','WD.Persist')
    # The drive walk behind the storage bar.
    Storage = @('WD.Core','WD.Detect','WD.Actions','WD.Custom')
}

function Set-WDDialogHost {
    # Where the themed dialogs get their brushes and their owner.
    param($Dictionary, $Owner, [System.Nullable[bool]]$Dark)
    if ($Dictionary)     { $script:WDDialogTheme = $Dictionary }
    if ($Owner)          { $script:WDDialogOwner = $Owner }
    if ($null -ne $Dark) { $script:WDDialogDark  = [bool]$Dark }
}

function Show-WDMessage {
    param(
        [Parameter(Mandatory, Position = 0)]$Text,
        [Parameter(Position = 1)][string]$Title = 'Windows Setup Toolkit',
        [Parameter(Position = 2)][string]$Buttons = 'OK',
        [Parameter(Position = 3)][string]$Icon = 'None',
        # Build the window and hand it back instead of showing it - the seam
        # every modal here needs, because ShowDialog blocks the dispatcher.
        [switch]$BuildOnly
    )

    # Both call forms. Forty sites pass the four arguments in parentheses, which
    # arrive as one array; converting them to parameter syntax meant deleting
    # the parentheses holding multi-line calls together.
    if ($Text -is [array]) {
        $packed = @($Text)
        $Text = [string]$packed[0]
        if ($packed.Count -gt 1) { $Title   = [string]$packed[1] }
        if ($packed.Count -gt 2) { $Buttons = [string]$packed[2] }
        if ($packed.Count -gt 3) { $Icon    = [string]$packed[3] }
    }
    $Text = [string]$Text
    if ($Buttons -notin @('OK','OKCancel','YesNo','YesNoCancel')) { $Buttons = 'OK' }
    if ($Icon    -notin @('None','Information','Warning','Error','Question')) { $Icon = 'None' }

    if (-not $script:WDDialogTheme -and -not $BuildOnly) {
        # The real one, spelled through a variable so the literal
        # "[Windows.MessageBox]::Show(" appears nowhere else - the conversion
        # sweep replaced one inside this very function.
        $box = [Windows.MessageBox]
        return [string]$box::Show($Text, $Title, $Buttons, $Icon)
    }

    # Nothing in this application makes a noise. A dialog is already the loudest
    # thing this interface can do, and a system sound is a setting the person
    # has made elsewhere.

    $ref = {
        param($El, [string]$Prop, [string]$Key)
        $t = $El.GetType()
        $dpd = [System.ComponentModel.DependencyPropertyDescriptor]::FromName($Prop, $t, $t)
        if ($dpd) { $El.SetResourceReference($dpd.DependencyProperty, "Wd$Key") }
    }

    $win = New-Object Windows.Window
    $win.Title = $Title
    $win.SizeToContent = 'Height'
    # Width is measured from the text below rather than fixed: fixed at 560, a
    # list of registry paths wrapped mid-path.
    $win.Width = 560
    # Tall dialogs scroll rather than growing past the screen; 0.72 leaves the
    # taskbar and the caption visible.
    $win.MaxHeight = [Math]::Max(320, [Windows.SystemParameters]::WorkArea.Height * 0.72)
    # Resizable, because no measurement answers for every screen and every
    # reader.
    $win.ResizeMode = 'CanResize'
    $win.MinWidth  = 380
    $win.MinHeight = 200
    $win.ShowInTaskbar = $false
    $win.WindowStartupLocation = $(if ($script:WDDialogOwner) { 'CenterOwner' } else { 'CenterScreen' })
    if ($script:WDDialogOwner) {
        try { $win.Owner = $script:WDDialogOwner } catch { }
    }
    # The owner's whole resource dictionary, not just the palette: Button,
    # TextBox, and ComboBox keep the system chrome unless retemplated, and that
    # chrome is light in both palettes.
    $merged = $false
    if ($script:WDDialogOwner) {
        try { $null = $win.Resources.MergedDictionaries.Add($script:WDDialogOwner.Resources); $merged = $true } catch { }
    }
    if (-not $merged -and $script:WDDialogTheme) {
        $null = $win.Resources.MergedDictionaries.Add($script:WDDialogTheme)
    }
    & $ref $win 'Background' 'Panel'

    $root = New-Object Windows.Controls.DockPanel
    $root.Margin = '18,16,18,14'
    $root.LastChildFill = $true

    $row = New-Object Windows.Controls.StackPanel
    $row.Orientation = 'Horizontal'
    $row.HorizontalAlignment = 'Right'
    $row.Margin = '0,16,0,0'
    [Windows.Controls.DockPanel]::SetDock($row, 'Bottom')

    $answer = @{ V = $(switch ($Buttons) { 'OK' { 'OK' } 'OKCancel' { 'Cancel' } default { 'No' } }) }
    $spec = switch ($Buttons) {
        'OK'          { @(@{ T = 'OK';     R = 'OK';     Default = $true;  Cancel = $true }) }
        'OKCancel'    { @(@{ T = 'OK';     R = 'OK';     Default = $true;  Cancel = $false },
                          @{ T = 'Cancel'; R = 'Cancel'; Default = $false; Cancel = $true }) }
        'YesNo'       { @(@{ T = 'Yes';    R = 'Yes';    Default = $false; Cancel = $false },
                          @{ T = 'No';     R = 'No';     Default = $true;  Cancel = $true }) }
        default       { @(@{ T = 'Yes';    R = 'Yes';    Default = $false; Cancel = $false },
                          @{ T = 'No';     R = 'No';     Default = $false; Cancel = $false },
                          @{ T = 'Cancel'; R = 'Cancel'; Default = $true;  Cancel = $true }) }
    }
    foreach ($b in $spec) {
        $btn = New-Object Windows.Controls.Button
        $btn.Content = $b.T
        $btn.MinWidth = 92
        $btn.Padding = '14,5,14,6'
        $btn.Margin = '8,0,0,0'
        $btn.IsDefault = [bool]$b.Default
        $btn.IsCancel  = [bool]$b.Cancel
        # A local, because the closure captures this scope and $b moves on.
        $give = [string]$b.R
        $btn.Add_Click({ $answer.V = $give; $win.DialogResult = $true }.GetNewClosure())
        $null = $row.Children.Add($btn)
    }
    $null = $root.Children.Add($row)

    $scroll = New-Object Windows.Controls.ScrollViewer
    $scroll.VerticalScrollBarVisibility = 'Auto'
    $scroll.HorizontalScrollBarVisibility = 'Disabled'

    # A DockPanel, not a horizontal StackPanel: that measures its children with
    # infinite width, so nothing wraps and the hard-coded Width it needed cannot
    # resize.
    $body = New-Object Windows.Controls.DockPanel
    $body.LastChildFill = $true

    # A bar rather than a glyph: the emoji this file builds are colour fonts
    # that ignore Foreground, so they cannot follow the theme.
    if ($Icon -ne 'None') {
        $bar = New-Object Windows.Controls.Border
        $bar.Width = 3; $bar.CornerRadius = 2
        $bar.Margin = '0,2,14,2'
        $bar.VerticalAlignment = 'Stretch'
        & $ref $bar 'Background' $(switch ($Icon) {
            'Error'   { 'Bad' }
            'Warning' { 'Warn' }
            default   { 'Accent' }
        })
        [Windows.Controls.DockPanel]::SetDock($bar, 'Left')
        $null = $body.Children.Add($bar)
    }

    $tb = New-Object Windows.Controls.TextBlock
    $tb.Text = $Text
    $tb.TextWrapping = 'Wrap'
    $tb.FontSize = 13
    $tb.LineHeight = 19
    & $ref $tb 'Foreground' 'Text'
    $null = $body.Children.Add($tb)

    # The window is sized to the text, not the text to the window - measured off
    # this element with wrapping off, so the typeface and line height are the
    # real ones.
    $tb.TextWrapping = 'NoWrap'
    $tb.Measure((New-Object Windows.Size ([double]::PositiveInfinity), ([double]::PositiveInfinity)))
    $natural = [double]$tb.DesiredSize.Width
    $tb.TextWrapping = 'Wrap'
    # Margins either side, the bar and its gutter, a reserved scrollbar, and the
    # window frame.
    $chrome = 36 + $(if ($Icon -ne 'None') { 17 } else { 0 }) + 18 + 20
    $cap    = [Math]::Max(460, [Windows.SystemParameters]::WorkArea.Width * 0.9)
    $win.Width = [Math]::Min([Math]::Max(460, $natural + $chrome), $cap)

    $scroll.Content = $body
    $null = $root.Children.Add($scroll)
    $win.Content = $root

    if ($BuildOnly) { return $win }

    # The caption is a DWM attribute and not a brush: without this the title bar
    # is white above a dark dialog.
    try {
        $null = (New-Object Windows.Interop.WindowInteropHelper $win).EnsureHandle()
        Initialize-WDDwmType
        $h = (New-Object Windows.Interop.WindowInteropHelper $win).Handle
        if ($h -ne [IntPtr]::Zero) {
            $mode = [int][bool]$script:WDDialogDark
            $null = [WD.Dwm]::DwmSetWindowAttribute($h, 20, [ref]$mode, 4)
        }
    } catch { }

    # SizeToContent gives the dialog its height on open and would fight the drag
    # afterwards, so it is dropped once the content has rendered.
    $win.Add_ContentRendered({ $this.SizeToContent = 'Manual' })

    $null = $win.ShowDialog()
    [string]$answer.V
}

$script:WDDialogDark = $false

$script:WDDwmReady = $false

function Initialize-WDDwmType {
    # P/Invoke for the two DWM calls the window needs. Compiled once.
    if ($script:WDDwmReady) { return }
    # No -UsingNamespace: Add-Type -MemberDefinition already emits "using
    # System.Runtime.InteropServices;", the duplicate is a warning treated as an
    # error, and the surrounding try swallows it.
    if (-not ('WD.Dwm' -as [type])) {
        Add-Type -Namespace 'WD' -Name 'Dwm' -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)]
public struct MARGINS { public int Left; public int Right; public int Top; public int Bottom; }

[DllImport("dwmapi.dll", PreserveSig = true)]
public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);

[DllImport("dwmapi.dll", PreserveSig = true)]
public static extern int DwmExtendFrameIntoClientArea(IntPtr hwnd, ref MARGINS margins);
'@
    }
    $script:WDDwmReady = $true
}

function Set-WDWindowBackdrop {
    # Mica behind the window, and a title bar that matches the palette. The two
    # fail separately, so this reports which arrived.
    param(
        [Parameter(Mandatory)]$Window,
        [Parameter(Mandatory)][bool]$Dark
    )

    try {
        Initialize-WDDwmType
        $h = (New-Object Windows.Interop.WindowInteropHelper $Window).Handle
        if ($h -eq [IntPtr]::Zero) { return $false }

        $mode = [int]$Dark
        $null = [WD.Dwm]::DwmSetWindowAttribute($h, 20, [ref]$mode, 4)

        if ([Environment]::OSVersion.Version.Build -lt 22621) { return $false }

        # -1 on every side is the documented "sheet of glass" form: the frame
        # covers the client area entirely.
        $m = New-Object WD.Dwm+MARGINS
        $m.Left = -1; $m.Right = -1; $m.Top = -1; $m.Bottom = -1
        if ([WD.Dwm]::DwmExtendFrameIntoClientArea($h, [ref]$m) -ne 0) { return $false }

        $backdrop = 2      # DWMSBT_MAINWINDOW - Mica
        if ([WD.Dwm]::DwmSetWindowAttribute($h, 38, [ref]$backdrop, 4) -ne 0) { return $false }

        # Without this WPF paints its own opaque background over the material.
        $src = [Windows.Interop.HwndSource]::FromHwnd($h)
        if (-not $src) { return $false }
        $src.CompositionTarget.BackgroundColor = [Windows.Media.Colors]::Transparent
        return $true
    } catch {
        Write-WDLog "Window backdrop not applied: $($_.Exception.Message)" -Level Debug
        return $false
    }
}

# GridLength has no static Parse in .NET Framework's WPF; it must be built with
# an explicit GridUnitType.
function New-WDGridLength {
    param([double]$Value, [ValidateSet('Pixel','Star','Auto')][string]$Unit = 'Pixel')
    New-Object System.Windows.GridLength -ArgumentList $Value, ([System.Windows.GridUnitType]::$Unit)
}

# Emoji are built from code points so this file stays pure ASCII - tooling would
# otherwise mangle literal multi-byte glyphs.
function New-WDGlyph { param([int]$CodePoint) [char]::ConvertFromUtf32($CodePoint) }

$script:CategoryGlyphs = @{
    'ai'                   = 0x1F916   # robot
    'onedrive'             = 0x2601    # cloud
    'security'             = 0x1F6E1   # shield
    'consumer'             = 0x1F4AC   # speech balloon
    'games'                = 0x1F3AE   # game controller
    'ads'                  = 0x1F4F0   # newspaper
    'privacy'              = 0x1F441   # eye
    'app-privacy'          = 0x1F510   # locked with key
    'inbox'                = 0x1F4E6   # package
    'oem'                  = 0x1F3ED   # factory
    'services'             = 0x2699    # gear
    'qol'                  = 0x2728    # sparkles
    'personalize'          = 0x1F3A8   # artist palette
    'performance'          = 0x1F680   # rocket
    'network'              = 0x1F310   # globe with meridians
    'update'               = 0x1F504   # arrows in a circle
    'persistence'          = 0x1F501   # repeat
    'finish'               = 0x2705    # check mark
    'extras'               = 0x1F9E9   # puzzle piece
    'discovered-vendor'    = 0x1F50D   # magnifier
    'discovered-apps'      = 0x1F5A5   # desktop computer
    'discovered-services'  = 0x1F527   # wrench
    'discovered-extensions' = 0x1F9E9  # puzzle piece
    'run-extras'           = 0x1F4CB   # clipboard
    'runopts'              = 0x1F39B   # control knobs
    'protected'            = 0x1F512   # lock
    'storage'              = 0x1F4BE   # floppy disk
    'install-dev'          = 0x1F6E0   # hammer and wrench
    'install-apps'         = 0x1F5F3   # ballot box
    'install-features'     = 0x1F9F1   # brick
    'section-remove'       = 0x1F5D1   # wastebasket
    'section-add'          = 0x2795    # heavy plus
}
function Get-WDChildScrollBar {
    # The ScrollBar of one orientation inside a control, by walking the visual
    # tree - a template part is not reliably named across themes.
    param($Element, [string]$Orientation = 'Vertical')
    if ($null -eq $Element) { return $null }
    if ($Element -is [Windows.Controls.Primitives.ScrollBar] -and
        [string]$Element.Orientation -eq $Orientation) { return $Element }
    $n = [Windows.Media.VisualTreeHelper]::GetChildrenCount($Element)
    for ($i = 0; $i -lt $n; $i++) {
        $hit = Get-WDChildScrollBar ([Windows.Media.VisualTreeHelper]::GetChild($Element, $i)) $Orientation
        if ($hit) { return $hit }
    }
    $null
}

function Get-WDChildScrollViewer {
    # ListBox exposes no ScrollViewer, and its template part is not reliably
    # named, so the visual tree is walked. Returns null until the page has been
    # laid out once.
    param($Element)
    if ($null -eq $Element) { return $null }
    if ($Element -is [Windows.Controls.ScrollViewer]) { return $Element }
    $n = [Windows.Media.VisualTreeHelper]::GetChildrenCount($Element)
    for ($i = 0; $i -lt $n; $i++) {
        $hit = Get-WDChildScrollViewer ([Windows.Media.VisualTreeHelper]::GetChild($Element, $i))
        if ($hit) { return $hit }
    }
    $null
}

function Get-WDCategoryGlyph {
    param([string]$Id)
    $cp = $script:CategoryGlyphs[$Id]
    if (-not $cp) { $cp = 0x1F4C1 }   # folder
    New-WDGlyph $cp
}

$script:IconSourceCache = @{}

function Get-WDIconSource {
    # Turns an icon path into something WPF can render. Null on any failure.
    param([string]$Path)
    if (-not $Path) { return $null }
    if ($script:IconSourceCache.ContainsKey($Path)) { return $script:IconSourceCache[$Path] }

    $src = $null
    try {
        if ($Path -match '\.(png|jpg|jpeg|bmp|gif)$') {
            $bi = New-Object Windows.Media.Imaging.BitmapImage
            $bi.BeginInit()
            $bi.UriSource        = New-Object Uri($Path)
            $bi.DecodePixelWidth = 22
            $bi.CacheOption      = [Windows.Media.Imaging.BitmapCacheOption]::OnLoad
            $bi.EndInit(); $bi.Freeze()
            $src = $bi
        } else {
            $ico = [System.Drawing.Icon]::ExtractAssociatedIcon($Path)
            if ($ico) {
                $src = [System.Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon(
                          $ico.Handle, [Windows.Int32Rect]::Empty,
                          [Windows.Media.Imaging.BitmapSizeOptions]::FromWidthAndHeight(22, 22))
                $src.Freeze()
                $ico.Dispose()
            }
        }
    } catch { $src = $null }

    $script:IconSourceCache[$Path] = $src
    $src
}

# The application's own icon: the Windows mark made of four things people run
# this toolkit to get rid of, with the antivirus trial being smashed.
# Assets\ holds the only binaries in this repo, and the exception is deliberate:
# four real product logos cannot be reconstructed from a description.

$script:WDIconRoot   = $null
$script:WDLogoCache  = @{}
$script:WDLogoWarned = $false

# What each tile reduces to when there is no room to draw it, and what the whole
# thing falls back to if the assets are missing.
$script:WDIconTiles = @(
    @{ Key = 'edge';     Flat = '#FF2E9AD8' },
    @{ Key = 'mcafee';   Flat = '#FFC8102E' },
    @{ Key = 'onedrive'; Flat = '#FF1D7BF5' },
    @{ Key = 'copilot';  Flat = '#FF9A4FE0' }
)

# Unit coordinates over the pane, and a direction to be thrown in. At spread 0
# they tile the pane exactly, which is what keeps them looking like one broken
# thing.
$script:WDIconPieces = @(
    @{ P = @(@(0.00, 0.00), @(0.45, 0.00), @(0.38, 0.30), @(0.00, 0.38)); D = @(-0.30, -0.34) },
    @{ P = @(@(0.45, 0.00), @(1.00, 0.00), @(0.72, 0.22), @(0.38, 0.30)); D = @(-0.04, -0.48) },
    @{ P = @(@(1.00, 0.00), @(1.00, 0.34), @(0.72, 0.22));                D = @( 0.34, -0.42) },
    @{ P = @(@(0.00, 0.38), @(0.38, 0.30), @(0.30, 0.62), @(0.00, 0.72)); D = @(-0.42, -0.08) },
    @{ P = @(@(0.38, 0.30), @(0.72, 0.22), @(0.66, 0.58), @(0.30, 0.62)); D = @( 0.05, -0.14) },
    @{ P = @(@(0.72, 0.22), @(1.00, 0.34), @(1.00, 0.70), @(0.66, 0.58)); D = @( 0.40, -0.05) },
    @{ P = @(@(0.00, 0.72), @(0.30, 0.62), @(0.40, 1.00), @(0.00, 1.00)); D = @(-0.26,  0.20) },
    @{ P = @(@(0.30, 0.62), @(0.66, 0.58), @(1.00, 0.70), @(1.00, 1.00), @(0.40, 1.00)); D = @( 0.18, 0.24) }
)

function Get-WDIconAssetRoot {
    # Assets\ beside Modules\, resolved once.
    if ($script:WDIconRoot) { return $script:WDIconRoot }
    $script:WDIconRoot = Join-Path (Split-Path -Parent $PSScriptRoot) 'Assets'
    $script:WDIconRoot
}

function Get-WDIconLogo {
    # One product mark, frozen and cached. Null when the file is not there,
    # which the caller answers by drawing the flat tile.
    param([string]$Key)
    if ($script:WDLogoCache.ContainsKey($Key)) { return $script:WDLogoCache[$Key] }
    $img = $null
    try {
        $path = Join-Path (Get-WDIconAssetRoot) "$Key.png"
        if (Test-Path -LiteralPath $path) {
            $bi = New-Object Windows.Media.Imaging.BitmapImage
            $bi.BeginInit()
            $bi.UriSource = New-Object Uri $path
            $bi.CacheOption = [Windows.Media.Imaging.BitmapCacheOption]::OnLoad
            $bi.EndInit()
            $bi.Freeze()
            $img = $bi
        }
    } catch { $img = $null }
    if (-not $img -and -not $script:WDLogoWarned) {
        $script:WDLogoWarned = $true
        Write-WDLog "Icon assets missing or unreadable under $(Get-WDIconAssetRoot); drawing the plain mark instead." -Level Warn
    }
    $script:WDLogoCache[$Key] = $img
    $img
}

$script:WDIconEdge = 0.62   # hairline, in the 64-unit authoring space

function Add-WDIconLogo {
    # One mark, fitted into a pane, on a hairline light edge. The silhouette
    # comes from pushing the bitmap as an opacity mask over white, eight times
    # around a small circle - scaling grows an outline from the centre and
    # leaves interior holes untouched.
    param($Ctx, $Rect, [string]$Key, [double]$Inset, [double]$Edge = -1.0)
    $bm = Get-WDIconLogo $Key
    if (-not $bm) { return $false }
    if ($Edge -lt 0) { $Edge = $script:WDIconEdge }
    $box = $Rect.W * (1.0 - 2 * $Inset)
    $ar = [double]$bm.PixelWidth / [double]$bm.PixelHeight
    $dw = $box; $dh = $box
    if ($ar -ge 1.0) { $dh = $box / $ar } else { $dw = $box * $ar }
    $rect = New-Object Windows.Rect `
        ($Rect.X + ($Rect.W - $dw) / 2), ($Rect.Y + ($Rect.W - $dh) / 2), $dw, $dh

    if ($Edge -gt 0) {
        $mask = New-Object Windows.Media.ImageBrush $bm
        $mask.Stretch = 'Fill'
        $mask.Freeze()
        $white = New-Object Windows.Media.SolidColorBrush ([Windows.Media.Colors]::White)
        $white.Freeze()
        for ($k = 0; $k -lt 8; $k++) {
            $a = $k * [Math]::PI / 4.0
            $Ctx.PushTransform((New-Object Windows.Media.TranslateTransform `
                ([Math]::Cos($a) * $Edge), ([Math]::Sin($a) * $Edge)))
            $Ctx.PushOpacityMask($mask)
            $Ctx.DrawRectangle($white, $null, $rect)
            $Ctx.Pop(); $Ctx.Pop()
        }
    }
    $Ctx.DrawImage($bm, $rect)
    $true
}

function New-WDIconPaneRects {
    # The four panes, on the Windows mark's proportions.
    param([double]$X, [double]$Y, [double]$W, [double]$GapFraction = 0.072)
    $gap = $W * $GapFraction
    $s = ($W - $gap) / 2.0
    $x2 = $X + $s + $gap; $y2 = $Y + $s + $gap
    @( @{ X = $X;  Y = $Y;  W = $s }, @{ X = $x2; Y = $Y;  W = $s },
       @{ X = $X;  Y = $y2; W = $s }, @{ X = $x2; Y = $y2; W = $s } )
}

function New-WDIconDrawing {
    # The icon, as a frozen Drawing fitted to a 64x64 tile.
    param([string]$Cut = 'full', [string]$Theme = '')

    $dark = $true
    if ($Theme -eq 'light')     { $dark = $false }
    elseif ($Theme -ne 'dark')  { $dark = [bool](Get-WDPalette).Dark }

    $mk = { param([string]$hex)
            $br = (New-Object Windows.Media.BrushConverter).ConvertFromString($hex)
            $br.Freeze(); $br }
    # The Windows logo's own blue, in both themes: a mark that is the Windows
    # logo should be its colour, and a solid blue holds against a dark taskbar
    # and a light one alike.
    $tileA = '#FF3D9EE8'; $tileB = '#FF0E68BC'
    # Only the keyline follows the theme, and it is the one thing that has to:
    # it separates the mark from whatever is behind it.
    $inkHex = '#FF0A3F6E'
    if (-not $dark) { $inkHex = '#FF1B527F' }

    $face = New-Object Windows.Media.LinearGradientBrush
    $face.StartPoint = New-Object Windows.Point 0.0, 0.0
    $face.EndPoint   = New-Object Windows.Point 1.0, 1.0
    $face.GradientStops.Add((New-Object Windows.Media.GradientStop ((& $mk $tileA).Color), 0.0))
    $face.GradientStops.Add((New-Object Windows.Media.GradientStop ((& $mk $tileB).Color), 1.0))
    $face.Freeze()

    $lite = ($Cut -eq 'lite')
    $pen = New-Object Windows.Media.Pen ((& $mk $inkHex), $(if ($lite) { 1.8 } else { 1.2 }))
    $pen.LineJoin = 'Round'
    $pen.Freeze()

    # The mark is sized to the tile and everything else may go off the edge.
    # Fitted by its own bounding box, the shards and handle nearly double it and
    # the four panes came out half size.
    $inset  = 0.02
    $spread = 0.45          # thrown clear, but mostly still in frame
    $radF   = 0.045
    $margin = 2.0
    $rects  = New-WDIconPaneRects $margin $margin (64.0 - 2 * $margin)

    $inner = New-Object Windows.Media.DrawingGroup
    $dc = $inner.Open()

    for ($i = 0; $i -lt 4; $i++) {
        if ($i -eq 1) { continue }        # the broken one, drawn below
        $r = $rects[$i]
        $clip = New-Object Windows.Media.RectangleGeometry `
                    (New-Object Windows.Rect $r.X, $r.Y, $r.W, $r.W), ($r.W * $radF), ($r.W * $radF)
        $clip.Freeze()
        $dc.DrawGeometry($face, $pen, $clip)
        # The logo goes on at both cuts. The small one used to draw a flat
        # swatch per tile, which is what "four coloured squares" in the taskbar
        # was.
        $dc.PushClip($clip)
        if (-not (Add-WDIconLogo $dc $r ([string]$script:WDIconTiles[$i].Key) $inset)) {
            $dc.DrawGeometry((& $mk ([string]$script:WDIconTiles[$i].Flat)), $null, $clip)
        }
        $dc.Pop()
    }

    # Fewer, bigger pieces on the small cut - eight fragments of a 7px tile is
    # eight single pixels.
    $br = $rects[1]
    $pieces = $script:WDIconPieces
    if ($lite) { $pieces = @($script:WDIconPieces[1], $script:WDIconPieces[3], $script:WDIconPieces[7]) }
    foreach ($pc in $pieces) {
        $dx = $pc.D[0] * $br.W * $spread; $dy = $pc.D[1] * $br.W * $spread
        $g = New-Object Windows.Media.StreamGeometry
        $c = $g.Open()
        $first = $true
        foreach ($p in $pc.P) {
            $pt = [Windows.Point]::new(($br.X + $p[0] * $br.W + $dx), ($br.Y + $p[1] * $br.W + $dy))
            if ($first) { $c.BeginFigure($pt, $true, $true); $first = $false }
            else { $c.LineTo($pt, $true, $false) }
        }
        $c.Close(); $g.Freeze()
        $dc.DrawGeometry($face, $pen, $g)
        $dc.PushClip($g)
        $dc.PushTransform((New-Object Windows.Media.TranslateTransform $dx, $dy))
        if (-not (Add-WDIconLogo $dc $br 'mcafee' $inset)) {
            $dc.DrawGeometry((& $mk ([string]$script:WDIconTiles[1].Flat)), $null, $g)
        }
        $dc.Pop(); $dc.Pop()
    }

    if (-not $lite) {
        # Inboard of the corner, so the head lands wholly on the tile and only
        # the handle is cut.
        $hx = $br.X + $br.W * 0.74; $hy = $br.Y + $br.W * 0.30
        $flash = New-Object Windows.Media.Pen ((& $mk '#FFFFD46B'), 2.3)
        $flash.StartLineCap = 'Round'; $flash.EndLineCap = 'Round'; $flash.Freeze()
        foreach ($a in @(-140.0, -104.0, -68.0, -30.0, 8.0, 150.0, 186.0)) {
            $rad = $a * [Math]::PI / 180.0
            $l = New-Object Windows.Media.LineGeometry `
                     ([Windows.Point]::new(($hx + [Math]::Cos($rad) * 5.3), ($hy + [Math]::Sin($rad) * 5.3))),
                     ([Windows.Point]::new(($hx + [Math]::Cos($rad) * 11.0), ($hy + [Math]::Sin($rad) * 11.0)))
            $l.Freeze()
            $dc.DrawGeometry($null, $flash, $l)
        }

        $hp = New-Object Windows.Media.Pen ((& $mk '#FF11365F'), 1.8)
        $hp.LineJoin = 'Round'; $hp.Freeze()
        $wood = New-Object Windows.Media.LinearGradientBrush
        $wood.StartPoint = New-Object Windows.Point 0.0, 0.0
        $wood.EndPoint   = New-Object Windows.Point 1.0, 1.0
        $wood.GradientStops.Add((New-Object Windows.Media.GradientStop ((& $mk '#FFE4B06B').Color), 0.0))
        $wood.GradientStops.Add((New-Object Windows.Media.GradientStop ((& $mk '#FF9B5F26').Color), 1.0))
        $wood.Freeze()
        $steel = New-Object Windows.Media.LinearGradientBrush
        $steel.StartPoint = New-Object Windows.Point 0.0, 0.0
        $steel.EndPoint   = New-Object Windows.Point 1.0, 1.0
        $steel.GradientStops.Add((New-Object Windows.Media.GradientStop ((& $mk '#FFF0F5FA').Color), 0.0))
        $steel.GradientStops.Add((New-Object Windows.Media.GradientStop ((& $mk '#FF93A3B5').Color), 1.0))
        $steel.Freeze()
        $faceBr = New-Object Windows.Media.LinearGradientBrush
        $faceBr.StartPoint = New-Object Windows.Point 0.0, 0.0
        $faceBr.EndPoint   = New-Object Windows.Point 1.0, 1.0
        $faceBr.GradientStops.Add((New-Object Windows.Media.GradientStop ((& $mk '#FFFFFFFF').Color), 0.0))
        $faceBr.GradientStops.Add((New-Object Windows.Media.GradientStop ((& $mk '#FFC6D2DE').Color), 1.0))
        $faceBr.Freeze()

        $rr = { param([double]$x, [double]$y, [double]$w, [double]$h, [double]$r)
                $g = New-Object Windows.Media.RectangleGeometry (New-Object Windows.Rect $x, $y, $w, $h), $r, $r
                $g.Freeze(); $g }

        $dc.PushTransform((New-Object Windows.Media.TranslateTransform $hx, $hy))
        $dc.PushTransform((New-Object Windows.Media.RotateTransform 146.0))
        $dc.DrawGeometry($wood, $hp, (& $rr -2.2 5.0 4.4 36.0 2.0))
        $grip = New-Object Windows.Media.Pen ((& $mk '#59000000'), 1.1)
        $grip.StartLineCap = 'Round'; $grip.EndLineCap = 'Round'; $grip.Freeze()
        foreach ($f in @(0.66, 0.76, 0.86)) {
            $yy = 5.0 + 36.0 * $f
            $l = New-Object Windows.Media.LineGeometry ([Windows.Point]::new(-1.8, $yy)), ([Windows.Point]::new(1.8, $yy))
            $l.Freeze()
            $dc.DrawGeometry($null, $grip, $l)
        }
        $dc.DrawGeometry($steel,  $hp, (& $rr -13.6 -6.0 22.0 12.0 1.6))
        $dc.DrawGeometry($faceBr, $hp, (& $rr -13.6 -6.0 6.2 12.0 1.6))
        $dc.DrawGeometry((& $mk '#59FFFFFF'), $null, (& $rr -12.4 -4.9 19.6 2.6 1.0))
        $dc.Pop(); $dc.Pop()
    }

    $dc.Close()
    $inner.Freeze()

    # Clipped to the tile rather than fitted into it: the render target is
    # already 64 square, and the explicit clip is what keeps the fit from
    # shrinking the panes.
    $clipAll = New-Object Windows.Media.RectangleGeometry (New-Object Windows.Rect 0, 0, 64, 64)
    $clipAll.Freeze()
    $outer = New-Object Windows.Media.DrawingGroup
    $outer.Children.Add($inner)
    $outer.ClipGeometry = $clipAll
    $outer.Freeze()
    $outer
}

function New-WDIconRender {
    # One frame, rendered to a bitmap.
    param($Drawing, [int]$Size)
    $vis = New-Object Windows.Media.DrawingVisual
    # HighQuality on the visual, or the logo bitmaps are point-sampled on the
    # way down and the small frames come out speckled.
    [Windows.Media.RenderOptions]::SetBitmapScalingMode($vis, [Windows.Media.BitmapScalingMode]::HighQuality)
    $dc = $vis.RenderOpen()
    $dc.PushTransform((New-Object Windows.Media.ScaleTransform ($Size / 64), ($Size / 64)))
    $dc.DrawDrawing($Drawing)
    $dc.Pop()
    $dc.Close()
    $rtb = New-Object Windows.Media.Imaging.RenderTargetBitmap `
               $Size, $Size, 96, 96, ([Windows.Media.PixelFormats]::Pbgra32)
    $rtb.Render($vis)
    $rtb
}

function New-WDIconPng {
    # One frame, as the bytes of a PNG.
    param($Drawing, [int]$Size)
    $enc = New-Object Windows.Media.Imaging.PngBitmapEncoder
    $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create((New-WDIconRender $Drawing $Size)))
    $ms = New-Object System.IO.MemoryStream
    $enc.Save($ms)
    $ms.ToArray()
}

function New-WDIconDib {
    # One frame as a 32-bit DIB - the format an .ico entry has carried since
    # 1985, and the reason the taskbar button was blank. Modern decoders read
    # PNG at any size; the shell's classic path does not.
    param($Drawing, [int]$Size)
    $rtb = New-WDIconRender $Drawing $Size
    $conv = New-Object Windows.Media.Imaging.FormatConvertedBitmap `
                $rtb, ([Windows.Media.PixelFormats]::Bgra32), $null, 0.0
    $stride = $Size * 4
    $px = New-Object 'byte[]' ($stride * $Size)
    $conv.CopyPixels($px, $stride, 0)

    $maskStride = [int]([Math]::Floor((($Size + 31) / 32)) * 4)
    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter $ms
    $bw.Write([uint32]40)              # biSize
    $bw.Write([int32]$Size)            # biWidth
    $bw.Write([int32]($Size * 2))      # biHeight - XOR plus AND
    $bw.Write([uint16]1)               # biPlanes
    $bw.Write([uint16]32)              # biBitCount
    $bw.Write([uint32]0)               # BI_RGB
    $bw.Write([uint32]($stride * $Size + $maskStride * $Size))
    $bw.Write([int32]0); $bw.Write([int32]0)   # pixels per metre
    $bw.Write([uint32]0); $bw.Write([uint32]0) # palette
    # Bottom-up, which is what a DIB means by row order.
    for ($y = $Size - 1; $y -ge 0; $y--) { $bw.Write($px, $y * $stride, $stride) }
    $bw.Write((New-Object 'byte[]' ($maskStride * $Size)))
    $bw.Flush()
    $ms.ToArray()
}

function New-WDIconBytes {
    # A complete .ico in memory: DIB frames up to 128, PNG at 256.
    param([string]$Theme = '')
    $sizes = @(16, 20, 24, 32, 48, 64, 128, 256)
    $full = New-WDIconDrawing 'full' $Theme
    $lite = New-WDIconDrawing 'lite' $Theme

    $pngs = New-Object System.Collections.Generic.List[byte[]]
    foreach ($sz in $sizes) {
        # 24px is where the taskbar usually draws, so it gets the real logos.
        # The cut used to be at 32 and the button was four coloured squares.
        $art = $full
        if ($sz -lt 24) { $art = $lite }
        if ($sz -ge 256) { $pngs.Add((New-WDIconPng $art $sz)) }
        else             { $pngs.Add((New-WDIconDib $art $sz)) }
    }

    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter $ms
    $bw.Write([uint16]0)               # reserved
    $bw.Write([uint16]1)               # 1 = icon
    $bw.Write([uint16]$sizes.Count)
    $offset = 6 + 16 * $sizes.Count
    for ($i = 0; $i -lt $sizes.Count; $i++) {
        $dim = $sizes[$i]
        if ($dim -ge 256) { $dim = 0 }  # 256 is recorded as zero
        $bw.Write([byte]$dim)           # width
        $bw.Write([byte]$dim)           # height
        $bw.Write([byte]0)              # palette entries
        $bw.Write([byte]0)              # reserved
        $bw.Write([uint16]1)            # colour planes
        $bw.Write([uint16]32)           # bits per pixel
        $bw.Write([uint32]$pngs[$i].Length)
        $bw.Write([uint32]$offset)
        $offset += $pngs[$i].Length
    }
    foreach ($p in $pngs) { $bw.Write($p) }
    $bw.Flush()
    # Leading comma: returned bare, the pipeline unrolls this into forty-three
    # thousand boxed objects and a function called ...Bytes hands back an
    # Object[].
    ,$ms.ToArray()
}

# Cached per theme, not once: the icon follows the palette, so a session that
# switches wants both.
$script:WDAppIcon  = @{}
$script:WDIconData = @{}
$script:WDAumidSet = $false

function Get-WDIconThemeKey {
    # Whatever the caller said, reduced to 'dark' or 'light'. One place, so the
    # two caches and the drawing cannot disagree about what an empty string
    # means.
    param([string]$Theme = '')
    if ($Theme -eq 'light' -or $Theme -eq 'dark') { return $Theme }
    if ([bool](Get-WDPalette).Dark) { return 'dark' }
    'light'
}

function Set-WDTaskbarIdentity {
    # Setting Window.Icon is not enough: a taskbar button is grouped by
    # AppUserModelID, and a process that sets none is given one derived from its
    # executable - so the shell draws the PowerShell shortcut's icon and never
    # consults Window.Icon.
    param([string]$Id = (Get-WDAppUserModelId))
    if ($script:WDAumidSet) { return }
    $script:WDAumidSet = $true
    try {
        # [WD.Native] rather than a type of its own: this is the last thing
        # before the splash goes up, and a csc invocation here is 400 ms of
        # blank screen.
        if (-not (Use-WDNative)) {
            Write-WDLog 'Could not build the taskbar identity helper; the taskbar will show the host icon.' -Level Warn
            return
        }
        [WD.Native]::SetCurrentProcessExplicitAppUserModelID($Id)
    } catch {
        Write-WDLog "Could not set the taskbar identity: $($_.Exception.Message)" -Level Warn
    }
}

function Get-WDAppIconBytes {
    # The .ico as bytes, built once. Bytes rather than a frame, because a
    # decoded frame cannot cross a thread.
    param([string]$Theme = '')
    $key = Get-WDIconThemeKey $Theme
    if (-not $script:WDIconData.ContainsKey($key)) {
        try { $script:WDIconData[$key] = [byte[]](New-WDIconBytes -Theme $key) }
        catch {
            Write-WDLog "Could not build the application icon: $($_.Exception.Message)" -Level Warn
            $script:WDIconData[$key] = [byte[]]@()
        }
    }
    if ($script:WDIconData[$key].Length) { ,$script:WDIconData[$key] } else { $null }
}

function Get-WDAppIcon {
    # The window icon for this thread, or null if anything went wrong - an icon
    # is never worth failing a launch over.
    param([string]$Theme = '')
    $key = Get-WDIconThemeKey $Theme
    if ($script:WDAppIcon.ContainsKey($key)) { return $script:WDAppIcon[$key] }
    $bytes = Get-WDAppIconBytes -Theme $key
    if (-not $bytes) { return $null }
    try {
        $ms = New-Object System.IO.MemoryStream (,$bytes)
        $dec = New-Object Windows.Media.Imaging.IconBitmapDecoder `
                   $ms, ([Windows.Media.Imaging.BitmapCreateOptions]::None),
                   ([Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
        # Hand back a middling frame rather than the first: WPF picks the
        # best-matching frame off this one's Decoder when it can.
        $pick = $dec.Frames[0]
        foreach ($f in $dec.Frames) { if ($f.PixelWidth -eq 32) { $pick = $f } }
        if ($pick.CanFreeze) { $pick.Freeze() }
        $script:WDAppIcon[$key] = $pick
    } catch {
        Write-WDLog "Could not build the application icon: $($_.Exception.Message)" -Level Warn
        $script:WDAppIcon[$key] = $null
    }
    $script:WDAppIcon[$key]
}

# How wide a vertical scrollbar is here: 16px of hit area carrying a 5.5px mark.
# Named because the Compare header reserves the same gutter, and asking
# SystemParameters gives the system's 17.33 rather than the one this window
# uses.
$script:WDVBarWidth = 16

$script:Xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Windows Setup Toolkit" Height="860" Width="1320"
        WindowStartupLocation="CenterScreen" MinWidth="1060" MinHeight="680"
        FontFamily="Segoe UI" FontSize="13">
  <!-- One scrollbar for the whole application, defined once and applied twice:
       keyed as WdSlimBar for the places that ask by name, and implicitly for
       everything else. This used to be keyed only, on the reasoning that an
       unkeyed Style TargetType="ScrollBar" reaches every bar in the window
       including the ones somebody has to be able to grab. That was the right
       objection to the old 4.25px hairline and it does not apply to this: the
       vertical bar is 16px of hit area carrying a 5.5px mark, so it is a
       control you can take hold of even when the pointer is thrown at the
       screen edge. The self test asserts both halves - hairline on the
       pickers, grabbable and flush on the lists.

       Both orientations in one template, switched by a trigger, because an
       implicit style replaces the theme style outright: a vertical-shaped
       template silently applied to a horizontal bar is a broken control
       nothing warns about. Retemplated to the thumb alone, since the default
       arrow buttons keep a fixed size and a narrowed bar squashes them into
       glyphs rather than losing them. The page buttons stay at Opacity 0
       rather than Collapsed - invisible, still hit-testable, so clicking the
       track still pages. -->
  <Window.Resources>
    <!-- One template per orientation rather than one with an Orientation
         trigger inside it. The single-template version needs the two page
         RepeatButtons to swap PageDown/PageUp for PageRight/PageLeft, and
         Setter.Value is typed object with no target-type hint, so the command
         name arrives as a string that nothing converts and the whole style
         throws at parse time. As attributes on the RepeatButton itself - which
         is what these are - the RoutedCommand converter runs and it just works.
         The Style below picks the template by orientation. -->
    <!-- The hover colour is set on the THUMB, not on the Border inside its
         template, and that is not a style choice. A Thumb.Template is its own
         namescope, so TargetName in the ScrollBar template's triggers cannot
         see a Border declared in there - the Setter resolves to nothing and
         throws at parse time, taking the whole style with it. Naming the Thumb
         instead puts the target back in the outer namescope, and the Border
         follows it by binding to its own TemplatedParent. -->
    <!-- THE FAINT BLACK DOTTED RECTANGLES, and nothing in this file was drawing
         them. They are WPF's default focus adornment, which is literally
         `<Rectangle Stroke="{DynamicResource SystemColors.ControlTextBrushKey}"
         StrokeThickness="1" StrokeDashArray="1 2"/>` - read out of the running
         framework rather than guessed at. Two things are wrong with it here.
         It is stroked in a SYSTEM colour, so it is black whatever this
         application's palette is doing, which is the same class of defect as
         the black text this file warns about twice. And it is drawn on TOP of
         whatever a retemplated control already does about focus, so a focused
         button showed an accent edge with a dotted rectangle over it.

         So it is replaced rather than removed - keyboard focus has to be
         visible or the window cannot be used without a mouse. One accent
         hairline, in the palette, with rounded corners so it reads as part of
         the design rather than as a rendering fault. Margin -2 puts it just
         outside the control instead of over its own border.

         A Style with no TargetType and a qualified `Control.Template` setter is
         the shape a FocusVisualStyle takes; WPF's own is written the same way.
         It goes on the controls that have no other cue - a CheckBox and a log
         row - while everything retemplated below gets {x:Null}, because those
         already light their own edge and two indications is one too many. -->
    <Style x:Key="WdFocus">
      <Setter Property="Control.Template">
        <Setter.Value>
          <ControlTemplate>
            <Rectangle Margin="-2" StrokeThickness="1" RadiusX="3" RadiusY="3"
                       Stroke="{DynamicResource WdAccent}" SnapsToDevicePixels="True"/>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="CheckBox">
      <Setter Property="FocusVisualStyle" Value="{StaticResource WdFocus}"/>
    </Style>
    <Style TargetType="ListBoxItem">
      <Setter Property="FocusVisualStyle" Value="{StaticResource WdFocus}"/>
    </Style>
    <!-- A container, and never a thing to indicate focus on. It is focusable so
         that the keyboard can scroll it, which is why this is the focus VISUAL
         and not Focusable - and the big dotted rectangle in the middle of the
         mode screen was this one, drawn round the whole of its content. -->
    <Style TargetType="ScrollViewer">
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
    </Style>
    <Style TargetType="ListBox">
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
    </Style>

    <ControlTemplate x:Key="WdVBarTemplate" TargetType="ScrollBar">
      <Grid Background="Transparent">
        <Track Name="PART_Track" IsDirectionReversed="True">
          <Track.Thumb>
            <Thumb Name="WdThumb" Background="{DynamicResource WdScrollThumb}">
              <Thumb.Template>
                <ControlTemplate TargetType="Thumb">
                  <!-- THE TRANSPARENT GRID IS THE DRAGGABLE PART, and leaving it
                       out is why widening the bar did not help. A Thumb with no
                       Background of its own is not hit-testable: only the mark
                       inside it was, so the outer 3px of a 16px bar fell through
                       to the track behind and PAGED instead of grabbing. Measured
                       - on the thumb's own row, x=W-1 and W-2 landed on the
                       bar's Grid and W-3 through W-6 on the thumb, which is
                       exactly "I shoved the pointer at the edge and could not
                       drag it".
                       The Grid fills the Thumb, so the whole 16px width of the
                       thumb's band drags. The mark stays 5.5px and stays inset,
                       because how wide it LOOKS and how wide it can be grabbed
                       by are two different questions. -->
                  <Grid Background="Transparent">
                    <Border CornerRadius="3" Width="5.5" Margin="0,0,3,0"
                            HorizontalAlignment="Right"
                            Background="{Binding Background, RelativeSource={RelativeSource TemplatedParent}}"/>
                  </Grid>
                </ControlTemplate>
              </Thumb.Template>
            </Thumb>
          </Track.Thumb>
          <Track.IncreaseRepeatButton>
            <RepeatButton Command="ScrollBar.PageDownCommand" Opacity="0" Focusable="False"/>
          </Track.IncreaseRepeatButton>
          <Track.DecreaseRepeatButton>
            <RepeatButton Command="ScrollBar.PageUpCommand" Opacity="0" Focusable="False"/>
          </Track.DecreaseRepeatButton>
        </Track>
      </Grid>
      <!-- The bar answers the pointer, which is the only thing that says it is
           a control rather than a mark on the page. Keyed off the whole bar
           rather than the thumb: a highlight you get only once the pointer is
           already on the thumb is one nobody sees before they have found the
           thing anyway. -->
      <ControlTemplate.Triggers>
        <Trigger Property="IsMouseOver" Value="True">
          <Setter TargetName="WdThumb" Property="Background"
                  Value="{DynamicResource WdScrollThumbHover}"/>
        </Trigger>
      </ControlTemplate.Triggers>
    </ControlTemplate>
    <ControlTemplate x:Key="WdHBarTemplate" TargetType="ScrollBar">
      <Grid Background="Transparent">
        <Track Name="PART_Track" Orientation="Horizontal">
          <Track.Thumb>
            <Thumb Name="WdThumb" Background="{DynamicResource WdScrollThumb}">
              <Thumb.Template>
                <ControlTemplate TargetType="Thumb">
                  <!-- Transparent Grid for the same reason as the vertical bar's:
                       the mark is inset, and without a fill behind it the inset
                       is not draggable. Here it is the bottom edge of the window
                       rather than the right. -->
                  <Grid Background="Transparent">
                    <Border CornerRadius="2" Margin="0,1.5"
                            Background="{Binding Background, RelativeSource={RelativeSource TemplatedParent}}"/>
                  </Grid>
                </ControlTemplate>
              </Thumb.Template>
            </Thumb>
          </Track.Thumb>
          <Track.IncreaseRepeatButton>
            <RepeatButton Command="ScrollBar.PageRightCommand" Opacity="0" Focusable="False"/>
          </Track.IncreaseRepeatButton>
          <Track.DecreaseRepeatButton>
            <RepeatButton Command="ScrollBar.PageLeftCommand" Opacity="0" Focusable="False"/>
          </Track.DecreaseRepeatButton>
        </Track>
      </Grid>
      <ControlTemplate.Triggers>
        <Trigger Property="IsMouseOver" Value="True">
          <Setter TargetName="WdThumb" Property="Background"
                  Value="{DynamicResource WdScrollThumbHover}"/>
        </Trigger>
      </ControlTemplate.Triggers>
    </ControlTemplate>
    <!-- Template and thickness both come from a trigger per orientation, and
         both the Min and the plain property have to be set. The default
         ScrollBar theme style sets Height AND MinHeight from its own trigger on
         Orientation=Horizontal; a theme-style trigger outranks a plain style
         setter for anything the style does not also set, and MinHeight beats
         Height in layout - so a bare Height setter landed on the element, read
         back correctly, and the bar still arranged at the system's 17.33. The
         other axis goes to Auto (NaN) so neither orientation keeps a size the
         other one pinned. -->
    <Style x:Key="WdSlimBar" TargetType="ScrollBar">
      <Setter Property="Background" Value="Transparent"/>
      <Style.Triggers>
        <Trigger Property="Orientation" Value="Vertical">
          <Setter Property="Template" Value="{StaticResource WdVBarTemplate}"/>
          <!-- 16, not 11.5. The visible mark is still 5.5 wide - see the thumb
               template - so this is hit area rather than ink: on a maximised
               window somebody shoves the pointer at the right edge and expects
               to have grabbed the bar, and five and a half pixels of target is a
               thing you aim at rather than arrive at. Both Width and MinWidth,
               for the reason written above. -->
          <Setter Property="Width" Value="16"/>
          <Setter Property="MinWidth" Value="16"/>
          <Setter Property="Height" Value="Auto"/>
        </Trigger>
        <Trigger Property="Orientation" Value="Horizontal">
          <Setter Property="Template" Value="{StaticResource WdHBarTemplate}"/>
          <Setter Property="Height" Value="7"/>
          <Setter Property="MinHeight" Value="7"/>
          <Setter Property="Width" Value="Auto"/>
        </Trigger>
      </Style.Triggers>
    </Style>
    <Style TargetType="ScrollBar" BasedOn="{StaticResource WdSlimBar}"/>

    <!-- The index rails want something narrower still - 5px beside a 184px
         column, where 11.5 would read as a second column. Defined once here and
         pulled into each rail's own ScrollViewer.Resources with a one-line
         BasedOn: an implicit style has to live in the ScrollViewer's own
         resources to reach the bar inside its template, but the definition does
         not, and two copies of it is how one of them came to be missing a hover
         state and the other a MinWidth.

         Hover on the bar rather than on the thumb, as above: a highlight you
         only get once the pointer is already on the thumb is one nobody sees
         before they have found the thing anyway - and on a 5px bar, finding it
         is the whole difficulty. -->
    <ControlTemplate x:Key="WdRailBarTemplate" TargetType="ScrollBar">
      <Grid Background="Transparent">
        <Track Name="PART_Track" IsDirectionReversed="True">
          <Track.Thumb>
            <Thumb Name="WdRailThumb" Background="{DynamicResource WdScrollThumb}">
              <Thumb.Template>
                <ControlTemplate TargetType="Thumb">
                  <!-- The rail's mark fills its width, so there is no inset to
                       lose - but the Grid goes in anyway, because the next person
                       to inset this mark should not have to rediscover why it
                       stopped being draggable. -->
                  <Grid Background="Transparent">
                    <Border CornerRadius="2.5"
                            Background="{Binding Background, RelativeSource={RelativeSource TemplatedParent}}"/>
                  </Grid>
                </ControlTemplate>
              </Thumb.Template>
            </Thumb>
          </Track.Thumb>
          <Track.IncreaseRepeatButton>
            <RepeatButton Command="ScrollBar.PageDownCommand" Opacity="0" Focusable="False"/>
          </Track.IncreaseRepeatButton>
          <Track.DecreaseRepeatButton>
            <RepeatButton Command="ScrollBar.PageUpCommand" Opacity="0" Focusable="False"/>
          </Track.DecreaseRepeatButton>
        </Track>
      </Grid>
      <ControlTemplate.Triggers>
        <Trigger Property="IsMouseOver" Value="True">
          <Setter TargetName="WdRailThumb" Property="Background"
                  Value="{DynamicResource WdScrollThumbHover}"/>
        </Trigger>
      </ControlTemplate.Triggers>
    </ControlTemplate>
    <!-- MinWidth as well as Width. The default ScrollBar theme style sets both,
         MinWidth beats Width in layout, so setting only Width leaves the bar
         arranged at the system's 17px while the property reads back 5. -->
    <Style x:Key="WdRailBar" TargetType="ScrollBar">
      <Setter Property="Width" Value="5"/>
      <Setter Property="MinWidth" Value="5"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Template" Value="{StaticResource WdRailBarTemplate}"/>
    </Style>

    <!-- Button, TextBox and ComboBox all keep the system chrome unless they are
         retemplated, and that chrome is light in BOTH palettes - which is why
         this file used to say "never paint a Button's Foreground": the dark
         theme's near-white text on a light gray face is white on white. The fix
         is not to keep painting around them, it is to give them a face the
         palette owns. Everything below is that, and nothing else changes.

         The hover state is an OVERLAY, not a Background setter. A trigger that
         writes Background by TargetName beats the TemplateBinding under it, so
         any button carrying a color of its own - Compare's green "in this mode"
         tick is the one that matters - would have flashed plain gray under the
         pointer. A translucent tint composites over whatever is there. -->
    <!-- The home page's three choices. A Button rather than a Border with a
         click handler, and that is not a detail: a Button is focusable, it
         answers the keyboard, it is what a screen reader announces as something
         to press, and it marks the click handled so nothing underneath it also
         reacts. Everything about it that is not a button is in the template -
         a card face rather than a chip, corners at 10 instead of 4, the content
         left-aligned and stretched so a glyph, a title and a paragraph can be
         stacked inside it.

         The edge goes to the accent under the pointer, on top of the ordinary
         tint. On a control this size the tint alone is a very slight change
         over a very large area, which reads as nothing at all; the edge is what
         says the whole card is the target rather than some word inside it. -->
    <Style x:Key="WdCardButton" TargetType="Button">
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Background" Value="{DynamicResource WdCard}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource WdLine}"/>
      <Setter Property="Foreground" Value="{DynamicResource WdText}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="22,20,22,22"/>
      <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
      <Setter Property="VerticalContentAlignment" Value="Top"/>
      <Setter Property="SnapsToDevicePixels" Value="True"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Grid>
              <Border Name="WdCardFace" CornerRadius="10"
                      Background="{TemplateBinding Background}"
                      BorderBrush="{TemplateBinding BorderBrush}"
                      BorderThickness="{TemplateBinding BorderThickness}"
                      SnapsToDevicePixels="True"/>
              <Border Name="WdCardTint" CornerRadius="10" Opacity="0"
                      Background="{DynamicResource WdBtnTint}"/>
              <ContentPresenter Margin="{TemplateBinding Padding}"
                                HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}"
                                VerticalAlignment="{TemplateBinding VerticalContentAlignment}"
                                TextElement.Foreground="{TemplateBinding Foreground}"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="WdCardTint" Property="Opacity" Value="0.55"/>
                <Setter TargetName="WdCardFace" Property="BorderBrush" Value="{DynamicResource WdAccent}"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="WdCardTint" Property="Opacity" Value="1"/>
              </Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True">
                <Setter TargetName="WdCardFace" Property="BorderBrush" Value="{DynamicResource WdAccent}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="WdButton" TargetType="Button">
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Background" Value="{DynamicResource WdBtnBg}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource WdBtnBorder}"/>
      <Setter Property="Foreground" Value="{DynamicResource WdText}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="10,4"/>
      <Setter Property="SnapsToDevicePixels" Value="True"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Grid>
              <Border Name="WdBtnFace" CornerRadius="4"
                      Background="{TemplateBinding Background}"
                      BorderBrush="{TemplateBinding BorderBrush}"
                      BorderThickness="{TemplateBinding BorderThickness}"
                      SnapsToDevicePixels="True"/>
              <Border Name="WdBtnTint" CornerRadius="4" Opacity="0"
                      Background="{DynamicResource WdBtnTint}"/>
              <ContentPresenter Margin="{TemplateBinding Padding}"
                                HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}"
                                VerticalAlignment="{TemplateBinding VerticalContentAlignment}"
                                RecognizesAccessKey="True"
                                TextElement.Foreground="{TemplateBinding Foreground}"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="WdBtnTint" Property="Opacity" Value="0.55"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="WdBtnTint" Property="Opacity" Value="1"/>
              </Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True">
                <Setter TargetName="WdBtnFace" Property="BorderBrush" Value="{DynamicResource WdAccent}"/>
              </Trigger>
              <!-- Dimmed rather than recoloured. A disabled Button used to gray
                   its own content whatever Foreground said, which is why a
                   button that has to read as finished is left enabled and made
                   inert with IsHitTestVisible instead. That workaround still
                   works; this just stops the graying being the system's idea of
                   gray on a dark page. -->
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.45"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="Button" BasedOn="{StaticResource WdButton}"/>

    <!-- The two Filter buttons are ToggleButtons - the popup follows IsChecked -
         so the Button style above never reached them and they stayed system
         white on a dark page. Keyed and applied by name rather than implicit:
         the ComboBox template's own ToggleButton would pick up an implicit one,
         and its Template is a local value that would then be fighting a style
         it has no business being in. The checked state is the tint held on,
         which is what says the popup below is open. -->
    <!-- NOT BasedOn WdButton. A Style's BasedOn TargetType has to be this
         type or a base of it, and Button is neither - Button and ToggleButton
         are siblings under ButtonBase. It parses, and then throws on the first
         element that uses it, with a message naming FrameworkElement.Style and
         nothing about why. The four setters are repeated instead. -->
    <Style x:Key="WdToggle" TargetType="ToggleButton">
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Background" Value="{DynamicResource WdBtnBg}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource WdBtnBorder}"/>
      <Setter Property="Foreground" Value="{DynamicResource WdText}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="SnapsToDevicePixels" Value="True"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ToggleButton">
            <Grid>
              <Border Name="WdTgFace" CornerRadius="4"
                      Background="{TemplateBinding Background}"
                      BorderBrush="{TemplateBinding BorderBrush}"
                      BorderThickness="{TemplateBinding BorderThickness}"
                      SnapsToDevicePixels="True"/>
              <Border Name="WdTgTint" CornerRadius="4" Opacity="0"
                      Background="{DynamicResource WdBtnTint}"/>
              <ContentPresenter Margin="{TemplateBinding Padding}"
                                HorizontalAlignment="Center" VerticalAlignment="Center"
                                RecognizesAccessKey="True"
                                TextElement.Foreground="{TemplateBinding Foreground}"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="WdTgTint" Property="Opacity" Value="0.55"/>
              </Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="WdTgTint" Property="Opacity" Value="1"/>
                <Setter TargetName="WdTgFace" Property="BorderBrush" Value="{DynamicResource WdAccent}"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.45"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- A PasswordBox is its own control and inherits nothing from TextBox, so
         the three password fields on the setup page stayed white while every
         box beside them followed the theme. Same template, same part name. -->
    <Style x:Key="WdPasswordBox" TargetType="PasswordBox">
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Background" Value="{DynamicResource WdFieldBg}"/>
      <Setter Property="Foreground" Value="{DynamicResource WdText}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource WdBtnBorder}"/>
      <Setter Property="CaretBrush" Value="{DynamicResource WdText}"/>
      <Setter Property="SelectionBrush" Value="{DynamicResource WdAccent}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="SnapsToDevicePixels" Value="True"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="PasswordBox">
            <Border Name="WdPbFace" CornerRadius="4"
                    Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}"
                    SnapsToDevicePixels="True">
              <ScrollViewer Name="PART_ContentHost" Focusable="False"
                            Margin="{TemplateBinding Padding}"
                            HorizontalScrollBarVisibility="Hidden"
                            VerticalScrollBarVisibility="Hidden"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsKeyboardFocusWithin" Value="True">
                <Setter TargetName="WdPbFace" Property="BorderBrush" Value="{DynamicResource WdAccent}"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.5"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="PasswordBox" BasedOn="{StaticResource WdPasswordBox}"/>

    <!-- PART_ContentHost must be the name, or the caret and the text never
         appear. Stretch rather than centred: the unattend page has multi-line
         boxes, and a centred content host collapses those to one line. -->
    <Style x:Key="WdTextBox" TargetType="TextBox">
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Background" Value="{DynamicResource WdFieldBg}"/>
      <Setter Property="Foreground" Value="{DynamicResource WdText}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource WdBtnBorder}"/>
      <Setter Property="CaretBrush" Value="{DynamicResource WdText}"/>
      <Setter Property="SelectionBrush" Value="{DynamicResource WdAccent}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="SnapsToDevicePixels" Value="True"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border Name="WdTbFace" CornerRadius="4"
                    Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}"
                    SnapsToDevicePixels="True">
              <ScrollViewer Name="PART_ContentHost" Focusable="False"
                            Margin="{TemplateBinding Padding}"
                            HorizontalScrollBarVisibility="Hidden"
                            VerticalScrollBarVisibility="Hidden"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsKeyboardFocusWithin" Value="True">
                <Setter TargetName="WdTbFace" Property="BorderBrush" Value="{DynamicResource WdAccent}"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.5"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="TextBox" BasedOn="{StaticResource WdTextBox}"/>

    <!-- The drop-down is the whole reason this one is retemplated. A ComboBox
         renders its closed bar from SelectionBoxItem in the ComboBox's OWN
         foreground, and draws its popup on the system window brush - which is
         white in both themes. So painting the items was the wrong fix and made
         it worse: near-white text on a white popup. The popup has to be a
         surface this file owns before anything on it can be read. -->
    <ControlTemplate x:Key="WdComboToggle" TargetType="ToggleButton">
      <Border Name="WdCbFace" CornerRadius="4"
              Background="{DynamicResource WdFieldBg}"
              BorderBrush="{DynamicResource WdBtnBorder}" BorderThickness="1"
              SnapsToDevicePixels="True">
        <Path HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,1,9,0"
              Data="M 0 0 L 8 0 L 4 4 Z" Fill="{DynamicResource WdSub}"/>
      </Border>
      <ControlTemplate.Triggers>
        <Trigger Property="IsMouseOver" Value="True">
          <Setter TargetName="WdCbFace" Property="BorderBrush" Value="{DynamicResource WdAccent}"/>
        </Trigger>
      </ControlTemplate.Triggers>
    </ControlTemplate>
    <Style x:Key="WdCombo" TargetType="ComboBox">
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Foreground" Value="{DynamicResource WdText}"/>
      <Setter Property="Background" Value="{DynamicResource WdFieldBg}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource WdBtnBorder}"/>
      <Setter Property="Padding" Value="8,4,24,4"/>
      <Setter Property="SnapsToDevicePixels" Value="True"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBox">
            <Grid>
              <ToggleButton Name="WdCbToggle" Focusable="False" ClickMode="Press"
                            Template="{StaticResource WdComboToggle}"
                            IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}"/>
              <ContentPresenter Name="WdCbText" IsHitTestVisible="False"
                                Content="{TemplateBinding SelectionBoxItem}"
                                ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"
                                Margin="{TemplateBinding Padding}"
                                HorizontalAlignment="Left" VerticalAlignment="Center"
                                TextElement.Foreground="{TemplateBinding Foreground}"/>
              <Popup Name="PART_Popup" Placement="Bottom" Focusable="False" AllowsTransparency="True"
                     IsOpen="{TemplateBinding IsDropDownOpen}">
                <Border Name="WdCbList" CornerRadius="4" BorderThickness="1"
                        MinWidth="{Binding ActualWidth, RelativeSource={RelativeSource TemplatedParent}}"
                        MaxHeight="{TemplateBinding MaxDropDownHeight}"
                        Background="{DynamicResource WdPanel}"
                        BorderBrush="{DynamicResource WdLine}"
                        SnapsToDevicePixels="True">
                  <ScrollViewer SnapsToDevicePixels="True">
                    <StackPanel IsItemsHost="True" KeyboardNavigation.DirectionalNavigation="Contained"/>
                  </ScrollViewer>
                </Border>
              </Popup>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.5"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ComboBox" BasedOn="{StaticResource WdCombo}"/>
    <!-- Through the style, never as a local value on the item. The self test
         asserts no ComboBoxItem anywhere carries a local Foreground or
         Background, because that is the mistake this replaces. -->
    <Style x:Key="WdComboItem" TargetType="ComboBoxItem">
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Foreground" Value="{DynamicResource WdText}"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Padding" Value="9,5"/>
      <Setter Property="SnapsToDevicePixels" Value="True"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBoxItem">
            <Border Name="WdItemFace" Background="{TemplateBinding Background}"
                    Padding="{TemplateBinding Padding}" SnapsToDevicePixels="True">
              <ContentPresenter TextElement.Foreground="{TemplateBinding Foreground}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsHighlighted" Value="True">
                <Setter TargetName="WdItemFace" Property="Background" Value="{DynamicResource WdRowHover}"/>
              </Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="WdItemFace" Property="Background" Value="{DynamicResource WdCardSel}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ComboBoxItem" BasedOn="{StaticResource WdComboItem}"/>
  </Window.Resources>
  <Grid Name="Root">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
    </Grid.RowDefinitions>

    <!-- Title, machine and drive in three tight rows. The title line carries
         the machine description on its right rather than under it: the drive
         had to go somewhere and a header three stacked lines deep pushes the
         list that people came for off the bottom of the screen. -->
    <Border Name="HeaderBar" Grid.Row="0" Padding="20,9,20,8" BorderThickness="0,0,0,1">
      <StackPanel>
        <DockPanel LastChildFill="False">
          <TextBlock Name="HeaderTitle" Text="Windows Setup Toolkit" FontSize="17" FontWeight="SemiBold"
                     VerticalAlignment="Center"/>
          <TextBlock Name="HeaderMachine" DockPanel.Dock="Right" FontSize="11.5" VerticalAlignment="Center"
                     TextTrimming="CharacterEllipsis" Margin="16,0,0,0"/>
        </DockPanel>
        <!-- Permanently on screen, on every page: what a run does to the drive
             is a consequence of choices made on all of them. -->
        <StackPanel Name="StorageBlock" Margin="0,6,0,0">
          <!-- Bar and figures on one line. A bar the width of the window says
               nothing a quarter of one does not, and the row it saves is a row
               of the list. -->
          <DockPanel LastChildFill="True">
            <Border Name="DiskBarFrame" DockPanel.Dock="Left" BorderThickness="1" Height="12" Width="220"
                    VerticalAlignment="Center" SnapsToDevicePixels="True" Margin="0,1,12,0">
              <Grid Name="DiskBar"/>
            </Border>
            <TextBlock Name="DiskCap" DockPanel.Dock="Right" FontSize="11.5" VerticalAlignment="Center"
                       Margin="12,0,0,0"/>
            <TextBlock Name="DiskNote" FontSize="11.5" VerticalAlignment="Center"
                       TextTrimming="CharacterEllipsis"/>
          </DockPanel>
          <!-- The Details popup lived here: per-bucket accounting, the slop
               band, and a "Not counted at all" list. It was a page of storage
               forensics hanging off a debloat tool, and the bar plus its one
               sentence carry everything a decision actually needs. -->
        </StackPanel>
      </StackPanel>
    </Border>

    <!-- ============================== HOME PAGE ============================ -->
    <!-- Three things this toolkit does, and until now two of them were buttons
         in the footer of the third. Somebody who came to undo a run met a page
         of five removal modes first and had to find "Revert past changes" in a
         strip of five controls at the bottom of it; somebody who came to build
         an answer file for a machine that is not this one met the same page.
         The debloat list is one of three destinations, not the application.

         Deliberately calm. Three cards, a line of prose, and nothing else - no
         drive bar (the header hides it here, since what a run does to this disk
         is not a question two of these three are about), no counts, no warning
         box. It is the first thing anybody sees and its whole job is to let
         them say which of three things they came for.

         The cards are built in code by $buildHomeCards rather than declared:
         three of anything with a glyph, a title, a paragraph, and identical
         hover and click behaviour is one builder and three lines of data, and
         written out three times in XAML it is three places for them to drift
         apart. -->
    <Grid Name="PageHome" Grid.Row="1">
      <ScrollViewer Name="HomeScroll" VerticalScrollBarVisibility="Auto"
                    Padding="0,0,20,0">
        <!-- Capped and centred. Stretched across a maximised 4K screen the
             three cards become slabs a foot wide with four words in each, and
             a hub reads as a hub at the width of a page rather than the width
             of a monitor. -->
        <StackPanel MaxWidth="1180" HorizontalAlignment="Center" Margin="20,0,0,0">
          <!-- One line, and no paragraph under it. There was a sentence here
               saying nothing on this page changes anything on its own - which
               is true, and is said better by each card's own description, and
               was standing between the question and the three answers to it. -->
          <TextBlock Name="TxtHomeHead" Text="What would you like to do?"
                     FontSize="26" FontWeight="Bold" Margin="4,34,4,24"/>
          <!-- A UniformGrid, not a Grid of three star columns. Measured, and
               the stars did not come out even: 323, 338 and 310 of the same
               970px, because star allocation is a negotiation with what each
               child asks for and three cards holding three different paragraphs
               do not ask for the same thing. Three cards of three widths on the
               first screen anybody sees reads as a layout that has come loose.
               A UniformGrid divides the room and hands out equal shares, which
               is the only thing wanted here. -->
          <UniformGrid Name="HomeGrid" Columns="3"/>
        </StackPanel>
      </ScrollViewer>
    </Grid>

    <!-- ============================= MODES PAGE ============================ -->
    <Grid Name="PageModes" Grid.Row="1" Visibility="Collapsed">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>   <!-- the page's name -->
        <RowDefinition Height="Auto"/>   <!-- compare-with, when it is being asked -->
        <RowDefinition Height="Auto"/>   <!-- what the modes are -->
        <RowDefinition Height="*"/>      <!-- the cards, and the box of loaded files -->
        <RowDefinition Height="Auto"/>   <!-- the Extreme warning -->
        <RowDefinition Height="Auto"/>   <!-- Back -->
      </Grid.RowDefinitions>

      <!-- The name of the page. It had none at all while it was the whole
           application; as one of three destinations it has to say which one you
           are on, in the same words the card that brought you here used. Back
           is at the foot of the page rather than beside this - see the row
           below the warning box. -->
      <TextBlock Name="TxtModesTitle" Grid.Row="0" Text="Debloat and customize" FontSize="19"
                 FontWeight="Bold" Margin="20,12,20,2"/>

      <!-- Which preset you asked to compare, and the instruction to pick the
           other one. In the page rather than in a dialog: the thing it is
           asking for is a click on one of the cards underneath it, and a modal
           over them would cover the answer to its own question. -->
      <Border Name="CmpPickBar" Grid.Row="1" Margin="20,6,20,0" Padding="14,9" CornerRadius="6"
              BorderThickness="1" Visibility="Collapsed">
        <DockPanel LastChildFill="True">
          <Button Name="BtnCmpPickCancel" DockPanel.Dock="Right" Content="Cancel"
                  Padding="14,4" FontSize="13" Margin="14,0,0,0"/>
          <TextBlock Name="TxtCmpPick" FontSize="14" TextWrapping="Wrap" VerticalAlignment="Center"/>
        </DockPanel>
      </Border>

      <!-- No MaxWidth and no DockPanel around it. Both stopped the line short of
           the window's own edge, so on a wide screen it wrapped with half the
           row still empty beside it. A TextBlock placed straight into the row
           takes the grid's width, so the wrap follows whatever the window is
           currently sized to. -->
      <TextBlock Name="TxtModeHint" Grid.Row="2" FontSize="16" TextWrapping="Wrap" LineHeight="22"
                 LineStackingStrategy="BlockLineHeight"
                 Margin="20,10,20,6"/>

      <!-- Padding on the right, never Margin, and this page was the one that
           still had it wrong. A ScrollViewer's Padding insets its CONTENT and
           not its scrollbar, so the bar lands hard against the window edge while
           the columns keep the same gap from it they had from the edge. With a
           20px margin here the bar floated 20px in, which on a maximised window
           means the pointer cannot reach it at all: slam right and you land on
           empty page. The other four pages already did it this way. -->
      <ScrollViewer Name="ModeScroll" Grid.Row="3" VerticalScrollBarVisibility="Auto"
                    Margin="20,0,0,0" Padding="0,0,20,0">
        <StackPanel>
          <!-- The five columns had no heading at all, so the only labelled block
               on this page was the box of loaded files under them - which read
               as though the shipped modes were the page and the saved ones were
               a footnote. They are two lists of the same kind of thing, so they
               get the same kind of heading, at the same weight. -->
          <TextBlock Name="TxtModeHead" Text="Default presets" FontSize="19"
                     FontWeight="Bold" Margin="5,4,5,8"/>
          <Grid Name="ModeGrid"/>
          <!-- Selections loaded from a file. Under the columns and much smaller
               than one, which is the right shape for what they are: a column is
               a comparison somebody wrote, with a blurb and a bullet list, and
               a saved file has neither. One line each is all there is to say.
               Everywhere else a loaded selection is an equal - Advanced picks
               it, Compare compares it, Reset preset resets it - and this is the
               only place it is deliberately smaller than the five. -->
          <Border Name="LoadBox" Margin="5,18,5,6" Padding="14,10,14,12" CornerRadius="8"
                  BorderThickness="1">
            <StackPanel>
              <DockPanel LastChildFill="False">
                <TextBlock Name="TxtLoadHead" Text="Preset from file" FontSize="19"
                           FontWeight="Bold" VerticalAlignment="Center"/>
                <!-- Load is docked first so it stays rightmost: a DockPanel
                     gives the first Right-docked child the outside edge, and
                     the button somebody reaches for most should not move when
                     a second one is added beside it.

                     Remove and Rename used to sit on every row, one pair per
                     file, and they act on the selected preset from here
                     instead. Two reasons. A row that carries its own two
                     buttons is three controls wide before it has said
                     anything, and the name - which is the whole content of the
                     row - was the part giving way to them. And the pair was
                     the only thing on the page that acted on a preset OTHER
                     than the selected one, so the way to rename the file you
                     were looking at was to find its row again rather than to
                     use the row you had just clicked.

                     Docked in reverse reading order, so the line comes out
                     Remove all | Remove | Rename | Load all | Load: the two
                     that add are together on the outside edge where the hand
                     goes, and the two that take away are at the far end from
                     them. -->
                <Button Name="BtnLoadPreset" DockPanel.Dock="Right" Content="Load"
                        Padding="12,5" FontSize="13"/>
                <Button Name="BtnLoadAll" DockPanel.Dock="Right" Content="Load all"
                        Padding="12,5" FontSize="13" Margin="0,0,8,0"
                        ToolTip="Loads every saved selection in the toolkit's profile_saves folder, skipping any already on this list. Files kept anywhere else are Load's job."/>
                <!-- ToolTipService.ShowOnDisabled, because these two are grayed
                     rather than hidden while a shipped mode is selected and a
                     disabled control that cannot say why it is disabled is
                     worse than one that is simply gone. -->
                <Button Name="BtnRenamePreset" DockPanel.Dock="Right" Content="Rename"
                        Padding="12,5" FontSize="13" Margin="0,0,8,0"
                        ToolTipService.ShowOnDisabled="True"
                        ToolTip="Renames the selected preset's file as well. The name of one of these is the name of its file, so the two cannot come apart. Select a preset from this list first."/>
                <Button Name="BtnRemovePreset" DockPanel.Dock="Right" Content="Remove"
                        Padding="12,5" FontSize="13" Margin="0,0,8,0"
                        ToolTipService.ShowOnDisabled="True"
                        ToolTip="Takes the selected preset off this list. The file itself is not touched. Select a preset from this list first."/>
                <Button Name="BtnRemoveAllPresets" DockPanel.Dock="Right" Content="Remove all"
                        Padding="12,5" FontSize="13" Margin="0,0,14,0"
                        ToolTip="Takes every saved preset off this list. The files themselves are not touched."/>
              </DockPanel>
              <TextBlock Name="TxtLoadHint" FontSize="12.5" TextWrapping="Wrap" Margin="0,5,0,0"/>
              <StackPanel Name="LoadedPanel" Margin="0,8,0,0"/>
            </StackPanel>
          </Border>
        </StackPanel>
      </ScrollViewer>

      <Border Name="WarnBox" Grid.Row="4" Margin="20,12,20,0" Padding="14,10" CornerRadius="6"
              BorderThickness="1" Visibility="Collapsed">
        <TextBlock Name="TxtModeWarning" FontSize="15" TextWrapping="Wrap"/>
      </Border>

      <!-- Back, bottom left, and on its own. It is the only thing left at the
           foot of this page: everything the old footer carried is either a card
           on the home page or a button on the mode card it acts on. Bottom left
           because that is where a way out belongs when the way ON is on a card
           in the middle of the page - the two must not be next to each other,
           or the last thing somebody does before running a preset is reach past
           Back to get to Preview. No rule above it either: one small button
           under a page does not need a bar drawn across the window to hold
           it. -->
      <Button Name="BtnModesBack" Grid.Row="5" Content="Back" Padding="16,6"
              HorizontalAlignment="Left" Margin="20,14,20,14"/>

      <!-- THERE IS NO FOOTER ANY MORE, and every one of its six controls left
           for a reason of its own rather than as one tidy-up.

           Revert past changes and Windows setup completion file are two of the
           three things this toolkit does, so they are cards on the home page
           now and not buttons at the bottom of the third thing.

           Show all options, Compare and Preview all act on the preset that has
           just been picked, and a control that acts on one of five cards
           belongs on that card - the same argument that moved Save and Reset
           there. Watching two people who had never seen this, both picked a
           mode and then had nowhere to go: the footer read as scenery and only
           Preview stood out of it, because Preview was filled.

           And the tally - "Balanced selects 108 of the 323 options still to be
           done on this machine" - was the card's own count restated in a corner
           of the window a long way from the card. -->
    </Grid>

    <!-- ============================ ADVANCED PAGE ========================== -->
    <Grid Name="PageAdvanced" Grid.Row="1" Visibility="Collapsed">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>

      <!-- The toolbar is chrome, not content, and it is given the same
           treatment as the header bar above it so it reads that way: its own
           surface, and a hard rule where it stops. Without that the Filter and
           List by controls sat eight pixels above the index rail on the same
           background and read as the first two entries in it. -->
      <!-- Half the height it was. Every control in here is one line of text in a
           box, and the box was carrying more air than the line - on the one page
           whose whole job is showing a long list, two toolbars' worth of padding
           is two categories nobody can see. The paddings below are halved rather
           than removed: a control still has to look like something you can hit. -->
      <Border Name="AdvToolbar" Grid.Row="0" Padding="20,5,20,4" BorderThickness="0,0,0,1">
      <StackPanel>
        <!-- LastChildFill, and the badge and its button docked Right, so the
             row of preset buttons gets whatever width is left and can scroll
             inside it. The number of presets has no ceiling - every loaded file
             adds one - and a horizontal stack that simply runs off the edge is
             a list with entries nothing can reach. The side effect is that the
             badge now keeps one fixed place at the end of the toolbar instead
             of sliding right as presets are loaded, which is the better of the
             two behaviors anyway. -->
        <DockPanel LastChildFill="True" Margin="0,0,0,4">
          <TextBlock Name="LblPreset" Text="Preset" DockPanel.Dock="Left" VerticalAlignment="Center" Margin="0,0,10,0" FontSize="13"/>
          <Button Name="BtnResetOne" DockPanel.Dock="Right" Padding="12,2" Margin="10,0,0,0" Visibility="Collapsed"
                  ToolTip="Put this mode back to what it removes as shipped. The other modes keep your edits."/>
          <Border Name="PresetBadge" DockPanel.Dock="Right" CornerRadius="4" Padding="10,2" VerticalAlignment="Center">
            <TextBlock Name="TxtActivePreset" FontSize="13" FontWeight="SemiBold"/>
          </Border>
          <!-- Built in code, not declared: the list is the five the manifest
               ships plus whatever selections have been loaded from a file, and
               that changes while the window is open. $ui still carries
               BtnConservative and its four siblings under their old names, so
               everything that drives them by name goes on working. -->
          <ScrollViewer Name="PresetScroll" Margin="0,0,14,0" VerticalScrollBarVisibility="Disabled"
                        HorizontalScrollBarVisibility="Auto">
            <!-- The same picker row as Compare's, and it takes the same bar
                 from the window's implicit style. It used to re-declare that
                 style here, which was needed only while the style was keyed:
                 the one definition now reaches every bar in the application,
                 including the ones inside a ScrollViewer's own template, which
                 can be reached no other way. -->
            <StackPanel Name="PresetRow" Orientation="Horizontal"/>
          </ScrollViewer>
        </DockPanel>
        <DockPanel LastChildFill="True">
          <!-- A drop-down of check boxes rather than a ComboBox: the filter is
               multi-select, and a ComboBox cannot show more than one choice in
               its closed box. -->
          <ToggleButton Name="BtnFilter" Content="Filter" Padding="12,2" FontSize="13"
                        Style="{StaticResource WdToggle}"
                        Margin="0,0,10,0" MinWidth="150"/>
          <!-- Arranging, not filtering. The filter decides what is on the page;
               these decide how the same set is laid out. Two controls because
               there are two questions - what the page is divided into, and what
               order rows run in inside a division - and every pairing of them
               means something, so there is nothing to gray out. -->
          <TextBlock Name="LblOrder" Text="Group by" VerticalAlignment="Center" Margin="0,0,8,0" FontSize="13"/>
          <ComboBox Name="CmbOrder" Width="150" Padding="8,1,24,1" FontSize="13" Margin="0,0,10,0"/>
          <!-- Sort by held four entries and a separate "Selected first" check
               box beside it. Two of the four ranked by things the page already
               says out loud - the risk badge and the size tag are on the rows -
               and both were also groupings, so the same question was asked
               twice in two controls. What is left is the only pair a sort has
               to answer: alphabetical, or what have I got so far. The check box
               is gone with them; it was a third control for what is plainly the
               second entry of this one. -->
          <TextBlock Name="LblSort" Text="Sort by" VerticalAlignment="Center" Margin="0,0,8,0" FontSize="13"/>
          <ComboBox Name="CmbSort" Width="150" Padding="8,1,24,1" FontSize="13" Margin="0,0,16,0"/>
          <!-- The same two signs every group heading wears, so the pair reads as
               "all of those at once" rather than as a control of its own that has
               to be learnt separately. Labelled, because two bare signs in a
               toolbar say nothing about what they act on - and kept to the signs
               rather than the words because this row is already the widest thing
               on the page at the minimum window size. -->
          <TextBlock Name="LblGroups" Text="Collapse all" VerticalAlignment="Center" Margin="0,0,8,0" FontSize="13"/>
          <Button Name="BtnCollapseAll" Content="-" Width="26" Padding="0,1" FontSize="13"
                  FontWeight="Bold" Margin="0,0,4,0" ToolTip="Collapse every group on the page"/>
          <Button Name="BtnExpandAll" Content="+" Width="26" Padding="0,1" FontSize="13"
                  FontWeight="Bold" Margin="0,0,16,0" ToolTip="Expand every group on the page"/>
          <!-- The page is a reading of the machine taken when it was built, and
               somebody may have changed something since. This asks again. -->
          <Button Name="BtnRefresh" Content="Refresh" Padding="10,2" FontSize="13" Margin="0,0,16,0"
                  ToolTip="Re-checks this machine and updates every row: what is installed, what is already set, and what is no longer here. Your ticks are kept."/>
          <TextBlock Name="TxtFilterCount" VerticalAlignment="Center" Margin="0,0,18,0" FontSize="13"/>
          <TextBlock Name="LblFilter" Text="Search" VerticalAlignment="Center" Margin="0,0,8,0" FontSize="13"/>
          <TextBox Name="TxtFilter" Padding="7,2" FontSize="13"/>
        </DockPanel>
        <!-- What is actually narrowing the list, and the one thing the button
             could never say. "Filter (3)" tells you how many, never which. Each
             chip drops its own facet; the last one says when a filter is hiding
             something you have already ticked, which is the state that can send
             an unread item into a run. -->
        <WrapPanel Name="FilterChips" Margin="0,8,0,0" Visibility="Collapsed"/>
        <!-- What the last preset button did. Last in the stack, so the only
             thing it ever pushes is the list: appearing anywhere above this
             would move the filter row out from under the pointer that had just
             reached for it, and the chips already establish that a line under
             the toolbar may come and go. See $sayPresetSwitch for why the page
             has to say this out loud at all. -->
        <TextBlock Name="TxtPresetNote" Margin="0,8,0,0" FontSize="12.5"
                   TextWrapping="Wrap" Visibility="Collapsed"/>
        <Popup Name="FilterPopup" PlacementTarget="{Binding ElementName=BtnFilter}" Placement="Bottom"
               StaysOpen="False" AllowsTransparency="True" VerticalOffset="4"
               IsOpen="{Binding IsChecked, ElementName=BtnFilter, Mode=TwoWay}">
          <Border Name="FilterCard" BorderThickness="1" CornerRadius="6" Padding="16,12" MinWidth="320">
            <StackPanel>
              <ScrollViewer MaxHeight="430" VerticalScrollBarVisibility="Auto">
                <StackPanel Name="FilterPanel"/>
              </ScrollViewer>
              <DockPanel LastChildFill="False" Margin="0,12,0,0">
                <Button Name="BtnFilterClear" Content="Clear all" Padding="12,4"/>
                <Button Name="BtnFilterDone"  DockPanel.Dock="Right" Content="Done" Padding="16,4"/>
              </DockPanel>
            </StackPanel>
          </Border>
        </Popup>
      </StackPanel>
      </Border>

      <!-- An index INTO the list, never a router. Clicking scrolls; the
           highlight follows the scroll. Content is never swapped and nothing is
           ever hidden, because the promise this page makes is that everything
           about to happen is on it. What the rail buys is the two things a
           long page genuinely lacks: somewhere to jump to, and a sense that the
           list is finite - which is what the per-category counts are for. -->
      <!-- Three columns, the middle one a splitter. Category names run from one
           word to five, so where the rail should stop is a matter of which
           twenty-three names are in it - which the operator can see and this
           cannot. The width is remembered in ui-state.json, and the column is
           the thing that carries it: the ScrollViewer inside is left to fill,
           because sizing both fights the splitter. -->
      <!-- No right margin, and the list's own ScrollViewer carries the inset as
           Padding instead. A ScrollViewer's Padding insets its CONTENT and not
           its scrollbar, so the bar lands hard against the window edge where
           every other application puts one, and the rows keep exactly the gap
           from it they had from the edge. With the margin here the bar floated
           20px in with a strip of empty page outside it, which reads as a
           layout that has come loose rather than as breathing room. -->
      <Grid Grid.Row="1" Margin="20,12,0,0">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Name="IndexCol" Width="184" MinWidth="120" MaxWidth="420"/>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>
        <ScrollViewer Name="IndexScroll" Grid.Column="0" Margin="0,0,4,0"
                      VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
          <!-- The 5px rail bar, defined once at window level. It has to be put
               back under the implicit key HERE, in this ScrollViewer's own
               resources, because a bar inside a ScrollViewer's template can be
               reached no other way. -->
          <ScrollViewer.Resources>
            <Style TargetType="ScrollBar" BasedOn="{StaticResource WdRailBar}"/>
          </ScrollViewer.Resources>
          <StackPanel Name="IndexPanel"/>
        </ScrollViewer>
        <GridSplitter Name="IndexSplit" Grid.Column="1" Width="6" HorizontalAlignment="Stretch"
                      VerticalAlignment="Stretch" Background="Transparent" ShowsPreview="False"
                      ResizeBehavior="PreviousAndNext" ResizeDirection="Columns"/>
      <ScrollViewer Name="AdvScroll" Grid.Column="2" Padding="0,0,20,0"
                    VerticalScrollBarVisibility="Auto"
                    HorizontalScrollBarVisibility="Disabled">
        <StackPanel Name="AdvContent">
          <!-- Two sections, each its own pair of columns. One grid with a
               spanning header in the middle cannot work: the columns are
               StackPanels, so the second section's rows would start level with
               the first section's, not below its longest column. -->
          <StackPanel Name="RemoveHeadBlock">
            <StackPanel Orientation="Horizontal" Margin="0,4,0,6">
              <TextBlock Name="RemoveGlyph" FontFamily="Segoe UI Emoji" FontSize="18" Margin="0,0,9,0"/>
              <TextBlock Name="RemoveHead" Text="Remove" FontSize="20" FontWeight="SemiBold"/>
            </StackPanel>
          </StackPanel>
          <!-- Square, not rounded: the box is there to say where a section
               starts and stops, and a rounded card reads as a control. -->
          <!-- Recurring used to have a hand-built block of its own down here,
               outside the category loop, on the reasoning that its rows cost
               something for as long as they stay. That is a note, not a
               structure: the note is a category field now and Recurring is an
               ordinary category, so it groups, sorts, filters and indexes like
               every other one instead of needing a special case in each. -->
          <Border Name="RemoveBox" BorderThickness="1" Padding="14,10,14,14">
            <Grid Name="AdvColumns">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="30"/>
                <ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <StackPanel Name="ColLeft"  Grid.Column="0"/>
              <StackPanel Name="ColRight" Grid.Column="2"/>
            </Grid>
          </Border>
          <StackPanel Name="AddHeadBlock" Margin="0,26,0,0">
            <StackPanel Orientation="Horizontal" Margin="0,4,0,6">
              <TextBlock Name="AddGlyph" FontFamily="Segoe UI Emoji" FontSize="18" Margin="0,0,9,0"/>
              <TextBlock Name="AddHead" Text="Add" FontSize="20" FontWeight="SemiBold"/>
            </StackPanel>
          </StackPanel>
          <Border Name="AddBox" BorderThickness="1" Padding="14,10,14,14">
            <StackPanel>
              <!-- The browser is a choice, not a tick, so it cannot be a row
                   like the rest of the Add list. Same picker as the one under
                   Edge removal, and the two stay in step. -->
              <StackPanel Name="BrowserAddBlock" Margin="0,0,0,10"/>
              <Grid Name="AddColumns">
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="30"/>
                  <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <StackPanel Name="AddLeft"  Grid.Column="0"/>
                <StackPanel Name="AddRight" Grid.Column="2"/>
              </Grid>
            </StackPanel>
          </Border>
          <StackPanel Name="ExtraHeadBlock" Margin="0,26,0,0">
            <StackPanel Orientation="Horizontal" Margin="0,4,0,6">
              <TextBlock Name="ExtraGlyph" FontFamily="Segoe UI Emoji" FontSize="18" Margin="0,0,9,0"/>
              <TextBlock Name="ExtraHead" Text="Extras" FontSize="20" FontWeight="SemiBold"/>
            </StackPanel>
          </StackPanel>
          <Border Name="ExtraBox" BorderThickness="1" Padding="14,10,14,14">
            <StackPanel>
              <!-- What the run does whatever is ticked. First in Extras, and
                   first for a reason: this section answers "how does the run
                   behave", and the steps nobody chose are the part of that
                   answer no tick on the page can lead you to. Rows here have no
                   check box because there is nothing to decide - they are
                   listed so the page's promise that everything about to happen
                   is on it stays true. -->
              <StackPanel Name="AlwaysBlock" Margin="0,0,0,4"/>
              <StackPanel Name="RunOptionsBlock" Margin="0,14,0,0">
                <StackPanel Orientation="Horizontal" Margin="0,0,0,4">
                  <TextBlock Name="RunOptGlyph" FontFamily="Segoe UI Emoji" FontSize="16" Margin="0,0,8,0"/>
                  <TextBlock Name="RunOptHead" Text="Authority" FontSize="16" FontWeight="SemiBold"/>
                </StackPanel>
                <Border Name="RunOptRule" Height="1" Margin="0,0,0,4"/>
                <CheckBox Name="ChkOwnership" IsChecked="False" Margin="0,6,0,0"
                          Content="Take ownership when Windows refuses"/>
                <TextBlock Name="LblOwnership" FontSize="13" TextWrapping="Wrap" Margin="24,2,0,6"
                           Text="For services, scheduled tasks and policy keys owned by TrustedInstaller, seize the key and retry. Does not apply to Appx packages Windows marks non-removable."/>
                <CheckBox Name="ChkDownloads" IsChecked="True" Margin="0,6,0,0"
                          Content="Allow vendor cleanup downloads"/>
                <TextBlock Name="LblDownloads" FontSize="13" TextWrapping="Wrap" Margin="24,2,0,6"
                           Text="Lets the tool fetch McAfee's MCPR scrubber and similar vendor removal utilities from the vendor's own site."/>
                <TextBlock Name="LblAccountsHead" FontSize="14" FontWeight="SemiBold" Margin="0,10,0,0"
                           Text="Which accounts per-user settings are written to"/>
                <TextBlock Name="LblAccounts" FontSize="13" TextWrapping="Wrap" Margin="0,2,0,4"/>
                <StackPanel Name="AccountsBlock" Margin="0,0,0,4"/>
              </StackPanel>
              <!-- Categories that belong to Extras rather than to Remove or
                   Add - the storage clean-ups. Same two-column treatment as the
                   other sections, so the page reads the same way throughout. -->
              <Grid Name="ExtraColumns" Margin="0,4,0,0">
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="30"/>
                  <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <StackPanel Name="ExtraLeft"  Grid.Column="0"/>
                <StackPanel Name="ExtraRight" Grid.Column="2"/>
              </Grid>
            </StackPanel>
          </Border>
          <!-- Settings for the application itself, not for the run. Last on the
               page because that is where you go looking for them, and boxed
               apart so they are plainly not part of the list. -->
          <Border Name="AppOptBox" BorderThickness="1" Padding="14,10,14,12" Margin="0,26,0,0">
            <StackPanel>
              <StackPanel Orientation="Horizontal" Margin="0,0,0,4">
                <TextBlock Name="AppOptGlyph" FontFamily="Segoe UI Emoji" FontSize="16" Margin="0,0,8,0"/>
                <TextBlock Name="AppOptHead" Text="App Options" FontSize="16" FontWeight="SemiBold"/>
              </StackPanel>
              <Border Name="AppOptRule" Height="1" Margin="0,0,0,8"/>
              <!-- Three one-off actions, not settings, and none of them belongs
                   in the item list: each happens the moment it is clicked
                   rather than when a run starts. Delete old run logs was a
                   manifest row under Recurring, which put a permanent, one-off
                   deletion behind a tick that had to survive a whole preview. -->
              <DockPanel LastChildFill="False">
                <Button Name="BtnTheme"     Content="Switch to light theme" Padding="14,6" Margin="0,0,8,0"/>
                <Button Name="BtnFactory"   Content="Restore factory defaults" Padding="14,6" Margin="0,0,8,0"/>
                <Button Name="BtnClearLogs" Content="Delete old run logs" Padding="14,6"/>
              </DockPanel>
              <!-- The one setting in a box of one-off actions, which is why it
                   sits under them behind a rule rather than beside them: a tick
                   that changes how the application behaves from now on is not
                   the same kind of thing as a button that deletes something the
                   moment it is pressed. -->
              <Border Name="AppOptRule2" Height="1" Margin="0,12,0,10"/>
              <CheckBox Name="ChkDetailPopup" Content="Open option details in a window instead of under the row"/>
              <TextBlock Name="DetailPopupNote" FontSize="12" TextWrapping="Wrap" Margin="24,3,0,0"
                         Text="Details normally open in place, under the option you clicked, so the list stays where it is. Turn this on to have them open over the page instead."/>
              <CheckBox Name="ChkTerse" Content="Verbose mode" Margin="0,10,0,0"/>
              <TextBlock Name="TerseNote" FontSize="12" TextWrapping="Wrap" Margin="24,3,0,0"
                         Text="Puts the standing text back on every page: the one-line description under each option, the cost lines, and the &quot;already installed&quot;, &quot;already set&quot;, and &quot;opt-in&quot; labels. It is off as shipped, because all of it is the same on every visit and Details still shows it on the one option you are asking about."/>
            </StackPanel>
          </Border>
          <StackPanel Name="ProtectedBlock" Margin="0,26,0,20"/>
        </StackPanel>
      </ScrollViewer>
      </Grid>

      <!-- The "96 of 240 selected" that used to sit at the left of this row is
           gone. It was the same two numbers as the badge in the top right,
           a window's diagonal away, in the corner nobody looks at; the badge
           carries the denominator now. -->
      <Border Grid.Row="2" Name="AdvFooter" Padding="20,6" BorderThickness="0,1,0,0">
        <DockPanel LastChildFill="False">
          <Button Name="BtnPreview"   DockPanel.Dock="Right" Content="Preview"        Padding="22,4" Margin="8,0,0,0" FontWeight="Bold"/>
          <Button Name="BtnSave"      DockPanel.Dock="Right" Content="Save" Padding="14,4" Margin="8,0,0,0"/>
          <Button Name="BtnBackModes" DockPanel.Dock="Right" Content="Back"  Padding="14,4" Margin="8,0,0,0"/>
          <Button Name="BtnAdvUndo"   DockPanel.Dock="Right" Content="Undo"           Padding="14,4" Margin="8,0,0,0" Visibility="Collapsed"/>
          <!-- What the Undo beside it would take back, in the same place and
               the same words Compare uses. A bare "Undo (7)" says how many
               gestures are on the stack and nothing about what the next one
               reverses, which on a page of 240 tick boxes is the only part
               worth knowing. -->
          <TextBlock Name="TxtAdvNote" DockPanel.Dock="Right" VerticalAlignment="Center" FontSize="13"
                     TextTrimming="CharacterEllipsis" MaxWidth="380" Margin="16,0,0,0"/>
        </DockPanel>
      </Border>
    </Grid>

    <!-- ============================= REVERT PAGE =========================== -->
    <!-- The rollback script's own window, in the application. The two are meant
         to be one interface: somebody who has used the standalone script has
         already learnt this page, and the other way round. Same toolbar in the
         same order, same two-column blocks, same rail with a scroll spy on it,
         same Details chip under every row - with a run picker above all of it,
         which is the one thing the standalone script has no need of because it
         is generated per run. -->
    <!-- ========================== PAST RUNS PAGE =========================== -->
    <!-- The runs this machine has a record of, one card each, shaped like the
         mode screen and for the same reason: a card is a thing you can read
         before deciding, and each one carries what you can do with it.
         Show all options opens the list of that run's changes; Revert
         everything puts the lot back.

         This is what the horizontal picker at the top of the page below used to
         be, and that picker was one line of buttons labelled with dates. It
         could not say what a run had done, how much of it was still in place,
         or whether its rollback script still existed - and it was the first
         thing anybody arriving to undo something saw. The picker is still
         there, on the page below, exactly as the Advanced toolbar keeps a preset
         row: it is for switching scope once you are already reading a list.

         A WrapPanel rather than a UniformGrid, because the number of runs a
         machine accumulates has no ceiling. Fixed-width cards wrapping onto as
         many rows as it takes. -->
    <Grid Name="PageRevertHome" Grid.Row="1" Visibility="Collapsed">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>
      <TextBlock Name="TxtRevHomeTitle" Grid.Row="0" Text="Revert past changes" FontSize="19"
                 FontWeight="Bold" Margin="20,12,20,2"/>
      <TextBlock Name="TxtRevHomeHint" Grid.Row="1" FontSize="14" TextWrapping="Wrap"
                 Margin="20,4,20,8"/>
      <ScrollViewer Name="RevHomeScroll" Grid.Row="2" VerticalScrollBarVisibility="Auto"
                    Margin="20,0,0,0" Padding="0,0,20,0">
        <WrapPanel Name="RevHomeCards"/>
      </ScrollViewer>
      <Button Name="BtnRevHomeBack" Grid.Row="3" Content="Back" Padding="16,6"
              HorizontalAlignment="Left" Margin="20,14,20,14"/>
    </Grid>

    <Grid Name="PageRevert" Grid.Row="1" Visibility="Collapsed">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>

      <StackPanel Grid.Row="0" Margin="20,12,20,0">
        <TextBlock Name="TxtRevertHead" FontSize="17" FontWeight="SemiBold" TextWrapping="Wrap"/>
        <TextBlock Name="TxtRevertSub" FontSize="12.5" Margin="0,4,0,0" TextWrapping="Wrap"/>
        <!-- The picker scrolls sideways, because the number of runs a machine
             accumulates has no ceiling and a fixed row that runs past the edge
             is a picker with entries nothing can reach. No ScrollViewer.Resources
             here: the bar style is implicit at window level and already reaches
             every bar in the application, including the ones inside a
             ScrollViewer's own template. The preset row it is modelled on
             dropped its own copy for the same reason. -->
        <ScrollViewer Name="RevertRunScroll" Margin="0,9,0,0"
                      HorizontalScrollBarVisibility="Auto" VerticalScrollBarVisibility="Disabled">
          <StackPanel Name="RevertRunRow" Orientation="Horizontal"/>
        </ScrollViewer>
        <Border Name="RevertBar" BorderThickness="1" CornerRadius="4" Padding="12,9,12,10" Margin="0,10,0,0">
          <StackPanel>
            <DockPanel LastChildFill="True">
              <ToggleButton Name="BtnRevFilter" Content="Filter" Padding="12,2" FontSize="13"
                            Style="{StaticResource WdToggle}" Margin="0,0,10,0" MinWidth="118"/>
              <TextBlock Name="LblRevOrder" Text="Group by" VerticalAlignment="Center" Margin="0,0,8,0" FontSize="13"/>
              <ComboBox Name="CmbRevOrder" Width="150" Padding="8,1,24,1" FontSize="13" Margin="0,0,10,0"/>
              <TextBlock Name="LblRevSort" Text="Sort by" VerticalAlignment="Center" Margin="0,0,8,0" FontSize="13"/>
              <ComboBox Name="CmbRevSort" Width="150" Padding="8,1,24,1" FontSize="13" Margin="0,0,16,0"/>
              <Button Name="BtnRevSelectAll" Content="Select all" Padding="10,2" FontSize="13"
                      Margin="0,0,16,0" MinWidth="92"
                      ToolTip="Selects every option on screen that can be reverted. Press again to clear them."/>
              <TextBlock Name="LblRevGroups" Text="Collapse all" VerticalAlignment="Center" Margin="0,0,8,0" FontSize="13"/>
              <Button Name="BtnRevCollapseAll" Content="-" Width="26" Padding="0,1" FontSize="13"
                      FontWeight="Bold" Margin="0,0,4,0" ToolTip="Collapse every group on the page"/>
              <Button Name="BtnRevExpandAll" Content="+" Width="26" Padding="0,1" FontSize="13"
                      FontWeight="Bold" Margin="0,0,16,0" ToolTip="Expand every group on the page"/>
              <Button Name="BtnRevRefresh" Content="Refresh" Padding="10,2" FontSize="13" Margin="0,0,16,0"
                      ToolTip="Reads this machine again and rebuilds the page, so anything undone by hand since it was opened is accounted for."/>
              <TextBlock Name="TxtRevCount" VerticalAlignment="Center" Margin="0,0,16,0" FontSize="13"/>
              <TextBlock Name="LblRevFind" Text="Search" VerticalAlignment="Center" Margin="0,0,8,0" FontSize="13"/>
              <TextBox Name="RevFind" Padding="7,3" FontSize="13" MinWidth="140"/>
            </DockPanel>
            <WrapPanel Name="RevFilterChips" Margin="0,9,0,0" Visibility="Collapsed"/>
          </StackPanel>
        </Border>
      </StackPanel>

      <Popup Name="RevFilterPopup" PlacementTarget="{Binding ElementName=BtnRevFilter}" Placement="Bottom"
             StaysOpen="False" AllowsTransparency="True" VerticalOffset="4"
             IsOpen="{Binding IsChecked, ElementName=BtnRevFilter, Mode=TwoWay}">
        <Border Name="RevFilterCard" BorderThickness="1" CornerRadius="6" Padding="16,12" MinWidth="300">
          <StackPanel>
            <ScrollViewer MaxHeight="430" VerticalScrollBarVisibility="Auto">
              <StackPanel Name="RevFilterPanel"/>
            </ScrollViewer>
            <DockPanel LastChildFill="False" Margin="0,12,0,0">
              <Button Name="BtnRevFilterClear" Content="Clear all" Padding="12,4" FontSize="13"/>
              <Button Name="BtnRevFilterDone" DockPanel.Dock="Right" Content="Done" Padding="16,4" FontSize="13" Margin="0"/>
            </DockPanel>
          </StackPanel>
        </Border>
      </Popup>

      <Grid Grid.Row="1" Margin="20,10,0,0">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Name="RevIndexCol" Width="184" MinWidth="120" MaxWidth="420"/>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>
        <ScrollViewer Name="RevIndexScroll" Grid.Column="0" Margin="0,0,4,0"
                      VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
          <ScrollViewer.Resources>
            <Style TargetType="ScrollBar" BasedOn="{StaticResource WdRailBar}"/>
          </ScrollViewer.Resources>
          <StackPanel Name="RevIndexPanel"/>
        </ScrollViewer>
        <Border Name="RevIndexRule" Grid.Column="1" Width="1" Margin="1,0,0,0"
                HorizontalAlignment="Left" IsHitTestVisible="False"/>
        <GridSplitter Name="RevIndexSplit" Grid.Column="1" Width="6" HorizontalAlignment="Stretch"
                      VerticalAlignment="Stretch" Background="Transparent" ShowsPreview="False"
                      ResizeBehavior="PreviousAndNext" ResizeDirection="Columns"/>
        <ScrollViewer Name="RevScroll" Grid.Column="2" Padding="0,0,20,0"
                      VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
          <StackPanel Name="RevList"/>
        </ScrollViewer>
      </Grid>

      <Border Grid.Row="2" Name="RevertFooter" Padding="20,12" BorderThickness="0,1,0,0">
        <DockPanel LastChildFill="False">
          <TextBlock Name="TxtRevertTally" VerticalAlignment="Center" FontSize="13" TextWrapping="Wrap"/>
          <Button Name="BtnRevertRun"  DockPanel.Dock="Right" Content="Revert selected" Padding="20,7" Margin="8,0,0,0" FontWeight="SemiBold"/>
          <Button Name="BtnRevertBack" DockPanel.Dock="Right" Content="Back"   Padding="14,7" Margin="8,0,0,0"/>
        </DockPanel>
      </Border>
    </Grid>

    <!-- =========================== COMPARE PAGE =========================== -->
    <Grid Name="PageCompare" Grid.Row="1" Visibility="Collapsed">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>

      <StackPanel Grid.Row="0" Margin="20,6,20,4">
        <!-- There was a paragraph here explaining that the page lists what one
             mode removes and the other does not, that the modes are a ladder,
             and that every item can be handed across. Every sentence of it is
             said better by the page itself: the two headings name the two modes
             and what "only" means, the counts under them say how many, and the
             button on each card says it can be handed over. A caption that
             repeats the thing it is captioning is three lines of the window
             spent on the one screen where vertical space is what runs out. -->
        <!-- The two mode pickers used to live here, side by side above the
             toolbar. They are built in code now and placed INSIDE the pinned
             header, one over each column - see $cmpHead. A picker that chooses
             what a column contains belongs over that column: with both of them
             here, "Compare [Balanced] against [Aggressive]" ran left to right
             across a page whose own two halves were the same two things, and
             nothing lined the pair up. -->
        <!-- The same three controls the Advanced page has, in the same order and
             with the same words. Two modes can differ by eighty items, and until
             now the only way through that was scrolling: the page grouped by
             category, always, and had no way to say "just the risky ones" or to
             find one name. Deliberately the same shape rather than a cleverer
             one - somebody who has learnt the Advanced toolbar has learnt this. -->
        <DockPanel LastChildFill="True">
          <ToggleButton Name="BtnCmpFilter" Content="Filter" Padding="12,2" FontSize="13"
                        Style="{StaticResource WdToggle}"
                        Margin="0,0,10,0" MinWidth="130"/>
          <TextBlock Name="LblCmpGroup" Text="Group by" VerticalAlignment="Center" Margin="0,0,8,0" FontSize="13"/>
          <ComboBox Name="CmbCmpGroup" Width="150" Padding="8,1,24,1" FontSize="13" Margin="0,0,16,0"/>
          <TextBlock Name="TxtCmpCount" VerticalAlignment="Center" Margin="0,0,18,0" FontSize="13"/>
          <TextBlock Name="LblCmpSearch" Text="Search" VerticalAlignment="Center" Margin="0,0,8,0" FontSize="13"/>
          <TextBox Name="TxtCmpSearch" Padding="7,2" FontSize="13"/>
        </DockPanel>
        <Popup Name="CmpFilterPopup" PlacementTarget="{Binding ElementName=BtnCmpFilter}" Placement="Bottom"
               StaysOpen="False" AllowsTransparency="True" VerticalOffset="4"
               IsOpen="{Binding IsChecked, ElementName=BtnCmpFilter, Mode=TwoWay}">
          <Border Name="CmpFilterCard" BorderThickness="1" CornerRadius="6" Padding="16,12" MinWidth="300">
            <StackPanel>
              <ScrollViewer MaxHeight="430" VerticalScrollBarVisibility="Auto">
                <StackPanel Name="CmpFilterPanel"/>
              </ScrollViewer>
              <DockPanel LastChildFill="False" Margin="0,12,0,0">
                <Button Name="BtnCmpFilterClear" Content="Clear all" Padding="12,4"/>
                <Button Name="BtnCmpFilterDone"  DockPanel.Dock="Right" Content="Done" Padding="16,4"/>
              </DockPanel>
            </StackPanel>
          </Border>
        </Popup>
      </StackPanel>

      <!-- The same index the Advanced page has, for the same reason: two modes
           can differ by eighty items across a dozen headings, and the filter
           and the search box answer "show me less", not "take me there". It
           gets the same splitter too: the argument for leaving this one fixed
           was that the headings change with the modes, so there is nothing
           stable to size it to - which is backwards. A list whose contents
           change is a list whose right width changes, and the operator is the
           only one who can see which twelve headings are in it today. -->
      <!-- No right margin here either - see the Advanced page. The cards carry
           the inset as the scroller's Padding and the pinned header adds it to
           its own gutter, so the two stay aligned with each other and the bar
           sits at the window edge. -->
      <Grid Grid.Row="1" Margin="20,0,0,0">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Name="CmpIndexCol" Width="184" MinWidth="120" MaxWidth="420"/>
          <ColumnDefinition Width="Auto"/>
          <!-- A hairline between the rail and the comparison, the same one the
               setup page has and for the same reason: without it the rail read
               as a short column of loose words floating beside the page rather
               than as an index belonging to it. It goes AFTER the splitter, so
               dragging the rail moves the line with it. -->
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>
        <ScrollViewer Name="CmpIndexScroll" Grid.Column="0"
                      VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
          <!-- The same 5px rail bar the Advanced rail wears, from the same
               window-level definition. It was a second copy of the whole style
               here, on the reasoning that the style has to live in a
               ScrollViewer's own resources to reach its bar - true of where the
               implicit KEY has to sit, and not of where the style is written.
               The two copies duly drifted: one gained a MinWidth and the other
               did not, and neither ever gained a hover state. -->
          <ScrollViewer.Resources>
            <Style TargetType="ScrollBar" BasedOn="{StaticResource WdRailBar}"/>
          </ScrollViewer.Resources>
          <StackPanel Name="CmpIndexPanel"/>
        </ScrollViewer>
        <GridSplitter Name="CmpIndexSplit" Grid.Column="1" Width="6" HorizontalAlignment="Stretch"
                      VerticalAlignment="Stretch" Background="Transparent" ShowsPreview="False"
                      ResizeBehavior="PreviousAndNext" ResizeDirection="Columns"/>
        <Border Name="CmpIndexRule" Grid.Column="2" Width="1" Margin="0,2,16,2"
                VerticalAlignment="Stretch"/>
        <!-- Two rows, and the split is what pins the headings. Which two modes
             are being compared, and what "only this one removes these" means, is
             the frame the whole page is read through - and it used to be the
             first thing to scroll off it, so eighty cards down there were two
             unlabeled columns of item names and no way to tell which mode either
             belonged to but the color of a 3px stripe.
             The picker sits above its own heading rather than below it: the
             order somebody works in is choose a mode, then read what only it
             removes, and the heading is the answer to the picker rather than a
             caption over it. -->
        <Grid Grid.Column="3">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>
          <Grid Name="CompareHead" Grid.Row="0"/>
          <!-- Visible, not Auto, and the gutter is the reason. The header above
               is a separate grid from the cards below, so the two only line up
               while they are the same width - and a scrollbar that comes and
               goes moves the cards seventeen pixels out from under their own
               heading. Reserved always, and $buildCompare gives the header a
               matching right margin measured off the system rather than
               guessed. -->
          <ScrollViewer Name="CmpScroll" Grid.Row="1" Padding="0,0,20,0"
                        VerticalScrollBarVisibility="Visible"
                        HorizontalScrollBarVisibility="Disabled">
            <Grid Name="CompareGrid"/>
          </ScrollViewer>
        </Grid>
      </Grid>

      <Border Grid.Row="2" Name="CompareFooter" Padding="20,6" BorderThickness="0,1,0,0" Margin="0,6,0,0">
        <DockPanel LastChildFill="False">
          <TextBlock Name="TxtCompareTally" VerticalAlignment="Center" FontSize="14" FontWeight="SemiBold"/>
          <Button Name="BtnCompareBack" DockPanel.Dock="Right" Content="Back" Padding="14,4" Margin="8,0,0,0"/>
          <!-- An added item stops being a difference, so its card leaves the
               page. The note is what stands in for the card that vanished. -->
          <Button Name="BtnCompareUndo" DockPanel.Dock="Right" Content="Undo" Padding="14,4" Margin="8,0,0,0" Visibility="Collapsed"/>
          <TextBlock Name="TxtCompareNote" DockPanel.Dock="Right" VerticalAlignment="Center" FontSize="13"
                     TextTrimming="CharacterEllipsis" Margin="16,0,0,0"/>
        </DockPanel>
      </Border>
    </Grid>

    <!-- ========================== ANSWER FILE PAGE ========================= -->
    <!--
      One long page with an index down the side, exactly like Advanced, and for
      exactly the same reason: everything the file will contain is on it. The
      two well-known generators pick the opposite ends of that. Schneegans is
      one page of twenty-seven sections with no index, which is honest and hard
      to navigate; the tabbed rewrites of it hide two thirds of the state behind
      seven tabs, which is easy to navigate and quietly stateful. The rail is
      what buys navigation without hiding anything.

      Three things carry the "works for anyone" half, and none of them is a
      simplified mode: every field is already filled in with the answer most
      people want, every field says in a line what it does to the installation,
      and the first section on the page is what the file will do rather than a
      form to fill in.
    -->
    <Grid Name="PageUnattend" Grid.Row="1" Visibility="Collapsed">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>

      <StackPanel Grid.Row="0" Margin="20,14,20,0">
        <TextBlock Name="TxtUaHint" FontSize="13" TextWrapping="Wrap"/>
      </StackPanel>

      <!-- Three columns, and the middle one is a hairline. The rail had nothing
           between it and the form, so on a wide window it read as a short
           column of loose words floating in the top left rather than as an
           index belonging to the page beside it. Its width and the size of its
           cards scale with the window - see $uaSizeRail - for the same reason:
           184px of rail against 1600px of window is a control that shrank away
           from the space it was given. -->
      <!-- No right margin, and the form's own ScrollViewer carries the inset as
           Padding instead - the same construction Advanced and Compare use, and
           for the same reason. A ScrollViewer's Padding insets its CONTENT and
           not its scrollbar, so the bar lands hard against the window edge
           where every other application puts one. With the margin here it
           floated 20px in with a strip of empty page outside it, which reads as
           a layout that has come loose rather than as breathing room.
           Row 0 above needs no matching gutter: the hint it holds is collapsed,
           so there is nothing up there to line up with. -->
      <Grid Grid.Row="1" Margin="20,10,0,0">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>
        <ScrollViewer Name="UaIndexScroll" Grid.Column="0" Width="184" Margin="0,0,14,0"
                      VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
          <StackPanel Name="UaIndexPanel"/>
        </ScrollViewer>
        <Border Name="UaIndexRule" Grid.Column="1" Width="1" Margin="0,2,18,2"
                VerticalAlignment="Stretch"/>
        <ScrollViewer Name="UaScroll" Grid.Column="2" Padding="0,0,20,0"
                      VerticalScrollBarVisibility="Auto"
                      HorizontalScrollBarVisibility="Disabled">
          <!-- No right margin of its own: the Padding above is the whole inset,
               exactly as AdvContent takes its gap from AdvScroll's. -->
          <StackPanel Name="UaContent" Margin="0,0,0,20"/>
        </ScrollViewer>
      </Grid>

      <Border Grid.Row="2" Name="UaFooter" Padding="20,12" BorderThickness="0,1,0,0">
        <DockPanel LastChildFill="False">
          <TextBlock Name="TxtUaTally" VerticalAlignment="Center" FontSize="13"/>
          <Button Name="BtnUaWrite"   DockPanel.Dock="Right" Content="Write autounattend.xml" Padding="20,7" Margin="8,0,0,0" FontWeight="SemiBold"/>
          <!-- The expert's escape hatch, and the honest boundary of the form:
               this page cannot offer every element the schema has, so it offers
               the file it produced. -->
          <Button Name="BtnUaShow"    DockPanel.Dock="Right" Content="Show the file"          Padding="14,7" Margin="8,0,0,0"/>
          <Button Name="BtnUaBack"    DockPanel.Dock="Right" Content="Back"          Padding="14,7" Margin="8,0,0,0"/>
        </DockPanel>
      </Border>
    </Grid>

    <!-- ============================== RUN PAGE ============================= -->
    <Grid Name="PageRun" Grid.Row="1" Visibility="Collapsed">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>

      <StackPanel Grid.Row="0" Margin="20,16,20,10">
        <!-- Which selection this is. The page can be reached from the mode
             screen, from Advanced, from a loaded file and from Revert, and it
             used to name none of them - so a preview two hundred rows long was
             a list of changes with nothing saying whose. -->
        <TextBlock Name="TxtRunPreset" FontSize="12" Margin="0,0,0,5" Visibility="Collapsed"/>
        <TextBlock Name="TxtPhase" FontWeight="SemiBold" FontSize="15" Margin="0,0,0,6"/>
        <ProgressBar Name="BarOverall" Height="10" Minimum="0" Maximum="100" Value="0"/>
        <TextBlock Name="TxtCurrent" Margin="0,8,0,0" TextTrimming="CharacterEllipsis" FontSize="13"/>
        <Border Name="LegendBox" Margin="0,10,0,0" Padding="12,7" CornerRadius="6" BorderThickness="1">
          <WrapPanel Name="LegendPanel"/>
        </Border>
        <WrapPanel Name="StatsPanel" Margin="0,10,0,0"/>
        <!-- Narrowing the list. The status chips above already filter by
             outcome; these two answer the other two questions somebody has in
             front of two hundred rows - "where is X" and "show me the ones
             that did something". Inside the header stack rather than a row of
             its own, so the grid's row numbering is left alone. -->
        <DockPanel Name="RunFilterBar" Margin="0,10,0,0" LastChildFill="False" Visibility="Collapsed">
          <TextBlock Text="Sort" VerticalAlignment="Center" FontSize="12" Margin="0,0,7,0"
                     Foreground="{DynamicResource WdSub}"/>
          <ComboBox Name="CmbRunSort" Width="170" FontSize="12" VerticalAlignment="Center"/>
          <TextBlock Text="Search" VerticalAlignment="Center" FontSize="12" Margin="16,0,7,0"
                     Foreground="{DynamicResource WdSub}"/>
          <TextBox Name="TxtRunSearch" Width="240" FontSize="12" VerticalAlignment="Center" Padding="6,3"/>
          <TextBlock Name="TxtRunShown" VerticalAlignment="Center" FontSize="12" Margin="14,0,0,0"/>
        </DockPanel>
      </StackPanel>

      <Border Grid.Row="1" Margin="20,0,20,0" BorderThickness="1" Name="LogBorder" CornerRadius="6">
        <ListBox Name="LogList" BorderThickness="0" Background="Transparent"
                 ScrollViewer.HorizontalScrollBarVisibility="Disabled"
                 HorizontalContentAlignment="Stretch"/>
      </Border>

      <Border Grid.Row="2" Name="RunFooter" Padding="20,12" BorderThickness="0,1,0,0">
        <!-- Buttons are declared first so the DockPanel reserves their width
             before the two text blocks flow in from the left. -->
        <DockPanel LastChildFill="False">
          <Button Name="BtnApplyNow" DockPanel.Dock="Right" Content="Apply"           Padding="22,7" Margin="8,0,0,0" Visibility="Collapsed" FontWeight="Bold"/>
          <Button Name="BtnOpenLogs" DockPanel.Dock="Right" Content="Open log folder" Padding="14,7" Margin="8,0,0,0" IsEnabled="False"/>
          <!-- The run folder is under LOCALAPPDATA and will be deleted by
               "Delete old run logs" one day. Somebody who wants to keep the
               record of what happened to their machine should not have to know
               that. Appears only after an apply - there is nothing to save
               about a preview. -->
          <Button Name="BtnSaveNotes" DockPanel.Dock="Right" Content="Save what this did" Padding="14,7" Margin="8,0,0,0" Visibility="Collapsed"/>
          <Button Name="BtnBackRun"  DockPanel.Dock="Right" Content="Back"            Padding="14,7" Margin="8,0,0,0" IsEnabled="False"/>
          <Button Name="BtnCancel"   DockPanel.Dock="Right" Content="Cancel"          Padding="18,7" Margin="8,0,0,0"/>
          <!-- TxtRunNote keeps its own name and its place in the horizontal
               order, because the footer-geometry test measures it against the
               estimate and the buttons. TxtRunWrap sits under it rather than
               beside it: after an apply this carries what the card at the
               bottom used to, which is how that second bar goes away. -->
          <StackPanel VerticalAlignment="Center" MaxWidth="560">
            <TextBlock Name="TxtRunNote" TextWrapping="Wrap" FontSize="13"/>
            <TextBlock Name="TxtRunWrap" TextWrapping="Wrap" FontSize="12" Margin="0,5,0,0" Visibility="Collapsed"/>
          </StackPanel>
          <TextBlock Name="TxtRunEstimate" VerticalAlignment="Center" Margin="26,0,10,0" FontSize="13"
                     FontWeight="SemiBold" TextWrapping="Wrap" MaxWidth="230" Visibility="Collapsed"/>
        </DockPanel>
      </Border>

      <!-- The card that answers "what is it doing right now". It sits at the
           bottom because that is where the eye already is - the log fills
           downwards and the buttons are down here. A sibling of RunFooter
           rather than a child of it, so RunFooter.Child keeps its meaning for
           the footer-geometry test. -->
      <Border Grid.Row="3" Name="NowCard" Padding="20,10" BorderThickness="0,1,0,0" Visibility="Collapsed">
        <DockPanel LastChildFill="True">
          <Button Name="BtnSkipItem" DockPanel.Dock="Right" Content="Skip this one" Padding="12,5"
                  Margin="10,0,0,0" FontSize="12" Visibility="Collapsed"/>
          <TextBlock Name="TxtNowElapsed" DockPanel.Dock="Right" VerticalAlignment="Center"
                     Margin="10,0,0,0" FontSize="12" FontFamily="Consolas"/>
          <TextBlock Name="TxtNowHead" DockPanel.Dock="Left" VerticalAlignment="Center"
                     FontSize="12" FontWeight="SemiBold" Margin="0,0,10,0"/>
          <StackPanel>
            <TextBlock Name="TxtNowItem" FontSize="13" TextTrimming="CharacterEllipsis"/>
            <TextBlock Name="TxtNowNote" FontSize="12" TextWrapping="Wrap" Visibility="Collapsed" Margin="0,3,0,0"/>
          </StackPanel>
        </DockPanel>
      </Border>
    </Grid>
  </Grid>
</Window>
'@

function Show-WDWindow {
    param(
        [Parameter(Mandatory)]$Categories,
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)]$Profile,
        [Parameter(Mandatory)][string]$ModulePath,
        [Parameter(Mandatory)][string]$ManifestPath,
        $Scan,
        # id -> @{Present; Bytes; Blind}. Absent means no opinion about
        # anything, which is what -NoScan produces.
        $Presence,
        [string[]]$PreSelected,
        [int]$SelfTestSeconds = 0,
        $Splash,
        [string]$Theme,
        $UiState,
        # A finished run's folder: the window opens on the run page showing that
        # run rather than on the mode screen.
        [string]$ShowRun = ''
    )
    if (-not $UiState) { $UiState = Get-WDUiState }
    if (-not $Theme)   { $Theme = [string]$UiState.theme }

    # What the scan enumerated, so Test-WDItemApplies can answer its third
    # question - whether an item's packages are ones Windows refuses to remove.
    $machineInv = $null
    if ($Scan) { $machineInv = $Scan.Inventory }

    # The item list's most expensive question - 2,599 ms across the manifest -
    # moved off the UI thread. An id missing from the map is asked the old way,
    # so it cannot be wrong.
    $satisfiedJob = Start-WDSatisfiedScan -ModulePath $ModulePath -Categories $Categories `
                                          -Inventory $machineInv -Profile $Profile
    $satisfiedMap = $(if ($satisfiedJob) { $satisfiedJob.Map } else { @{} })

    # Building the rows is the visible part of the wait, and every second is
    # spent on this thread with the dispatcher blocked.
    $buildClock = [Diagnostics.Stopwatch]::StartNew()
    # One build per run now, so progress has one place to go: the splash.
    $steps = @{ Done = 0; Total = 24 }
    # Where the build's seconds go. Kept in rather than measured once and thrown
    # away.
    $phaseMs = [ordered]@{}
    $phaseAt = [Diagnostics.Stopwatch]::StartNew()
    $phaseNow = @{ Name = 'start' }
    $say = {
        param([string]$Text, [string]$Note)
        $steps.Done++
        $key = [string]$phaseNow.Name
        $phaseMs[$key] = [int]$phaseMs[$key] + [int]$phaseAt.ElapsedMilliseconds
        $phaseAt.Restart()
        $phaseNow.Name = $(if ($Note) { $Note } else { $Text })
        if ($Splash) { try { & $Splash.Status $Text $Note } catch { } }
    }
        & $say 'Building the interface' 'Window and theme'

    $pal   = Get-WDPalette -Theme $Theme
    # Kept by hex string, and frozen: a BrushConverter is a new object and a
    # string parse per call, and $paintPresetButton calls it once per card per
    # build.
    $brushOf = @{}
    $Brush = {
        param($hex)
        $k = [string]$hex
        $b = $brushOf[$k]
        if (-not $b) {
            $b = (New-Object Windows.Media.BrushConverter).ConvertFromString($k)
            if ($b.CanFreeze) { $b.Freeze() }
            $brushOf[$k] = $b
        }
        $b
    }

    # The page is loaded into a throwaway window and then moved: every element
    # is looked up here while the XAML namescope still exists, and nothing calls
    # FindName later.
    $shell = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader ([xml]$script:Xaml)))
    $win   = $shell
    # Set before the window is shown, so the taskbar button and the title bar
    # are right on the first frame.
    $appIcon = Get-WDAppIcon
    if ($appIcon) { $win.Icon = $appIcon }
    # The bag the window carries across rebuilds: the overlay, the current
    # dispatcher frame, and whatever this build wants done on close.
    if (-not $win.Tag) { $win.Tag = @{} }

    # Every palette entry is a keyed brush and everything that carries a colour
    # points at a key through $Ref, which is what makes a theme switch a repaint
    # rather than a rebuild.
    $themeDict = $(if ($win.Tag.ThemeDict) { $win.Tag.ThemeDict } else { New-Object Windows.ResourceDictionary })
    $win.Tag.ThemeDict = $themeDict
    foreach ($host_ in @($shell, $win)) {
        if (-not $host_.Resources.MergedDictionaries.Contains($themeDict)) {
            $host_.Resources.MergedDictionaries.Add($themeDict)
        }
    }

    # The colours a loaded preset can wear. They must differ from each other or
    # the Compare pickers become indistinguishable, and from the five shipped
    # ones.
    $LOADED_KEYS = @('L1', 'L2', 'L3', 'L4', 'L5', 'L6', 'L7', 'L8')
    $LOADED_HEX  = @('#FF8B5CD6', '#FF14919B', '#FFC9761F', '#FFB03A78',
                     '#FF3F7BD8', '#FF2E9E58', '#FFB5442F', '#FF7A6BC4')
    $paintTheme = {
        param($P)
        # This list is the dictionary. A palette entry not named here does not
        # become a brush, and $Ref throws on a key it cannot find.
        foreach ($k in @('Bg','Panel','Card','CardSel','Text','Sub','Line','Accent',
                         'Ok','Warn','Bad','Muted','Obstruct','RowHover','ScrollThumb','ScrollThumbHover',
                         'BtnBg','BtnBorder','BtnTint','FieldBg',
                         # The filled run button. Its own three entries rather
                         # than Accent plus a guess, because the ink that reads
                         # on it differs between palettes.
                         'GoBg','GoText','GoBorder',
                         'T1','T2','T3','T4')) {
            $themeDict["Wd$k"] = & $Brush ([string]$P[$k])
        }
        $themeDict['WdDiskUsers'] = & $Brush $(if ($P.Dark) { '#FFB08CE0' } else { '#FF7A4FC0' })
        foreach ($k in @('Warn','Bad','Ok','Accent')) {
            $themeDict["Wd${k}Tint"] = & $Brush ('#33' + ([string]$P[$k]).Substring(3))
        }
        # Half-strength preset colours, for edges that say which mode a card
        # belongs to without four saturated stripes down a page of eighty.
        foreach ($k in @('T1','T2','T3','T4','Sub')) {
            $themeDict["Wd${k}Soft"] = & $Brush ('#80' + ([string]$P[$k]).Substring(3))
        }
        # The colours a preset loaded from a file can wear, with the same
        # half-strength companions.
        for ($li = 0; $li -lt $LOADED_HEX.Count; $li++) {
            $themeDict["WdL$($li + 1)"]     = & $Brush $LOADED_HEX[$li]
            $themeDict["WdL$($li + 1)Soft"] = & $Brush ('#80' + $LOADED_HEX[$li].Substring(3))
        }
        # Not a palette entry: transparent to look at, still hit-testable, which
        # is what every clickable row and heading needs at rest.
        $themeDict['WdFlat'] = & $Brush '#01000000'
    }.GetNewClosure()
    & $paintTheme $pal
    # Published before anything can raise a dialog. Without a dictionary
    # Show-WDMessage falls back to the real MessageBox.
    Set-WDDialogHost -Dictionary $themeDict -Owner $win -Dark ([bool]$pal.Dark)

    # An exception inside a routed event handler is caught by nothing: WPF hands
    # it to the dispatcher, which has nowhere to put it, and the process ends.
    $faultText = {
        param($Ex)
        $parts = New-Object System.Collections.Generic.List[string]
        $walk = $Ex; $depth = 0
        while ($walk -and $depth -lt 5) {
            $parts.Add("$($walk.GetType().Name): $($walk.Message)")
            if ($walk.PSObject.Properties['ErrorRecord'] -and $walk.ErrorRecord -and
                [string]$walk.ErrorRecord.ScriptStackTrace) {
                foreach ($l in @(([string]$walk.ErrorRecord.ScriptStackTrace) -split "`r?`n" | Select-Object -First 4)) {
                    if ($l.Trim()) { $parts.Add("    $($l.Trim())") }
                }
            }
            $walk = $walk.InnerException; $depth++
        }
        ($parts -join "`r`n")
    }.GetNewClosure()

    # Shown once per distinct message: a handler that throws on MouseMove throws
    # hundreds of times, and a dialog per throw is worse than the crash.
    $seenFault = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $win.Dispatcher.Add_UnhandledException({
        $e = $args[1]
        try {
            $text = 'unknown'
            try { $text = [string](& $faultText $e.Exception) } catch { $text = [string]$e.Exception.Message }
            try { Write-WDLog "Unhandled interface fault: $text" -Level Error } catch { }
            $e.Handled = $true
            $key = [string]$e.Exception.Message
            if ($seenFault.Add($key)) {
                Show-WDMessage ((
                    "Something in the interface failed and the action you just took did not finish." +
                    "`r`n`r`nThe window is still open and nothing else has been affected - a run in " +
                    "progress carries on. If it keeps happening, the log has the details." +
                    "`r`n`r`n$text"), 'That did not work', 'OK', 'Error') | Out-Null
            }
        } catch {
            # The handler must never be the thing that takes the window down, so
            # a failure to report is swallowed.
            $e.Handled = $true
        }
    }.GetNewClosure())

    # Points a dependency property at a theme key instead of assigning a brush.
    $dpCache = @{}
    $Ref = {
        param($El, [string]$Prop, [string]$Key)
        if (-not $El) { return }
        # A DynamicResource that resolves to nothing is silent: the property
        # keeps its default, which for Foreground is black on a dark page.
        if (-not $themeDict.Contains("Wd$Key")) { throw "no theme key 'Wd$Key'" }
        $t  = $El.GetType()
        $ck = $t.FullName + '|' + $Prop
        $dp = $dpCache[$ck]
        if (-not $dp) {
            # System.ComponentModel, not System.Windows: it lives in WindowsBase
            # under the ComponentModel namespace.
            $dpd = [System.ComponentModel.DependencyPropertyDescriptor]::FromName($Prop, $t, $t)
            if (-not $dpd) { throw "'$Prop' is not a dependency property on $($t.Name)" }
            $dp = $dpd.DependencyProperty
            $dpCache[$ck] = $dp
        }
        $El.SetResourceReference($dp, "Wd$Key")
    }.GetNewClosure()

    $ui = @{}
    foreach ($n in @('Root','HeaderBar','HeaderTitle','HeaderMachine',
                     'PageHome','HomeScroll','TxtHomeHead','HomeGrid',
                     'PageModes','TxtModeHint','ModeScroll','ModeGrid','WarnBox','TxtModeWarning',
                     'BtnModesBack','TxtModesTitle','CmpPickBar','TxtCmpPick','BtnCmpPickCancel',
                     'LoadBox','TxtLoadHead','TxtModeHead','TxtLoadHint','BtnLoadPreset','BtnLoadAll','LoadedPanel',
                     'BtnRemovePreset','BtnRenamePreset','BtnRemoveAllPresets',
                     'PageUnattend','TxtUaHint','UaIndexScroll','UaIndexPanel','UaIndexRule','UaScroll','UaContent',
                     'UaFooter','TxtUaTally','BtnUaWrite','BtnUaShow','BtnUaBack',
                     'PageCompare',
                     'CmpIndexCol','CmpIndexScroll','CmpIndexPanel','CmpScroll','CmpIndexSplit','CmpIndexRule',
                     'CompareHead','CompareGrid','CompareFooter','TxtCompareTally','BtnCompareBack',
                     'TxtCompareNote','BtnCompareUndo',
                     'BtnCmpFilter','CmpFilterPopup','CmpFilterCard','CmpFilterPanel',
                     'BtnCmpFilterClear','BtnCmpFilterDone','LblCmpGroup','CmbCmpGroup',
                     'TxtCmpCount','LblCmpSearch','TxtCmpSearch',
                     'PageAdvanced','LblPreset','LblFilter','PresetBadge','TxtActivePreset',
                     'PresetRow','PresetScroll','BtnResetOne','TxtFilter',
                     'BtnFilter','TxtFilterCount','FilterPopup','FilterCard','FilterPanel','BtnFilterClear','BtnFilterDone',
                     'FilterChips','TxtPresetNote',
                     'LblOrder','CmbOrder','LblSort','CmbSort',
                     'AdvToolbar',
                     'AdvColumns','ColLeft','ColRight','ProtectedBlock','AlwaysBlock','AdvFooter',
                     'LblGroups','BtnCollapseAll','BtnExpandAll','BtnRefresh','BtnRevRefresh',
                     'IndexScroll','IndexPanel','IndexCol','IndexSplit','AdvScroll','AdvContent',
                     'AddColumns','AddLeft','AddRight','RemoveHeadBlock','AddHeadBlock','ExtraHeadBlock',
                     'RemoveGlyph','RemoveHead','AddGlyph','AddHead','ExtraGlyph','ExtraHead',
                     'RemoveBox','AddBox','ExtraBox','AppOptBox','AppOptGlyph','AppOptHead','AppOptRule',
                     'AppOptRule2','ChkDetailPopup','DetailPopupNote','ChkTerse','TerseNote',
                     'BtnTheme','BtnFactory','BtnClearLogs','BrowserAddBlock','ExtraColumns','ExtraLeft','ExtraRight',
                     'RunOptionsBlock','RunOptGlyph','RunOptHead','RunOptRule',
                     'StorageBlock','DiskCap','DiskBarFrame','DiskBar','DiskNote',
                     'ChkDownloads','ChkOwnership','LblOwnership','LblDownloads',
                     'LblAccountsHead','LblAccounts','AccountsBlock',
                     'BtnPreview','BtnSave','BtnBackModes','BtnAdvUndo','TxtAdvNote',
                     'PageRevert','RevertFooter','TxtRevertTally','BtnRevertRun','BtnRevertBack',
                     'PageRevertHome','TxtRevHomeTitle','TxtRevHomeHint','RevHomeScroll','RevHomeCards','BtnRevHomeBack',
                     'TxtRevertHead','TxtRevertSub','RevertRunScroll','RevertRunRow','RevertBar',
                     'BtnRevFilter','RevFilterPopup','RevFilterCard','RevFilterPanel','RevFilterChips',
                     'BtnRevFilterClear','BtnRevFilterDone','CmbRevOrder','CmbRevSort','BtnRevSelectAll',
                     'BtnRevCollapseAll','BtnRevExpandAll','TxtRevCount','RevFind',
                     'LblRevOrder','LblRevSort','LblRevGroups','LblRevFind',
                     'RevIndexCol','RevIndexScroll','RevIndexPanel','RevIndexRule','RevIndexSplit','RevScroll','RevList',
                     'PageRun','TxtPhase','BarOverall','TxtCurrent','LegendBox','LegendPanel',
                     'StatsPanel','LogList','LogBorder','RunFooter','TxtRunNote','TxtRunWrap','TxtRunEstimate','BtnCancel','BtnOpenLogs','BtnSaveNotes',
                     'TxtRunPreset','RunFilterBar','CmbRunSort','TxtRunSearch','TxtRunShown',
                     'BtnApplyNow','BtnBackRun',
                     'NowCard','TxtNowHead','TxtNowItem','TxtNowNote','TxtNowElapsed','BtnSkipItem')) {
        $ui[$n] = $shell.FindName($n)
    }

    & $Ref $ui.Root 'Background' 'Bg'
    foreach ($b in @('HeaderBar','AdvToolbar','AdvFooter','RunFooter','RevertFooter','CompareFooter','UaFooter','NowCard')) {
        & $Ref $ui[$b] 'Background' 'Panel'
        & $Ref $ui[$b] 'BorderBrush' 'Line'
    }
    foreach ($b in @('LogBorder','LegendBox')) {
        & $Ref $ui[$b] 'BorderBrush' 'Line'
        & $Ref $ui[$b] 'Background' 'Panel'
    }
    # The home page opens with the drive bar down: what a run does to this disk
    # is not a question two of the three cards are about.
    $ui.StorageBlock.Visibility = 'Collapsed'
    & $Ref $ui.CmpPickBar 'Background' 'CardSel'
    & $Ref $ui.CmpPickBar 'BorderBrush' 'Accent'
    & $Ref $ui.TxtCmpPick 'Foreground' 'Text'
    & $Ref $ui.TxtHomeHead 'Foreground' 'Text'
    & $Ref $ui.TxtModesTitle 'Foreground' 'Text'
    # Declared in the XAML and then painted by nothing, which on the dark
    # palette is black on near-black.
    & $Ref $ui.TxtRevHomeTitle 'Foreground' 'Text'
    & $Ref $ui.TxtRevHomeHint  'Foreground' 'Sub'
    # The run buttons, filled. Preview is the only way into an apply and was the
    # same gray as Back beside it.
    foreach ($b in @('BtnModePreview', 'BtnPreview', 'BtnApplyNow')) {
        if (-not $ui[$b]) { continue }
        & $Ref $ui[$b] 'Background'  'GoBg'
        & $Ref $ui[$b] 'Foreground'  'GoText'
        & $Ref $ui[$b] 'BorderBrush' 'GoBorder'
    }
    & $Ref $ui.LoadBox 'Background' 'Card'
    & $Ref $ui.LoadBox 'BorderBrush' 'Line'
    & $Ref $ui.TxtLoadHint 'Foreground' 'Sub'
    foreach ($t in @('HeaderTitle','TxtPhase','LblPreset','LblFilter','LblOrder','LblSort','LblGroups','TxtCompareTally',
                     'LblCmpGroup','LblCmpSearch','TxtLoadHead','TxtModeHead')) {
        # 'Text', not 'Accent': bold and a point of size already separate these
        # from the muted lines around them.
        & $Ref $ui[$t] 'Foreground' 'Text'
    }
    foreach ($t in @('HeaderMachine','TxtCurrent','TxtRunNote','TxtRevertTally',
                     'TxtUaHint','TxtUaTally','TxtRunPreset','TxtRunWrap','TxtRunShown',
                     'TxtNowHead','TxtNowElapsed','TxtNowNote')) {
        & $Ref $ui[$t] 'Foreground' 'Sub'
    }
    # The paragraph the mode screen opens with, and the first thing anybody
    # reads.
    & $Ref $ui.TxtModeHint 'Foreground' 'Text'
    & $Ref $ui.TxtNowItem 'Foreground' 'Text'
    & $Ref $ui.TxtRunEstimate 'Foreground' 'Text'
    & $Ref $ui.ChkDownloads 'Foreground' 'Text'
    & $Ref $ui.ChkOwnership 'Foreground' 'Text'
    # A CheckBox keeps the system foreground unless given one, and the system
    # foreground is black.
    & $Ref $ui.RunOptHead 'Foreground' 'Text'
    $ui.RunOptGlyph.Text        = Get-WDCategoryGlyph -Id 'runopts'
    & $Ref $ui.RunOptRule 'Background' 'Line'
    # Painted here rather than in the XAML because the colour is a palette key.
    & $Ref $ui.CmpIndexRule 'Background' 'Line'
    & $Ref $ui.DiskCap 'Foreground' 'Sub'
    & $Ref $ui.DiskNote 'Foreground' 'Sub'
    # Frozen and put in as a resource rather than assigned, because a thumb
    # inside a template cannot be reached any other way.

    & $Ref $ui.DiskBarFrame 'BorderBrush' 'Line'
    # Never assigned a brush, so the run page's progress bar rendered the system
    # light track on a dark page.
    & $Ref $ui.BarOverall 'Foreground' 'Accent'
    & $Ref $ui.BarOverall 'Background' 'Card'
    & $Ref $ui.BarOverall 'BorderBrush' 'Line'
    # Free space is the frame showing through, so it needs a colour of its own
    # rather than the panel it sits on.
    & $Ref $ui.DiskBarFrame 'Background' 'Bg'
    foreach ($t in @('LblOwnership','LblDownloads','LblAccounts')) {
        & $Ref $ui[$t] 'Foreground' 'Sub'
    }
    & $Ref $ui.LblAccountsHead 'Foreground' 'Text'
    $ui.RemoveGlyph.Text = Get-WDCategoryGlyph -Id 'section-remove'
    $ui.AddGlyph.Text    = Get-WDCategoryGlyph -Id 'section-add'
    $ui.ExtraGlyph.Text  = Get-WDCategoryGlyph -Id 'extras'
    $ui.AppOptGlyph.Text = Get-WDCategoryGlyph -Id 'runopts'
    # Glyphs are text, and text with no Foreground is black. Most are colour
    # emoji that ignore it - the monochrome ones do not.
    foreach ($t in @('RemoveGlyph','AddGlyph','ExtraGlyph','AppOptGlyph','RunOptGlyph')) {
        & $Ref $ui[$t] 'Foreground' 'Text'
    }
    foreach ($t in @('RemoveHead','AddHead','ExtraHead','AppOptHead')) { & $Ref $ui[$t] 'Foreground' 'Text' }
    & $Ref $ui.AppOptRule 'Background' 'Line'
    & $Ref $ui.AppOptRule2 'Background' 'Line'
    # There is no implicit CheckBox style in this window, and WPF's default
    # Foreground is the system control-text brush.
    & $Ref $ui.ChkDetailPopup 'Foreground' 'Text'
    & $Ref $ui.DetailPopupNote 'Foreground' 'Sub'
    & $Ref $ui.ChkTerse 'Foreground' 'Text'
    & $Ref $ui.TerseNote 'Foreground' 'Sub'
    # The section boxes carry the eye down the page, so their edge is the only
    # thing drawn in the accent colour.
    foreach ($b in @('RemoveBox','AddBox','ExtraBox')) {
        & $Ref $ui[$b] 'BorderBrush' 'Line'
        & $Ref $ui[$b] 'Background' 'Panel'
    }
    & $Ref $ui.AppOptBox 'BorderBrush' 'Line'
    # Names the theme you would get, not the one you are in.
    $ui.BtnTheme.Content = if ($pal.Dark) { 'Switch to light theme' } else { 'Switch to dark theme' }
    foreach ($c in @('TxtFilter')) {
        & $Ref $ui[$c] 'Background' 'Card'
        & $Ref $ui[$c] 'Foreground' 'Text'
        & $Ref $ui[$c] 'BorderBrush' 'Line'
    }
    # No Foreground override on BtnFilter: buttons keep the system chrome, which
    # is light with dark text.
    & $Ref $ui.TxtFilterCount 'Foreground' 'Sub'
    & $Ref $ui.FilterCard 'Background' 'Card'
    & $Ref $ui.FilterCard 'BorderBrush' 'Line'
    & $Ref $ui.CmpFilterCard 'Background' 'Card'
    & $Ref $ui.CmpFilterCard 'BorderBrush' 'Line'
    & $Ref $ui.TxtCmpCount 'Foreground' 'Sub'
    & $Ref $ui.WarnBox 'Background' 'Panel'
    & $Ref $ui.WarnBox 'BorderBrush' 'Bad'
    & $Ref $ui.TxtModeWarning 'Foreground' 'Bad'

    $ui.HeaderMachine.Text = '{0}  |  {1} {2} (build {3}.{4})  |  {5} {6}  |  {7}' -f
        $Profile.ComputerName, $Profile.Caption, $Profile.DisplayVersion, $Profile.Build, $Profile.UBR,
        $Profile.Manufacturer, $Profile.Model, $(if ($Profile.IsPortable) { 'laptop' } else { 'desktop' })

    # Custom is a GUI-only column, not a rung on the engine's ladder.
    $ladderNames = @(Get-WDPresetNames)
    # Theme keys, not colours, so a preset's colour follows the palette without
    # this table being rebuilt.
    $presetColor = @{ Conservative = 'T1'; Balanced = 'T2'; Aggressive = 'T3'; Extreme = 'T4'
                      Custom = 'Sub' }
    # Custom at the far left, opposite Extreme: one selects nothing, the other
    # everything, and the ladder runs between them.
    $presetNames = New-Object System.Collections.Generic.List[string]
    foreach ($n in @(@('Custom') + $ladderNames)) { $null = $presetNames.Add([string]$n) }
    # The shipped five, kept separately: the mode grid builds its columns from
    # this, so loading a file never widens it.
    $shippedNames = @(@('Custom') + $ladderNames)
    # name -> @{ Path; Ids; Ink }. Ordered so the box lists them as loaded and
    # the settings file round-trips in the same order.
    $loadedPresets = [ordered]@{}

    # Which presets have actually been run here. Persisted, unlike an override:
    # an edit is something somebody might not have meant to keep, and a run is a
    # thing that happened.
    $appliedRuns = @{}
    if ($UiState -and $UiState.PSObject.Properties['applied'] -and $UiState.applied) {
        foreach ($p in @($UiState.applied.PSObject.Properties)) {
            if (-not $p -or -not [string]$p.Name) { continue }
            try {
                $appliedRuns[[string]$p.Name] = @{
                    When    = [string]$p.Value.When
                    Folder  = [string]$p.Value.Folder
                    Run     = [string](Get-Prop $p.Value 'Run' '')
                    Machine = $(if ($p.Value.PSObject.Properties['Machine']) { $p.Value.Machine } else { $null })
                    Ids     = @($p.Value.Ids | ForEach-Object { [string]$_ })
                }
            } catch { }
        }
    }

    # How much of each recorded run is still in place, for the marker on the
    # mode cards. Read from here only - the answer costs about 1.8 seconds and
    # this paints on the startup path.
    $appliedState = @{}
    $appliedWant  = New-Object System.Collections.Generic.List[string]
    # $LOADED_KEYS and $LOADED_HEX are declared above $paintTheme, which reads
    # them and cannot see anything written below itself.
    $PRESET_NAME_MAX  = 12
    $PRESET_NAME_HOME = 50
    # name -> what to print where twelve characters is the budget. Derived once
    # at registration, so two files differing past the twelfth character cannot
    # draw identical buttons.
    $shortOf = @{}
    $shortPreset = {
        param([string]$Name)
        if ($shortOf.ContainsKey($Name)) { return [string]$shortOf[$Name] }
        [string]$Name
    }.GetNewClosure()
    # Custom selects no removals, but it is not a mode that does nothing - the
    # run's own guarantees still apply.
    $presetBlurb = @{ Custom = 'Creates a system restore point, tracks every change and writes a rollback script, blocks all Windows reinstall attempts, and produces a lookup file for common issues and how to revert individual options yourself.' }
    # What is left to warn about since the scanner's finds went to tier 0.
    $extremeWarning = 'Extreme switches off services and features other software quietly depends on. Use Show all options on the card and read the list before you preview it.'
    foreach ($p in $ladderNames) { $presetBlurb[$p] = (Get-WDPresetInfo -Name $p).Blurb }

    $state = [pscustomobject]@{
        Sync = [hashtable]::Synchronized(@{
            Queue = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
            Cancel = $false; Done = $false; Error = $null
            # Set by the Skip button, read by the engine between the actions of
            # the item running.
            SkipItem = $false
            # The background runspace has its own session, so its run folder and
            # reboot flag are not the ones this thread can see.
            RunDir = $null; Reboot = $false; NotesFile = $null; RestartCount = 0; KeepDir = $null
            # Whether the rollback script actually got written. It is an option
            # with a row now, so the closing notice has to ask.
            HasUndo = $false
            # 'ok', 'failed', or empty for a run that never tried.
            RestorePoint = '' })
        Runspace = $null; Shell = $null; Handle = $null
        Preview = $true; Mode = 'debloat'
        Counts = @{ Removed=0; Changed=0; AlreadySet=0; NotPresent=0; Skipped=0; Obstruction=0; Partial=0; Blocked=0; Failed=0 }
        # NowSince is $null whenever nothing is running, which is what stops the
        # clock.
        NowItem = ''
        NowSince = $null
        # How far the run actually got. The progress bar is driven to its
        # maximum the moment a run ends, whether it finished or was cancelled.
        RunIndex = 0
        RunTotal = 0
        # Apply is only reachable through a simulation, so this is what its
        # confirmation has to name.
        RunLabel = ''
        # A finished apply has to be acknowledged before the window closes
        # without asking; a simulation changed nothing.
        Acknowledged = $true
        # A saved name that is no longer a mode falls back rather than throwing.
        Preset = $(if ([string]$UiState.preset -and [string]$UiState.preset -in @(Get-WDPresetNames) + @('Custom')) { [string]$UiState.preset } else { 'Balanced' })
        Modified = $false
        Suspend = $false
        LastSelection = @()
        Excluded = New-Object System.Collections.Generic.HashSet[string]
        EstimateSeconds = 0.0
        ReturnPage = 'PageModes'
        # Two settings because they are two questions - see $GROUPS and $SORTS.
        Group = $(if ([string]$UiState.group) { [string]$UiState.group }
                  elseif ([string]$UiState.sort) { [string]$UiState.sort } else { 'category' })
        Sort  = $(if ([string]$UiState.sortBy) { [string]$UiState.sortBy } else { 'name' })
        # In-line is the shipped answer; this is for somebody who would rather
        # have the dialog.
        DetailPopup = [bool](Get-Prop $UiState 'detailPopup' $false)
        # Non-verbose takes away the text that is the same on every visit.
        # Stored as the positive of the non-default, so a file written before
        # the default changed cannot hold somebody at the old behaviour.
        Terse = -not [bool](Get-Prop $UiState 'verbose' $false)
        # A list: one browser being installed is no reason not to install a
        # second.
        BrowserChoices = @()
        # What the user picked, as opposed to what is queued now. $null means
        # nobody has ever picked; an empty list means they chose None.
        BrowserPreferred = $null
        # Null means nobody has said, so the preset decides. Once the user ticks
        # the box their answer outlives every mode switch.
        OwnershipChoice = $null
        # True while the queued browser is the one picked on the user's behalf.
        # A deliberate pick clears it, and only an automatic one is withdrawn.
        BrowserAuto   = $false
        BrowserAsked  = $false
        SyncingBrowser = $false
        # Which Edge extensions were ticked because Edge removal was, so backing
        # out withdraws exactly those and leaves a deliberate tick alone.
        EdgeExtAuto = @()
        EdgeExtOn   = $false
        # True only while a whole mode is being written into the tick boxes: how
        # a gesture is told from a state.
        PresetSweep = $false
        # The interaction harness drives real routed events, and a modal dialog
        # would block the dispatcher with nobody to dismiss it.
        NoPrompts = ($SelfTestSeconds -gt 0)
        # True while the page is being assembled. Every route into $syncBrowser
        # is a gesture except the opening restore.
        Building = $true
        # Switching repaints in place, so there is no second build and nothing
        # for the caller to be told about.
        Theme   = $(if ($pal.Dark) { 'dark' } else { 'light' })
        # Whether the current order keeps the Remove / Add / Extras split.
        Sectioned = $true
        # Ids the current grouping does not lay out at all - not the same as
        # filtered away, and every count on the page has to know the difference.
        OffPage = New-Object System.Collections.Generic.HashSet[string]
        # The manifest carries a default for every caller with no GUI; this is
        # what the strips collect.
        DeferDays = @{
            Feature = $(if ([int](Get-Prop $UiState 'deferFeatureDays' 0) -gt 0) { [int]$UiState.deferFeatureDays } else { 365 })
            Quality = $(if ([int](Get-Prop $UiState 'deferQualityDays' 0) -gt 0) { [int]$UiState.deferQualityDays } else { 7 })
        }
        # Remembered between sessions, because it is a decision rather than a
        # state of the machine.
        DefaultBrowser = [string](Get-Prop $UiState 'defaultBrowser' '')
        # There was an IssuesFolder here and a folder picker beside the row.
        # Both went when every apply started leaving a folder on the desktop.
    }
    $EDGE_ID    = 'remove-edge'
    $BROWSER_ID = 'install-browser'

    # Every preset button carries its mode's colour on its edge. Buttons keep
    # the system chrome otherwise, and painting their Foreground gives white on
    # white.
    $paintPresetButton = {
        param($Button, [string]$Name, [bool]$Selected)
        # A theme key through $Ref, like everything else that carries a colour.
        $key = [string]$presetColor[$Name]
        if (-not $key) { $key = 'Sub' }
        & $Ref $Button 'BorderBrush' $key
        $Button.BorderThickness = New-Object Windows.Thickness $(if ($Selected) { 2 } else { 1 })
        $Button.FontWeight      = if ($Selected) { 'Bold' } else { 'Normal' }
    }
    # Filled by $buildAdvPresetRow rather than written out, because the row is
    # no longer a fixed five.
    $advPresetButtons = [ordered]@{}
    $paintAdvancedPresets = {
        foreach ($n in @($advPresetButtons.Keys)) {
            & $paintPresetButton $advPresetButtons[$n] $n ($state.Preset -eq $n)
        }
    }
    # The mode grid is built - and $selectPreset runs - long before the Advanced
    # rows exist, so the coupling cannot be a plain variable.
    $browserSync = @{ Fn = $null }
    # $selectPreset has to repaint the box of loaded selections, and it is
    # written above it.
    $loadedRef   = @{ Paint = $null }
    # The category headings are built before $updateTally exists, and their
    # click handlers call it.
    $updateTallyRef = @{ Fn = $null }
    # Every row and heading is built before the undo stack exists, and all of
    # them record into it.
    $advUndoRef = @{ Push = $null }
    # Dependent rows re-run the filter when their parent is ticked, and it is
    # built long after they are.
    $applyFilterRef = @{ Fn = $null }
    # $paintStorage needs to reach it and is defined long before the ordering
    # block that fills it in.
    $applyOrderRef  = @{ Fn = $null }
    # Built after the category rows exist, but repainted and invalidated from
    # code above it.
    $indexRef       = @{ Paint = $null; Invalidate = $null; Spy = $null }
    # The rail is rebuilt per order, from $applyOrder, which is declared far
    # below the rail itself.
    $railRef        = @{ Rebuild = $null }
    # Fn decides which resets are on screen and Do is what the button does; both
    # are written below every heading that needs them.
    $groupResetRef  = @{ Fn = $null; Do = $null }
    # Only the storage grouping needs its cached partition thrown away, and it
    # needs it badly: its two bands are decided by sizes that arrive later.
    $groupsRef      = @{ Drop = $null }
    # The per-row strips follow a tick, and $updateTally is declared above the
    # strips themselves.
    $syncStripsRef  = @{ Fn = $null }

    # 1 data collection, 2 advertises, 3 software you did not ask for, 4 legacy
    # and leftovers, 5 sometimes useful, 6 not recommended.
    # A list of pairs, not an ordered dictionary: that has both an Item[object]
    # and an Item[int] indexer, so an integer key binds to the position overload
    # and every band comes out labelled with its neighbour's name.
    $BLOAT_BAND = @(
        @{ B = 1;      N = 'Data collection' }
        @{ B = 2;      N = 'Advertising and nagging' }
        @{ B = 3;      N = 'Bloatware' }
        @{ B = 4;      N = 'Legacy and leftovers' }
        @{ B = 5;      N = 'Sometimes useful' }
        @{ B = 6;      N = 'Not recommended' }
        @{ B = 0;      N = 'Not a removal - unrated' }
        @{ B = 'apps'; N = 'Your apps' }
    )
    $BLOAT_RATED = @($BLOAT_BAND | Where-Object { $_.B -is [int] -and [int]$_.B -gt 0 })
    # Keys are stringified because one of them is 'apps' and the rest are
    # numbers.
    $bandName = @{}
    foreach ($band in $BLOAT_BAND) { $bandName[[string]$band.B] = [string]$band.N }
    # Software the scan found rather than the manifest naming, minus the vendor
    # bucket - preinstalled OEM software is exactly what band 3 says.
    $YOUR_APP_CATS = @('discovered-apps', 'discovered-services', 'discovered-extensions')
    # Not simply $Row.Bloat: a rating answers "how bad is it that this is here",
    # which does not apply to a run switch or to software the operator chose.
    $bandOf = {
        param($Row)
        # Band 6 outranks every other rule: "we think you should not do this" is
        # as true of a run switch as of a removal.
        if ([int]$Row.Bloat -eq 6) { return 6 }
        if ($YOUR_APP_CATS -contains [string]$Row.CatId) { return 'apps' }
        # Extras otherwise scatters through the ratings on whatever number it
        # was authored with.
        if ([string]$Row.Section -ne 'remove') { return 0 }
        [int]$Row.Bloat
    }.GetNewClosure()

    # Everything the manifest carries, applicable or not, so a loaded selection
    # can tell "dropped because it does not apply" from "not in this build".
    $catIdByName = @{}
    foreach ($c in $Categories) { $catIdByName[[string]$c.name] = [string]$c.id }

    $applicable = New-Object System.Collections.Generic.List[psobject]
    $allItems = @{}
    foreach ($cat in $Categories) {
        foreach ($item in @($cat.items)) {
            $allItems[[string]$item.id] = $item
            # The replacement browser is never listed or counted on its own: it
            # is chosen under Edge removal and threaded into the run from there.
            if ([string]$item.id -eq $BROWSER_ID) { continue }
            if (-not (Test-WDItemApplies -Item $item -Profile $Profile -Inventory $machineInv)) { continue }
            # Risk and presence ride along so the mode columns can say what a
            # mode costs without a second walk of the manifest.
            $pres = $null
            if ($Presence -and $Presence.ContainsKey([string]$item.id)) {
                $pres = $Presence[[string]$item.id].Present
            }
            $applicable.Add([pscustomobject]@{
                Id = [string]$item.id; Tier = (Get-WDItemTier -Item $item); Cat = [string]$cat.name
                Risk = [int](Get-Prop $item 'risk' 0); Present = $pres
                # The three fields $bandOf reads, so the columns can count by
                # band without a second walk.
                Band = [string](& $bandOf ([pscustomobject]@{
                    Bloat   = [int](Get-Prop $item 'bloat' 0)
                    CatId   = [string]$cat.id
                    Section = [string](Get-WDItemSection -Item $item -Category $cat)
                })) })
        }
    }

    # Every extension the scan found belonging to Edge. Read off the discovered
    # item's own browser field rather than the "(Edge)" its name ends with - a
    # label is the wrong thing to decide from, and it is the half that gets
    # translated.
    $edgeExtIds = New-Object System.Collections.Generic.List[string]
    foreach ($item in $allItems.Values) {
        if ([string](Get-Prop $item 'browser' '') -eq 'Edge') { $edgeExtIds.Add([string]$item.id) }
    }

    # Authored, and briefly generated instead: a count per bloat band says how
    # much of each kind a mode takes and never says what any of it is.
    $presetBullets = @{
        Custom       = @()
        Conservative = @(
            'Copilot app, taskbar entry, and key (now right ctrl)'
            'Notepad, Paint, and Photos AI features'
            'Everything McAfee'
            'All pre-installed games'
            'Microsoft 365 ads'
            '"Finish setting up your device"'
            '"recommendations" in File Explorer, Settings, Start'
            'OneDrive (preserves local leftover folders)'
            'Duolingo, Dropbox, Amazon, Instagram, etc'
        )
        Balanced = @(
            'Xbox game bar and Xbox startup services'
            'To Do, Movies and TV, Phone Link, and Quick Assist'
	    'Windows AI fabric service'
	    'Shared experiences and Nearby sharing'
	    'Widgets board and Windows Web Experience Pack'
	    'Stops apps from reading notifications'
	    'Sticky keys shortcut disabled'
	    'Windows 10 context menu, file extensions on, clean taskbar'
        )
        Aggressive = @(
            'CoreAI system package'
            'Edge, and all of its reinstall attempts'
            'Vendor security agents'
            'Deletes leftover OneDrive folders'
            'Background app permissions'
            'Non-essential apps denied startup run access'
	    'File explorer opens to This PC'
	    'Kill task added as taskbar right-click option'
        )
        Extreme = @(
            'Re-applies removal selection after a Windows feature update'
            'Fast startup disabled'
            'Biometric services'
            'Windows Search indexing'
            'Xbox Game Pass'
            'Location services'
	    'Clears all existing history, everywhere'
	    'Defer Windows feature updates'
	    'Everything is permanently trashed - no reversion'
        )
    }
    $itemCat   = @{}
    $catTotals = @{}
    foreach ($a in $applicable) {
        $itemCat[$a.Id] = $a.Cat
        if (-not $catTotals.ContainsKey($a.Cat)) { $catTotals[$a.Cat] = 0 }
        $catTotals[$a.Cat]++
    }

    # Custom's base is empty of removals by definition, with two exceptions its
    # own column promises.
    $CUSTOM_BASE = @('rollback-script', 'issues-doc')
    $baseIds = @{ Custom = @($applicable | Where-Object { $CUSTOM_BASE -contains $_.Id } | ForEach-Object { $_.Id }) }
    foreach ($p in $ladderNames) {
        $lvl = (Get-WDPresetInfo -Name $p).Level
        $baseIds[$p] = @($applicable | Where-Object { $_.Tier -ne 0 -and $_.Tier -le $lvl } | ForEach-Object { $_.Id })
    }

    # Three layers: $baseIds is what the manifest ships, $presetDefaults is what
    # this person redefined the preset to be, $overrides is edits on top still
    # shown as edits.
    $presetDefaults = ConvertTo-WDPresetMap $UiState.presetDefaults
    $overrides      = @{}

    # Declared here rather than beside the code that uses them, because
    # GetNewClosure captures the local scope as it stands and $dropLoaded clears
    # these.
    $counts      = @{}
    $totDelta    = @{}       # preset -> @{ Added; Removed }, edits only
    $consequence = @{}       # preset -> @{ Risky; Here }
    # The two sides of the Compare page, up here for the same reason: a preset
    # can be taken away while it is sitting in one of these slots.
    $cmpState = @{ A = 'Balanced'; B = 'Aggressive' }

    $knownIds = New-WDStringSet @($applicable | ForEach-Object { [string]$_.Id })

    # Why one id in a saved selection did not survive the load, in a sentence:
    # an id is not something anybody can look up.
    $dropReason = {
        param([string]$Id)
        $item = $allItems[$Id]
        if (-not $item) {
            return 'no option with this id exists in this version of the toolkit - the file was probably saved by a different build'
        }
        if ([string]$Id -eq $BROWSER_ID) {
            return 'the replacement browser is chosen under Edge removal rather than selected on its own'
        }
        $why = ''
        try { $why = [string](Get-WDGuardFailure -Guards @(Get-Prop $item 'guards' @()) -Profile $Profile) } catch { }
        if ($why) { return $why }
        # Item guards passed, so the block is one level down: every action is
        # either guarded off or inert on this machine.
        return 'nothing it does can run on this machine - every step it takes is either for a different edition of Windows or aimed at something Windows will not let go of here'
    }.GetNewClosure()

    $registerLoaded = {
        param([string]$Path)
        $raw = $null
        try { $raw = Import-WDSelection -Path $Path } catch { $raw = $null }
        if ($null -eq $raw) { return $null }
        $keep = @(@($raw) | Where-Object { $knownIds.Contains([string]$_) } | ForEach-Object { [string]$_ })
        # Recorded at the moment they are dropped, with the name the file cannot
        # carry.
        $lost = New-Object System.Collections.Generic.List[psobject]
        foreach ($id in @(@($raw) | ForEach-Object { [string]$_ })) {
            if ($knownIds.Contains($id)) { continue }
            $nm = $id
            if ($allItems.ContainsKey($id)) { $nm = [string](Get-Prop $allItems[$id] 'name' $id) }
            $lost.Add([pscustomobject]@{ Id = $id; Name = $nm; Why = [string](& $dropReason $id) })
        }
        $stem = [IO.Path]::GetFileNameWithoutExtension($Path)
        if (-not $stem) { $stem = 'Loaded selection' }
        # One truncation helper at both budgets. The ellipsis counts toward the
        # cap, so the cap is what the name occupies.
        $cut = {
            param([string]$S, [int]$Max)
            if ($S.Length -le $Max) { return $S }
            $S.Substring(0, $Max - 1).TrimEnd() + [char]0x2026
        }
        $stem = [string](& $cut $stem $PRESET_NAME_HOME)
        # Names are the key everywhere, so a second file with the same stem
        # cannot quietly replace the first.
        $name = $stem
        $n = 2
        while ($presetNames -contains $name) {
            if ($loadedPresets.Contains($name) -and [string]$loadedPresets[$name].Path -eq $Path) { return $name }
            # The suffix counts toward the cap, so the stem gives way to it
            # rather than the pair running over.
            $suffix = " ($n)"
            $head = $stem
            if ($head.Length + $suffix.Length -gt $PRESET_NAME_HOME) {
                $head = $head.Substring(0, [Math]::Max(1, $PRESET_NAME_HOME - $suffix.Length))
            }
            $name = "$head$suffix"; $n++
        }
        # And the short form is made unique among the short forms, not against
        # $presetNames: two files differing past the twelfth character would
        # draw identical buttons.
        $short = [string](& $cut $stem $PRESET_NAME_MAX)
        $taken = @(@($shortOf.Values) + @($shippedNames))
        $m = 2
        while ($taken -contains $short) {
            $suffix = " ($m)"
            $head = [string](& $cut $stem $PRESET_NAME_MAX)
            if ($head.Length + $suffix.Length -gt $PRESET_NAME_MAX) {
                $head = $head.Substring(0, [Math]::Max(1, $PRESET_NAME_MAX - $suffix.Length))
            }
            $short = "$head$suffix"; $m++
        }
        $shortOf[$name] = $short
        # The first ink nobody is wearing, not the count modulo the palette:
        # modulo counts how many are loaded, which is a different question once
        # one has been removed.
        $inUse = @($loadedPresets.Keys | ForEach-Object { [string]$loadedPresets[$_].Key })
        $ink = -1
        for ($i = 0; $i -lt $LOADED_KEYS.Count; $i++) {
            if ($inUse -notcontains [string]$LOADED_KEYS[$i]) { $ink = $i; break }
        }
        if ($ink -lt 0) { $ink = $loadedPresets.Count % $LOADED_KEYS.Count }
        $loadedPresets[$name] = @{ Path = [string]$Path; Ids = $keep; Total = @($raw).Count
                                    Dropped = @($lost)
                                    Key = [string]$LOADED_KEYS[$ink]; Hex = [string]$LOADED_HEX[$ink] }
        $baseIds[$name]     = $keep
        $presetColor[$name] = [string]$LOADED_KEYS[$ink]
        $null = $presetNames.Add($name)
        $name
    }.GetNewClosure()

    $dropLoaded = {
        param([string]$Name)
        if (-not $loadedPresets.Contains($Name)) { return }
        $loadedPresets.Remove($Name)
        $baseIds.Remove($Name)
        # Freed as well as forgotten: the short form is unique among the short
        # forms, so leaving a removed preset's in the table gives the next file
        # a "(2)" with no sibling.
        if ($shortOf.ContainsKey($Name)) { $shortOf.Remove($Name) }
        $presetColor.Remove($Name)
        $null = $presetNames.Remove($Name)
        # Its edits go with it: loading the same file tomorrow must not arrive
        # pre-edited by a session nobody remembers.
        foreach ($h in @($presetDefaults, $overrides)) { if ($h.ContainsKey($Name)) { $h.Remove($Name) } }
        # So does the record of it having been run.
        if ($appliedRuns.ContainsKey($Name)) { $appliedRuns.Remove($Name) }
        # And every derived table keyed on it. $recount rebuilds two of these
        # from $presetNames, but $counts is filled in place and would keep the
        # entry for ever.
        foreach ($h in @($counts, $consequence, $totDelta)) { if ($h.ContainsKey($Name)) { $h.Remove($Name) } }
        # Nothing is left pointing at it: loading a file selects it on the way
        # in, so load-look-remove hit the dangling name every time, and it
        # failed at whatever read the name next.
        if ([string]$state.Preset -eq $Name) { $state.Preset = 'Balanced' }
        if ([string]$cmpState.A -eq $Name)   { $cmpState.A   = 'Balanced' }
        if ([string]$cmpState.B -eq $Name)   { $cmpState.B   = 'Aggressive' }
    }.GetNewClosure()

    # A loaded preset saved to a different file used to become that file -
    # renamed, re-pointed, and the original gone from the list.

    foreach ($p in @($UiState.loadedPresets)) {
        if (-not [string]$p) { continue }
        $null = & $registerLoaded ([string]$p)
    }
    # A file moved or deleted since last time takes its preset with it, and the
    # window may have been left sitting on it.
    if ([string]$state.Preset -notin $presetNames) { $state.Preset = 'Balanced' }

    foreach ($h in @($presetDefaults, $overrides)) {
        foreach ($k in @($h.Keys)) { if ($k -notin $presetNames) { $h.Remove($k) } }
    }

    $applyLayer = {
        param($Set, $Layer, [string]$Name)
        if (-not $Layer.ContainsKey($Name)) { return }
        foreach ($id in $Layer[$Name].Removed) { $null = $Set.Remove($id) }
        foreach ($id in $Layer[$Name].Added)   { $null = $Set.Add($id) }
    }
    # One-directional and stated as such: When wins, Blocks goes, and Why is
    # printed on the row that went.
    $EXCLUSIONS = @(
        @{ When   = 'irreversible'
           Blocks = 'rollback-script'
           Why    = 'Unavailable while "Make this run permanent" is selected: that mode deletes files outright and empties the Recycle Bin, so nothing the script could write would put them back.' }
        @{ When   = 'wu-off'
           Blocks = 'wu-notify-first'
           Why    = 'Unavailable while "Turn Windows Update off completely" is selected: both set the same policy value and turning updates off runs last, so this one would be overwritten rather than applied.' }
    )

    # Applied to both id functions: without the second, a preset selecting both
    # halves of a pair reads as modified for a change nobody made.
    $applyExclusions = {
        param($Set)
        foreach ($x in $EXCLUSIONS) {
            if ($Set.Contains([string]$x.When)) { $null = $Set.Remove([string]$x.Blocks) }
        }
    }
    $defaultIds = {
        param([string]$name)
        $set = New-WDStringSet $baseIds[$name]
        & $applyLayer $set $presetDefaults $name
        & $applyExclusions $set
        @($set)
    }
    $effectiveIds = {
        param([string]$name)
        $set = New-WDStringSet $baseIds[$name]
        & $applyLayer $set $presetDefaults $name
        & $applyLayer $set $overrides $name
        & $applyExclusions $set
        @($set)
    }

    # "Applied on ... Run folder at ...", or nothing at all.
    $appliedNote = {
        param([string]$name)
        if (-not $appliedRuns.ContainsKey($name)) { return '' }
        $rec = $appliedRuns[$name]
        $now = New-WDStringSet (@(& $effectiveIds $name))
        $then = New-WDStringSet (@($rec.Ids))

        # Set equality was the first rule and it is wrong in the one case that
        # matters - after a run that worked. A removal makes items stop
        # applying, so five of a hundred and forty-nine dropped out that way.
        foreach ($id in $now)  { if (-not $then.Contains($id)) { return '' } }
        foreach ($id in $then) {
            if ($now.Contains($id)) { continue }
            if ($knownIds.Contains($id)) { return '' }
        }

        # ui-state.json lives under LOCALAPPDATA, but a roamed or restored
        # profile carries it, and a card claiming a preset was applied to a
        # computer it never touched is worse than no card.
        if ((Test-WDSameMachine $rec.Machine) -eq $false) { return '' }

        # Read from the cache only: a paint that wants an answer it does not
        # have prints the plain line and queues the run id.
        $runId = [string]$rec.Run
        $st = $null
        if ($runId) {
            if ($appliedState.ContainsKey($runId)) { $st = $appliedState[$runId] }
            elseif (-not $appliedWant.Contains($runId)) { $null = $appliedWant.Add($runId) }
        }
        $partly = $false
        if ($st -and [int]$st.Total) {
            # Nothing left in place and nothing that could not be asked about:
            # this run has been undone.
            if ([int]$st.Outstanding -eq 0 -and [int]$st.Unknown -eq 0) { return '' }
            # Unknown does not count as reverted - it is the default profile and
            # the things too costly to ask about, and calling those undone would
            # be a claim.
            if ([int]$st.Done -gt 0) { $partly = $true }
        }

        $when = [string]$rec.When
        try { $when = ([datetime][string]$rec.When).ToString('d MMMM yyyy') + ' at ' + ([datetime][string]$rec.When).ToString('HH:mm') } catch { }
        $line = "Applied on $when"
        if ($partly) { $line += ' - some options have since been reverted' }
        $line += '.'
        if ([string]$rec.Folder) { $line += " Run folder at $([string]$rec.Folder)." }
        $line
    }

    # Preview writes nothing: a marker saying a preset was applied, put there by
    # a simulation, is the one lie this cannot tell.
    $recordApplied = {
        param([string]$name, $Ran, [string]$Folder, [string]$RunId)
        if (-not $name) { return $false }
        $want = @(& $effectiveIds $name)
        $wantSet = New-WDStringSet $want
        $ranSet  = New-WDStringSet @(@($Ran) | Where-Object { $_ -and [string]$_ -ne $BROWSER_ID })
        if ($wantSet.Count -ne $ranSet.Count) { return $false }
        foreach ($id in $wantSet) { if (-not $ranSet.Contains($id)) { return $false } }
        $appliedRuns[$name] = @{
            When    = (Get-Date).ToString('o')
            Folder  = [string]$Folder
            # Which run, so the marker can ask how much is still in place, and
            # which machine, so it does not speak for another one.
            Run     = [string]$RunId
            Machine = (Get-WDMachineIdentity)
            Ids     = @($want | Sort-Object -Unique)
        }
        $true
    }

    # Declared up here because $saveUiState is called several times during
    # preset setup and would otherwise write a null.
    $storage = @{ Snapshot = $null; Cache = $UiState.storage; Scan = $null; Saved = $false }
    # Same reason: $saveUiState runs long before the boxes it reads exist, and
    # an empty list means "no accounts" rather than "not asked".
    $accountChecks = New-Object System.Collections.Generic.List[psobject]
    # Emitted unrolled, no comma: wrapping would make the caller's @(&
    # $accountKeys) an array holding one array, and the engine would match no
    # account at all.
    $accountKeys = {
        @($accountChecks | Where-Object { $_.Box.IsChecked } | ForEach-Object { [string]$_.Key })
    }
    # Held here rather than read off its column: $buildCompare collapses that
    # column to zero when there is nothing to index, and reading it live would
    # save "no rail" as though somebody had chosen it.
    $cmpRail = @{ W = 184 }
    # Up here for the same reason: the splitter's handler is written below and
    # has to throw the offsets away.
    $cmpSpy    = @{ Offsets = $null; Active = $null; Busy = $false }
    $cmpSpyRef = @{ Fn = $null }

    # Built and handed back rather than written. The split is what lets the
    # harness read the payload, since the write is gated on NoPrompts.
    $uiStateOut = {
        # Rebuilt from scratch rather than mutated: the object came from JSON,
        # and adding members to it is how a stale shape gets written back out.
        # There is deliberately no overrides property.
        $out = [pscustomobject]@{
            theme          = [string]$state.Theme
            preset         = [string]$state.Preset
            presetDefaults = [pscustomobject]@{}
            # What has actually been run here.
            applied        = [pscustomobject]@{}
            storage        = $storage.Cache
            # The explicit list rather than "all", because "all" on a machine
            # that gains an account later means something different.
            accounts       = @(& $accountKeys)
            # A preference, like the theme.
            group          = [string]$state.Group
            sortBy         = [string]$state.Sort
            # Where an item's details are drawn.
            detailPopup    = [bool]$state.DetailPopup
            # Stored as the positive of the non-default, so absent means the
            # shipped behaviour.
            verbose        = (-not [bool]$state.Terse)
            # Read off the column rather than the ScrollViewer inside it - the
            # column is what the splitter moves.
            railWidth      = [int]$ui.IndexCol.Width.Value
            # A separate preference: it indexes a different and shorter list.
            cmpRailWidth   = [int]$cmpRail.W
            # The files, not the ids: a saved selection is a file somebody owns
            # and may edit between sessions.
            loadedPresets  = @($loadedPresets.Keys | ForEach-Object { [string]$loadedPresets[$_].Path })
            # The three answers collected beside a row rather than in it.
            deferFeatureDays = [int]$state.DeferDays.Feature
            deferQualityDays = [int]$state.DeferDays.Quality
            defaultBrowser   = [string]$state.DefaultBrowser
        }
        foreach ($n in $presetDefaults.Keys) {
            $out.presetDefaults | Add-Member -NotePropertyName $n -NotePropertyValue ([pscustomobject]@{
                Added   = @($presetDefaults[$n].Added)
                Removed = @($presetDefaults[$n].Removed)
            }) -Force
        }
        foreach ($n in $appliedRuns.Keys) {
            $out.applied | Add-Member -NotePropertyName $n -NotePropertyValue ([pscustomobject]@{
                When    = [string]$appliedRuns[$n].When
                Folder  = [string]$appliedRuns[$n].Folder
                Run     = [string]$appliedRuns[$n].Run
                Machine = $appliedRuns[$n].Machine
                Ids     = @($appliedRuns[$n].Ids)
            }) -Force
        }
        $out
    }

    $saveUiState = {
        # The harness makes hundreds of edits it never means to keep, and
        # writing them to the real file would hand somebody mangled presets.
        if ($state.NoPrompts) { return }
        $null = Save-WDUiState -State (& $uiStateOut)
    }

    # $counts, $totDelta, and $consequence are declared with the loaded-preset
    # tables above, because $dropLoaded clears them.
    $modeTotal   = @{ N = 0 }
    # Built once: the columns are rebuilt on every preset edit, and walking the
    # manifest each time is a manifest walk per click.
    $itemFacts = @{}
    foreach ($a in $applicable) { $itemFacts[$a.Id] = $a }

    # Save and Reset stand on the card they speak for, one pair per card. There
    # was one shared pair, and an edit to Aggressive could only be kept or
    # thrown away by first selecting Aggressive.
    $presetEditRows = @{}
    # By name rather than by "whatever is selected". Holders, because both are
    # written far below and a closure would capture null.
    $editActions = @{ Save = $null; Reset = $null; SaveLoaded = $null; SaveOut = $null }
    $makeEditRow = {
        # -Inline is the mode card, where this pair shares a line with Preview.
        # A WrapPanel: the three want 199px and a mode column is 170 at the
        # window's minimum, so Reset drops under Save rather than being
        # squeezed.
        param([string]$Name, [switch]$Inline)
        $row = New-Object Windows.Controls.WrapPanel
        $row.Orientation = 'Horizontal'
        if ($Inline) {
            $row.HorizontalAlignment = 'Right'
            $row.Margin = '8,0,0,0'
        } else {
            $row.Margin = '0,10,0,0'
        }
        $row.Visibility = $(if ($overrides.ContainsKey($Name)) { 'Visible' } else { 'Collapsed' })
        foreach ($b in @(@{ K = 'Save'; T = 'Save'
                            Tip = 'Makes your edits the contents of this preset. Reset then has nothing left to undo.' },
                         @{ K = 'Reset'; T = 'Reset'
                            Tip = 'Puts this preset back to what it opens with. The other presets keep your edits.' })) {
            $btn = New-Object Windows.Controls.Button
            $btn.Content = [string]$b.T
            $btn.Padding = '12,4'; $btn.Margin = '0,0,5,0'; $btn.FontSize = 12.5
            $btn.ToolTip = [string]$b.Tip
            # Which preset and which action, both on the Tag: this is a closure
            # built inside a builder, so it can see neither.
            $btn.Tag = @{ Name = [string]$Name; Do = [string]$b.K; Acts = $editActions }
            $btn.Add_Click({
                $t = $this.Tag
                $fn = $t.Acts[$t.Do]
                if ($fn) { & $fn ([string]$t.Name) }
            }.GetNewClosure())
            $null = $row.Children.Add($btn)
            if ([string]$b.K -eq 'Save') { $row.Tag = @{ Save = $btn } }
            else { $row.Tag.Reset = $btn }
        }
        $presetEditRows[[string]$Name] = $row
        $row
    }.GetNewClosure()

    # Separate from $recount because it is cheap and $recount is not: every
    # repaint of the box makes new rows.
    $syncEditRows = {
        foreach ($k in @($presetEditRows.Keys)) {
            # A removed preset leaves its row orphaned off the page. Dropped
            # here rather than in $dropLoaded, which is a closure written above
            # this table.
            if (-not $presetNames.Contains([string]$k)) { $presetEditRows.Remove([string]$k); continue }
            $presetEditRows[$k].Visibility =
                $(if ($overrides.ContainsKey([string]$k)) { 'Visible' } else { 'Collapsed' })
        }
        # For the self test, and anything else wanting "the pair on the preset
        # in front of me".
        $row = $presetEditRows[[string]$state.Preset]
        $ui.PresetEditRow   = $row
        $ui.BtnSavePreset   = $(if ($row) { $row.Tag.Save }  else { $null })
        $ui.BtnResetPresets = $(if ($row) { $row.Tag.Reset } else { $null })
    }.GetNewClosure()

    $recount = {
        $totDelta.Clear()
        $consequence.Clear()
        # The most any mode could select here, with everything already dealt
        # with taken out. Rebuilt each pass because an edit can add to it.
        $ceiling = New-Object System.Collections.Generic.HashSet[string]
        foreach ($p in $presetNames) {
            $ids = @(& $effectiveIds $p)
            $counts[$p] = $ids.Count
            # What the column can honestly claim.
            $risky = 0; $here = 0
            foreach ($id in $ids) {
                $f = $itemFacts[$id]
                if (-not $f) { continue }
                if ($f.Risk -ge 2) { $risky++ }
                # The ceiling comes off the shipped presets only: a loaded file
                # can name tier-0 items no mode selects, and letting those in
                # would move the number printed on Extreme.
                if ($f.Present -ne $false) {
                    $here++
                    if ($shippedNames -contains $p) { $null = $ceiling.Add([string]$id) }
                }
            }
            $consequence[$p] = @{ Risky = $risky; Here = $here }
            # Custom is measured against nothing, so every tick would read as an
            # addition.
            if ($p -eq 'Custom' -or -not $overrides.ContainsKey($p)) { continue }
            $totDelta[$p] = @{ Added = @($overrides[$p].Added).Count; Removed = @($overrides[$p].Removed).Count }
        }
        # Mutated, not reassigned: $modeTotal is captured by the mode grid's
        # closure.
        $modeTotal.N = $ceiling.Count
        # Save and Reset appear when their own preset is edited, not when the
        # selected one is.
        & $syncEditRows
    }

    # Kept out of the click handler so the self test can drive it without a
    # MessageBox.
    $setOverride = {
        param([string]$Name, [string[]]$Added, [string[]]$Removed)
        if (@($Added).Count -or @($Removed).Count) {
            $overrides[$Name] = @{ Added = @($Added); Removed = @($Removed) }
        } else {
            # Edited back to the preset's own contents. An empty override would
            # leave Reset preset offering to undo nothing.
            $overrides.Remove($Name)
        }
        & $recount
            & $repaintModeGrid
        & $saveUiState
    }
    $clearOverrides = {
        $overrides.Clear()
        & $recount
            & $repaintModeGrid
        & $saveUiState
    }
    # The edit stops being an edit and becomes the preset, so the marks clear.
    # Recomputed from $baseIds rather than merged, because merging two
    # Added/Removed pairs has four cases.
    $promoteOverride = {
        param([string]$Name)
        if (-not $overrides.ContainsKey($Name)) { return $false }
        $was = New-WDStringSet $baseIds[$Name]
        $now = New-WDStringSet (& $effectiveIds $Name)
        $add = @($now | Where-Object { -not $was.Contains($_) })
        $rem = @($was | Where-Object { -not $now.Contains($_) })
        if (@($add).Count -or @($rem).Count) { $presetDefaults[$Name] = @{ Added = @($add); Removed = @($rem) } }
        else                                 { $presetDefaults.Remove($Name) }
        $overrides.Remove($Name)
        & $recount
            & $repaintModeGrid
        & $saveUiState
        $true
    }
    $restoreFactory = {
        $presetDefaults.Clear()
        $overrides.Clear()
        & $recount
            & $repaintModeGrid
        & $saveUiState
    }
    & $recount

    # Green for what was added to the preset, red for what was taken out.
    $fillCountCell = {
        param($Cell, [string]$Text, [string]$BaseKey, [int]$Added, [int]$Removed)
        $Cell.Inlines.Clear()
        $head = New-Object Windows.Documents.Run $Text
        # A Run is a TextElement, not a control, but Foreground is still a
        # dependency property on it.
        & $Ref $head 'Foreground' $BaseKey
        $null = $Cell.Inlines.Add($head)
        if (-not ($Added -or $Removed)) { return }
        $head.FontWeight = 'Bold'

        $first = $true
        foreach ($bit in @(@{ N = $Added; Word = 'added'; Col = 'Ok' },
                           @{ N = $Removed; Word = 'removed'; Col = 'Bad' })) {
            if (-not $bit.N) { continue }
            $lead = New-Object Windows.Documents.Run $(if ($first) { '   ' } else { ', ' })
            & $Ref $lead 'Foreground' $BaseKey
            $null = $Cell.Inlines.Add($lead)
            $piece = New-Object Windows.Documents.Run "$($bit.N) item$(if ($bit.N -ne 1) { 's' }) $($bit.Word)"
            & $Ref $piece 'Foreground' $bit.Col
            $piece.FontWeight = 'Bold'
            $null = $Cell.Inlines.Add($piece)
            $first = $false
        }
    }

    # It used to end by pointing at two footer buttons, one of which is a
    # home-page card now.
    $ui.TxtModeHint.Text = 'Each mode does everything the mode before it does, and more. The count on a card leaves out the opt-in options - your own apps, and the quality-of-life changes - because no mode selects those. Pick a mode, then use Show all options on it to read and change every one of them.'

    $modeCols = @{}

    # The fill is a plain Border with no width of its own, so it is sized
    # against the column it sits in. From SizeChanged alone, an edit that
    # rebuilt the grid without resizing it left every bar flat.
    $sizingBars = @{ Busy = $false }
    # -1 forces the first fit and is reset by every rebuild, because a rebuild
    # makes new TextBlocks with no floor.
    $blurbFit   = @{ W = -1.0 }
    # Split out because a repaint - an edit that moves the numbers and nothing
    # else - needs the widths and not the measuring pass.
    $sizeModeFills = {
        foreach ($k in $modeCols.Keys) {
            if (-not $modeCols[$k].Fill -or -not $modeCols[$k].Track) { continue }
            # Measured off the track, not off the card minus a guess at its
            # padding.
            $w = $modeCols[$k].Track.ActualWidth
            if ($w -gt 0) { $modeCols[$k].Fill.Width = [Math]::Max(2, $w * $modeCols[$k].Ratio) }
        }
    }
    $sizeModeBars = {
        if ($sizingBars.Busy) { return }
        $sizingBars.Busy = $true
        try {
            # A Border created moments ago has ActualWidth 0 until the layout
            # pass runs, so measuring straight after a rebuild silently skipped
            # every one.
            $ui.ModeGrid.UpdateLayout()
            & $sizeModeFills

            # Measured rather than a MinHeight constant. Keyed on the grid's
            # width, because a SizeChanged handler that changes layout feeds
            # itself and a re-entrancy flag does not catch it - each turn is a
            # separate dispatcher event.
            $w = [double]$ui.ModeGrid.ActualWidth
            $blurbs = @($modeCols.Keys | ForEach-Object { $modeCols[$_].Blurb } | Where-Object { $_ })
            if ($blurbs.Count -and $w -gt 0 -and [Math]::Abs($w - [double]$blurbFit.W) -gt 0.5) {
                $blurbFit.W = $w
                foreach ($b in $blurbs) { $b.MinHeight = 0 }
                $ui.ModeGrid.UpdateLayout()
                $tallest = 0.0
                foreach ($b in $blurbs) {
                    if ($b.ActualHeight -gt $tallest) { $tallest = [double]$b.ActualHeight }
                }
                if ($tallest -gt 0) { foreach ($b in $blurbs) { $b.MinHeight = $tallest } }
            }
        } finally { $sizingBars.Busy = $false }
    }

    # Both routes into a mode call have to reach this: $selectPreset for the
    # grid and $applyPresetToChecks for the toolbar buttons.
    $syncOwnership = {
        param([string]$name)
        $ui.ChkOwnership.IsChecked =
            if ($null -ne $state.OwnershipChoice) { [bool]$state.OwnershipChoice }
            else { $name -in @('Aggressive', 'Extreme') }
    }
    # Click, not Checked: Checked cannot tell a person ticking the box from the
    # line above setting it, so it would latch on the first mode switch.
    $ui.ChkOwnership.Add_Click({
        $state.OwnershipChoice = [bool]$ui.ChkOwnership.IsChecked
    }.GetNewClosure())

    # A holder is only useful if it is a live object by the time the block that
    # closes over it is invoked. These are declared above $selectPreset because
    # $buildModeGrid runs thousands of lines above where their handlers are
    # written.
    $advRef   = @{ Ensure = $null; Open = $null }
    $goRef    = @{ Compare = $null; ComparePick = $null; Preview = $null; Home = $null }
    $cmpPickRef = @{ Take = $null; End = $null }

    # One page at a time, decided in one place. Every navigation used to be
    # "collapse the one you are on, show the one you want", which is correct
    # only while you are on the one it names.
    $showPage = {
        param([string]$Name)
        foreach ($p in @('PageHome','PageModes','PageAdvanced','PageRevertHome','PageRevert',
                         'PageCompare','PageUnattend','PageRun')) {
            if ($ui[$p]) { $ui[$p].Visibility = $(if ($p -eq $Name) { 'Visible' } else { 'Collapsed' }) }
        }
        $ui.StorageBlock.Visibility = $(if ($Name -eq 'PageHome') { 'Collapsed' } else { 'Visible' })
    }

    $selectPreset = {
        param([string]$name)
        # Belt and braces against a name that is no longer a preset.
        if (-not $presetNames.Contains($name)) { $name = 'Balanced' }
        $state.Preset = $name
        & $recount          # Reset preset follows the mode on screen
        foreach ($k in $modeCols.Keys) {
            $sel = ($k -eq $name)
            & $Ref $modeCols[$k].Border 'Background' $(if ($sel) { 'CardSel' } else { 'Card' })
            & $Ref $modeCols[$k].Border 'BorderBrush' $(if ($sel) { $presetColor[$k] } else { 'Line' })
            $modeCols[$k].Border.BorderThickness = New-Object Windows.Thickness $(if ($sel) { 2 } else { 1 })
            if ($modeCols[$k].Check) {
                $modeCols[$k].Check.Text       = $(if ($sel) { 'SELECTED' } else { 'click to select' })
                & $Ref $modeCols[$k].Check 'Foreground' $(if ($sel) { $presetColor[$k] } else { 'Muted' })
            }
            # Hidden rather than Collapsed on the four. Two things, not one:
            # Preview shares its row with Save and Reset, which follow the edit
            # rather than the selection.
            if ($modeCols[$k].Acts) {
                $modeCols[$k].Acts.Visibility = $(if ($sel) { 'Visible' } else { 'Hidden' })
            }
            if ($modeCols[$k].Go) {
                $modeCols[$k].Go.Visibility = $(if ($sel) { 'Visible' } else { 'Hidden' })
            }
        }
        # The selected card's three buttons, re-pointed on every selection, so
        # the forty places that press them by name go on working.
        if ($modeCols.ContainsKey($name) -and $modeCols[$name].Open) {
            $ui.BtnAdvanced    = $modeCols[$name].Open
            $ui.BtnCompare     = $modeCols[$name].Cmp
            $ui.BtnModePreview = $modeCols[$name].Go
        }
        # The tally under the columns is gone: it was the card's own count
        # restated in a corner of the window a long way from the card.
        if ($loadedRef.Paint) { & $loadedRef.Paint }
        # After the repaint, because that rebuilt the rows the pairs live on.
        & $syncEditRows
        & $syncOwnership $name
        # The mode screen never touches the Advanced checkboxes, so ask the
        # preset itself whether Edge removal is in play.
        if ($browserSync.Fn) { & $browserSync.Fn (@(& $effectiveIds $name) -contains $EDGE_ID) }
        if ($name -eq 'Extreme') {
            $ui.TxtModeWarning.Text = $extremeWarning
            $ui.WarnBox.Visibility = 'Visible'
        } else {
            $ui.WarnBox.Visibility = 'Collapsed'
        }
    }

    # What a click on a preset means, which is not always "select this one":
    # while the Compare question is up it means "compare with this one".
    $pickOrSelect = {
        param([string]$name)
        if ($cmpPickRef.Take -and (& $cmpPickRef.Take $name)) { return }
        & $selectPreset $name
    }

    # Everything about one mode column that an edit can change, so a repaint
    # does not need a rebuild.
    $paintModeCol = {
        param([string]$Name)
        $col = $modeCols[$Name]
        if (-not $col -or -not $col.Num) { return }
        # The numerator is what this mode will actually do here, not what it
        # nominally selects.
        $shown = $counts[$Name]
        if ($consequence[$Name]) { $shown = [int]$consequence[$Name].Here }
        $td = $totDelta[$Name]
        # "options selected" rather than a bare fraction: on its own the
        # fraction reads as a count of removals.
        & $fillCountCell $col.Num "$shown of $($modeTotal.N) options selected" 'Text' ([int]$td.Added) ([int]$td.Removed)
        # Same number the line above quotes. A bar that disagrees with the
        # figure printed on it is worse than no bar.
        $col.Ratio = 0.0
        if ($modeTotal.N -gt 0) { $col.Ratio = [double]$shown / $modeTotal.N }
        # Painted rather than built, so an apply that finishes with the window
        # open marks its own card.
        if ($col.Applied) {
            $note = & $appliedNote $Name
            $col.Applied.Text = $note
            $col.Applied.Visibility = $(if ($note) { 'Visible' } else { 'Collapsed' })
        }
        # The risky count. Absent on Custom.
        if ($col.Facts) {
            $cq = $consequence[$Name]
            if ($cq -and [int]$cq.Risky -gt 0) {
                $col.Facts.Text = "$($cq.Risky) risky"
                & $Ref $col.Facts 'Foreground' 'Warn'
                $col.Facts.FontWeight = 'SemiBold'
            } else {
                $col.Facts.Text = 'nothing marked risky'
                & $Ref $col.Facts 'Foreground' 'Sub'
                $col.Facts.FontWeight = 'Normal'
            }
        }
    }

    $buildModeGrid = {
        # GetNewClosure captures only the local scope, and this scriptblock runs
        # in a child one - so anything a handler below needs is copied into a
        # local first.
        $onSelect = $pickOrSelect
        # The card's own ways off this page, copied in for the same reason.
        $openRef  = $advRef
        $goRefL   = $goRef

        $g = $ui.ModeGrid
        $g.Children.Clear(); $g.RowDefinitions.Clear(); $g.ColumnDefinitions.Clear()
        $modeCols.Clear()

        # $shippedNames, not $presetNames: a loaded file is a preset everywhere
        # else and deliberately not a column here.
        for ($i = 0; $i -lt $shippedNames.Count; $i++) {
            $cd = New-Object Windows.Controls.ColumnDefinition
            $cd.Width    = New-WDGridLength -Value 1 -Unit 'Star'
            $cd.MinWidth = 190
            $null = $g.ColumnDefinitions.Add($cd)
        }
        $rd = New-Object Windows.Controls.RowDefinition
        $rd.Height = New-WDGridLength -Value 0 -Unit 'Auto'
        $null = $g.RowDefinitions.Add($rd)

        # Clickable column backgrounds first, so everything else draws on top.
        for ($c = 0; $c -lt $shippedNames.Count; $c++) {
            $p = $shippedNames[$c]
            $border = New-Object Windows.Controls.Border
            $border.CornerRadius    = 8
            $border.Margin          = '5,0,5,0'
            $border.BorderThickness = New-Object Windows.Thickness 1
            & $Ref $border 'Background' 'Card'
            & $Ref $border 'BorderBrush' 'Line'
            $border.Cursor          = 'Hand'
            $border.Tag             = $p
            # No tooltip: the blurb is already printed in the column, and a
            # hover card repeating it covers the thing it describes.
            [Windows.Controls.Grid]::SetColumn($border, $c)
            [Windows.Controls.Grid]::SetRow($border, 0)
            $border.Add_MouseLeftButtonUp({ & $onSelect $this.Tag }.GetNewClosure())
            $null = $g.Children.Add($border)
            $modeCols[$p] = @{ Border = $border }
        }

        for ($c = 0; $c -lt $shippedNames.Count; $c++) {
            $p = $shippedNames[$c]
            # A DockPanel, so what a card can do sits at the bottom rather than
            # wherever that card's prose ends. Stacked from the top, Custom's
            # three landed a third of the way up while the others were near the
            # foot - 399px of spread.
            $sp = New-Object Windows.Controls.DockPanel
            $sp.LastChildFill = $true
            $sp.Margin = '12,12,12,12'
            # Hit-testable, and it takes the same click the column background
            # does. It was IsHitTestVisible = $false, and WPF does not descend
            # into a subtree whose root is not hit-testable.
            $sp.Background = [Windows.Media.Brushes]::Transparent
            $sp.Tag = $p
            # A Button marks MouseLeftButtonUp handled before it bubbles, so
            # Save and Reset do not also re-select the preset they stand on.
            $sp.Add_MouseLeftButtonUp({ & $onSelect $this.Tag }.GetNewClosure())

            # The bottom edge, claimed first so it gets the foot of the card;
            # $spTop is added last and fills what is left.
            $spFoot = New-Object Windows.Controls.StackPanel
            [Windows.Controls.DockPanel]::SetDock($spFoot, 'Bottom')
            $null = $sp.Children.Add($spFoot)

            $spTop = New-Object Windows.Controls.StackPanel
            $null = $sp.Children.Add($spTop)

            $title = New-Object Windows.Controls.TextBlock
            $title.Text = $p; $title.FontSize = 18; $title.FontWeight = 'SemiBold'
            & $Ref $title 'Foreground' $presetColor[$p]
            $null = $spTop.Children.Add($title)

            # The only count on the page, so the edit delta rides along with it.
            $num = New-Object Windows.Controls.TextBlock
            $num.FontSize = 13; $num.Margin = '0,2,0,6'; $num.TextWrapping = 'Wrap'
            $null = $spTop.Children.Add($num)

            $track = New-Object Windows.Controls.Border
            $track.Height = 5; $track.CornerRadius = 3; & $Ref $track 'Background' 'Line'
            $fillHost = New-Object Windows.Controls.Grid
            $fill = New-Object Windows.Controls.Border
            $fill.Height = 5; $fill.CornerRadius = 3
            & $Ref $fill 'Background' $presetColor[$p]
            $fill.HorizontalAlignment = 'Left'
            $null = $fillHost.Children.Add($track)
            $null = $fillHost.Children.Add($fill)
            $fillHost.Margin = '0,0,0,6'
            $null = $spTop.Children.Add($fillHost)

            # What the mode costs, in the one term this can answer honestly.
            $facts = $null
            if ($p -ne 'Custom') {
                $facts = New-Object Windows.Controls.TextBlock
                $facts.FontSize = 12; $facts.Margin = '0,0,0,8'; $facts.TextWrapping = 'Wrap'
                $null = $spTop.Children.Add($facts)
            }

            # The description says what the mode is for and what it costs; the
            # bullets say what it takes.
            $blurb = New-Object Windows.Controls.TextBlock
            $blurb.Text = $presetBlurb[$p]
            # No MinHeight: $sizeModeBars raises all five to the tallest.
            $blurb.FontSize = 12.5; $blurb.TextWrapping = 'Wrap'
            $blurb.LineHeight = 17
            # All five in the normal text colour.
            & $Ref $blurb 'Foreground' 'Text'
            $null = $spTop.Children.Add($blurb)

            # Not @($presetBullets[$p]) alone - a missing key yields $null, and
            # @($null) is a one-element array holding nothing.
            $bullets = @()
            if ($presetBullets.ContainsKey($p)) { $bullets = @($presetBullets[$p]) }
            if ($bullets.Count) {
                $bh = New-Object Windows.Controls.TextBlock
                # "ADDS TO PREVIOUS" on every rung including the first: Custom
                # has a base set, so Conservative does have a previous.
                $bh.Text = 'ADDS TO PREVIOUS'
                $bh.FontSize = 11; $bh.FontWeight = 'SemiBold'; $bh.Margin = '0,6,0,3'
                & $Ref $bh 'Foreground' 'Muted'
                $null = $spTop.Children.Add($bh)
                foreach ($b in $bullets) {
                    $li = New-Object Windows.Controls.TextBlock
                    $li.Text = "$([char]0x2022)  $b"
                    $li.FontSize = 12.5; $li.TextWrapping = 'Wrap'; $li.Margin = '0,0,0,3'
                    & $Ref $li 'Foreground' 'Text'
                    $null = $spTop.Children.Add($li)
                }
                # Nine lines is not the whole of what a mode does, and a list
                # that simply stops reads as the whole list.
                $more = New-Object Windows.Controls.TextBlock
                $more.Text = "$([char]0x2022)  and more..."
                $more.FontSize = 12.5; $more.TextWrapping = 'Wrap'; $more.Margin = '0,0,0,3'
                $more.FontStyle = 'Italic'
                & $Ref $more 'Foreground' 'Muted'
                $null = $spTop.Children.Add($more)
            }

            $chk = New-Object Windows.Controls.TextBlock
            $chk.Text = 'click to select'; $chk.FontSize = 11; $chk.Margin = '0,14,0,0'
            $chk.FontWeight = 'SemiBold'
            & $Ref $chk 'Foreground' 'Muted'
            $null = $spFoot.Children.Add($chk)

            # Built empty on every column, like the item rows' Gate line: a
            # marker that exists only where somebody remembered to build one is
            # a rule that half works. Below the selection line, or it would push
            # one column's bullets out of step with the others.
            $applied = New-Object Windows.Controls.TextBlock
            $applied.FontSize = 11; $applied.Margin = '0,6,0,0'; $applied.TextWrapping = 'Wrap'
            $applied.Visibility = 'Collapsed'
            & $Ref $applied 'Foreground' 'Ok'
            $null = $spFoot.Children.Add($applied)

            # Everything you can do with a preset, on the preset. Stacked rather
            # than in a row: three across want about 260px and a column is 190
            # at its narrowest.
            $acts = New-Object Windows.Controls.StackPanel
            $acts.Margin = '0,14,0,0'
            $acts.Visibility = 'Hidden'

            # Preview's line, with Save and Reset in the right corner. Auto then
            # star, so Preview is the one that can never be squeezed - which is
            # the right way round for the only button that starts a run.
            $goRow = New-Object Windows.Controls.Grid
            foreach ($cw in @(@{ V = 0; U = 'Auto' }, @{ V = 1; U = 'Star' })) {
                $gcd = New-Object Windows.Controls.ColumnDefinition
                $gcd.Width = New-WDGridLength -Value $cw.V -Unit $cw.U
                $null = $goRow.ColumnDefinitions.Add($gcd)
            }
            $editPair = & $makeEditRow $p -Inline
            [Windows.Controls.Grid]::SetColumn($editPair, 1)
            $null = $goRow.Children.Add($editPair)

            $mkAct = {
                param([string]$Text, [string]$Tip, [bool]$Go, [scriptblock]$Do)
                $b = New-Object Windows.Controls.Button
                $b.Content = $Text
                $b.Padding = '12,6'; $b.Margin = '0,0,0,6'; $b.FontSize = 12.5
                # Left and content-width, not stretched: stretched, all three
                # ran the full card and read as three slabs.
                $b.HorizontalAlignment = 'Left'
                $b.ToolTip = $Tip
                if ($Go) {
                    $b.FontWeight = 'Bold'
                    & $Ref $b 'Background'  'GoBg'
                    & $Ref $b 'Foreground'  'GoText'
                    & $Ref $b 'BorderBrush' 'GoBorder'
                }
                # A Button marks the click handled before it bubbles, so none of
                # these also re-selects the card underneath.
                $b.Add_Click($Do)
                # Preview goes into its own row beside Save and Reset; the other
                # two are stacked above it.
                if ($Go) {
                    $b.Margin = '0,0,0,0'
                    [Windows.Controls.Grid]::SetColumn($b, 0)
                    $null = $goRow.Children.Add($b)
                } else {
                    $null = $acts.Children.Add($b)
                }
                $b
            }

            $open = & $mkAct 'Show all options' `
                'Opens the full list with this preset ticked, so you can change any of it. Nothing is applied until you press Preview.' `
                $false { if ($openRef.Open) { & $openRef.Open } }.GetNewClosure()
            # The card names itself to the pick: by the time somebody answers,
            # the selected preset may be a different one.
            $cardName = [string]$p
            $cmp = & $mkAct 'Compare with...' `
                'Shows what this preset removes that another one leaves alone, and lets you hand items between them.' `
                $false { if ($goRefL.ComparePick) { & $goRefL.ComparePick $cardName } }.GetNewClosure()
            $go = & $mkAct 'Preview' `
                'Works out exactly what this preset would do to this machine and shows you, without changing anything.' `
                $true { if ($goRefL.Preview) { & $goRefL.Preview } }.GetNewClosure()
            # Show all options and Compare, stacked; then Preview's row,
            # carrying this column's Save and Reset.
            $null = $spFoot.Children.Add($acts)
            $goRow.Margin = '0,0,0,0'
            $null = $spFoot.Children.Add($goRow)

            [Windows.Controls.Grid]::SetRow($sp, 0); [Windows.Controls.Grid]::SetColumn($sp, $c)
            $null = $g.Children.Add($sp)
            $modeCols[$p].Fill  = $fill
            $modeCols[$p].Track = $track
            $modeCols[$p].Ratio = 0.0
            $modeCols[$p].Check = $chk
            $modeCols[$p].Acts  = $acts
            $modeCols[$p].GoRow = $goRow
            $modeCols[$p].Open  = $open
            $modeCols[$p].Cmp   = $cmp
            $modeCols[$p].Go    = $go
            $modeCols[$p].Applied = $applied
            $modeCols[$p].Num   = $num
            $modeCols[$p].Facts = $facts
            $modeCols[$p].Blurb = $blurb
            $modeCols[$p].Bullets = $bullets
            $modeCols[$p].Panel = $sp
            # Last, because it writes into the three elements above and needs
            # them findable by name.
            & $paintModeCol $p
        }

        & $selectPreset $state.Preset
        # The bars are new objects every rebuild, so size them here as well as
        # on resize.
        $blurbFit.W = -1.0
        & $sizeModeBars
    }

    $ui.ModeGrid.Add_SizeChanged($sizeModeBars.GetNewClosure())

    # An edit cannot change the shape of this page - the columns, titles,
    # descriptions, and bullets all come off the manifest.
    $repaintModeGrid = {
        foreach ($p in $shippedNames) { & $paintModeCol $p }
        # The tally line under the columns is counted too, and it is
        # $selectPreset that writes it.
        & $selectPreset $state.Preset
        # $sizeModeFills, not $sizeModeBars: nothing changed size, so the tracks
        # are still the width the last layout measured.
        & $sizeModeFills
    }

        & $buildModeGrid

    # Three cards, one line of prose, and nothing else. A Button with a card
    # template rather than a Border with a click handler: a Button is focusable,
    # answers the keyboard, and marks its click handled.
    $homeCards = @{}
    $buildHomeCards = {
        # Copied in because the handlers below are closures made inside a block
        # invoked with &.
        $uiRef   = $ui
        $refFn   = $Ref
        $cards   = $homeCards

        $g = $ui.HomeGrid
        $g.Children.Clear()

        # The paragraph says what the thing is, in the words somebody who has
        # never opened this would use.
        $spec = @(
            @{ Key = 'debloat'; Glyph = 0x1F9F9
               Title = 'Debloat and customize'
               Body  = 'Pick one of five modes, or go through every option yourself. Nothing is removed until you have seen a preview of exactly what would happen.' }
            @{ Key = 'revert';  Glyph = 0x21A9
               Title = 'Revert past changes'
               Body  = 'Put back what an earlier run changed - all of it, or one option at a time. It reads this machine to find what is still in place.' }
            @{ Key = 'unattend'; Glyph = 0x1F4C4
               Title = 'Autounattend generator'
               Body  = 'Build an autounattend.xml for installing Windows on another machine, so it arrives already set up. Nothing on this computer is touched.' }
        )

        for ($i = 0; $i -lt $spec.Count; $i++) {
            $s = $spec[$i]
            $btn = New-Object Windows.Controls.Button
            $btn.Style  = $ui.Root.FindResource('WdCardButton')
            # The same margin on all three, not none on the outside edges: equal
            # cells minus unequal margins gave 330/322/330.
            $btn.Margin = '8,0,8,0'
            $btn.VerticalAlignment = 'Stretch'
            $btn.MinHeight = 200

            $body = New-Object Windows.Controls.StackPanel

            $gl = New-Object Windows.Controls.TextBlock
            $gl.Text = New-WDGlyph $s.Glyph
            # A colour emoji ignores Foreground, which is most of these; the two
            # that are not carry the card's own accent.
            $gl.FontSize = 34; $gl.Margin = '0,0,0,14'
            & $refFn $gl 'Foreground' 'Sub'
            $null = $body.Children.Add($gl)

            $ti = New-Object Windows.Controls.TextBlock
            $ti.Text = [string]$s.Title
            $ti.FontSize = 19; $ti.FontWeight = 'Bold'; $ti.TextWrapping = 'Wrap'
            $ti.Margin = '0,0,0,8'
            & $refFn $ti 'Foreground' 'Text'
            $null = $body.Children.Add($ti)

            $bo = New-Object Windows.Controls.TextBlock
            $bo.Text = [string]$s.Body
            $bo.FontSize = 13.5; $bo.TextWrapping = 'Wrap'; $bo.LineHeight = 19
            $bo.LineStackingStrategy = 'BlockLineHeight'
            & $refFn $bo 'Foreground' 'Sub'
            $null = $body.Children.Add($bo)

            $btn.Content = $body
            # No SetRow/SetColumn: a UniformGrid places children in the order
            # they arrive.
            $null = $g.Children.Add($btn)
            $cards[[string]$s.Key] = $btn
        }

        # Only the first is wired here. The other two already had handlers
        # written for the footer buttons they replace.
        $uiRef.BtnRevert   = $cards['revert']
        $uiRef.BtnUnattend = $cards['unattend']
        $uiRef.BtnDebloat  = $cards['debloat']
        $showRef = $showPage
        $cards['debloat'].Add_Click({ & $showRef 'PageModes' }.GetNewClosure())
    }
    & $buildHomeCards

    # The rows are the expensive half of the application, so each step is added
    # to a list and run the first time anything needs the page.
    $advWork  = New-Object System.Collections.Generic.List[scriptblock]
    # Busy guards re-entrancy between the two routes into the work list: the
    # pre-warm runs off a dispatcher tick, and $ensureAdvanced pumps frames.
    $advBuilt = @{ Done = $false; Ms = 0; Ms0 = 0; Busy = $false; Warmed = 0; Peak = 0; PeakAt = 0; PeakOpen = 0 }
    # Null until something asks for the page, so the work items say nothing when
    # nobody is watching.
    $advSay   = @{ Fn = $null; N = 0; Shown = 0.0 }
    $rows = New-Object System.Collections.Generic.List[psobject]
    # The check box is wired near the top of this function and the pass that
    # answers it cannot be written until every page's elements exist.
    $terseRef = @{ Do = $null }
    # LastReport is the seam: both handlers end in a modal, which a headless
    # check cannot dismiss.
    $refreshRef = @{ Adv = $null; Rev = $null; LastReport = '' }
    # Col is a theme key. Its tint - the same hue at low alpha - is that key
    # plus 'Tint', which $paintTheme derives.
    $riskStyle = @{ 1 = @{ Label = 'caution'; Col = 'Warn' }; 2 = @{ Label = 'risky'; Col = 'Bad' } }

    # Section, then order, then name. Sorting by name threw the authored order
    # away; order alone is wrong too, because the sections are laid out one
    # after another.
    $secRank = @{}
    $rank = 0
    foreach ($s in (Get-WDSectionNames)) { $secRank[[string]$s] = $rank; $rank++ }
    # Every category, Recurring included. It used to be pulled out and
    # hand-built below the columns, which cost it a place in every other
    # mechanism on the page.
    $normalCats = @($Categories |
                    Sort-Object @{ E = { [int]$secRank[[string](Get-WDItemSection -Item $null -Category $_)] } },
                                @{ E = { [int](Get-Prop $_ 'order' 100) } },
                                @{ E = { [string]$_.name } })

    # Builds one item row. Shared by the two-column body and by Extras.
    $rowById = @{}

    # One registry sweep, cached, rather than a `winget list` per item -
    # thirteen of those would add most of a minute to startup.
    & $say 'Building the interface' 'Checking what is already installed'
    # A List filled in place rather than an array assigned: $alreadySatisfied
    # captures this, and a fresh assignment would leave it reading the old one
    # for ever.
    $installedNames = New-Object System.Collections.Generic.List[string]
    $readInstalled = {
        $installedNames.Clear()
        try {
            foreach ($p in @(Get-WDInstalledPrograms)) { $installedNames.Add([string]$p.DisplayName) }
        } catch { }
    }.GetNewClosure()
    & $readInstalled

    # A plain local, never $script:. A $script: variable read from inside a
    # closure resolves against that closure's own module scope, which is empty.
    $browserNames   = @((Get-WDBrowserCatalog).Keys)
    # Matched loosely, because an uninstall entry reads "Google Chrome" on one
    # machine and something longer on another.
    $browserHere = New-Object System.Collections.Generic.HashSet[string]
    # Filled in place, for the reason $installedNames is a List: half a dozen
    # closures capture this set and Refresh has to change what it holds.
    $sweepBrowsers = {
        $browserHere.Clear()
        foreach ($b in $browserNames) {
            foreach ($n in $installedNames) {
                if ($n -like "*$b*") { $null = $browserHere.Add([string]$b); break }
            }
        }
    }.GetNewClosure()
    & $sweepBrowsers
    $refreshBrowsers = @{ Do = $sweepBrowsers }
    # The one offered when a mode removes Edge without anybody having chosen.
    $freeBrowsers   = @($browserNames | Where-Object { -not $browserHere.Contains([string]$_) })
    $browserDefault = ''
    if (-not $browserHere.Count) {
        $browserDefault = 'Google Chrome'
        if ($browserDefault -notin $freeBrowsers) { $browserDefault = [string]@($freeBrowsers)[0] }
        if (-not $browserDefault) { $browserDefault = [string]@($browserNames)[0] }
    }
    $BROWSER_NONE   = 'No browser - I will sort it out myself'

    # "Chrome and Firefox", not "Chrome, Firefox". Declared above $tellBrowser
    # because that is where it is captured.
    $joinNames = {
        param([string[]]$Names)
        $n = @($Names)
        if ($n.Count -le 1) { return [string]$n[0] }
        if ($n.Count -eq 2) { return "$($n[0]) and $($n[1])" }
        (($n[0..($n.Count - 2)]) -join ', ') + " and $($n[-1])"
    }

    # Selecting a mode that removes Edge does not stop to ask: it says what will
    # happen and where to change it. A modal that blocks on a decision nobody
    # came here to make is worse than a default with a visible way to change it.
    $tellBrowser = {
        if (-not $browserDefault) { return }
        Show-WDMessage (
            "This mode removes Microsoft Edge.`n`n" +
            "$browserDefault will be installed during the run so the machine is not left without a browser.`n`n" +
            "To choose a different one, or none at all, use Show all options on your mode's card and change it under 'Uninstall Microsoft Edge'.",
            'Removing Microsoft Edge', 'OK', 'None') | Out-Null
    }.GetNewClosure()

    # Two pickers, one answer - the strip under Edge removal and the standing
    # block in Add - so every route goes through $setBrowsers and every panel
    # repaints.
    $rowStrips = @{}
    # Rows whose presence is a live condition rather than a fact about the
    # machine. A guard cannot answer this, because a guard is evaluated once
    # when the list is built.
    $rowGate = @{}
    $browserUi = @{ Panels = New-Object System.Collections.Generic.List[psobject]; Row = $null; Strip = $null }
    # Built inside the deferred page build and reachable from $setBrowsers, so
    # it is declared here.
    $defBrowserUi = @{ Panel = $null; Refresh = $null }
    $setBrowsers = {
        param([string[]]$Names, [bool]$Remember)
        # State and UI only. The choice reaches disk once, from $startRun, where
        # the process is elevated: %ProgramData%'s root grants Users create but
        # not modify.
        $want = @($browserNames | Where-Object { $_ -in @($Names) -and -not $browserHere.Contains([string]$_) })
        if ($Remember) { $state.BrowserPreferred = $want }
        $state.BrowserChoices = $want
        # Any deliberate pick stops being the one made on the user's behalf,
        # which is what decides whether backing out of Edge removal withdraws
        # it.
        $state.BrowserAuto = $false
        $pretty = & $joinNames $want
        foreach ($p in $browserUi.Panels) {
            if ($p.Label) {
                $p.Label.Text = if ($want.Count) {
                    if ($p.Kind -eq 'edge') { "Installs $pretty so the machine is not left without a browser:" }
                    else                    { "$pretty will be installed:" }
                } else {
                    if ($p.Kind -eq 'edge') { 'No replacement browser will be installed:' }
                    else                    { 'No browser will be installed:' }
                }
            }
            foreach ($n in $p.Buttons.Keys) {
                $btn = $p.Buttons[$n]
                $on = if ($want.Count) { $n -in $want } else { $n -eq $BROWSER_NONE }
                # Weight alone was enough when this was one-of-N. With several
                # on at once the set needs to be readable at a glance.
                $btn.FontWeight      = if ($on) { 'Bold' } else { 'Normal' }
                & $Ref $btn 'BorderBrush' $(if ($on) { 'Accent' } else { 'Line' })
                $btn.BorderThickness = New-Object Windows.Thickness $(if ($on) { 2 } else { 1 })
            }
        }
        # A browser occupies a drive like anything else and is not a row, so
        # nothing in the tally's loop would notice it.
        if ($storage.Paint) { & $storage.Paint }
        # And one row's presence depends on this answer: "Change default
        # browser" appears the moment a browser is queued.
        if ($applyFilterRef.Fn) { & $applyFilterRef.Fn }
        # Its picker lists what is here plus what is queued, so queueing one has
        # to put it on the list.
        if ($defBrowserUi.Refresh) { & $defBrowserUi.Refresh }
    }.GetNewClosure()

    # What a click on one of the buttons means: add it, or take it away. None is
    # not a browser, it is the way to clear the lot.
    $toggleBrowser = {
        param([string]$Name)
        if ($Name -eq $BROWSER_NONE) { & $setBrowsers @() $true; return }
        $now = @($state.BrowserChoices)
        if ($Name -in $now) { $now = @($now | Where-Object { $_ -ne $Name }) } else { $now = @($now) + $Name }
        & $setBrowsers $now $true
    }.GetNewClosure()

    # The strip is a sibling of the Edge row, not a child, so nothing hides it
    # implicitly.
    $showBrowserStrip = {
        param([bool]$EdgeOn)
        if (-not $browserUi.Strip) { return }
        $vis = $EdgeOn
        if ($vis -and $browserUi.Row -and $browserUi.Row.Panel.Visibility -ne 'Visible') { $vis = $false }
        $browserUi.Strip.Visibility = if ($vis) { 'Visible' } else { 'Collapsed' }
    }.GetNewClosure()

    # One entry point for every route into and out of Edge removal.
    $syncBrowser = {
        param([bool]$EdgeOn)
        if ($state.SyncingBrowser) { return }
        & $showBrowserStrip $EdgeOn
        if (-not $EdgeOn) {
            # Only a choice this made on the user's behalf is withdrawn. A
            # browser picked deliberately in Add is an install in its own right.
            if (@($state.BrowserChoices).Count -and $state.BrowserAuto) { & $setBrowsers @() $false }
            $state.BrowserAsked = $false
            return
        }
        if ($state.BrowserAsked) { return }
        $state.BrowserAsked = $true
        # A pick made earlier survives a trip through modes that leave Edge
        # alone.
        if ($null -ne $state.BrowserPreferred) {
            & $setBrowsers @($state.BrowserPreferred) $false
            return
        }
        if (@($state.BrowserChoices).Count) { return }
        # Nothing left to offer means every browser in the catalog is already
        # here.
        if (-not @($freeBrowsers).Count) { return }
        # Default rather than ask: the notice says what will happen and where to
        # change it.
        if ($browserDefault) {
            & $setBrowsers @($browserDefault) $false
            $state.BrowserAuto = $true
        }
        # Everything above this line has to run at boot, or a restored mode that
        # removes Edge opens with no queued browser and a hidden picker.
        if (-not $state.NoPrompts -and -not $state.Building) { & $tellBrowser }
    }.GetNewClosure()
    $browserSync.Fn = $syncBrowser

    # The install is a choice rather than a tick, so it is never a row - its id
    # is threaded into the selection here.
    $withBrowser = {
        param([string[]]$Ids)
        $out = @($Ids | Where-Object { $_ -ne $BROWSER_ID })
        if (@($state.BrowserChoices).Count) { $out += $BROWSER_ID }
        ,$out
    }

    # Built twice: the strip under the Edge row, and the standing block in Add.
    # Same handler, same state.
    $makeBrowserPicker = {
        param([string]$Kind)
        $set = $toggleBrowser
        $ui2 = $browserUi
        # Copied in because this is a closure and can only see its own locals.
        $strips = $rowStrips
        $edgeId = $EDGE_ID
        $entry = @{ Kind = $Kind; Label = $null; Buttons = @{} }

        $box = New-Object Windows.Controls.Border
        $box.Margin = $(if ($Kind -eq 'edge') { '30,0,0,8' } else { '0,0,0,8' })
        $box.Padding = '12,8,12,10'; $box.CornerRadius = 5
        & $Ref $box 'Background' 'Card'
        & $Ref $box 'BorderBrush' 'Line'
        $box.BorderThickness = New-Object Windows.Thickness 1
        if ($Kind -eq 'edge') { $box.Visibility = 'Collapsed' }

        $sp = New-Object Windows.Controls.StackPanel
        $lbl = New-Object Windows.Controls.TextBlock
        $lbl.FontSize = 12.5; $lbl.TextWrapping = 'Wrap'; $lbl.Margin = '0,0,0,6'
        & $Ref $lbl 'Foreground' 'Sub'
        $null = $sp.Children.Add($lbl)

        $wrap = New-Object Windows.Controls.WrapPanel
        # Copied in for the same reason.
        $here = $browserHere
        foreach ($n in @(@($browserNames) + $BROWSER_NONE)) {
            $btn = New-Object Windows.Controls.Button
            $btn.Content = $(if ($n -eq $BROWSER_NONE) { 'None' } else { $n })
            $btn.Padding = '10,3'; $btn.Margin = '0,0,6,4'; $btn.FontSize = 12.5
            $btn.Tag = $n
            # A browser the machine already has is not an offer: left enabled it
            # queued a download and an installer for something already here.
            if ($here.Contains([string]$n)) {
                $btn.Content   = "$n (installed)"
                $btn.IsEnabled = $false
                $btn.ToolTip   = 'Already on this machine, so there is nothing to install.'
            } else {
                $btn.Add_Click({ & $set $this.Tag }.GetNewClosure())
            }
            $null = $wrap.Children.Add($btn)
            $entry.Buttons[$n] = $btn
        }
        $null = $sp.Children.Add($wrap)
        $box.Child = $sp

        $entry.Box   = $box
        $entry.Label = $lbl
        $ui2.Panels.Add([pscustomobject]$entry)
        # The Edge one is also the row strip for the Edge row, so $fillColumns
        # places it.
        if ($Kind -eq 'edge') { $ui2.Strip = $box; $strips[$edgeId] = $box }
        $box
    }

    # Asking and disabling are two questions, and one function was answering
    # both - which is why a preset already applied showed a page of ticked rows
    # with nothing saying so.
    $alreadySatisfied = {
        param($item)
        foreach ($pat in @(Get-Prop $item 'detect' @())) {
            if (-not $pat) { continue }
            foreach ($n in $installedNames) { if ($n -like $pat) { return 'already installed' } }
        }
        # The inventory and the profile both matter and neither used to be
        # passed: without the inventory an appx or uninstall action can never
        # answer.
        $key = [string]$item.id
        if ($satisfiedMap.ContainsKey($key)) {
            if ($satisfiedMap[$key]) { return 'already applied' }
            return ''
        }
        if (Test-WDItemSatisfied -Item $item -Inventory $machineInv -Profile $Profile) { return 'already applied' }
        ''
    }
    # $alreadyDone answers the second, and is deliberately still tier 0 only: a
    # row a preset selects has to stay tickable.
    $alreadyDone = {
        param($item, [int]$tier)
        if ($tier -ne 0) { return '' }
        $r = [string](& $alreadySatisfied $item)
        # One word for the disabled case, because there the row is the claim.
        if ($r -eq 'already applied') { return 'already set' }
        $r
    }
    # Which parent rows count as satisfied without being ticked: PowerToys does
    # not have to be queued if it is already here.
    $installedIds = New-Object System.Collections.Generic.HashSet[string]

    # "Make your other browser the default" is the one row that means nothing
    # without an answer to this.
    $otherBrowserHere = [bool]($browserHere.Count)
    # A browser queued for install counts too, and that changes while the page
    # is open - hence a gate re-asked on every filter pass.
    $rowGate['set-default-browser'] = {
        [bool]($otherBrowserHere -or @($state.BrowserChoices).Count)
    }.GetNewClosure()

    # Matched on the category id rather than its name, which is a label.
    $STORAGE_CAT = 'storage'

    # Only registry values written with scope allusers have a per-account
    # answer. Everything else is machine-wide and always was.
    $accountList = @()
    try { $accountList = @(Get-WDUserAccounts) } catch { }
    # Which rows the choice actually governs, worked out once from the actions.
    $perUserIds = New-Object System.Collections.Generic.HashSet[string]
    foreach ($cat in $Categories) {
        foreach ($item in @(Get-Prop $cat 'items' @())) {
            foreach ($a in @(Get-Prop $item 'actions' @())) {
                if ([string]$a.type -eq 'registry' -and [string](Get-Prop $a 'scope' '') -ieq 'allusers') {
                    $null = $perUserIds.Add([string]$item.id); break
                }
                # The taskbar blob is a per-user registry write in all but name.
                if ([string]$a.type -eq 'script' -and [string](Get-Prop $a 'handler' '') -eq 'SetTaskbarAutoHide') {
                    $null = $perUserIds.Add([string]$item.id); break
                }
            }
        }
    }
    $accountTags = New-Object System.Collections.Generic.List[psobject]

    # A row is a click target the width of half the window, and without the
    # hover tint there is nothing to say so.

    # What the Details panel says: the risk note first, then what the option
    # changes, then whether it can be taken back.
    $itemDetailParts = {
        param($Item, [switch]$Live)
        $m    = Get-WDItemMechanics -Item $Item -ShowState:$Live
        $part = New-Object System.Collections.Generic.List[hashtable]

        # The risk note comes first, and that is the whole reason it is a
        # separate part: it is the one thing written to stop somebody, and it
        # was under forty lines of registry paths.
        $risk = [int](Get-Prop $Item 'risk' 0)
        if ($riskStyle.ContainsKey($risk)) {
            $note = [string](Get-Prop $Item 'riskNote' '')
            if (-not $note) { $note = 'No explanation was recorded for this one.' }
            $part.Add(@{ Text = ([string]$riskStyle[$risk].Label).ToUpper() + "`r`n  " + $note + "`r`n`r`n"
                         Ink  = $riskStyle[$risk].Col })
        }

        $out  = New-Object System.Collections.Generic.List[string]
        $out.Add('WHAT THIS CHANGES')
        if (@($m.Lines).Count) {
            foreach ($l in @($m.Lines)) { $out.Add("  $l") }
        } else {
            $out.Add('  Nothing was recorded for this one.')
        }
        # The count, because a panel listing thirty values is one nobody adds up
        # by eye - and "nothing, it is all already set" is the most useful thing
        # it can say.
        $marked = @($m.Lines | Where-Object { $_ -match '\[(already set|will be set|already set for)' })
        if ($marked.Count) {
            $todo = @($marked | Where-Object { $_ -match '\[will be set\]' }).Count +
                    @($marked | Where-Object { $_ -match '\[already set for' }).Count
            $out.Add('')
            if ($todo -eq 0) {
                $out.Add("All $($marked.Count) of these are already set. Applying this would change nothing.")
            } else {
                $out.Add("$todo of $($marked.Count) still to do; the rest are already set.")
            }
        }
        $part.Add(@{ Text = ($out -join "`r`n"); Ink = 'Sub' })

        # Three-valued, because the honest answer is: "undoing the run puts
        # every one of these back exactly" was untrue of anything that deletes.
        $part.Add(@{ Text = "`r`n`r`nRevertible: $($m.Revert)"; Ink = 'Sub' })
        ,$part
    }.GetNewClosure()

    # The flat view. Everything that wants one string comes through here, so
    # none of them can drift from the panel.
    $itemDetail = {
        param($Item, [switch]$Live)
        $parts = & $itemDetailParts $Item -Live:$Live
        $sb = New-Object System.Text.StringBuilder
        foreach ($p in $parts) { $null = $sb.Append([string]$p.Text) }
        $sb.ToString()
    }.GetNewClosure()

    # The chip that opens it. The shape is what says "button" - a border, a hand
    # cursor, a hover fill.
    $terseLead = {
        param($Facts)
        $out = New-Object System.Collections.Generic.List[hashtable]
        if (-not $Facts) { return ,$out }
        # One row, comma separated, at the very start: these are the tags that
        # used to sit beside the name.
        $words = @(@($Facts.Status) | Where-Object { $_ })
        if ($words.Count) {
            $out.Add(@{ Text = ($words -join ', ') + "`r`n`r`n"; Ink = 'Muted' })
        }
        if ([string]$Facts.Desc) {
            $out.Add(@{ Text = ([string]$Facts.Desc) + "`r`n`r`n"; Ink = 'Sub' })
        }
        if ([string]$Facts.Over) {
            $out.Add(@{ Text = ([string]$Facts.Over) + "`r`n`r`n"; Ink = 'Warn' })
        }
        ,$out
    }.GetNewClosure()

    $makeDetailChip = {
        param([string]$Title, $Item, $Stack, $StateRef, $Facts)
        $setBrush = $Ref
        $partsFn  = $itemDetailParts
        $leadFn   = $terseLead
        # It has to read as a button at rest, not only under the pointer.
        $chip = New-Object Windows.Controls.Border
        $chip.CornerRadius = New-Object Windows.CornerRadius 4
        $chip.Padding = '9,2,9,3'; $chip.Margin = '8,2,0,0'
        $chip.BorderThickness = New-Object Windows.Thickness 1
        $chip.VerticalAlignment = 'Center'
        & $Ref $chip 'BorderBrush' 'BtnBorder'
        & $Ref $chip 'Background' 'BtnBg'
        $chip.Cursor = 'Hand'
        $t = New-Object Windows.Controls.TextBlock
        $t.Text = 'Details'; $t.FontSize = 11
        & $Ref $t 'Foreground' 'Text'
        $chip.Child = $t
        # The label is repainted too: a chip whose edge lights while its word
        # stays gray reads as a hover effect on a label.
        $chip.Tag = @{ Title = $Title; Item = $Item; State = $StateRef; Label = $t
                       Stack = $Stack; Panel = $null; Facts = $Facts; Lead = $leadFn }
        $chip.Add_MouseEnter({
            & $setBrush $this 'Background' 'RowHover'; & $setBrush $this 'BorderBrush' 'Accent'
            & $setBrush $this.Tag.Label 'Foreground' 'Accent'
        }.GetNewClosure())
        $chip.Add_MouseLeave({
            & $setBrush $this 'Background' 'BtnBg';    & $setBrush $this 'BorderBrush' 'BtnBorder'
            & $setBrush $this.Tag.Label 'Foreground' 'Text'
        }.GetNewClosure())
        $chip.Add_MouseLeftButtonUp({
            $d = $this.Tag
            # The state read happens here and only here: every line saying
            # whether a value is already what this would write costs a registry
            # read, and doing it per row cost 2.5 seconds of the build.
            $parts = $(if ($d.Item -is [string]) {
                           @(@{ Text = [string]$d.Item; Ink = 'Sub' })
                       } else { @(& $partsFn $d.Item -Live) })
            # Under Non-verbose the row is no longer saying any of this, so the
            # panel does.
            if ($d.State.Terse -and $d.Facts) {
                # Assigned first, then wrapped. $terseLead ends in ,$out so a
                # caller who assigns gets the list.
                $lead = & $d.Lead $d.Facts
                if ($lead.Count) { $parts = @($lead) + @($parts) }
            }
            if ($d.State.DetailPopup -or -not $d.Stack) {
                # 'None', not 'Information': MessageBox couples the icon to a
                # system sound, and reading a description is not an event.
                if (-not $d.State.NoPrompts) {
                    $flat = New-Object System.Text.StringBuilder
                    foreach ($p in $parts) { $null = $flat.Append([string]$p.Text) }
                    Show-WDMessage ($flat.ToString(), "$($d.Title) - what this does", 'OK', 'None') | Out-Null
                }
                $args[1].Handled = $true
                return
            }
            # Open already: fold it and stop. The element is kept.
            if ($d.Panel -and $d.Panel.Visibility -eq 'Visible') {
                $d.Panel.Visibility = 'Collapsed'
                $args[1].Handled = $true
                return
            }
            if (-not $d.Panel) {
                $tb = New-Object Windows.Controls.TextBlock
                $tb.FontSize = 12; $tb.Margin = '2,4,8,7'
                $tb.TextWrapping = 'Wrap'; $tb.LineHeight = 18
                $tb.LineStackingStrategy = 'BlockLineHeight'
                $null = $d.Stack.Children.Add($tb)
                $d.Panel = $tb
            }
            # Filled on every open, not once when the element was made: what it
            # says can change between two presses of the same chip.
            $d.Panel.Inlines.Clear()
            foreach ($p in $parts) {
                $run = New-Object Windows.Documents.Run
                $run.Text = [string]$p.Text
                & $setBrush $run 'Foreground' ([string]$p.Ink)
                $null = $d.Panel.Inlines.Add($run)
            }
            $d.Panel.Visibility = 'Visible'
            $args[1].Handled = $true
        }.GetNewClosure())
        $chip
    }.GetNewClosure()

    $makeItemRow = {
        param($item, $catName, $catId, $secName)
        if (-not $secName) { $secName = 'remove' }
        # $Ref copied into this scope on purpose: GetNewClosure captures the
        # local scope only.
        $setBrush = $Ref

        $tier = Get-WDItemTier -Item $item
        $risk = [int](Get-Prop $item 'risk' 0)
        # Copied into this scope so the handlers below capture it.
        $undoRef = $advUndoRef

        # An item that only makes sense underneath another one is indented and
        # hidden until its parent is ticked.
        $needs = [string](Get-Prop $item 'requires' '')

        $panel = New-Object Windows.Controls.DockPanel
        $panel.Margin = $(if ($needs) { '26,5,0,5' } else { '0,5,0,5' })
        $panel.LastChildFill = $true
        & $Ref $panel 'Background' 'Flat'
        # The hover handlers are attached further down, once it is known whether
        # this row is one the machine can act on.

        $cb = New-Object Windows.Controls.CheckBox
        $cb.IsChecked = $false
        $cb.VerticalAlignment = 'Top'
        $cb.Margin = '0,4,8,0'
        $cb.Tag = [string]$item.id
        [Windows.Controls.DockPanel]::SetDock($cb, 'Left')
        $null = $panel.Children.Add($cb)
        # Click, not Checked: Checked fires for every programmatic set, so
        # applying a preset would push 200 entries onto the undo stack.
        $cb.Add_Click({
            if ($undoRef.Push) { & $undoRef.Push @(@{ Id = [string]$this.Tag; Was = (-not $this.IsChecked) }) }
        }.GetNewClosure())

        # Only a real application icon earns space here. A generic category
        # glyph on every row is noise.
        $src = $null
        $ik  = [string](Get-Prop $item 'iconKind' '')
        $inm = [string](Get-Prop $item 'iconName' '')
        if ($ik -and $inm) { $src = Get-WDIconSource -Path (Get-WDIconPath -Kind $ik -Name $inm) }
        if ($src) {
            $img = New-Object Windows.Controls.Image
            $img.Source = $src; $img.Width = 22; $img.Height = 22; $img.Margin = '0,2,8,0'
            $img.VerticalAlignment = 'Top'
            [Windows.Controls.DockPanel]::SetDock($img, 'Left')
            $null = $panel.Children.Add($img)
        }

        $stack = New-Object Windows.Controls.StackPanel
        # WrapPanel, not a horizontal StackPanel: that measures every child with
        # infinite width, so nothing wraps and the last chip is drawn off the
        # card.
        $line  = New-Object Windows.Controls.WrapPanel
        $line.Orientation = 'Horizontal'

        $name = New-Object Windows.Controls.TextBlock
        $name.Text = [string](Get-Prop $item 'name' $item.id)
        $name.FontSize = 15; $name.FontWeight = 'SemiBold'
        & $Ref $name 'Foreground' 'Text'
        $name.TextWrapping = 'Wrap'
        $null = $line.Children.Add($name)

        # Filled in by $updateTally when this row differs from the preset.
        # Colour alone is not enough, so it carries a word.
        $diffTag = New-Object Windows.Controls.TextBlock
        $diffTag.FontSize = 11.5; $diffTag.Margin = '8,4,0,0'; $diffTag.FontWeight = 'Bold'
        $diffTag.Visibility = 'Collapsed'
        $null = $line.Children.Add($diffTag)

        # What this row does to the drive: negative frees, positive fills.
        $rowDelta = 0L
        $rowBlind = 0
        if ($Presence -and $Presence.ContainsKey([string]$item.id)) {
            $rowDelta = -[int64]$Presence[[string]$item.id].Bytes
            $rowBlind = [int]$Presence[[string]$item.id].Blind
        }
        $addMb = [int](Get-Prop $item 'installSize' 0)
        if ($addMb -gt 0) { $rowDelta = [int64]$addMb * 1MB }

        # Only when it is worth a decision: every row used to carry its figure,
        # which put "-4 MB" beside two hundred names.
        $SIZE_TAG_FLOOR = 1GB
        $sizeTag = $null
        if ([string]$catId -eq $STORAGE_CAT -or [Math]::Abs($rowDelta) -ge $SIZE_TAG_FLOOR) {
            $sizeTag = New-Object Windows.Controls.TextBlock
            $sizeTag.FontSize = 11.5; $sizeTag.Margin = '8,4,0,0'; $sizeTag.FontWeight = 'Bold'
            if ([string]$catId -eq $STORAGE_CAT) {
                $sizeTag.Text = 'measuring'
                & $Ref $sizeTag 'Foreground' 'Muted'
            } else {
                $sizeTag.Text = $(if ($rowDelta -gt 0) { '+' } else { '-' }) + (Format-WDBytes ([Math]::Abs($rowDelta)))
                & $Ref $sizeTag 'Foreground' $(if ($rowDelta -gt 0) { 'Warn' } else { 'Accent' })
                $sizeTag.ToolTip = $(if ($rowDelta -gt 0) {
                    'Roughly what this occupies once installed. An authored figure, not a measurement - nothing here knows the size of something that is not installed yet.'
                } else {
                    'The size this program recorded in its own uninstall entry. Installers are not always careful about that number, so treat it as a ballpark.'
                })
            }
            $null = $line.Children.Add($sizeTag)
        }

        # One probe per row, read two ways: it is the most expensive thing on a
        # row, so it is asked once and both answers come out of it.
        $absent = $false
        if ($Presence -and $Presence.ContainsKey([string]$item.id)) {
            $absent = ($false -eq $Presence[[string]$item.id].Present)
        }
        $satisfied = ''
        if (-not $absent) { $satisfied = [string](& $alreadySatisfied $item) }
        # Whichever of the three status words this row wears. Exactly one is
        # possible.
        $terseTag = $null
        # Already done and not a decision: say so, gray it out, take it out of
        # play.
        $here = $(if ($tier -eq 0) {
                      if ($satisfied -eq 'already applied') { 'already set' } else { $satisfied }
                  } else { '' })
        # One element, built on every row, whichever word it ends up wearing -
        # or none. It was three TextBlocks in three branches, so a row whose
        # answer changed needed an element that was never created.
        $terseTag = New-Object Windows.Controls.TextBlock
        $terseTag.FontSize = 11; $terseTag.Margin = '6,4,0,0'
        $terseTag.Visibility = 'Collapsed'
        $null = $line.Children.Add($terseTag)

        # And one place that decides what it says, so Refresh and the build
        # cannot disagree.
        $stateHere = $state
        # What the row is currently saying about itself, for the Details panel
        # to pick up when Non-verbose has taken it off the row.
        $rowFacts = @{ Status = @(); Desc = ''; Over = ''; Absent = $absent }
        $paintStatus = {
            param([string]$Word, [string]$Sat, [int]$Tr)
            if ($Word) {
                $terseTag.Text = "  $Word"
                & $setBrush $terseTag 'Foreground' 'Ok'
                $terseTag.ToolTip = $(if ($Word -eq 'already installed') {
                    'Found in the installed programs list, so there is nothing to do.'
                } else {
                    'This machine is already set up this way, so there is nothing to do.'
                })
                $terseTag.Visibility = 'Visible'
            }
            # Already done and a preset does select it: tag it, leave it alone.
            # The row stays live and stays ticked.
            elseif ($Sat) {
                $terseTag.Text = "  $Sat"
                & $setBrush $terseTag 'Foreground' 'Ok'
                $terseTag.ToolTip = 'Every change this option makes is already in place, so applying it would report nothing to do. It is still ticked because it is part of what this mode covers - untick it if you want it out of the run.'
                $terseTag.Visibility = 'Visible'
            }
            elseif ($Tr -eq 0) {
                $terseTag.Text = '  opt-in'
                & $setBrush $terseTag 'Foreground' 'Muted'
                $terseTag.ToolTip = 'No preset selects this. Tick it yourself if you want it.'
                $terseTag.Visibility = 'Visible'
            }
            else { $terseTag.Visibility = 'Collapsed' }
            if ($stateHere.Terse) { $terseTag.Visibility = 'Collapsed' }
            # Rebuilt rather than appended, so a row that stops being
            # outstanding stops saying it.
            $words = New-Object System.Collections.Generic.List[string]
            if ($Word)          { $words.Add($Word) }
            elseif ($Sat)       { $words.Add($Sat) }
            elseif ($Tr -eq 0)  { $words.Add('opt-in') }
            if ($rowFacts.Absent) { $words.Add('not on this machine') }
            $rowFacts.Status = @($words)
        }.GetNewClosure()

        if ($here) {
            $null = $installedIds.Add([string]$item.id)
            $cb.IsEnabled  = $false
            $cb.IsChecked  = $false
            & $Ref $name 'Foreground' 'Muted'
        }
        & $paintStatus $here $satisfied $tier

        # Only rows the account choice governs get this: a policy in HKLM
        # applies to the whole machine.
        if ($perUserIds.Contains([string]$item.id)) {
            $acct = New-Object Windows.Controls.TextBlock
            $acct.FontSize = 11; $acct.Margin = '6,4,0,0'
            & $Ref $acct 'Foreground' 'Muted'
            $null = $line.Children.Add($acct)
            $accountTags.Add([pscustomobject]@{ Id = [string]$item.id; Tag = $acct })
        }

        if ($absent) {
            # Full size, and unmistakably not a decision. These were drawn at
            # half scale under Non-verbose, which saved room and cost legibility
            # - a name at 7pt is not read.
            & $Ref $name 'Foreground' 'Muted'
            $name.TextDecorations = [Windows.TextDecorations]::Strikethrough
            # On the panel, so it carries the tick box and every tag with it.
            $panel.Opacity = 0.6
            $gone = New-Object Windows.Controls.TextBlock
            $gone.Text = '  not on this machine'; $gone.FontSize = 11; $gone.Margin = '6,4,0,0'
            & $Ref $gone 'Foreground' 'Muted'
            $gone.ToolTip = 'Every target this item names was looked for and none of them is here, so a run would report nothing to do. It is still listed because it says what the toolkit covers.'
            $null = $line.Children.Add($gone)
        }

        # Built from the item's own actions rather than from anything anybody
        # wrote twice.
        $detailText = & $itemDetail $item

        if ($riskStyle.ContainsKey($risk)) {
            $badge = New-Object Windows.Controls.Border
            $badge.CornerRadius = 3; $badge.Padding = '6,1,6,2'; $badge.Margin = '8,3,0,0'
            $badge.BorderThickness = New-Object Windows.Thickness 1
            & $Ref $badge 'BorderBrush' $riskStyle[$risk].Col
            # A marker, not a control. It used to open a dialog of its own, so a
            # row with a badge had two things to click and each said half an
            # answer.
            $bt = New-Object Windows.Controls.TextBlock
            $bt.Text = $riskStyle[$risk].Label
            $bt.FontSize = 11
            & $Ref $bt 'Foreground' $riskStyle[$risk].Col
            $badge.Child = $bt
            $null = $line.Children.Add($badge)
        }

        # And a way in for the other two hundred rows: the risk badge was the
        # only route to the per-item detail.
        $detChip = & $makeDetailChip ([string](Get-Prop $item 'name' $item.id)) $item $stack $state $rowFacts
        $null = $line.Children.Add($detChip)
        $null = $stack.Children.Add($line)

        # Held, because Non-verbose takes it away.
        $descEl = $null
        $descText = [string](Get-Prop $item 'desc' '')
        if ($descText) {
            $d = New-Object Windows.Controls.TextBlock
            $d.Text = $descText; $d.FontSize = 13; $d.TextWrapping = 'Wrap'; $d.Margin = '0,2,0,0'
            & $Ref $d 'Foreground' 'Sub'
            # Built collapsed under Non-verbose rather than skipped, and asked
            # here rather than only in $applyTerse: rows are built lazily.
            if ($state.Terse) { $d.Visibility = 'Collapsed' }
            $null = $stack.Children.Add($d)
            $descEl = $d
        }
        $rowFacts.Desc = $descText

        # There was a $showOverhead switch here, passed true only by the
        # hand-built Recurring block. The field's presence already says the same
        # thing.
        $ovhEl = $null
        $ovh = [string](Get-Prop $item 'overhead' '')
        if ($ovh) {
            $o = New-Object Windows.Controls.TextBlock
            $o.Text = 'Cost: ' + $ovh
            $o.FontSize = 12.5; $o.TextWrapping = 'Wrap'; $o.Margin = '0,4,0,0'
            & $Ref $o 'Foreground' 'Warn'
            if ($state.Terse) { $o.Visibility = 'Collapsed' }
            $null = $stack.Children.Add($o)
            $ovhEl = $o
            $rowFacts.Over = 'Cost: ' + $ovh
        }

        # Built empty on every row rather than only where a rule exists:
        # $EXCLUSIONS is data, and a rule can name any id.
        $gate = New-Object Windows.Controls.TextBlock
        $gate.FontSize = 12.5; $gate.TextWrapping = 'Wrap'; $gate.Margin = '0,4,0,0'
        $gate.Visibility = 'Collapsed'
        & $Ref $gate 'Foreground' 'Warn'
        $null = $stack.Children.Add($gate)

        $null = $panel.Children.Add($stack)

        # A row with nothing to act on is inert: the box refuses a tick, the row
        # ignores a click, and the pointer gets no tint.
        if ($absent) {
            $cb.IsEnabled = $false
            $panel.Cursor = 'Arrow'
            $panel.Opacity = 0.75
        } else {
            $panel.Cursor = 'Hand'
            $panel.Add_MouseEnter({ & $setBrush $this 'Background' 'RowHover' }.GetNewClosure())
            $panel.Add_MouseLeave({ & $setBrush $this 'Background' 'Flat'     }.GetNewClosure())
        }
        $panel.Tag = $cb
        $panel.Add_MouseLeftButtonUp({
            # IsEnabled does not block a programmatic set, so the row click has
            # to honour it too.
            if (-not $args[1].Handled -and $this.Tag.IsEnabled) {
                $was = [bool]$this.Tag.IsChecked
                $this.Tag.IsChecked = -not $was
                # The box's own Click never fires for this route, so the row
                # records its own gesture.
                if ($undoRef.Push) { & $undoRef.Push @(@{ Id = [string]$this.Tag.Tag; Was = $was }) }
            }
        }.GetNewClosure())

        # Nothing here for Non-verbose any more: an absent row is drawn full
        # size and struck through instead.

        [pscustomobject]@{
            Id = [string]$item.id; Tier = $tier; Risk = $risk
            Bloat = [int](Get-Prop $item 'bloat' 0)
            Check = $cb; Panel = $panel; Category = $catName; CatId = [string]$catId; Section = $secName
            # A row that belongs in one of the page's fixed blocks rather than
            # its category's columns.
            HostBlock = [string](Get-Prop $item 'block' '')
            Name = $name; DiffTag = $diffTag; SizeTag = $sizeTag; Requires = $needs
            # The Details chip's Tag, where the expanded panel lands on first
            # open. Held so Collapse all can shut every one.
            Detail = $detChip.Tag
            # What Non-verbose takes away: the standing description, the cost
            # line, and whichever status word this row wears.
            Desc = $descEl; Over = $ovhEl; TerseTag = $terseTag
            # The item, and the one place that repaints the status word: Refresh
            # re-reads the machine and needs both.
            Item = $item; PaintStatus = $paintStatus
            # Gated separately from Absent: one means another tick has taken
            # this row away, the other means the machine has.
            Gate = $gate; Gated = $false
            # Done is "refuses a tick because it is finished" and is tier 0
            # only; Applied is "a run would find nothing to do here".
            Absent = $absent; Done = [bool]$here; Applied = [bool]$satisfied
            Delta = $rowDelta; Blind = $rowBlind
            # The detail text is in here, which is what makes a registry path
            # findable by typing it.
            Search = (([string](Get-Prop $item 'name' '')) + ' ' + $descText + ' ' + $catName + ' ' + $detailText).ToLower()
        }
    }

        & $say 'Building the interface' 'Laying out the item list'

    # Fills a pair of columns newspaper fashion: the first half down the left,
    # the rest down the right.
    $fillColumns = {
        param($RowList, $ColL, $ColR, $Grid)

        $ColL.Children.Clear(); $ColR.Children.Clear()
        $list = @($RowList)

        # A dependent row travels with its parent wherever the parent lands; one
        # whose parent is not in the list stands alone rather than vanishing.
        $here = New-Object System.Collections.Generic.HashSet[string]
        foreach ($r in $list) { $null = $here.Add([string]$r.Id) }
        $kids = @{}
        foreach ($r in $list) {
            if ($r.Requires -and $here.Contains([string]$r.Requires)) {
                if (-not $kids.ContainsKey([string]$r.Requires)) {
                    $kids[[string]$r.Requires] = New-Object System.Collections.Generic.List[psobject]
                }
                $kids[[string]$r.Requires].Add($r)
            }
        }
        # Weighed by what is on the page, not by how many rows exist: a
        # Collapsed row takes no height.
        $groups  = New-Object System.Collections.Generic.List[psobject]
        $weights = New-Object System.Collections.Generic.List[int]
        $total   = 0
        foreach ($r in $list) {
            if ($r.Requires -and $here.Contains([string]$r.Requires)) { continue }
            $block = New-Object System.Collections.Generic.List[psobject]
            $block.Add($r)
            if ($kids.ContainsKey([string]$r.Id)) { foreach ($k in $kids[[string]$r.Id]) { $block.Add($k) } }
            $groups.Add($block)
            $w = 0
            foreach ($x in $block) { if ($x.Panel.Visibility -eq 'Visible') { $w++ } }
            $weights.Add($w)
            $total += $w
        }

        # The boundary that leaves the two columns closest in height, rather
        # than the first group to cross halfway.
        $split = 0
        if ($total -ge 4) {
            $run = 0; $bestGap = [double]::PositiveInfinity
            for ($i = 0; $i -lt $groups.Count; $i++) {
                $run += $weights[$i]
                $gap = [Math]::Abs($run - ($total - $run))
                if ($gap -lt $bestGap) { $bestGap = $gap; $split = $i + 1 }
            }
        } else {
            $split = $groups.Count
        }

        for ($gi = 0; $gi -lt $groups.Count; $gi++) {
            $target = $(if ($gi -lt $split) { $ColL } else { $ColR })
            foreach ($r in $groups[$gi]) {
                # A row that still has a parent means two groups in this order
                # both listed it. Caught here rather than left to WPF, whose
                # message names neither.
                if ($r.Panel.Parent) { throw "row '$($r.Id)' is listed by two groups in this order" }
                $null = $target.Children.Add($r.Panel)
                # A strip belonging to this row goes in as a sibling, not a
                # child, so nothing hides it implicitly.
                if ($rowStrips.ContainsKey([string]$r.Id)) {
                    $strip = $rowStrips[[string]$r.Id]
                    if ($strip.Parent) { $strip.Parent.Children.Remove($strip) }
                    $null = $target.Children.Add($strip)
                }
            }
        }

        # Nothing landed on the right, so give its width back: half a window of
        # nothing beside four rows reads as a layout gone wrong.
        $rightDrawn = 0
        foreach ($c in $ColR.Children) { if ($c.Visibility -eq 'Visible') { $rightDrawn++ } }
        if ($Grid) {
            if ($rightDrawn) {
                $Grid.ColumnDefinitions[1].Width = New-WDGridLength 30
                $Grid.ColumnDefinitions[2].Width = New-WDGridLength 1 'Star'
            } else {
                $Grid.ColumnDefinitions[1].Width = New-WDGridLength 0
                $Grid.ColumnDefinitions[2].Width = New-WDGridLength 0
            }
        }
    }.GetNewClosure()

    # One group, full width, its own rows in two columns inside it.
    $shutRowDetails = {
        param($Rows)
        foreach ($r in @($Rows)) {
            if ($r.Detail -and $r.Detail.Panel) { $r.Detail.Panel.Visibility = 'Collapsed' }
        }
    }

    $setGroupOpen = {
        param($Grid, $Note, $Btn, [bool]$Open, $GroupRows)
        $v = $(if ($Open) { 'Visible' } else { 'Collapsed' })
        $Grid.Visibility = $v
        if ($Note) { $Note.Visibility = $v }
        $Btn.Content = $(if ($Open) { '-' } else { '+' })
        $Btn.ToolTip = $(if ($Open) { 'Collapse this group' } else { 'Expand this group' })
        if (-not $Open -and $GroupRows) { & $shutRowDetails $GroupRows }
    }

    $makeGroupBlock = {
        param([string]$Title, [string]$Glyph, [string]$Section, $GroupRows, [string]$Note)

        $block = New-Object Windows.Controls.StackPanel
        $grid  = New-Object Windows.Controls.Grid
        foreach ($w in @((New-WDGridLength 1 'Star'), (New-WDGridLength 30), (New-WDGridLength 1 'Star'))) {
            $cd = New-Object Windows.Controls.ColumnDefinition
            $cd.Width = $w
            $grid.ColumnDefinitions.Add($cd)
        }
        $colL = New-Object Windows.Controls.StackPanel
        $colR = New-Object Windows.Controls.StackPanel
        [Windows.Controls.Grid]::SetColumn($colL, 0)
        [Windows.Controls.Grid]::SetColumn($colR, 2)
        $null = $grid.Children.Add($colL)
        $null = $grid.Children.Add($colR)

        $headPanel = New-Object Windows.Controls.StackPanel
        $headPanel.Orientation = 'Horizontal'; $headPanel.Margin = '0,18,0,6'
        if ($Glyph) {
            $hg = New-Object Windows.Controls.TextBlock
            $hg.Text = $Glyph
            $hg.FontFamily = New-Object Windows.Media.FontFamily 'Segoe UI Emoji'
            $hg.FontSize = 16; $hg.Margin = '0,0,8,0'
            & $Ref $hg 'Foreground' 'Text'
            $null = $headPanel.Children.Add($hg)
        }
        $head = New-Object Windows.Controls.TextBlock
        $head.Text = $Title; $head.FontSize = 16; $head.FontWeight = 'SemiBold'
        & $Ref $head 'Foreground' 'Text'; $head.TextWrapping = 'Wrap'
        $null = $headPanel.Children.Add($head)
        $null = $block.Children.Add($headPanel)

        # Fainter than the box edge around the whole section: at full strength
        # every group read as its own boxed section.
        $rule = New-Object Windows.Controls.Border
        $rule.Height = 1; & $Ref $rule 'Background' 'Line'; $rule.Opacity = 0.55; $rule.Margin = '0,0,0,4'
        $null = $block.Children.Add($rule)

        # One line of prose under the heading, only where a category has
        # something no row name can say.
        $sub = $null
        if ($Note) {
            $sub = New-Object Windows.Controls.TextBlock
            $sub.Text = $Note; $sub.FontSize = 12.5; $sub.TextWrapping = 'Wrap'
            $sub.Margin = '0,0,0,6'
            & $Ref $sub 'Foreground' 'Sub'
            $null = $block.Children.Add($sub)
        }
        $null = $block.Children.Add($grid)

        # Plain assignment and an explicit null test: an empty collection is
        # falsy, and an if-expression unrolls it to $null.
        $rowList = $GroupRows
        if ($null -eq $rowList) { $rowList = New-Object System.Collections.Generic.List[psobject] }

        # Buttons on the heading, and the heading itself is inert: with a
        # collapse control on the same line, clicking the name is as likely to
        # mean "fold this away" as "take all of it".
        $toggle = New-Object Windows.Controls.Button
        $toggle.Content = '-'
        $toggle.Width = 24; $toggle.Padding = '0,1'; $toggle.FontSize = 13
        $toggle.FontWeight = 'Bold'; $toggle.Margin = '10,0,0,0'
        $toggle.VerticalAlignment = 'Center'
        $toggle.ToolTip = 'Collapse this group'
        # Index rather than Rows: collapsing a group moves every heading below
        # it, so the rail's measured offsets are stale afterwards.
        $toggle.Tag = @{ Body = $grid; Note = $sub; Index = $indexRef; Set = $setGroupOpen; Rows = $rowList }
        $toggle.Add_Click({
            $t = $this.Tag
            & $t.Set $t.Body $t.Note $this (-not ($t.Body.Visibility -eq 'Visible')) $t.Rows
            if ($t.Index.Invalidate) { & $t.Index.Invalidate }
            if ($t.Index.Spy) { & $t.Index.Spy }
        }.GetNewClosure())
        $null = $headPanel.Children.Add($toggle)

        # Takes the whole group and takes it back. It acts on what is visible,
        # so it respects the filter.
        $selAll = New-Object Windows.Controls.Button
        $selAll.Content = 'Select all'
        $selAll.FontSize = 11.5; $selAll.Padding = '8,2'
        $selAll.Margin = '8,0,0,0'; $selAll.VerticalAlignment = 'Center'
        $selAll.ToolTip = 'Ticks every option in this group that is on screen and can be ticked. Press again to clear them.'
        $selAll.Tag = @{ Rows = $rowList; State = $state; Tally = $updateTallyRef; Undo = $advUndoRef }
        $selAll.Add_Click({
            $t = $this.Tag
            $vis = @($t.Rows | Where-Object { $_.Panel.Visibility -eq 'Visible' -and $_.Check.IsEnabled })
            if (-not $vis.Count) { return }
            $want = @($vis | Where-Object { -not $_.Check.IsChecked }).Count -gt 0
            # One gesture, one undo entry - taking a whole group back one row at
            # a time would be worse than not offering it.
            $changed = @($vis | Where-Object { [bool]$_.Check.IsChecked -ne $want } |
                         ForEach-Object { @{ Id = $_.Id; Was = [bool]$_.Check.IsChecked } })
            # Suspend, or every box in the group restyles all ~200 rows.
            $t.State.Suspend = $true
            try   { foreach ($r in $vis) { $r.Check.IsChecked = $want } }
            finally { $t.State.Suspend = $false }
            if ($t.Tally.Fn) { & $t.Tally.Fn }
            if ($t.Undo.Push) { & $t.Undo.Push $changed }
        }.GetNewClosure())
        $null = $headPanel.Children.Add($selAll)

        # Puts this group back to what the selected mode does, and nothing else.
        # Measured against $defaultIds rather than $effectiveIds, which folds in
        # every other group's edits.
        $reset = New-Object Windows.Controls.Button
        $reset.Content = 'Reset'
        $reset.FontSize = 11.5; $reset.Padding = '8,2'
        $reset.Margin = '8,0,0,0'; $reset.VerticalAlignment = 'Center'
        $reset.Visibility = 'Collapsed'
        $reset.ToolTip = 'Puts this group back to what the selected mode removes, leaving your changes to every other group alone.'
        $reset.Tag = @{ Rows = $rowList; Ref = $groupResetRef }
        $reset.Add_Click({
            $t = $this.Tag
            if ($t.Ref.Do) { & $t.Ref.Do $t.Rows }
        }.GetNewClosure())
        $null = $headPanel.Children.Add($reset)

        # Ordered and VisN are filled by $applyOrder and read by
        # $rebalanceGroups.
        [pscustomobject]@{ Name = $Title; Head = $headPanel; Rule = $rule; Rows = $rowList
                           Section = $Section; Block = $block
                           L = $colL; R = $colR; Grid = $grid; Note = $sub
                           SelAll = $selAll; Toggle = $toggle; Reset = $reset
                           Ordered = $rowList; VisN = -1 }
    }.GetNewClosure()

    $catHeaders = New-Object System.Collections.Generic.List[psobject]

    # The rows: the expensive half of the application, and why any of this is
    # deferred. The unit is a fixed number of rows, because rows are what cost.
    $CAT_CHUNK = 8
    foreach ($cat in $normalCats) {
    $catBox = @{ Cat = $cat; Items = $null; At = 0; InCat = $null; Step = $null }
    $catStep = {
        if ($null -eq $catBox.Items) {
            # $knownIds, not a second Test-WDItemApplies - worth 1.9s of the
            # deferred build, and it removes the chance of the page and the
            # preset counts disagreeing.
            $catBox.Items = @($catBox.Cat.items |
                              Where-Object { $knownIds.Contains([string]$_.id) } |
                              Sort-Object { [string](Get-Prop $_ 'name' $_.id) })
            # return, not continue: this is one category's own scriptblock, and
            # there is no loop here.
            if (-not $catBox.Items.Count) { return }
            if ($advSay.Fn) { & $advSay.Fn ([string]$catBox.Cat.name) }

            # A category is one section or the other; an item that disagrees
            # with its category still reports its own.
            $secName = Get-WDItemSection -Item $null -Category $catBox.Cat
            $catBox.InCat = New-Object System.Collections.Generic.List[psobject]
            $g = & $makeGroupBlock ([string]$catBox.Cat.name) `
                                   (Get-WDCategoryGlyph -Id ([string]$catBox.Cat.id)) `
                                   $secName $catBox.InCat ([string](Get-Prop $catBox.Cat 'note' ''))
            # The block is added as soon as it exists and its rows fill in
            # underneath over the steps that follow.
            $catHeaders.Add($g)
        }
        $n = 0
        while ($catBox.At -lt $catBox.Items.Count -and $n -lt $CAT_CHUNK) {
            $item = $catBox.Items[$catBox.At]
            $catBox.At++; $n++
            $row = & $makeItemRow $item ([string]$catBox.Cat.name) ([string]$catBox.Cat.id) `
                                  (Get-WDItemSection -Item $item -Category $catBox.Cat)
            $rows.Add($row)
            # A hosted row goes straight into its fixed block and is never
            # offered to the grouping.
            if ($row.HostBlock) {
                $hostPanel = $null
                switch ($row.HostBlock) { 'authority' { $hostPanel = $ui.RunOptionsBlock } }
                if ($hostPanel) { $null = $hostPanel.Children.Add($row.Panel); continue }
            }
            $catBox.InCat.Add($row)
            # The replacement browser is chosen right here, under the item that
            # makes it necessary.
            if ($row.Id -eq $EDGE_ID) {
                $null = & $makeBrowserPicker 'edge'
                $browserUi.Row = $row
            }
        }
        if ($catBox.At -lt $catBox.Items.Count) { $advWork.Insert(0, $catBox.Step) }
    }.GetNewClosure()
    # After the closure is made, and it still works: the closure captured the
    # holder rather than this variable.
    $catBox.Step = $catStep
    $advWork.Add($catStep)
    }

    # Strips that belong to one row.
    $advWork.Add({
        # Every entry on this list names itself, not only the categories: these
        # six said nothing, so the bar and the line under it both stopped for
        # the last third of the wait.
        if ($advSay.Fn) { & $advSay.Fn 'Building the fields beside a row' }
        # Built from $rows rather than $rowById: that table is filled by a later
        # entry in this same list.
        $byId = @{}
        foreach ($r in $rows) { $byId[[string]$r.Id] = $r }

        $makeStripBox = {
            param([string]$Indent)
            $box = New-Object Windows.Controls.Border
            $box.Margin = "$Indent,0,0,8"; $box.Padding = '12,7,12,8'; $box.CornerRadius = 5
            & $Ref $box 'Background' 'Card'
            & $Ref $box 'BorderBrush' 'Line'
            $box.BorderThickness = New-Object Windows.Thickness 1
            $box.Visibility = 'Collapsed'
            $box
        }

        # "Defer for [ 30 ] days (max 365)". The ceiling is a fact about the
        # field rather than the end of the sentence.
        foreach ($d in @(@{ Id = 'wu-defer-feature'; Key = 'Feature'; Max = 365 },
                         @{ Id = 'wu-defer-quality'; Key = 'Quality'; Max = 30 })) {
            if (-not $byId.ContainsKey([string]$d.Id)) { continue }
            $box = & $makeStripBox '30'
            $sp = New-Object Windows.Controls.WrapPanel
            $lbl = New-Object Windows.Controls.TextBlock
            $lbl.Text = 'Defer for'; $lbl.FontSize = 13; $lbl.VerticalAlignment = 'Center'
            & $Ref $lbl 'Foreground' 'Text'
            $null = $sp.Children.Add($lbl)
            $tb = New-Object Windows.Controls.TextBox
            $tb.Width = 56; $tb.FontSize = 13; $tb.Padding = '6,3'; $tb.Margin = '8,0,8,0'
            $tb.TextAlignment = 'Center'
            $tb.Text = [string]$state.DeferDays[[string]$d.Key]
            $null = $sp.Children.Add($tb)
            $unit = New-Object Windows.Controls.TextBlock
            $unit.Text = 'days'; $unit.FontSize = 13; $unit.VerticalAlignment = 'Center'
            & $Ref $unit 'Foreground' 'Text'
            $null = $sp.Children.Add($unit)
            $cap = New-Object Windows.Controls.TextBlock
            $cap.Text = "(max $([int]$d.Max))"; $cap.FontSize = 13; $cap.Margin = '7,0,0,0'
            $cap.VerticalAlignment = 'Center'
            & $Ref $cap 'Foreground' 'Sub'
            $null = $sp.Children.Add($cap)
            $box.Child = $sp
            # Clamped as it is typed, not on the way to the engine, so the box
            # shows the number that will be written. Windows silently ignores a
            # period outside its range.
            $tb.Tag = @{ Key = [string]$d.Key; Max = [int]$d.Max; State = $state; Save = $saveUiState }
            $tb.Add_LostFocus({
                $t = $this.Tag
                $n = 0
                if (-not [int]::TryParse([string]$this.Text, [ref]$n)) { $n = $t.Max }
                if ($n -lt 1) { $n = 1 }
                if ($n -gt $t.Max) { $n = $t.Max }
                $this.Text = [string]$n
                $t.State.DeferDays[$t.Key] = $n
                & $t.Save
            }.GetNewClosure())
            $rowStrips[[string]$d.Id] = $box
        }

        # Which browser to hand the associations to.
        if ($byId.ContainsKey('set-default-browser')) {
            # Copied into this scope first: this whole block is a closure, and
            # one written inside it captures only what is local here.
            $defUi     = $defBrowserUi
            $hereNames = $browserHere
            $stateRef  = $state
            $paint     = $Ref
            $saveRef   = $saveUiState

            $box = & $makeStripBox '30'
            $sp = New-Object Windows.Controls.StackPanel
            $lbl = New-Object Windows.Controls.TextBlock
            $lbl.Text = 'Make this the default'; $lbl.FontSize = 13; $lbl.Margin = '0,0,0,6'
            & $Ref $lbl 'Foreground' 'Text'
            $null = $sp.Children.Add($lbl)
            $btnRow = New-Object Windows.Controls.WrapPanel
            $null = $sp.Children.Add($btnRow)
            $box.Child = $sp
            $rowStrips['set-default-browser'] = $box
            # Rebuilt on demand rather than once: what is installed cannot
            # change while the window is open, but what is queued can.
            $defBrowserUi.Panel   = $btnRow
            $defBrowserUi.Refresh = {
                $panel = $defUi.Panel
                if (-not $panel) { return }
                $panel.Children.Clear()
                $names = @(@($hereNames) + @($stateRef.BrowserChoices) | Sort-Object -Unique)
                if (-not $names.Count) { return }
                # An answer nobody has given yet is the first one, not none: the
                # row does nothing without a browser to point at.
                if (-not $stateRef.DefaultBrowser -or $names -notcontains $stateRef.DefaultBrowser) {
                    $stateRef.DefaultBrowser = [string]$names[0]
                }
                foreach ($n in $names) {
                    $b = New-Object Windows.Controls.Button
                    $b.Content = $n; $b.FontSize = 12.5; $b.Padding = '10,3'; $b.Margin = '0,0,6,4'
                    if ([string]$n -eq [string]$stateRef.DefaultBrowser) {
                        $b.FontWeight = 'Bold'
                        & $paint $b 'BorderBrush' 'Accent'
                        $b.BorderThickness = New-Object Windows.Thickness 2
                    }
                    # Everything the handler needs travels on the Tag rather
                    # than in a third-level closure.
                    $b.Tag = @{ Name = [string]$n; State = $stateRef; Ui = $defUi; Save = $saveRef }
                    $b.Add_Click({
                        $t = $this.Tag
                        $t.State.DefaultBrowser = [string]$t.Name
                        & $t.Ui.Refresh
                        & $t.Save
                    })
                    $null = $panel.Children.Add($b)
                }
            }.GetNewClosure()
            & $defBrowserUi.Refresh
        }

        # There was a third strip here - a folder picker under the common issues
        # document. Every apply leaves a folder on the desktop now.
    }.GetNewClosure())

    # These two follow their row's visibility alone and not its tick: the number
    # is the whole of what the option does, so it is worth setting before
    # deciding whether to take it.
    $STRIP_ALWAYS = @('wu-defer-feature', 'wu-defer-quality')

    # Every strip follows its own row's tick and visibility. One loop rather
    # than a handler per strip.
    $syncStrips = {
        foreach ($id in @($rowStrips.Keys)) {
            if ($id -eq $EDGE_ID) { continue }
            $row = $rowById[[string]$id]
            $strip = $rowStrips[[string]$id]
            if (-not $row -or -not $strip) { continue }
            $on = ($row.Panel.Visibility -eq 'Visible') -and
                  ([bool]$row.Check.IsChecked -or ($STRIP_ALWAYS -contains [string]$id))
            $strip.Visibility = $(if ($on) { 'Visible' } else { 'Collapsed' })
        }
    }.GetNewClosure()
    $syncStripsRef.Fn = $syncStrips

    # The index rail.
    $indexEntries = New-Object System.Collections.Generic.List[psobject]
    $indexSpy     = @{ Offsets = $null; Active = $null; Busy = $false }

    # A jump card. Every order builds its own set, so this is rebuilt rather
    # than hidden and re-shown.
    $indexRowFor = {
        param([string]$Name, $Head, $Rows)
        # Copied in for the hover handlers below: this block is itself a
        # closure.
        $setBrush = $Ref
        $b = New-Object Windows.Controls.Border
        $b.Padding      = '8,5'
        $b.CornerRadius = New-Object Windows.CornerRadius 4
        $b.Margin       = '0,0,0,1'
        & $Ref $b 'Background' 'Flat'   # transparent, but hit-testable
        $b.Cursor       = 'Hand'
        $d = New-Object Windows.Controls.DockPanel
        $d.LastChildFill = $true
        $cnt = New-Object Windows.Controls.TextBlock
        $cnt.FontSize = 11.5; $cnt.Margin = '8,0,0,0'; $cnt.VerticalAlignment = 'Center'
        & $Ref $cnt 'Foreground' 'Muted'
        [Windows.Controls.DockPanel]::SetDock($cnt, 'Right')
        $null = $d.Children.Add($cnt)
        $nm = New-Object Windows.Controls.TextBlock
        $nm.Text = $Name; $nm.FontSize = 12.5
        $nm.TextTrimming = 'CharacterEllipsis'
        & $Ref $nm 'Foreground' 'Sub'
        $null = $d.Children.Add($nm)
        $b.Child = $d

        $sv = $ui.AdvScroll
        $content = $ui.AdvContent
        $target = $Head
        # Computed at click time rather than read from the cache: one
        # TransformToAncestor is cheap and cannot be stale.
        $b.Add_MouseLeftButtonUp({
            try {
                if (-not $target.IsDescendantOf($content)) { return }
                if ($target.Visibility -ne 'Visible') { return }
                $content.UpdateLayout()
                $y = $target.TransformToAncestor($content).Transform((New-Object Windows.Point 0, 0)).Y
                $sv.ScrollToVerticalOffset([Math]::Max(0, $y - 8))
            } catch { }
        }.GetNewClosure())
        $b.Add_MouseEnter({ if ($this.Tag -ne 'on') { & $setBrush $this 'Background' 'RowHover' } }.GetNewClosure())
        $b.Add_MouseLeave({ if ($this.Tag -ne 'on') { & $setBrush $this 'Background' 'Flat' } }.GetNewClosure())

        # Key, not Name, is this entry's identity.
        [pscustomobject]@{ Kind = 'jump'; Key = ''; Name = $Name; Head = $Head; Rows = $Rows
                           Panel = $b; Label = $nm; Count = $cnt }
    }.GetNewClosure()

    # Not a card and not clickable: it marks where removals stop and additions
    # begin, which is a fact about the page rather than a place to go.
    $indexSepFor = {
        param([string]$Text)
        $t = New-Object Windows.Controls.TextBlock
        $t.Text = $Text.ToUpper(); $t.FontSize = 10.5; $t.FontWeight = 'Bold'
        $t.Margin = '8,14,0,3'
        $t.IsHitTestVisible = $false
        & $Ref $t 'Foreground' 'Muted'
        [pscustomobject]@{ Kind = 'sep'; Key = ''; Name = $Text; Head = $null; Rows = @()
                           Panel = $t; Label = $t; Count = $null }
    }.GetNewClosure()

    # What the current grouping is not showing, said on the rail and nowhere
    # else. Deliberately not a card: there is nothing to scroll to.
    $indexOmitFor = {
        param([string]$Title, [int]$Count, [string]$Where)
        $sp = New-Object Windows.Controls.StackPanel
        $sp.Margin = '8,14,4,2'
        $sp.IsHitTestVisible = $false
        $sp.Opacity = 0.75
        $h = New-Object Windows.Controls.TextBlock
        $h.Text = ($Title + ' - NOT LISTED').ToUpper()
        $h.FontSize = 10.5; $h.FontWeight = 'Bold'; $h.TextWrapping = 'Wrap'
        & $Ref $h 'Foreground' 'Muted'
        $null = $sp.Children.Add($h)
        $b = New-Object Windows.Controls.TextBlock
        $b.Text = "$Count item$(if ($Count -ne 1) { 's' }). $Where"
        $b.FontSize = 11; $b.TextWrapping = 'Wrap'; $b.Margin = '0,2,0,0'
        & $Ref $b 'Foreground' 'Muted'
        $null = $sp.Children.Add($b)
        [pscustomobject]@{ Kind = 'omit'; Key = ''; Name = $Title; Head = $null; Rows = @()
                           Panel = $sp; Label = $h; Count = $null }
    }.GetNewClosure()

    # Blocks on the page under every grouping that are not made of item rows.
    # Cards without counts, because a 0/0 would read as "nothing selected here".
    $railFixed = @(
        @{ Key = 'browser';   Name = 'Web browser'; Target = 'BrowserAddBlock'; Where = 'add-top'
           NeedsSection = $true }
        @{ Key = 'always';    Name = 'Default behaviors'; Target = 'AlwaysBlock'; Where = 'extras-top' }
        @{ Key = 'authority'; Name = 'Authority';   Target = 'RunOptionsBlock'; Where = 'extras-top' }
        @{ Key = 'appopts';   Name = 'App Options'; Target = 'AppOptBox';       Where = 'extras-end' }
    )

    $railRef.Rebuild = {
        param($Groups, [bool]$Sectioned, $Omitted)

        $ui.IndexPanel.Children.Clear()
        $indexEntries.Clear()
        $indexSpy.Active = $null

        # Keyed by position, not by label: keyed by label, two blocks with the
        # same title were one entry as far as the scroll spy was concerned.
        $add = {
            param($Entry)
            $Entry.Key = 'rail' + $indexEntries.Count
            $indexEntries.Add($Entry)
            $null = $ui.IndexPanel.Children.Add($Entry.Panel)
        }
        $fixedFor = {
            param([string]$Where)
            foreach ($f in $railFixed) {
                if ($f.Where -ne $Where) { continue }
                # A section's own block is off the page entirely when the
                # grouping lays out no sections.
                if ($f.NeedsSection -and -not $Sectioned) { continue }
                & $add (& $indexRowFor ([string]$f.Name) $ui[[string]$f.Target] @())
            }
        }
        # A plain local rather than $SEC_LABEL, which is declared with the
        # filter three hundred lines below.
        $secTitle = @{ remove = 'Remove'; add = 'Add'; extras = 'Extras' }

        if ($Sectioned) {
            foreach ($sec in @(@{ K = 'remove'; T = 'Remove' }, @{ K = 'add'; T = 'Add' }, @{ K = 'extras'; T = 'Extras' })) {
                $mine = @($Groups | Where-Object { $_.Section -eq $sec.K })
                # Extras always has content even when no category lands in it -
                # Authority lives there and is not a category.
                if (-not $mine.Count -and $sec.K -ne 'extras') { continue }
                & $add (& $indexSepFor $sec.T)
                & $fixedFor "$($sec.K)-top"
                foreach ($g in $mine) { & $add (& $indexRowFor $g.Name $g.Head $g.Rows) }
                & $fixedFor "$($sec.K)-end"
            }
        } else {
            # No section titles: this grouping has no sections.
            foreach ($g in $Groups) { & $add (& $indexRowFor $g.Name $g.Head $g.Rows) }
            & $add (& $indexSepFor 'Also on this page')
            foreach ($w in @('remove-end','add-top','extras-top','extras-end')) { & $fixedFor $w }
        }
        # Last, under everything: a grouping that does not lay out a whole
        # section says so here rather than dropping the rows silently.
        foreach ($sec in @($Omitted)) {
            if (-not $sec) { continue }
            $n = @($rows | Where-Object { [string]$_.Section -eq [string]$sec }).Count
            if (-not $n) { continue }
            & $add (& $indexOmitFor ([string]$secTitle[[string]$sec]) $n 'Group by a different category to see these options.')
        }
        if ($indexRef.Paint) { & $indexRef.Paint }
    }.GetNewClosure()

    # A group the filter has emptied is dimmed and kept, never removed: a rail
    # whose entries come and go as you type reads as broken.
    $paintIndex = {
        foreach ($e in $indexEntries) {
            if ($e.Kind -ne 'jump') { continue }
            $total = @($e.Rows).Count
            if (-not $total) {
                # A fixed block has no rows, so a count would be a zero meaning
                # "nothing here" rather than "nothing selected".
                $live = [bool]($e.Head -and $e.Head.Visibility -eq 'Visible')
                $e.Count.Text = ''
                & $Ref $e.Label 'Foreground' $(if ($live) { 'Sub' } else { 'Muted' })
                $e.Panel.Opacity = $(if ($live) { 1.0 } else { 0.45 })
                # Inert rather than merely dimmed: IsHitTestVisible takes the
                # hover tint and the hand cursor with it in one property.
                $e.Panel.IsHitTestVisible = $live
                continue
            }
            # The denominator is decisions, not rows, and filtering is not part
            # of it: a denominator that shrank as somebody typed could not be
            # compared with the one they saw a moment ago.
            $tot = 0; $on = 0; $vis = 0
            foreach ($r in $e.Rows) {
                if ($r.Panel.Visibility -eq 'Visible') { $vis++ }
                # Unless it is ticked anyway: a clean-up that turns out to free
                # nothing is disabled where it stands but still acted on.
                if (-not $r.Check.IsEnabled -and -not $r.Check.IsChecked) { continue }
                $tot++
                if ($r.Check.IsChecked) { $on++ }
            }
            $e.Count.Text = "$on/$tot"
            $visOn = $on
            # Dimming still follows the filter - that is about whether there is
            # anything to jump to.
            $dim = ($vis -eq 0)
            # Green when there is nothing left in it. A full block is a settled
            # state, and Accent says "there is something here".
            $full = ($tot -gt 0 -and $on -eq $tot)
            & $Ref $e.Label 'Foreground' $(if ($dim) { 'Muted' } else { 'Sub' })
            & $Ref $e.Count 'Foreground' $(if ($dim) { 'Muted' } elseif ($full) { 'Ok' } elseif ($visOn) { 'Accent' } else { 'Muted' })
            $e.Panel.Opacity          = $(if ($dim) { 0.45 } else { 1.0 })
            $e.Panel.IsHitTestVisible = (-not $dim)
        }
    }.GetNewClosure()
    $indexRef.Paint = $paintIndex

    # Offsets are measured once into a table and reused: transforming
    # twenty-three headers on every scroll tick is how this ships janky.
    $indexRef.Invalidate = { $indexSpy.Offsets = $null }.GetNewClosure()

    $spyIndex = {
        if ($indexSpy.Busy) { return }
        $indexSpy.Busy = $true
        try {
            if (-not $indexSpy.Offsets) {
                # A page that is not on screen has no layout, so every heading
                # transforms to Y=0 - and a table of zeros is still a table, so
                # it was cached and the highlight named the first entry for the
                # rest of the session.
                if ($ui.PageAdvanced.Visibility -ne 'Visible') { return }
                # UpdateLayout first, because this runs from $applyFilter and
                # the rows it collapsed have not been re-measured.
                $ui.AdvContent.UpdateLayout()
                if ([double]$ui.AdvContent.ActualHeight -le 0) { return }
                $tbl = @{}
                foreach ($e in $indexEntries) {
                    try {
                        if ($e.Kind -ne 'jump' -or -not $e.Head) { continue }
                        if (-not $e.Head.IsDescendantOf($ui.AdvContent)) { continue }
                        # A heading the filter has emptied is not on the page,
                        # and a collapsed element has no layout.
                        if ($e.Head.Visibility -ne 'Visible') { continue }
                        $tbl[$e.Key] = $e.Head.TransformToAncestor($ui.AdvContent).Transform(
                            (New-Object Windows.Point 0, 0)).Y
                    } catch { }
                }
                if (-not $tbl.Count) { return }
                $indexSpy.Offsets = $tbl
            }
            # The last heading at or above the top of the viewport, plus slack
            # so one sitting just under the edge counts.
            $y = [double]$ui.AdvScroll.VerticalOffset + 24
            $best = $null; $bestY = [double]::NegativeInfinity
            foreach ($e in $indexEntries) {
                if ($e.Kind -ne 'jump') { continue }
                if (-not $indexSpy.Offsets.ContainsKey($e.Key)) { continue }
                $oy = [double]$indexSpy.Offsets[$e.Key]
                if ($oy -le $y -and $oy -gt $bestY) { $best = $e; $bestY = $oy }
            }
            if (-not $best) { $best = @($indexEntries | Where-Object { $_.Kind -eq 'jump' })[0] }
            if ($best -and $indexSpy.Active -ne $best.Key) {
                foreach ($e in $indexEntries) {
                    if ($e.Kind -ne 'jump') { continue }
                    $isOn = ($e.Key -eq $best.Key)
                    $e.Panel.Tag        = $(if ($isOn) { 'on' } else { '' })
                    & $Ref $e.Panel 'Background' $(if ($isOn) { 'CardSel' } else { 'Flat' })
                    $e.Label.FontWeight = $(if ($isOn) { 'SemiBold' } else { 'Normal' })
                }
                $indexSpy.Active = $best.Key
            }
        } finally { $indexSpy.Busy = $false }
    }.GetNewClosure()

    $ui.AdvScroll.Add_ScrollChanged({ & $spyIndex }.GetNewClosure())
    $indexRef.Spy = $spyIndex

    # Clamped to the column's own bounds rather than trusted: a saved file is
    # editable.
    $savedRail = [int](Get-Prop $UiState 'railWidth' 0)
    if ($savedRail -ge [int]$ui.IndexCol.MinWidth -and $savedRail -le [int]$ui.IndexCol.MaxWidth) {
        $ui.IndexCol.Width = New-Object Windows.GridLength ([double]$savedRail)
    }
    # The Compare rail, same treatment and the same clamp. Its column is set
    # from $cmpRail.W on every rebuild.
    $savedCmpRail = [int](Get-Prop $UiState 'cmpRailWidth' 0)
    if ($savedCmpRail -ge [int]$ui.CmpIndexCol.MinWidth -and $savedCmpRail -le [int]$ui.CmpIndexCol.MaxWidth) {
        $cmpRail.W = $savedCmpRail
        $ui.CmpIndexCol.Width = New-Object Windows.GridLength ([double]$savedCmpRail)
    }
    $ui.CmpIndexSplit.Add_DragCompleted({
        $w = [int]$ui.CmpIndexCol.Width.Value
        if ($w -gt 0) { $cmpRail.W = $w }
        & $saveUiState
        # The comparison is narrower now, so the cards re-wrap and every heading
        # below the first has moved.
        if ($cmpSpyRef.Fn) { $cmpSpy.Offsets = $null; & $cmpSpyRef.Fn }
    }.GetNewClosure())
    # DragCompleted, not DragDelta: the second fires per mouse-move and would
    # write the settings file a hundred times across one drag.
    $ui.IndexSplit.Add_DragCompleted({
        & $saveUiState
        # Every heading has moved sideways, which does not change a vertical
        # offset - but the rows re-wrap, so the ones below the fold have.
        if ($indexRef.Invalidate) { & $indexRef.Invalidate }
        if ($indexRef.Spy) { & $indexRef.Spy }
    }.GetNewClosure())
    # There was a note here offering the way back to category order. Every order
    # builds groups now.

    # Every order is full-width blocks down the left panel, so the section's own
    # right column is never used.
    foreach ($g in @(@{ Grid = $ui.AdvColumns;   R = $ui.ColRight },
                     @{ Grid = $ui.AddColumns;   R = $ui.AddRight },
                     @{ Grid = $ui.ExtraColumns; R = $ui.ExtraRight })) {
        if ($g.R.Children.Count) { continue }
        $g.Grid.ColumnDefinitions[1].Width = New-WDGridLength 0
        $g.Grid.ColumnDefinitions[2].Width = New-WDGridLength 0
    }

    # The account picker, under the run-behavior switches.
    $syncAccounts = {
        $on = @(& $accountKeys)
        $names = @($accountList | Where-Object { $_.Key -in $on -and $_.Kind -eq 'account' } | ForEach-Object { [string]$_.Name })
        $future = [bool](@($accountList | Where-Object { $_.Kind -eq 'future' -and $_.Key -in $on }).Count)

        $short = $(if (-not $names.Count -and -not $future) { 'no accounts' }
                   elseif (-not $names.Count) { 'new accounts only' }
                   else { "$($names.Count) account$(if ($names.Count -ne 1) { 's' })" + $(if ($future) { ' + new' } else { '' }) })
        $long  = $(if (-not $names.Count -and -not $future) {
                       'Nothing is ticked under "which accounts per-user settings are written to", so this item has nowhere to write.'
                   } else {
                       'Written to: ' + (@($names) + @(if ($future) { 'accounts created later' }) -join ', ') +
                       ".`n`nChange this under How the run behaves. Machine-wide parts of an item are not affected by it."
                   })
        foreach ($t in $accountTags) {
            $t.Tag.Text    = "  $short"
            $t.Tag.ToolTip = $long
        }
        $ui.LblAccounts.Text = $(if (-not $names.Count -and -not $future) {
            'Nothing is ticked, so per-user settings will be skipped. Machine-wide changes - HKLM policies, services, scheduled tasks, Windows features, removed packages - still apply to the whole PC either way.'
        } else {
            'Settings that live in a user profile are written to each of these. Machine-wide changes - HKLM policies, services, scheduled tasks, Windows features, removed packages - apply to the whole PC either way and are not affected by this.'
        })
    }
    if ($accountList.Count) {
        $savedAccounts = @(Get-Prop $UiState 'accounts' $null)
        foreach ($acc in $accountList) {
            $cb = New-Object Windows.Controls.CheckBox
            $cb.Content = $(if ($acc.Kind -eq 'future') { $acc.Name } else { "$($acc.Name)" })
            $cb.FontSize = 13; $cb.Margin = '0,3,0,0'
            & $Ref $cb 'Foreground' 'Text'
            $cb.ToolTip = $acc.Note
            # A stored choice wins; nothing stored means everything, which is
            # what this did before the choice existed.
            $cb.IsChecked = $(if ($null -eq $savedAccounts -or -not @($savedAccounts).Count) { $true }
                              else { [string]$acc.Key -in @($savedAccounts) })
            $null = $ui.AccountsBlock.Children.Add($cb)
            $accountChecks.Add([pscustomobject]@{ Key = [string]$acc.Key; Box = $cb; Kind = [string]$acc.Kind })
        }
        foreach ($e in $accountChecks) {
            $e.Box.Add_Checked({ & $syncAccounts; & $saveUiState }.GetNewClosure())
            $e.Box.Add_Unchecked({ & $syncAccounts; & $saveUiState }.GetNewClosure())
        }
    } else {
        $ui.LblAccountsHead.Visibility = 'Collapsed'
        $ui.LblAccounts.Visibility     = 'Collapsed'
    }

    # Always here, whatever Edge is doing: installing a browser is a thing to
    # want on a machine that is keeping Edge.
    $bh = New-Object Windows.Controls.StackPanel
    $bh.Orientation = 'Horizontal'; $bh.Margin = '0,0,0,4'
    $bhg = New-Object Windows.Controls.TextBlock
    $bhg.Text = New-WDGlyph 0x1F310                      # globe
    $bhg.FontFamily = New-Object Windows.Media.FontFamily 'Segoe UI Emoji'
    $bhg.FontSize = 16; $bhg.Margin = '0,0,8,0'
    & $Ref $bhg 'Foreground' 'Text'
    $null = $bh.Children.Add($bhg)
    $bht = New-Object Windows.Controls.TextBlock
    $bht.Text = 'Web browser'; $bht.FontSize = 16; $bht.FontWeight = 'SemiBold'
    & $Ref $bht 'Foreground' 'Text'
    $null = $bh.Children.Add($bht)
    $null = $ui.BrowserAddBlock.Children.Add($bh)
    $bhr = New-Object Windows.Controls.Border
    $bhr.Height = 1; & $Ref $bhr 'Background' 'Line'; $bhr.Opacity = 0.6; $bhr.Margin = '0,0,0,6'
    $null = $ui.BrowserAddBlock.Children.Add($bhr)
    $null = $ui.BrowserAddBlock.Children.Add((& $makeBrowserPicker 'add'))
    # Paint both pickers once now: a strip with a blank label and no button
    # marked reads as broken rather than as "None".
    & $setBrowsers @($state.BrowserChoices) $false

    # Captured while the block is still where it belongs: under A-Z it is taken
    # out of the Add section and filed under W.
    $browserHome = $ui.BrowserAddBlock.Parent

    # The browser picker as a member of a group, so the alphabet can hold it.
    # Not in $rows, so no count, filter pass, or preset touches it.
    $browserRow = [pscustomobject]@{
        Id       = '__browser-block'
        Panel    = $ui.BrowserAddBlock
        Name     = $bht
        Check    = [pscustomobject]@{ IsChecked = $false; IsEnabled = $false }
        Requires = ''
        Section  = 'add'
        Tier     = 0; Risk = 0; Bloat = 0
        Category = 'Web browser'; CatId = 'browser'
        Absent   = $false
    }

    & $say 'Building the interface' 'Protected inventory'
    # Protected inventory, pinned below the two columns.
    if ($Scan -and @($Scan.Protected).Count) {
        $hp = New-Object Windows.Controls.StackPanel
        $hp.Orientation = 'Horizontal'; $hp.Margin = '0,0,0,6'
        $hg = New-Object Windows.Controls.TextBlock
        $hg.Text = Get-WDCategoryGlyph -Id 'protected'
        $hg.FontFamily = New-Object Windows.Media.FontFamily 'Segoe UI Emoji'
        $hg.FontSize = 16; $hg.Margin = '0,0,8,0'
        & $Ref $hg 'Foreground' 'Text'
        $null = $hp.Children.Add($hg)
        $h = New-Object Windows.Controls.TextBlock
        $h.Text = "Protected on this machine ($(@($Scan.Protected).Count))"
        $h.FontSize = 16; $h.FontWeight = 'SemiBold'; & $Ref $h 'Foreground' 'Text'
        $null = $hp.Children.Add($h)
        $null = $ui.ProtectedBlock.Children.Add($hp)

        $sub = New-Object Windows.Controls.TextBlock
        $sub.Text = 'These are never offered for removal, at any mode including Extreme. Hover any entry for the reason.'
        $sub.FontSize = 13; $sub.TextWrapping = 'Wrap'; $sub.Margin = '0,0,0,8'
        & $Ref $sub 'Foreground' 'Sub'
        $null = $ui.ProtectedBlock.Children.Add($sub)

        $rule = New-Object Windows.Controls.Border
        $rule.Height = 1; & $Ref $rule 'Background' 'Line'; $rule.Margin = '0,0,0,8'
        $null = $ui.ProtectedBlock.Children.Add($rule)

        $wrap = New-Object Windows.Controls.WrapPanel
        foreach ($pr in ($Scan.Protected | Sort-Object Name)) {
            $chip = New-Object Windows.Controls.Border
            $chip.CornerRadius = 4; $chip.Padding = '8,3,8,4'; $chip.Margin = '0,0,8,8'
            $chip.BorderThickness = New-Object Windows.Thickness 1
            & $Ref $chip 'BorderBrush' 'Line'
            & $Ref $chip 'Background' 'Card'
            $chip.ToolTip = "$($pr.Name)`n`n$($pr.Reason)"
            $ct = New-Object Windows.Controls.TextBlock
            $ct.Text = $pr.Name; $ct.FontSize = 12.5
            & $Ref $ct 'Foreground' 'Sub'
            $chip.Child = $ct
            $null = $wrap.Children.Add($chip)
        }
        $null = $ui.ProtectedBlock.Children.Add($wrap)
    }

    # What the run does whatever is ticked. Rows without a tick, rather than a
    # tick that is always on and cannot be cleared - a control that cannot be
    # operated lies about being one.
    $alwaysSteps = @(
        @{ Name = 'Close revival paths'
           Text  = @('WHAT THIS CHANGES',
                     '  Runs whenever the rest of the run removes an app, a Windows feature, or a Windows capability.',
                     '',
                     '  Deprovisions what was uninstalled, so a later Windows update cannot stage it again for a new account.',
                     '  Sets the four ContentDeliveryManager values under HKCU that reinstall bundled apps at the next sign-in.',
                     '  Sets the DisableWindowsConsumerFeatures policy, which is what re-adds promoted apps after an update.',
                     '  Disables the scheduled tasks under \Microsoft\Windows\PushToInstall.',
                     '  Disables the edgeupdate and edgeupdatem services, but only when Edge itself is gone - an un-updating browser is worse than the thing it guards against.',
                     '',
                     'Revertible: fully') }
        @{ Name = 'Restart Explorer to apply shell changes'
           Text  = @('WHAT THIS CHANGES',
                     '  Stops and restarts explorer.exe once, at the end of every run.',
                     '',
                     '  The taskbar, Start menu, and context menus read most of their settings once at sign-in, so anything this run wrote to the registry is invisible until Explorer reads it again.',
                     '  Not conditional on the run having touched the shell: a needless restart is one blink, and a missed one is a change you wrote, cannot see, and reasonably read as broken.',
                     '',
                     'Revertible: nothing to revert') }
        # Not a plan step, unlike the two above: it is something four of the
        # executors do on their own when a removal is refused, so it never gets
        # a preview row and this block is the only place it is stated.
        @{ Name = 'Close programs that are in the way'
           Text  = @('WHAT THIS CHANGES',
                     '  Closes a running program when it is what is stopping a removal, and only then.',
                     '',
                     '  An uninstaller that exits non-zero because the application is open reports "exit 1" and says nothing about why - so anything running out of the program''s own folder is closed before the uninstaller starts, along with any launcher the option names by hand. Riot Client holding Valorant is the case this exists for: it lives in a different folder entirely, so sweeping the target''s own directory never finds it.',
                     '  If a removal is refused anyway and something new turns up on a second look, that is closed and the removal is tried once more. Only once, and only when the second look actually found something - repeating a refusal that had another cause is ten more minutes of the same answer.',
                     '  The same applies to a Store app Windows reports as in use, a folder something is holding open, and a service that will not stop.',
                     '',
                     '  Never a service sharing svchost.exe with the rest of Windows, and never this toolkit or the shell. Every program it closes is named in the run log.',
                     '',
                     'UNSAVED WORK',
                     '  A program closed this way is killed, not asked to exit, so anything unsaved in it is lost. Close what you are working in before an Apply.',
                     '',
                     'Revertible: no - nothing can put a running program back, so nothing here is journalled or undone by the rollback script.') }
    )
    $ahp = New-Object Windows.Controls.StackPanel
    $ahp.Orientation = 'Horizontal'; $ahp.Margin = '0,0,0,4'
    $ahg = New-Object Windows.Controls.TextBlock
    $ahg.Text = Get-WDCategoryGlyph -Id 'persistence'
    $ahg.FontFamily = New-Object Windows.Media.FontFamily 'Segoe UI Emoji'
    $ahg.FontSize = 16; $ahg.Margin = '0,0,8,0'
    & $Ref $ahg 'Foreground' 'Text'
    $null = $ahp.Children.Add($ahg)
    $aht = New-Object Windows.Controls.TextBlock
    $aht.Text = 'Default behaviors'; $aht.FontSize = 16; $aht.FontWeight = 'SemiBold'
    & $Ref $aht 'Foreground' 'Text'
    $null = $ahp.Children.Add($aht)
    $null = $ui.AlwaysBlock.Children.Add($ahp)

    $arule = New-Object Windows.Controls.Border
    $arule.Height = 1; & $Ref $arule 'Background' 'Line'; $arule.Opacity = 0.6; $arule.Margin = '0,0,0,4'
    $null = $ui.AlwaysBlock.Children.Add($arule)

    foreach ($step in $alwaysSteps) {
        # WrapPanel for the same reason every name-plus-chip line here is one.
        $holder = New-Object Windows.Controls.StackPanel
        $sp = New-Object Windows.Controls.WrapPanel
        $sp.Orientation = 'Horizontal'; $sp.Margin = '0,6,0,2'
        $nm = New-Object Windows.Controls.TextBlock
        $nm.Text = [string]$step.Name; $nm.FontSize = 13.5; $nm.TextWrapping = 'Wrap'
        $nm.VerticalAlignment = 'Center'
        & $Ref $nm 'Foreground' 'Text'
        $null = $sp.Children.Add($nm)
        $null = $sp.Children.Add((& $makeDetailChip ([string]$step.Name) (@($step.Text) -join "`r`n") $holder $state))
        $null = $holder.Children.Add($sp)
        $null = $ui.AlwaysBlock.Children.Add($holder)
    }

        & $say 'Building the interface' 'Filters and preset counts'
    # Within a group the boxes are OR-ed, across groups AND-ed, which is what
    # makes "Checked only + AI + Games" read the way people say it.
    $CHANGED   = 'Changed from preset'
    $CHECKED   = 'Checked only'
    $UNCHECKED = 'Unchecked only'
    $SEC_LABEL = [ordered]@{ remove = 'Remove'; add = 'Add'; extras = 'Extras' }
    $riskLabel = @{ 0 = 'No risk'; 1 = 'Caution'; 2 = 'Risky' }

    $filterSel = @{
        View  = New-Object System.Collections.Generic.HashSet[string]
        Risk  = New-Object System.Collections.Generic.HashSet[string]
        Cat   = New-Object System.Collections.Generic.HashSet[string]
        Sec   = New-Object System.Collections.Generic.HashSet[string]
        # The bloat bands as a filter rather than only as a grouping: grouping
        # answers "arranged by how bad it is", picking two bands answers "only
        # the two worst".
        Bloat = New-Object System.Collections.Generic.HashSet[string]
        # The boxes that subtract rows rather than narrowing to them, and the
        # only ones that do. They AND with each other, because that is how
        # subtraction composes.
        Avail = New-Object System.Collections.Generic.HashSet[string]
        # The rows tagged "opt-in": tier 0, which no mode selects. Its own group
        # rather than a fourth box under VIEW, because boxes in a group are
        # OR-ed.
        Tier  = New-Object System.Collections.Generic.HashSet[string]
    }
    $HIDE_ABSENT = 'Hide "not on this machine" options'
    # The third subtracting box, and the one somebody with a mode already
    # applied reaches for first: it leaves exactly the rows a run would still
    # change.
    $HIDE_APPLIED = 'Hide options already applied'
    # Both named for the tag they act on: somebody reaching for either has just
    # read the word off a row.
    $OPT_IN_ONLY = 'Opt-in only'
    $HIDE_OPT_IN = 'Hide opt-in options'
    # The group names, in chip order, written once. Four of them used to be
    # spelled out in six places.
    $FILTER_GROUPS = @('Sec', 'Avail', 'View', 'Tier', 'Risk', 'Cat', 'Bloat')
    # Boxes that are the two halves of one question, so both at once says
    # exactly what no filter says. Named A/B sides rather than nested arrays,
    # because a single-element array of arrays flattens.
    $FILTER_PAIRS = @(
        @{ A = @{ Group = 'View'; Name = $CHECKED }
           B = @{ Group = 'View'; Name = $UNCHECKED } }
        # Opt-in only narrows to tier 0 and Hide opt-in takes it away, so
        # together they select nothing - and they live in different groups,
        # which is why this is a table.
        @{ A = @{ Group = 'Tier';  Name = $OPT_IN_ONLY }
           B = @{ Group = 'Avail'; Name = $HIDE_OPT_IN } }
    )
    $pickedCount = {
        $n = 0
        foreach ($g in $FILTER_GROUPS) { $n += $filterSel[$g].Count }
        $n
    }.GetNewClosure()
    $filterBoxes = New-Object System.Collections.Generic.List[psobject]

    # "12 of 37 selected" for whatever is on screen. Two numbers used to exist
    # and never meet.
    $makeChip = {
        param([string]$Label, [scriptblock]$OnDrop, [string]$Tint)
        $b = New-Object Windows.Controls.Border
        $b.CornerRadius = New-Object Windows.CornerRadius 4
        $b.Padding      = '8,3'
        $b.Margin       = '0,0,6,6'
        & $Ref $b 'Background' 'Card'
        & $Ref $b 'BorderBrush' $(if ($Tint) { $Tint } else { 'Line' })
        $b.BorderThickness = New-Object Windows.Thickness 1
        $b.Cursor = 'Hand'
        $sp = New-Object Windows.Controls.StackPanel
        $sp.Orientation = 'Horizontal'
        $t = New-Object Windows.Controls.TextBlock
        $t.Text = $Label; $t.FontSize = 12
        & $Ref $t 'Foreground' $(if ($Tint) { $Tint } else { 'Sub' })
        $null = $sp.Children.Add($t)
        $x = New-Object Windows.Controls.TextBlock
        $x.Text = '  x'; $x.FontSize = 12; $x.FontWeight = 'Bold'
        & $Ref $x 'Foreground' $(if ($Tint) { $Tint } else { 'Muted' })
        $null = $sp.Children.Add($x)
        $b.Child = $sp
        $b.Tag = $OnDrop
        $b.Add_MouseLeftButtonUp({ & $this.Tag }.GetNewClosure())
        $b
    }.GetNewClosure()

    $paintChips = {
        $host2 = $ui.FilterChips
        $host2.Children.Clear()
        $boxes = $filterBoxes
        $groupNames = $FILTER_GROUPS

        foreach ($g in $groupNames) {
            foreach ($nm in @($filterSel[$g])) {
                $grp = $g; $name = [string]$nm
                $drop = {
                    foreach ($b in $boxes) {
                        if ($b.Group -eq $grp -and $b.Name -eq $name) { $b.Box.IsChecked = $false }
                    }
                }.GetNewClosure()
                $null = $host2.Children.Add((& $makeChip $name $drop ''))
            }
        }
        $q = [string]$ui.TxtFilter.Text
        if ($q) {
            $box = $ui.TxtFilter
            $drop = { $box.Text = '' }.GetNewClosure()
            $null = $host2.Children.Add((& $makeChip "search: $q" $drop ''))
        }

        # There was a "N selected, not shown" chip here: a filter narrows what
        # is on screen and changes nothing about what is selected, which is what
        # a filter is.
        $host2.Visibility = $(if ($host2.Children.Count) { 'Visible' } else { 'Collapsed' })
    }.GetNewClosure()

    $paintFilterCount = {
        $vis = 0; $sel = 0
        foreach ($r in $rows) {
            if ($r.Panel.Visibility -ne 'Visible') { continue }
            $vis++
            if ($r.Check.IsChecked) { $sel++ }
        }
        & $paintChips
        # The rail's counts are a live map of the same rows, so they move with
        # every tick and every filter pass.
        if ($indexRef.Paint) { & $indexRef.Paint }
        $picked = & $pickedCount
        $narrowed = ($picked -gt 0 -or [string]$ui.TxtFilter.Text)
        # Unfiltered, the denominator is still the visible set rather than
        # $rows.Count: dependent rows are hidden until their parent is ticked.
        $ui.TxtFilterCount.Text = $(if ($narrowed) { "$sel of $vis selected  (filtered)" } else { "$sel of $vis selected" })
        & $Ref $ui.TxtFilterCount 'Foreground' $(if ($vis) { 'Sub' } else { 'Bad' })
        if (-not $vis) { $ui.TxtFilterCount.Text = 'nothing matches' }
    }.GetNewClosure()

    # Snapshots taken the moment the box is ticked, never live queries: a live
    # one deletes the row you just clicked.
    $snapChecked   = New-Object System.Collections.Generic.HashSet[string]
    $snapUnchecked = New-Object System.Collections.Generic.HashSet[string]
    # A closure, not a bare block: this is invoked from a check box handler two
    # scopes down.
    $takeSnapshot = {
        param([string]$Which)
        # Plain assignment, not an if-expression: the value goes through the
        # pipeline, which unrolls collections, and an empty one becomes $null.
        $want = ($Which -eq $CHECKED)
        $set = $snapUnchecked
        if ($want) { $set = $snapChecked }
        $set.Clear()
        foreach ($r in $rows) { if ([bool]$r.Check.IsChecked -eq $want) { $null = $set.Add($r.Id) } }
    }.GetNewClosure()
    # The selection lives in the boxes - once there are boxes. Until the item
    # list is built, the preset is exactly what the boxes will hold.
    $checkedIds = {
        $sel = New-Object System.Collections.Generic.HashSet[string]
        if (-not $rows.Count) {
            foreach ($id in (& $effectiveIds $state.Preset)) { $null = $sel.Add([string]$id) }
            return ,$sel
        }
        foreach ($r in $rows) { if ($r.Check.IsChecked) { $null = $sel.Add($r.Id) } }
        ,$sel
    }

    # Measured against the preset as this person has defined it: the shipped
    # contents plus anything promoted with Save.
    $currentDiff = {
        $sel  = & $checkedIds
        $base = New-WDStringSet (& $defaultIds $state.Preset)
        # A row for something not on this machine is never ticked even when the
        # mode names it, and that is not an edit the operator made.
        $gone = New-Object System.Collections.Generic.HashSet[string]
        foreach ($r in $rows) { if ($r.Absent) { $null = $gone.Add([string]$r.Id) } }
        [pscustomobject]@{
            Selected = @($sel)
            Added    = @($sel  | Where-Object { -not $base.Contains($_) })
            Removed  = @($base | Where-Object { -not $sel.Contains($_) -and -not $gone.Contains($_) })
        }
    }

    # What differs from the version already stored. Only used to decide whether
    # leaving Advanced is worth a prompt.
    $unsavedEdits = {
        $sel   = & $checkedIds
        $saved = New-WDStringSet (& $effectiveIds $state.Preset)
        if ($sel.Count -ne $saved.Count) { return $true }
        foreach ($id in $sel) { if (-not $saved.Contains($id)) { return $true } }
        $false
    }

    # Built once: creating brushes inside the restyle loop would mean hundreds
    # of BrushConverter round-trips per click.

    # The storage bar.
    $diskColors = @{
        windows = 'Accent'
        apps    = 'Warn'
        users   = 'DiskUsers'
        other   = 'Muted'
        unknown = 'Muted'
        spare   = 'Ok'
        pick    = 'Ok'
        grow    = 'Bad'
    }
    # A list filled when the rows exist, not an array taken from them now: this
    # is read from the drive scan's timer, which may fire first.
    $storageRows = New-Object System.Collections.Generic.List[psobject]
    $advWork.Add({
        if ($advSay.Fn) { & $advSay.Fn 'Collecting the clean-up rows' }
        foreach ($r in $rows) { if ($r.CatId -eq $STORAGE_CAT) { $storageRows.Add($r) } }
    }.GetNewClosure())

    # What the selection does to the drive, per item, without needing a row to
    # ask. The bar is in the header and is on screen on every page.
    $sizeFacts = @{}
    foreach ($cat in $Categories) {
        foreach ($item in @(Get-Prop $cat 'items' @())) {
            $id = [string]$item.id
            # The same two sources $makeItemRow reads, in the same order.
            $d = 0L; $bl = 0
            if ($Presence -and $Presence.ContainsKey($id)) {
                $d  = -[int64]$Presence[$id].Bytes
                $bl = [int]$Presence[$id].Blind
            }
            $addMb = [int](Get-Prop $item 'installSize' 0)
            if ($addMb -gt 0) { $d = [int64]$addMb * 1MB }
            $sizeFacts[$id] = [pscustomobject]@{
                Name  = [string](Get-Prop $item 'name' $id)
                CatId = [string]$cat.id
                Delta = $d
                Blind = $bl
            }
        }
    }

    $diskSlop = @{ measured = 0.05; recorded = 0.25; authored = 0.40 }

    # Three numbers and two lists, and the lists are the honest half: what has
    # no figure at all is named rather than averaged in.
    $rowBytes = {
        param($Row)
        if ($Row.CatId -eq $STORAGE_CAT) {
            $s = $storage.Snapshot
            if ($s -and $s.Items.ContainsKey($Row.Id)) { return -[int64]$s.Items[$Row.Id] }
            return 0L
        }
        [int64]$Row.Delta
    }

    $diskImpact = {
        $snap = $storage.Snapshot
        $free = 0L; $add = 0L; $slop = 0.0
        $frees = New-Object System.Collections.Generic.List[psobject]
        $adds  = New-Object System.Collections.Generic.List[psobject]
        $blind = New-Object System.Collections.Generic.List[psobject]

        # Over the selection, not over the rows: this has to answer before the
        # item list is built and after.
        foreach ($id in (& $checkedIds)) {
            $r = $sizeFacts[[string]$id]
            # The replacement browser is a picker rather than an item, and is
            # counted on its own below.
            if (-not $r) { continue }
            if ($r.CatId -eq $STORAGE_CAT) {
                if ($snap -and $snap.Items.ContainsKey([string]$id)) {
                    $b = [int64]$snap.Items[[string]$id]
                    if ($b -le 0) { continue }
                    $free += $b; $slop += $b * $diskSlop.measured
                    $frees.Add([pscustomobject]@{ Name = [string]$r.Name; Bytes = $b; Kind = 'measured' })
                } else {
                    $blind.Add([pscustomobject]@{ Name = [string]$r.Name; Why = 'only DISM can size this, and only by running it' })
                }
                continue
            }
            if ($r.Delta -gt 0) {
                $add += $r.Delta; $slop += $r.Delta * $diskSlop.authored
                $adds.Add([pscustomobject]@{ Name = [string]$r.Name; Bytes = [int64]$r.Delta; Kind = 'authored' })
            } elseif ($r.Delta -lt 0) {
                $b = -[int64]$r.Delta
                $free += $b; $slop += $b * $diskSlop.recorded
                $frees.Add([pscustomobject]@{ Name = [string]$r.Name; Bytes = $b; Kind = 'recorded' })
            }
            # A Store package has no readable size at all - WindowsApps refuses
            # administrators - so it is counted, never sized.
            if ($r.Blind -gt 0) {
                $blind.Add([pscustomobject]@{ Name = [string]$r.Name
                                              Why = "$($r.Blind) Store package(s); Windows does not publish their size" })
            }
        }

        # The browser is a picker rather than a row, so nothing above sees it.
        foreach ($b in @($state.BrowserChoices)) {
            $mb = [int64](Get-WDBrowserSizeMb -Name $b) * 1MB
            $add += $mb; $slop += $mb * $diskSlop.authored
            $adds.Add([pscustomobject]@{ Name = $b; Bytes = $mb; Kind = 'authored' })
        }

        [pscustomobject]@{
            Freed = $free; Added = $add; Net = ($add - $free)
            Slop  = [int64][Math]::Round($slop)
            Frees = @($frees | Sort-Object Bytes -Descending)
            Adds  = @($adds  | Sort-Object Bytes -Descending)
            Blind = @($blind)
        }
    }

    # $paintDiskCard lived here - the Details drop-down. Removed with the rest
    # of the storage forensics.

    $paintStorage = {
        $snap = $storage.Snapshot
        $bar  = $ui.DiskBar
        $bar.ColumnDefinitions.Clear()
        $bar.Children.Clear()

        # The clean-up rows first and outside everything below, because their
        # sizes do not depend on the drive having reported a capacity.
        foreach ($r in $storageRows) {
            if (-not $r.SizeTag) { continue }
            if ($snap -and $snap.Items.ContainsKey($r.Id)) {
                $b = [int64]$snap.Items[$r.Id]
                if ($b -gt 0) {
                    $r.SizeTag.Text = '-' + (Format-WDBytes $b)
                    & $Ref $r.SizeTag 'Foreground' 'Accent'
                    $r.SizeTag.ToolTip = 'Measured on this machine just now.'
                } else {
                    $r.SizeTag.Text = 'nothing to free'
                    & $Ref $r.SizeTag 'Foreground' 'Muted'
                    $r.SizeTag.ToolTip = 'Nothing was found to clean up here.'
                    # Left alone if already ticked: taking a choice back because
                    # the answer turned out to be zero is worse than leaving it.
                    if (-not $r.Check.IsChecked) {
                        $r.Check.IsEnabled = $false
                        & $Ref $r.Name 'Foreground' 'Muted'
                    }
                }
            } elseif (-not $snap -or -not $snap.Priced) {
                $r.SizeTag.Text = 'measuring'
                & $Ref $r.SizeTag 'Foreground' 'Muted'
            } else {
                $r.SizeTag.Text = 'size unknown'
                & $Ref $r.SizeTag 'Foreground' 'Muted'
                $r.SizeTag.ToolTip = 'This one cannot be sized ahead of the run, so it is not counted in the bar above.'
            }
        }

        $hit = & $diskImpact
        $storage.Impact = $hit

        # Two different empty states, and saying the wrong one is worse than
        # saying nothing.
        if (-not $snap -or $snap.TotalBytes -le 0) {
            $ui.DiskCap.Text  = ''
            $ui.DiskNote.Text = $(if ($snap) {
                'This drive did not report a size, so there is nothing to draw here.'
            } else {
                'Measuring what is on this drive.'
            })
            return
        }

        # What the selection frees comes out of the used side and what it
        # installs out of the free side, so the two sit either side of the
        # boundary.
        $picked = [Math]::Min($hit.Freed, $snap.UsedBytes)
        $spare  = [Math]::Max(0L, $snap.Reclaimable - [Math]::Min($hit.Freed, $snap.Reclaimable))
        $newFree = $snap.FreeBytes + $picked
        $coming = [Math]::Min($hit.Added, $newFree)
        $rest   = [Math]::Max(0L, $newFree - $coming)

        $blocks = New-Object System.Collections.Generic.List[psobject]
        foreach ($s in $snap.Segments) {
            $tip = ''
            if ($s.Key -eq 'other') {
                $lines = @('Everything else on the drive, including whatever sits at its root.')
                if ($snap.Reserve) {
                    foreach ($n in $snap.Reserve.Keys) { $lines += ('{0}   {1}' -f $n, (Format-WDBytes ([int64]$snap.Reserve[$n]))) }
                }
                if ($snap.Denied -gt 0) { $lines += "$($snap.Denied) folder(s) refused to be read and are counted here." }
                $tip = ($lines -join "`n")
            }
            # Falls back rather than leaving the colour empty: an empty one is
            # how free space is drawn.
            $col = [string]$diskColors[[string]$s.Key]
            if (-not $col) { $col = 'Muted' }
            # Whatever the selection frees has to come out of the blocks it is
            # leaving, or the bar adds up to more than the drive holds.
            $blocks.Add([pscustomobject]@{
                Key = [string]$s.Key; Label = [string]$s.Label; Bytes = [int64]$s.Bytes
                Color = $col; Alpha = 1.0; Tip = $tip })
        }
        $blocks.Add([pscustomobject]@{
            Key = 'spare'; Label = 'Can be freed'; Bytes = [int64]$spare
            Color = [string]$diskColors.spare; Alpha = 0.30
            Tip = 'What the clean-ups could free, and have not been asked to.' })
        $blocks.Add([pscustomobject]@{
            Key = 'pick'; Label = 'Frees'; Bytes = [int64]$picked
            Color = [string]$diskColors.pick; Alpha = 1.0
            Tip = 'What your selection would give back.' })
        $blocks.Add([pscustomobject]@{
            Key = 'grow'; Label = 'Installs'; Bytes = [int64]$coming
            Color = [string]$diskColors.grow; Alpha = 1.0
            Tip = 'Roughly what your selection would install. Approximate - see Details.' })
        $blocks.Add([pscustomobject]@{
            Key = 'free'; Label = 'Free'; Bytes = [int64]$rest
            Color = ''; Alpha = 1.0; Tip = '' })

        # The freed block is drawn out of the descriptive ones, so their total
        # has to come down by the same amount.
        $known = 0L
        foreach ($b in $blocks) { if ($b.Key -in @('windows','apps','users','other','unknown')) { $known += $b.Bytes } }
        if ($picked -gt 0 -and $known -gt 0) {
            $keep = [double][Math]::Max(0L, $known - $picked) / [double]$known
            foreach ($b in $blocks) {
                if ($b.Key -in @('windows','apps','users','other','unknown')) { $b.Bytes = [int64]($b.Bytes * $keep) }
            }
        }

        $col = 0
        foreach ($b in $blocks) {
            if ($b.Bytes -le 0) { continue }
            $cd = New-Object Windows.Controls.ColumnDefinition
            $cd.Width = New-WDGridLength ([double]$b.Bytes) 'Star'
            # A selection too small to see is still a selection, and a bar that
            # does not visibly react to a click reads as broken.
            if ($b.Key -in @('pick', 'grow')) { $cd.MinWidth = 3 }
            $bar.ColumnDefinitions.Add($cd)
            if ($b.Color) {
                $seg = New-Object Windows.Controls.Border
                & $Ref $seg 'Background' $b.Color
                $seg.Opacity    = $b.Alpha
                if ($b.Tip) { $seg.ToolTip = $b.Tip }
                [Windows.Controls.Grid]::SetColumn($seg, $col)
                $null = $bar.Children.Add($seg)
            }
            $col++
        }
        $storage.Blocks = $blocks

        $ui.DiskCap.Text = '{0} free of {1}' -f (Format-WDBytes $snap.FreeBytes), (Format-WDBytes $snap.TotalBytes)

        $caveat = @("$($snap.Drive) is $($snap.UsedPercent)% full.",
                    'Windows, Apps and Your files are measured by adding up file sizes, which is close but not exact.')
        if ($snap.Scaled) {
            $caveat += 'They add up to more than the volume holds - the component store is a hardlink farm, so the same file counts once per name it has - and have been scaled to fit.'
        }
        if ($snap.Denied -gt 0) {
            $caveat += "$($snap.Denied) folder(s) refused to be read; whatever is in them shows up under Other."
        }
        $caveat += 'Open Details for what your selection does to it, item by item.'
        $ui.DiskBarFrame.ToolTip = ($caveat -join "`n`n")

        # One line, and it has to fit on one line: this sits in the header on
        # every page.
        if (-not $snap.Priced) {
            $ui.DiskNote.Text = "Measuring what is on $($snap.Drive)."
        } elseif ($hit.Freed -le 0 -and $hit.Added -le 0) {
            $ui.DiskNote.Text = "$($snap.Drive) is $($snap.UsedPercent)% full. Nothing selected changes that."
        } else {
            $net    = $hit.Added - $hit.Freed
            $band   = $hit.Slop
            $nowPct = [int][Math]::Round(100 * [Math]::Max(0L, $snap.UsedBytes + $net) / $snap.TotalBytes)
            $verb   = $(if ($net -le 0) { 'frees about {0}' } else { 'costs about {0}' })
            $txt = ($verb -f (Format-WDBytes ([Math]::Abs($net)))) +
                   $(if ($band -gt 0) { " (give or take $(Format-WDBytes $band))" } else { '' }) +
                   " - $($snap.Drive) would go from $($snap.UsedPercent)% to $nowPct% full"
            if ($hit.Freed -gt 0 -and $hit.Added -gt 0) {
                $txt = "Frees $(Format-WDBytes $hit.Freed), installs $(Format-WDBytes $hit.Added) - net " + $txt.Substring($txt.IndexOf('about'))
            }
            if ($hit.Blind.Count) {
                $txt += ", and $($hit.Blind.Count) item$(if ($hit.Blind.Count -ne 1) { 's' }) nothing can size"
            }
            $ui.DiskNote.Text = $txt + '.'
        }
        # It shares a line with everything else, so it will be trimmed on a
        # narrow window and the whole sentence has to stay reachable.
        $ui.DiskNote.ToolTip = $ui.DiskNote.Text

        # The clean-ups have no figure until the drive walk finishes, half a
        # minute after the window opens.
        if ([string]$state.Group -eq 'space' -and $applyOrderRef.Fn) {
            if ($groupsRef.Drop) { & $groupsRef.Drop 'space' }
            & $applyOrderRef.Fn
        }
    }
    $storage.Paint = $paintStorage

    # Enforced before anything counts, so the tally, the deltas, and the storage
    # bar all describe the selection that survives the rules.
    $syncExclusions = {
        foreach ($x in $EXCLUSIONS) {
            $src = $rowById[[string]$x.When]
            $dst = $rowById[[string]$x.Blocks]
            if (-not $src -or -not $dst) { continue }
            $off = [bool]$src.Check.IsChecked
            if ($off -eq [bool]$dst.Gated) { continue }
            $dst.Gated = $off
            if ($off) {
                $dst.Check.IsChecked = $false
                $dst.Check.IsEnabled = $false
                $dst.Panel.Cursor    = 'Arrow'
                $dst.Panel.Opacity   = 0.75
                $dst.Gate.Text       = [string]$x.Why
                $dst.Gate.Visibility = 'Visible'
            } else {
                # Absent wins: a row with nothing to act on stays inert whatever
                # the rules say, or clearing an exclusion would hand back a tick
                # the machine cannot honour.
                if (-not $dst.Absent) {
                    $dst.Check.IsEnabled = $true
                    $dst.Panel.Cursor    = 'Hand'
                    $dst.Panel.Opacity   = 1.0
                }
                $dst.Gate.Visibility = 'Collapsed'
            }
        }
    }

    # Ticking Edge removal ticks its extensions; backing out takes back exactly
    # the rows this put there and nothing else.
    $syncEdgeExtensions = {
        if (-not $edgeExtIds.Count) { return }
        $edgeRow = $rowById[$EDGE_ID]
        # The Advanced rows are built on demand, so this legitimately has
        # nothing to work with until they exist.
        if (-not $edgeRow) { return }
        $on = [bool]$edgeRow.Check.IsChecked
        if ($on -eq [bool]$state.EdgeExtOn) { return }
        $state.EdgeExtOn = $on
        # A mode was applied, not a box ticked. Where Edge ended up is recorded
        # so the next real gesture measures from the right place.
        if ($state.PresetSweep) { return }

        # Suspended around the sets: each raises Checked, and letting a dozen of
        # those re-enter the tally is the restyle storm.
        $was = $state.Suspend
        $state.Suspend = $true
        try {
            if ($on) {
                $took = New-Object System.Collections.Generic.List[string]
                foreach ($id in $edgeExtIds) {
                    $r = $rowById[[string]$id]
                    if (-not $r -or -not $r.Check.IsEnabled -or $r.Check.IsChecked) { continue }
                    $r.Check.IsChecked = $true
                    $took.Add([string]$id)
                }
                $state.EdgeExtAuto = @($took)
            } else {
                foreach ($id in @($state.EdgeExtAuto)) {
                    $r = $rowById[[string]$id]
                    if ($r -and $r.Check.IsChecked) { $r.Check.IsChecked = $false }
                }
                $state.EdgeExtAuto = @()
            }
        } finally { $state.Suspend = $was }
    }

    $updateTally = {
        if ($state.Suspend) { return }
        & $syncExclusions
        & $syncEdgeExtensions
        $d  = & $currentDiff
        $on = @($d.Selected).Count
        # A strip belongs to its row's tick, and ticking a row runs this rather
        # than the filter.
        if ($syncStripsRef.Fn) { & $syncStripsRef.Fn }

        # Mark the options themselves, so what you changed is visible in the
        # list rather than only as a count at the top.
        $addedSet = New-WDStringSet $d.Added
        $remSet   = New-WDStringSet $d.Removed
        foreach ($r in $rows) {
            if ($addedSet.Contains($r.Id)) {
                & $Ref $r.Name 'Foreground' 'Ok';    $r.Name.FontWeight = 'Bold'
                $r.DiffTag.Text = 'added';       & $Ref $r.DiffTag 'Foreground' 'Ok'
                $r.DiffTag.Visibility = 'Visible'
            } elseif ($remSet.Contains($r.Id)) {
                & $Ref $r.Name 'Foreground' 'Bad';   $r.Name.FontWeight = 'Bold'
                $r.DiffTag.Text = 'removed';     & $Ref $r.DiffTag 'Foreground' 'Bad'
                $r.DiffTag.Visibility = 'Visible'
            } elseif ($r.DiffTag.Visibility -eq 'Visible') {
                & $Ref $r.Name 'Foreground' 'Text'; $r.Name.FontWeight = 'SemiBold'
                $r.DiffTag.Visibility = 'Collapsed'
            }
        }
        # Handed the two sets that just marked the rows, rather than diffing
        # itself once per group per tick.
        if ($groupResetRef.Fn) { & $groupResetRef.Fn $addedSet $remSet }

        # The deltas coloured, so a modified preset is obvious at a glance.
        $tb = $ui.TxtActivePreset
        $tb.Inlines.Clear()
        # Short form here too: the badge shares one toolbar row with a scrolling
        # button strip.
        $shown = [string](& $shortPreset ([string]$state.Preset))
        $ui.PresetBadge.ToolTip = $(if ($shown -ne [string]$state.Preset) { [string]$state.Preset } else { $null })
        $head = New-Object Windows.Documents.Run ("${shown}: $on of $($rows.Count) options")
        & $Ref $head 'Foreground' $presetColor[$state.Preset]
        $null = $tb.Inlines.Add($head)
        if ($d.Added.Count) {
            $r = New-Object Windows.Documents.Run ("   +$($d.Added.Count) added")
            & $Ref $r 'Foreground' 'Ok'; $r.FontWeight = 'Bold'
            $null = $tb.Inlines.Add($r)
        }
        if ($d.Removed.Count) {
            $r = New-Object Windows.Documents.Run ("   -$($d.Removed.Count) removed")
            & $Ref $r 'Foreground' 'Bad'; $r.FontWeight = 'Bold'
            $null = $tb.Inlines.Add($r)
        }
        $modified = ($d.Added.Count -gt 0 -or $d.Removed.Count -gt 0)
        & $Ref $ui.PresetBadge 'Background' $(if ($modified) { 'Card' } else { 'CardSel' })
        $state.Modified = $modified
        # Offered only when there is something to undo, and scoped to the mode
        # in front of you.
        $ui.BtnResetOne.Content    = "Reset $shown"
        $ui.BtnResetOne.Visibility = if ($modified) { 'Visible' } else { 'Collapsed' }
        # Save follows it from the other direction: with nothing changed there
        # is nothing to keep, and all three of its answers are about a change
        # that has not been made.
        $ui.BtnSave.Visibility = $ui.BtnResetOne.Visibility
        & $paintAdvancedPresets
        # Last, so the browser notice appears over a list that already reflects
        # the change that triggered it.
        $edge = $rowById[$EDGE_ID]
        if ($edge) { & $syncBrowser ([bool]$edge.Check.IsChecked) }
        # The bar is a view of the selection, so it is repainted wherever the
        # selection changes.
        & $paintStorage
        # Not $applyFilter, which would rewrite Visibility on three hundred rows
        # on every click.
        & $paintFilterCount
    }
    $updateTallyRef.Fn = $updateTally
    # Bound here at the function's own scope and reused for every row: re-bound
    # per row from inside the loop, GetNewClosure re-binds the block to the
    # calling scope.
    $rowTally = $updateTally.GetNewClosure()
    $advWork.Add({
    if ($advSay.Fn) { & $advSay.Fn 'Wiring the rows up' }
    foreach ($r in $rows) { $rowById[$r.Id] = $r }
    foreach ($r in $rows) {
        $r.Check.Add_Checked($rowTally)
        $r.Check.Add_Unchecked($rowTally)
    }

    # Unticking the parent takes its children with it, and the filter is what
    # puts them back on screen.
    $dependants = @{}
    foreach ($r in $rows) {
        if (-not $r.Requires) { continue }
        if (-not $dependants.ContainsKey($r.Requires)) { $dependants[$r.Requires] = New-Object System.Collections.Generic.List[psobject] }
        $dependants[$r.Requires].Add($r)
    }
    # $parentId, not $pid: $PID is a readonly automatic variable, and foreach
    # over it throws.
    foreach ($parentId in $dependants.Keys) {
        $parent = $rowById[$parentId]
        if (-not $parent) { continue }
        $kids   = $dependants[$parentId]
        $filt   = $applyFilterRef
        $inst   = $installedIds
        $pidKey = [string]$parentId
        $sync = {
            # Nothing is withdrawn when the parent is already on the machine:
            # its box is off because there is nothing to install.
            if (-not $this.IsChecked -and -not $inst.Contains($pidKey)) {
                foreach ($k in $kids) { $k.Check.IsChecked = $false }
            }
            if ($filt.Fn) { & $filt.Fn }
        }.GetNewClosure()
        $parent.Check.Add_Checked($sync)
        $parent.Check.Add_Unchecked($sync)
    }
    }.GetNewClosure())

    # One entry per gesture, so clearing a whole section takes one Undo rather
    # than thirty.
    $advUndo = New-Object System.Collections.Generic.List[psobject]
    # What was ticked when this page was last handed a preset, which is what "as
    # it was when you opened it" means.
    $advBase = New-Object System.Collections.Generic.HashSet[string]
    # Cheap enough to ask on every gesture: one pass over ~240 booleans.
    $advAtBase = {
        $n = 0
        foreach ($r in $rows) {
            if (-not $r.Check.IsChecked) { continue }
            $n++
            if (-not $advBase.Contains([string]$r.Id)) { return $false }
        }
        ($n -eq $advBase.Count)
    }.GetNewClosure()
    # A gesture is a list of rows that moved together, so a heading click and a
    # single tick are the same shape.
    $advSayGesture = {
        param($Changes)
        $c = @($Changes)
        if (-not $c.Count) { return '' }
        if ($c.Count -eq 1) {
            $r = $rowById[[string]$c[0].Id]
            $nm = [string]$(if ($r) { $r.Name.Text } else { $c[0].Id })
            return $(if ([bool]$c[0].Was) { "Cleared $nm" } else { "Selected $nm" })
        }
        # Was is the value before the gesture, so a batch that was mostly off is
        # one that has just been turned on.
        $on = @($c | Where-Object { -not [bool]$_.Was }).Count
        if ($on -eq $c.Count) { return "Selected $($c.Count) items" }
        if ($on -eq 0)        { return "Cleared $($c.Count) items" }
        "Changed $($c.Count) items"
    }.GetNewClosure()
    $showAdvUndo = {
        # Back where it started means there is nothing to take back, whatever
        # the stack still holds.
        if ($advUndo.Count -and (& $advAtBase)) { $advUndo.Clear() }
        $ui.BtnAdvUndo.Content    = $(if ($advUndo.Count -gt 1) { "Undo ($($advUndo.Count))" } else { 'Undo' })
        $ui.BtnAdvUndo.Visibility = $(if ($advUndo.Count) { 'Visible' } else { 'Collapsed' })
        $ui.TxtAdvNote.Text = $(if ($advUndo.Count) { & $advSayGesture $advUndo[$advUndo.Count - 1] } else { '' })
        & $Ref $ui.TxtAdvNote 'Foreground' 'Sub'
    }.GetNewClosure()
    $advUndoRef.Push = {
        param($Changes)
        $c = @(@($Changes) | Where-Object { $_ })
        if (-not $c.Count) { return }
        $advUndo.Add($c)
        & $showAdvUndo
    }.GetNewClosure()
    $undoAdvEdit = {
        if (-not $advUndo.Count) { return }
        $last = $advUndo[$advUndo.Count - 1]
        $advUndo.RemoveAt($advUndo.Count - 1)
        # Same suspend as a bulk set: an undo of a whole section is a bulk set.
        $state.Suspend = $true
        try {
            foreach ($ch in $last) {
                $r = $rowById[[string]$ch.Id]
                if ($r) { $r.Check.IsChecked = [bool]$ch.Was }
            }
        } finally { $state.Suspend = $false }
        & $updateTally
        & $showAdvUndo
    }
    $ui.BtnAdvUndo.Add_Click({ & $undoAdvEdit }.GetNewClosure())

    $applyPresetToChecks = {
        param([string]$name)
        $state.Preset = $name
        & $syncOwnership $name
        # Reset preset names the mode on screen, so switching mode re-asks
        # whether there is anything to reset.
        & $recount
        # The stack describes edits to the boxes as they were, and a preset
        # switch replaces every one.
        $advUndo.Clear()
        & $showAdvUndo
        $want = New-WDStringSet (& $effectiveIds $name)
        # Suspend while bulk-setting, or each of ~200 boxes restyles all ~200
        # rows.
        $state.PresetSweep = $true
        try {
            $state.Suspend = $true
            try   { foreach ($r in $rows) { $r.Check.IsChecked = ($want.Contains($r.Id) -and -not $r.Absent) } }
            finally { $state.Suspend = $false }
            # This is the page as it was opened, so it is the baseline Undo
            # measures against. Taken off the boxes, because an absent row is
            # never ticked whatever the mode says.
            $advBase.Clear()
            foreach ($r in $rows) { if ($r.Check.IsChecked) { $null = $advBase.Add([string]$r.Id) } }
            & $updateTally
        } finally { $state.PresetSweep = $false }
        # A wholesale preset change makes a checked/unchecked snapshot a view of
        # what used to be ticked.
        foreach ($b in $filterBoxes) {
            if ($b.Group -eq 'View' -and $b.Name -in @($CHECKED, $UNCHECKED) -and $b.Box.IsChecked) {
                & $takeSnapshot ([string]$b.Name)
            }
        }
        # "Changed from preset" is computed live against the preset that was on
        # screen, and nothing above re-runs the filter.
        if ($filterSel.View.Count -and $applyFilterRef.Fn) { & $applyFilterRef.Fn }
        # Selected first is a layout, not a paint, so nothing above moves a row.
        if ([string]$state.Sort -in @('selected', 'unselected') -and $applyOrderRef.Fn) { & $applyOrderRef.Fn }
    }
    # Saying that the button did something: two hundred boxes change at once,
    # which is too much to perceive as one event.
    $presetNote = @{ Timer = (New-Object Windows.Threading.DispatcherTimer) }
    $presetNote.Timer.Interval = [TimeSpan]::FromSeconds(6)
    $presetNote.Timer.Add_Tick({
        $presetNote.Timer.Stop()
        $el = $ui.TxtPresetNote
        $fade = New-Object Windows.Media.Animation.DoubleAnimation
        $fade.From = 1.0
        $fade.To = 0.0
        $fade.Duration = [Windows.Duration][TimeSpan]::FromMilliseconds(450)
        $fade.Add_Completed({ $el.Visibility = 'Collapsed' }.GetNewClosure())
        $el.BeginAnimation([Windows.UIElement]::OpacityProperty, $fade)
    }.GetNewClosure())
    $sayPresetSwitch = {
        param([string]$To, [string]$From, [int]$Before, [int]$After, [int]$Kept)
        $tb = $ui.TxtPresetNote
        # An animation holds the property it last wrote, so it has to be
        # released before the opacity can be set by hand.
        $tb.BeginAnimation([Windows.UIElement]::OpacityProperty, $null)
        $tb.Opacity = 1
        $tb.Inlines.Clear()

        $lead = New-Object Windows.Documents.Run 'Switched to '
        & $Ref $lead 'Foreground' 'Sub'
        $null = $tb.Inlines.Add($lead)
        $name = New-Object Windows.Documents.Run ([string]$To)
        # Asked for, never assumed: $presetColor is keyed by name and a dropped
        # or renamed file leaves nothing behind it, and handing $Ref an empty
        # key throws from inside a click handler.
        $tint = [string]$presetColor[[string]$To]
        if (-not $tint) { $tint = 'Text' }
        & $Ref $name 'Foreground' $tint
        $name.FontWeight = 'SemiBold'
        $null = $tb.Inlines.Add($name)

        # The delta, which is the whole point: somebody who cannot yet read a
        # page of two hundred tick boxes can read "70 more".
        $moved = $After - $Before
        $said = '. The same options stay selected.'
        if ($moved -gt 0) {
            $said = ". $moved more option$(if ($moved -ne 1) { 's' }) selected."
        } elseif ($moved -lt 0) {
            $n = [Math]::Abs($moved)
            $said = ". $n fewer option$(if ($n -ne 1) { 's' }) selected."
        }
        # Only when it happened, and it is the half nobody would guess: leaving
        # a preset mid-edit keeps the edit rather than discarding it.
        if ($Kept -gt 0) {
            $said += $(if ($Kept -eq 1) { " Your 1 change to $From was kept." }
                       else            { " Your $Kept changes to $From were kept." })
        }
        $rest = New-Object Windows.Documents.Run $said
        & $Ref $rest 'Foreground' 'Sub'
        $null = $tb.Inlines.Add($rest)
        $tb.Visibility = 'Visible'

        # Held long enough to read, then faded: a line that vanishes reads as
        # something missed.
        if ($state.NoPrompts) { return }
        # Restart, not start: a second switch inside the hold re-arms it rather
        # than inheriting the remainder.
        $presetNote.Timer.Stop()
        $presetNote.Timer.Start()
    }.GetNewClosure()

    # Switching preset in Advanced keeps whatever you had changed, exactly as
    # leaving the page does.
    $switchPreset = {
        param([string]$name)
        $from = [string]$state.Preset
        $before = 0
        foreach ($r in $rows) { if ($r.Check.IsChecked) { $before++ } }
        $kept = 0
        if ($name -ne $state.Preset -and (& $unsavedEdits)) {
            $d = & $currentDiff
            $kept = @($d.Added).Count + @($d.Removed).Count
            & $setOverride $state.Preset @($d.Added) @($d.Removed)
        }
        & $applyPresetToChecks $name
        $after = 0
        foreach ($r in $rows) { if ($r.Check.IsChecked) { $after++ } }
        & $sayPresetSwitch $name $from $before $after $kept
    }
    # Drops the edit for this mode only, saved or not. No confirmation: it is
    # one mode, and re-making the edit costs what it did the first time.
    $resetOnePreset = {
        param([string]$Name = '')
        if (-not $Name) { $Name = [string]$state.Preset }
        if (-not $overrides.ContainsKey($Name)) { return }
        $overrides.Remove($Name)
        & $recount
            & $repaintModeGrid
        # Only when it is the preset the boxes are showing: re-ticking them for
        # one nobody is looking at would move the page under them.
        if ($Name -eq [string]$state.Preset) { & $applyPresetToChecks $Name }
        & $saveUiState
    }
    $ui.BtnResetOne.Add_Click({ & $resetOnePreset }.GetNewClosure())

    # Rebuilt whenever the list of presets changes, which now happens while the
    # window is open.
    $advBtnNames = @{ Conservative = 'BtnConservative'; Balanced = 'BtnBalanced'
                      Aggressive = 'BtnAggressive'; Extreme = 'BtnExtreme'; Custom = 'BtnCustom' }
    $buildAdvPresetRow = {
        $go   = $switchPreset
        $row  = $ui.PresetRow
        $map  = $advPresetButtons
        $tips = @{ Custom = 'Clear every selection and build the list yourself.' }
        $row.Children.Clear()
        $map.Clear()
        foreach ($n in $presetNames) {
            $b = New-Object Windows.Controls.Button
            # The short form: this row grows by one for every file loaded.
            $b.Content = [string](& $shortPreset ([string]$n))
            $b.Padding = '12,5'; $b.Margin = '0,0,6,0'
            if ($tips.ContainsKey($n)) { $b.ToolTip = [string]$tips[$n] }
            elseif ($loadedPresets.Contains($n)) {
                $b.ToolTip = "$n - loaded from $([string]$loadedPresets[$n].Path)"
            }
            $b.Tag = [string]$n
            $b.Add_Click({ & $go ([string]$this.Tag) }.GetNewClosure())
            $null = $row.Children.Add($b)
            $map[[string]$n] = $b
            if ($advBtnNames.ContainsKey([string]$n)) { $ui[$advBtnNames[[string]$n]] = $b }
        }
        & $paintAdvancedPresets
    }.GetNewClosure()
    & $buildAdvPresetRow

    # Grouping and sorting are two questions, two controls. There is no pair of
    # these that has to be forbidden, so nothing is grayed out.
    $GROUPS = [ordered]@{
        'category' = 'Category'
        'bloat'    = 'Bloat rating'
        'risk'     = 'Risk'
        'alpha'    = 'Name (A-Z)'
        'space'    = 'Storage savings'
    }
    # Two entries; it held four plus a check box. Three of the four were also
    # groupings, and a ranked list of 250 rows has no line saying where risky
    # stops.
    $SORTS = [ordered]@{
        'name'     = 'Name (A-Z)'
        'selected' = 'Selected first'
        'unselected' = 'Selected last'
    }
    # Which grouping keeps the Remove / Add / Extras split. Only Category: a
    # section is itself a way of grouping, so any other crossed with it produces
    # the same band three times.
    $GROUP_SECTIONED = @{ category = $true; alpha = $false; risk = $false; bloat = $false; space = $false }
    # Sections a grouping does not lay out at all, as opposed to folding into a
    # band. Only Bloat rating, and only Add: there is no answer to "how bad is
    # it that this is here" about software the machine does not have.
    $GROUP_OMITS = @{ bloat = @('add') }
    # The bloat bands and $bandOf are declared far above, before the mode page,
    # because the mode columns read them too.
    $SPACE_FLOOR = 500MB

    # There was an $orderKey here mapping a sort mode to a number. It went with
    # the three sorts that were also groupings.

    # The order rows run in inside one block, and the one structural rule that
    # outranks it.
    $sortMembers = {
        param($Rows, [string]$SortMode)
        # "Selected first" floats the ticked rows to the top of each block, and
        # the alphabet still holds inside each half.
        $selFirst = ($SortMode -eq 'selected')
        $selLast  = ($SortMode -eq 'unselected')
        $byId = @{}
        foreach ($r in $Rows) { $byId[[string]$r.Id] = $r }
        $anchorOf = {
            param($R)
            if ($R.Requires -and $byId.ContainsKey([string]$R.Requires)) { $byId[[string]$R.Requires] } else { $R }
        }
        # A dependent row takes its parent's half, which is why this reads the
        # anchor's box rather than its own.
        $band = {
            param($R)
            $box = (& $anchorOf $R).Check
            if ($box.IsChecked) { return $(if ($selFirst) { 0 } else { 1 }) }
            if (-not $box.IsEnabled) { return 2 }
            $(if ($selFirst) { 1 } else { 0 })
        }
        $half = {
            param($R)
            if (-not ($selFirst -or $selLast)) { return 0 }
            & $band $R
        }
        # Sort-Object is not stable in 5.1, so the name is always a key -
        # without it rows shuffle every time the order is re-applied.
        @($Rows | Sort-Object `
            @{ E = { [int](& $half $_) } },
            @{ E = { [string](& $anchorOf $_).Name.Text } },
            @{ E = { $(if ((& $anchorOf $_) -eq $_) { 0 } else { 1 }) } },
            @{ E = { [string]$_.Name.Text } })
    }.GetNewClosure()

    # Every grouping is a list of full-width group blocks, exactly like
    # Category.
    $groupCache = @{}
    $liveGroups = New-Object System.Collections.Generic.List[psobject]

    # A WPF element has exactly one parent, so a block has to be emptied before
    # anything else can claim its rows. Collapsed as well, because a parentless
    # block reporting Visible is a lie.
    $letGoGroup = {
        param($G)
        $G.L.Children.Clear(); $G.R.Children.Clear()
        $G.Head.Visibility = 'Collapsed'; $G.Rule.Visibility = 'Collapsed'; $G.Block.Visibility = 'Collapsed'
    }.GetNewClosure()

    # Drop a cached partition, rows first.
    $groupsRef.Drop = {
        param([string]$Mode)
        if (-not $groupCache.ContainsKey($Mode)) { return }
        foreach ($g in $groupCache[$Mode]) { & $letGoGroup $g }
        $groupCache.Remove($Mode)
    }.GetNewClosure()

    $buildGroups = {
        param([string]$Mode)
        if ($groupCache.ContainsKey($Mode)) { return }

        $out = New-Object System.Collections.Generic.List[psobject]
        # Every row. Recurring used to be excluded, because it was hand-built
        # into a block of its own and could not be re-parented.
        $omit = @()
        if ($GROUP_OMITS.ContainsKey($Mode)) { $omit = @($GROUP_OMITS[$Mode]) }
        # A row hosted in a fixed block is never grouped: it is already parented
        # there and $fillColumns would tear it out.
        $all = @($rows | Where-Object { [string]$_.Section -notin $omit -and -not $_.HostBlock })

        # A dependent row means nothing away from its parent, so it never gets a
        # group of its own.
        $idsHere = New-Object 'System.Collections.Generic.HashSet[string]'
        foreach ($r in $all) { $null = $idsHere.Add([string]$r.Id) }
        $hasParent = New-Object 'System.Collections.Generic.HashSet[string]'
        foreach ($r in $all) {
            if ($r.Requires -and $idsHere.Contains([string]$r.Requires)) { $null = $hasParent.Add([string]$r.Id) }
        }
        $kidsOf = @{}
        foreach ($r in $all) {
            if (-not $hasParent.Contains([string]$r.Id)) { continue }
            $k = [string]$r.Requires
            if (-not $kidsOf.ContainsKey($k)) { $kidsOf[$k] = New-Object System.Collections.Generic.List[psobject] }
            $kidsOf[$k].Add($r)
        }
        $lead = @($all | Where-Object { -not $hasParent.Contains([string]$_.Id) })

        $addGroup = {
            param([string]$Title, [string]$Glyph, [string]$Section, $Members)
            $lst = New-Object System.Collections.Generic.List[psobject]
            foreach ($m in @($Members)) {
                $lst.Add($m)
                if ($kidsOf.ContainsKey([string]$m.Id)) { foreach ($k in $kidsOf[[string]$m.Id]) { $lst.Add($k) } }
            }
            if (-not $lst.Count) { return }
            $out.Add((& $makeGroupBlock $Title $Glyph $Section $lst))
        }

        if ($Mode -eq 'space') {
            # One ranked list and one honest admission underneath: sorting 250
            # rows by size and calling the bottom 200 an answer is not one.
            $big  = @($lead | Where-Object { [int64](& $rowBytes $_) -le -$SPACE_FLOOR })
            $rest = @($lead | Where-Object { [int64](& $rowBytes $_) -gt -$SPACE_FLOOR })
            & $addGroup ("Frees " + (Format-WDBytes $SPACE_FLOOR) + " or more") '' 'remove' $big
            & $addGroup 'Inconsequential' '' 'remove' $rest
        } elseif ($Mode -eq 'risk') {
            foreach ($band in @(@{ R = 2; T = 'Risky' }, @{ R = 1; T = 'Caution' }, @{ R = 0; T = 'No risk' })) {
                & $addGroup $band.T '' 'remove' @($lead | Where-Object { [int]$_.Risk -eq $band.R })
            }
        } elseif ($Mode -eq 'bloat') {
            # $BLOAT_BAND is worst-first with the two non-ratings last, so the
            # bands come out in reading order.
            foreach ($band in $BLOAT_BAND) {
                $b = $band.B
                & $addGroup ([string]$band.N) '' 'remove' @($lead | Where-Object { (& $bandOf $_) -eq $b })
            }
        } else {
            # Letters merged into ranges while a range stays short: one card per
            # letter is 26 cards for 250 rows, most holding two.
            $sorted = @(@($lead) + @($browserRow) | Sort-Object @{ E = { [string]$_.Name.Text } })
            $run = New-Object System.Collections.Generic.List[psobject]
            $first = ''; $last = ''
            foreach ($r in $sorted) {
                $ch = ([string]$r.Name.Text).ToUpper()
                $ch = $(if ($ch.Length -and $ch[0] -ge 'A' -and $ch[0] -le 'Z') { [string]$ch[0] } else { '#' })
                if ($run.Count -ge 10 -and $ch -ne $last) {
                    & $addGroup $(if ($first -eq $last) { $first } else { "$first-$last" }) '' 'remove' $run
                    $run = New-Object System.Collections.Generic.List[psobject]
                    $first = $ch
                }
                if (-not $run.Count) { $first = $ch }
                $run.Add($r); $last = $ch
            }
            if ($run.Count) {
                & $addGroup $(if ($first -eq $last) { $first } else { "$first-$last" }) '' 'remove' $run
            }
        }
        $groupCache[$Mode] = $out
    }.GetNewClosure()

    $applyOrder = {
        $mode = [string]$state.Group
        if (-not $GROUPS.Contains($mode)) { $mode = 'category' }
        $sortBy = [string]$state.Sort
        if (-not $SORTS.Contains($sortBy)) { $sortBy = 'name' }
        $sectioned = [bool]$GROUP_SECTIONED[$mode]
        $state.Sectioned = $sectioned

        # Which rows this grouping does not lay out. Recorded before anything
        # moves, because two things downstream have to tell "not on the page"
        # from "filtered away".
        $state.OffPage.Clear()
        $omitSecs = @()
        if ($GROUP_OMITS.ContainsKey($mode)) { $omitSecs = @($GROUP_OMITS[$mode]) }
        if ($omitSecs.Count) {
            foreach ($r in $rows) {
                if ([string]$r.Section -in $omitSecs) { $null = $state.OffPage.Add([string]$r.Id) }
            }
        }

        $panels = @{
            remove = @{ L = $ui.ColLeft;   R = $ui.ColRight;   G = $ui.AdvColumns }
            add    = @{ L = $ui.AddLeft;   R = $ui.AddRight;   G = $ui.AddColumns }
            extras = @{ L = $ui.ExtraLeft; R = $ui.ExtraRight; G = $ui.ExtraColumns }
        }

        # Plain assignment, not an if-expression: the value is a collection and
        # an if-expression unrolls it.
        $groups = $catHeaders
        if ($mode -ne 'category') {
            & $buildGroups $mode
            $groups = $groupCache[$mode]
        }

        # A WPF element has exactly one parent, so everything is let go before
        # anything is re-homed.
        foreach ($g in $catHeaders) { & $letGoGroup $g }
        foreach ($k in @($groupCache.Keys)) {
            foreach ($g in $groupCache[$k]) { & $letGoGroup $g }
        }
        $liveGroups.Clear()
        foreach ($sec in @('remove','add','extras')) {
            $p = $panels[$sec]
            $p.L.Children.Clear(); $p.R.Children.Clear()
            # Every order is full-width blocks down the left panel, so the
            # section's second column is never used.
            $p.G.ColumnDefinitions[1].Width = New-WDGridLength 0
            $p.G.ColumnDefinitions[2].Width = New-WDGridLength 0
        }

        # The browser picker is filed under W by Name (A-Z) and sits at the top
        # of Add otherwise, so it changes parent with the grouping.
        $bblk = $ui.BrowserAddBlock
        if ($bblk.Parent -is [Windows.Controls.Panel]) { $null = $bblk.Parent.Children.Remove($bblk) }
        if ($mode -ne 'alpha') { $browserHome.Children.Insert(0, $bblk) }

        foreach ($g in $groups) {
            # Kept on the block, because $rebalanceGroups has to re-lay this out
            # after a filter pass.
            $g.Ordered = @(& $sortMembers $g.Rows $sortBy)
            & $fillColumns $g.Ordered $g.L $g.R $g.Grid
            # Forced stale, so the rebalance at the end of $applyFilter always
            # runs once for a freshly laid-out block.
            $g.VisN = -1
            # A block from the cache keeps whatever the last grouping folded it
            # to, and one that opens collapsed reads as a page that failed to
            # draw.
            if ($g.Toggle) { & $setGroupOpen $g.Grid $g.Note $g.Toggle $true $g.Rows }
            $host2 = $(if ($sectioned) { $panels[$g.Section].L } else { $panels['remove'].L })
            $null = $host2.Children.Add($g.Block)
            $liveGroups.Add($g)
        }
        # These blocks are new to the page, so nothing has yet decided which
        # have been changed from the mode.
        if ($groupResetRef.Fn) { & $groupResetRef.Fn $null $null }

        # The Remove banner speaks for the whole list when there are no
        # sections, so it says what the list is.
        $ui.RemoveHead.Text = $(if ($sectioned) { 'Remove' } else { [string]$GROUPS[$mode] })

        # There were two loops here stamping a flag on every block ever built.
        # $applyOrder records what it laid out instead.
        if ($railRef.Rebuild) { & $railRef.Rebuild $groups $sectioned $omitSecs }
        # Every row has just been re-parented, so every cached heading offset
        # describes a layout that no longer exists.
        if ($indexRef.Invalidate) { & $indexRef.Invalidate }
        if ($applyFilterRef.Fn) { & $applyFilterRef.Fn }
    }.GetNewClosure()
    $applyOrderRef.Fn = $applyOrder

    # The category names the filter offers.
    $catNames = New-Object System.Collections.Generic.List[string]
    $advWork.Add({
        if ($advSay.Fn) { & $advSay.Fn 'Listing the categories' }
        foreach ($h in $catHeaders) { $catNames.Add([string]$h.Name) }
    }.GetNewClosure())

    # The group headings' own Reset, and Collapse/Expand all.
    $syncGroupResets = {
        param($AddedSet, $RemSet)
        if ($null -eq $AddedSet) {
            $d = & $currentDiff
            $AddedSet = New-WDStringSet $d.Added
            $RemSet   = New-WDStringSet $d.Removed
        }
        foreach ($g in $liveGroups) {
            if (-not $g.Reset) { continue }
            $changed = $false
            foreach ($r in $g.Rows) {
                # Disabled rows are not decisions and so are not things to put
                # back - except a gated one, which is disabled only because
                # another tick is holding it down.
                if (-not $r.Check.IsEnabled -and -not $r.Gated) { continue }
                $id = [string]$r.Id
                if ($AddedSet.Contains($id) -or $RemSet.Contains($id)) { $changed = $true; break }
            }
            $g.Reset.Visibility = $(if ($changed) { 'Visible' } else { 'Collapsed' })
        }
    }.GetNewClosure()
    $groupResetRef.Fn = $syncGroupResets

    # This group's rows back to the mode's own selection, as one undo entry.
    # Measured against $defaultIds, not $effectiveIds.
    $resetGroupRows = {
        param($Rows)
        $want = New-WDStringSet (& $defaultIds $state.Preset)
        $list = @($Rows)
        # Read off the boxes before anything moves: working out what changed
        # afterwards is the only way to be right, because the second pass can
        # set a row the first could not.
        $before = @{}
        foreach ($r in $list) { $before[[string]$r.Id] = [bool]$r.Check.IsChecked }

        # Suspend, or every box restyles all ~200 rows on the way past.
        $state.Suspend = $true
        try {
            # Off first, then the rules, then on. One pass in row order is wrong
            # whenever a group holds both halves of an exclusion.
            foreach ($r in $list) {
                if ($r.Check.IsEnabled -and $r.Check.IsChecked -and -not $want.Contains([string]$r.Id)) {
                    $r.Check.IsChecked = $false
                }
            }
            & $syncExclusions
            foreach ($r in $list) {
                if ($r.Check.IsEnabled -and -not $r.Check.IsChecked -and $want.Contains([string]$r.Id)) {
                    $r.Check.IsChecked = $true
                }
            }
        } finally { $state.Suspend = $false }

        $changed = New-Object System.Collections.Generic.List[psobject]
        foreach ($r in $list) {
            $was = [bool]$before[[string]$r.Id]
            if ($was -ne [bool]$r.Check.IsChecked) { $changed.Add(@{ Id = $r.Id; Was = $was }) }
        }
        if (-not $changed.Count) { return }
        & $updateTally
        if ($advUndoRef.Push) { & $advUndoRef.Push @($changed) }
    }.GetNewClosure()
    $groupResetRef.Do = $resetGroupRows

    # Every group at once. One gesture, so the rail's offsets are thrown away
    # once rather than ninety times.
    $setAllGroups = {
        param([bool]$Open)
        foreach ($g in $liveGroups) {
            if (-not $g.Toggle) { continue }
            & $setGroupOpen $g.Grid $g.Note $g.Toggle $Open $g.Rows
        }
        if ($indexRef.Invalidate) { & $indexRef.Invalidate }
        if ($indexRef.Spy) { & $indexRef.Spy }
    }.GetNewClosure()
    $ui.BtnCollapseAll.Add_Click({ & $setAllGroups $false }.GetNewClosure())
    $ui.BtnExpandAll.Add_Click({   & $setAllGroups $true  }.GetNewClosure())
    # Through the holder: $refreshAdvanced cannot be written until every page's
    # elements exist.
    $ui.BtnRefresh.Add_Click({ if ($refreshRef.Adv) { & $refreshRef.Adv } }.GetNewClosure())

    # Re-lay each block's two columns, for the blocks whose visible row count
    # has actually moved.
    $rebalanceGroups = {
        foreach ($g in $liveGroups) {
            $n = 0
            foreach ($r in $g.Rows) { if ($r.Panel.Visibility -eq 'Visible') { $n++ } }
            if ($n -eq [int]$g.VisN) { continue }
            $g.VisN = $n
            & $fillColumns $g.Ordered $g.L $g.R $g.Grid
        }
    }.GetNewClosure()

    $applyFilter = {
        $q = $ui.TxtFilter.Text.Trim().ToLower()

        $viewIds = $null
        if ($filterSel.View.Count) {
            $viewIds = New-Object System.Collections.Generic.HashSet[string]
            if ($filterSel.View.Contains($CHECKED))   { foreach ($id in $snapChecked)   { $null = $viewIds.Add($id) } }
            if ($filterSel.View.Contains($UNCHECKED)) { foreach ($id in $snapUnchecked) { $null = $viewIds.Add($id) } }
            if ($filterSel.View.Contains($CHANGED)) {
                $d = & $currentDiff
                foreach ($id in $d.Added)   { $null = $viewIds.Add($id) }
                foreach ($id in $d.Removed) { $null = $viewIds.Add($id) }
            }
        }

        $shown = 0
        $offPage = $state.OffPage
        foreach ($r in $rows) {
            # A row this grouping does not lay out is not on the page, and every
            # count is taken off Visibility.
            $ok = -not $offPage.Contains([string]$r.Id)
            if ($ok -and $null -ne $viewIds) { $ok = $viewIds.Contains($r.Id) }
            # A row that only means something under another one is not on the
            # page until that one is ticked - or is already installed.
            if ($ok -and $r.Requires) {
                $parent = $rowById[[string]$r.Requires]
                $ok = [bool]($installedIds.Contains([string]$r.Requires) -or ($parent -and $parent.Check.IsChecked))
            }
            # A row whose whole meaning depends on something else being true.
            if ($ok -and $rowGate.ContainsKey([string]$r.Id)) { $ok = [bool](& $rowGate[[string]$r.Id]) }
            # The three boxes that subtract. Every other facet narrows to what
            # was ticked; these take away what they name, and they AND with each
            # other.
            if ($ok -and $filterSel.Avail.Contains($HIDE_ABSENT))  { $ok = -not [bool]$r.Absent }
            if ($ok -and $filterSel.Avail.Contains($HIDE_APPLIED)) { $ok = -not [bool]$r.Applied }
            if ($ok -and $filterSel.Avail.Contains($HIDE_OPT_IN))  { $ok = ([int]$r.Tier -ne 0) }
            # The tier the manifest ships, which is what the "opt-in" tag is
            # drawn from - not a live "is this in any preset" query, or the
            # filter would disagree with the label it is named after.
            if ($ok -and $filterSel.Tier.Count) { $ok = ([int]$r.Tier -eq 0) }
            if ($ok -and $filterSel.Sec.Count)  { $ok = $filterSel.Sec.Contains([string]$SEC_LABEL[[string]$r.Section]) }
            if ($ok -and $filterSel.Risk.Count) { $ok = $filterSel.Risk.Contains([string]$riskLabel[[int]$r.Risk]) }
            if ($ok -and $filterSel.Cat.Count)  { $ok = $filterSel.Cat.Contains([string]$r.Category) }
            # Through $bandOf, not $r.Bloat: the filter and the grouping have to
            # agree about which band a row is in.
            if ($ok -and $filterSel.Bloat.Count) { $ok = $filterSel.Bloat.Contains([string]$bandName[[string](& $bandOf $r)]) }
            if ($ok -and $q)             { $ok = $r.Search.Contains($q) }
            $r.Panel.Visibility = if ($ok) { 'Visible' } else { 'Collapsed' }
            if ($ok) { $shown++ }
        }
        # Hide a heading once everything under it is filtered away.
        $narrowed = [bool]$q -or $filterSel.Risk.Count -or $filterSel.Cat.Count -or $filterSel.View.Count -or $filterSel.Bloat.Count -or $filterSel.Tier.Count
        $secOk = {
            param([string]$Key)
            (-not $filterSel.Sec.Count) -or $filterSel.Sec.Contains([string]$SEC_LABEL[$Key])
        }
        # The Add section can be off the page and its picker goes with it.
        $addOmit   = @($GROUP_OMITS[[string]$state.Group]) -contains 'add'
        $addAsSec  = [bool]$GROUP_SECTIONED[[string]$state.Group]
        $addAlpha  = ([string]$state.Group -eq 'alpha')
        $showBrowser = (& $secOk 'add')    -and -not $narrowed -and -not $addOmit -and ($addAsSec -or $addAlpha)
        $showRunOpts = (& $secOk 'extras') -and -not $narrowed
        $ui.BrowserAddBlock.Visibility  = if ($showBrowser) { 'Visible' } else { 'Collapsed' }
        $ui.RunOptionsBlock.Visibility  = if ($showRunOpts) { 'Visible' } else { 'Collapsed' }
        # What the run always does is not a choice, so nothing that narrows the
        # choices has anything to say about it.
        $ui.AlwaysBlock.Visibility      = if ($showRunOpts) { 'Visible' } else { 'Collapsed' }

        $liveSec = @{ remove = 0; add = 0; extras = 0 }
        foreach ($ch in $liveGroups) {
            $any = @($ch.Rows | Where-Object { $_.Panel.Visibility -eq 'Visible' }).Count
            $vis = if ($any) { 'Visible' } else { 'Collapsed' }
            $ch.Head.Visibility = $vis
            $ch.Rule.Visibility = $vis
            # The block is what occupies the page and carries its own margins:
            # collapsing only the heading and the rule left an empty gap.
            $ch.Block.Visibility = $vis
            if ($any) { $liveSec[[string]$ch.Section] += $any }
        }
        # There was a second count here for Recurring alone, because it was the
        # one category built outside the column loop.
        foreach ($s in @(@{ K = 'remove'; Head = 'RemoveHeadBlock'; Box = 'RemoveBox'; Extra = $false },
                         @{ K = 'add';    Head = 'AddHeadBlock';    Box = 'AddBox';    Extra = ($showBrowser -and $addAsSec) },
                         @{ K = 'extras'; Head = 'ExtraHeadBlock';  Box = 'ExtraBox';  Extra = $showRunOpts })) {
            $on = [bool]($liveSec[$s.K] -or $s.Extra)
            $v  = if ($on) { 'Visible' } else { 'Collapsed' }
            $ui[$s.Head].Visibility = $v
            $ui[$s.Box].Visibility  = $v
        }
        # The browser strip is not a row, so the loop above never touched it.
        & $showBrowserStrip ([bool]($browserUi.Row -and $browserUi.Row.Check.IsChecked))
        # Nor are the others. They follow their own row in and out.
        & $syncStrips

        $picked = & $pickedCount
        $unfiltered = (-not $picked -and -not $q)
        # An inventory of what will never be touched, not a list to search.
        $ui.ProtectedBlock.Visibility = if ($unfiltered) { 'Visible' } else { 'Collapsed' }
        # Settings for the application itself. They belong to no section, and no
        # filter can have anything to say about them.
        $ui.AppOptBox.Visibility = if ($unfiltered) { 'Visible' } else { 'Collapsed' }
        $ui.BtnFilter.Content = if ($picked) { "Filter ($picked)" } else { 'Filter' }
        & $paintFilterCount
        # Hiding rows changes where the two columns should break, so the blocks
        # that lost or gained one are laid out again.
        & $rebalanceGroups
        # Filtering moves the page as surely as re-ordering it does - every
        # collapsed row takes its height with it.
        if ($indexRef.Invalidate) { & $indexRef.Invalidate }
        if ($indexRef.Spy) { & $indexRef.Spy }
    }.GetNewClosure()
    $applyFilterRef.Fn = $applyFilter

    # Boxes are created once; ticking one mutates the sets above and re-filters.
    $buildFilterPanel = {
        $onFilter = $applyFilter
        $snap     = $takeSnapshot
        $sel      = $filterSel
        $boxes    = $filterBoxes
        # First of the two hops. $section copies this again, and $flip reads
        # that copy - GetNewClosure sees one scope up and no further.
        $pairList = $FILTER_PAIRS
        $panel = $ui.FilterPanel
        $panel.Children.Clear()
        $boxes.Clear()

        $section = {
            # $Names is untyped on purpose: [string[]] quietly cast every @{
            # Group; Name } pair to its type name.
            param([string]$Title, [string]$Group, $Names, [string]$Note)
            # Second hop down the scope chain, so the handler's dependencies are
            # copied again here.
            $onSel   = $onFilter
            $snapNow = $snap
            $sets    = $sel
            $changed = $CHANGED
            # $boxes is a List captured by reference, so the handler sees every
            # box however late it was added.
            $allBoxes  = $boxes
            $pairs     = $pairList
            $h = New-Object Windows.Controls.TextBlock
            $h.Text = $Title; $h.FontSize = 12; $h.FontWeight = 'SemiBold'
            & $Ref $h 'Foreground' 'Muted'
            $h.Margin = $(if ($panel.Children.Count) { '0,14,0,4' } else { '0,0,0,4' })
            $null = $panel.Children.Add($h)
            if ($Note) {
                $n = New-Object Windows.Controls.TextBlock
                $n.Text = $Note; $n.FontSize = 11; $n.TextWrapping = 'Wrap'; $n.MaxWidth = 300
                & $Ref $n 'Foreground' 'Muted'; $n.Margin = '0,0,0,4'
                $null = $panel.Children.Add($n)
            }
            foreach ($entry in $Names) {
                # A plain string belongs to this section's own group; a pair
                # carries its own, which is how two boxes sit under VIEW and
                # answer to different groups.
                $g  = [string]$Group
                $nm = $entry
                if ($entry -is [hashtable]) { $g = [string]$entry.Group; $nm = [string]$entry.Name }
                $cb = New-Object Windows.Controls.CheckBox
                $cb.Content = $nm; $cb.FontSize = 13; $cb.Margin = '0,3,0,3'
                & $Ref $cb 'Foreground' 'Text'
                $cb.Tag = @{ Group = $g; Name = $nm }
                $flip = {
                    $t = $this.Tag
                    if ($this.IsChecked) {
                        if ($t.Group -eq 'View' -and $t.Name -ne $changed) { & $snapNow $t.Name }
                        $null = $sets[$t.Group].Add($t.Name)
                    } else {
                        $null = $sets[$t.Group].Remove($t.Name)
                    }
                    # Two boxes that are the halves of one question take each
                    # other out of play rather than being quietly ignored.
                    foreach ($pair in $pairs) {
                        $other = $null
                        if     ($t.Group -eq $pair.A.Group -and $t.Name -eq $pair.A.Name) { $other = $pair.B }
                        elseif ($t.Group -eq $pair.B.Group -and $t.Name -eq $pair.B.Name) { $other = $pair.A }
                        if (-not $other) { continue }
                        foreach ($b in $allBoxes) {
                            if ($b.Group -eq $other.Group -and $b.Name -eq $other.Name) {
                                $b.Box.IsEnabled = -not $this.IsChecked
                            }
                        }
                    }
                    & $onSel
                }.GetNewClosure()
                $cb.Add_Checked($flip); $cb.Add_Unchecked($flip)
                $null = $panel.Children.Add($cb)
                $boxes.Add([pscustomobject]@{ Group = $g; Name = $nm; Box = $cb })
            }
        }

        & $section 'SECTION' 'Sec' @($SEC_LABEL.Values) $null
        # A heading is not a group: five boxes under VIEW belong to three
        # groups, because boxes in a group are OR-ed and these have to AND.
        & $section 'VIEW' 'View' @($CHECKED, $UNCHECKED, $CHANGED,
                                   @{ Group = 'Tier';  Name = $OPT_IN_ONLY },
                                   @{ Group = 'Avail'; Name = $HIDE_OPT_IN },
                                   @{ Group = 'Avail'; Name = $HIDE_ABSENT },
                                   @{ Group = 'Avail'; Name = $HIDE_APPLIED }) $null
        & $section 'RISK' 'Risk' @('No risk', 'Caution', 'Risky') $null
        # The rated bands only. "Not a removal - unrated" and "Your apps" are
        # exceptions to rating rather than degrees of it.
        & $section 'BLOAT RATING' 'Bloat' @($BLOAT_RATED | ForEach-Object { [string]$_.N }) $null
        & $section 'CATEGORY' 'Cat' $catNames $null

        # There was a SIZE box here - a signed number, negative for "frees at
        # least". It went with the rest of the storage forensics; "show me the
        # big ones" is a sort.
    }
    # The category boxes are one per heading, so this waits for the headings.
    $advWork.Add({
        if ($advSay.Fn) { & $advSay.Fn 'Building the filter' }
        & $buildFilterPanel
    }.GetNewClosure())

    $clearFilters = {
        foreach ($b in $filterBoxes) { $b.Box.IsChecked = $false }
        foreach ($g in $FILTER_GROUPS) { $filterSel[$g].Clear() }
        & $applyFilter
    }.GetNewClosure()

    # Whatever was just done shows now; the expensive consequence catches up.
    $newDebounce = {
        param([int]$Ms, [scriptblock]$Work)
        # The harness sets the text and asserts in the next statement, so a
        # timer that has not ticked would fail checks that are not about the
        # delay.
        if ($state.NoPrompts) { return $Work }
        $box = @{ Timer = (New-Object Windows.Threading.DispatcherTimer); Work = $Work }
        $box.Timer.Interval = [TimeSpan]::FromMilliseconds($Ms)
        $box.Timer.Add_Tick({ $box.Timer.Stop(); & $box.Work }.GetNewClosure())
        # Restart, not start: every keystroke pushes the deadline out, so the
        # pass runs once at the end.
        { $box.Timer.Stop(); $box.Timer.Start() }.GetNewClosure()
    }

    # Bound as closures: a bare scriptblock loses sight of this function's
    # locals once the event fires from the dispatcher.
    $ui.TxtFilter.Add_TextChanged((& $newDebounce 180 $applyFilter))

    # No brushes on this control, and that is the fix rather than an omission: a
    # ComboBox draws its closed bar from SelectionBoxItem in its own foreground
    # and its popup on the system window brush.
    foreach ($k in $GROUPS.Keys) {
        $it = New-Object Windows.Controls.ComboBoxItem
        $it.Content = $GROUPS[$k]; $it.Tag = $k
        $null = $ui.CmbOrder.Items.Add($it)
        if ($k -eq [string]$state.Group) { $ui.CmbOrder.SelectedItem = $it }
    }
    if (-not $ui.CmbOrder.SelectedItem) { $ui.CmbOrder.SelectedIndex = 0 }
    $ui.CmbOrder.Add_SelectionChanged({
        $sel = $ui.CmbOrder.SelectedItem
        if (-not $sel) { return }
        $want = [string]$sel.Tag
        if ($want -eq [string]$state.Group) { return }
        $state.Group = $want
        & $applyOrder
    }.GetNewClosure())

    foreach ($k in $SORTS.Keys) {
        $it = New-Object Windows.Controls.ComboBoxItem
        $it.Content = $SORTS[$k]; $it.Tag = $k
        $null = $ui.CmbSort.Items.Add($it)
        if ($k -eq [string]$state.Sort) { $ui.CmbSort.SelectedItem = $it }
    }
    if (-not $ui.CmbSort.SelectedItem) { $ui.CmbSort.SelectedIndex = 0 }
    $ui.CmbSort.Add_SelectionChanged({
        $sel = $ui.CmbSort.SelectedItem
        if (-not $sel) { return }
        $want = [string]$sel.Tag
        if ($want -eq [string]$state.Sort) { return }
        $state.Sort = $want
        & $applyOrder
    }.GetNewClosure())

    $ui.BtnFilterClear.Add_Click($clearFilters.GetNewClosure())
    $ui.BtnFilterDone.Add_Click({ $ui.BtnFilter.IsChecked = $false }.GetNewClosure())

    # The two halves of Save, as seams the self test can drive: a MessageBox
    # would block the harness.
    $tickedIds = { @($rows | Where-Object { $_.Check.IsChecked } | ForEach-Object { $_.Id }) }
    $saveToFile = {
        $dlg = New-Object Windows.Forms.SaveFileDialog
        $dlg.Filter = 'Windows Setup Toolkit profile (*.json)|*.json'
        $dlg.FileName = "$($state.Preset).json"
        try {
            $seed = Join-Path (Split-Path -Parent $ModulePath) 'profile_saves'
            if (Test-Path -LiteralPath $seed) { $dlg.InitialDirectory = $seed }
        } catch { }
        if ($dlg.ShowDialog() -ne 'OK') { return }
        & $editActions.SaveOut ([string]$state.Preset) ([string]$dlg.FileName) (& $tickedIds)
    }
    $saveAsDefault = {
        # Whatever is ticked becomes this preset, so the pending edit has to be
        # recorded before it can be promoted.
        if (& $unsavedEdits) {
            $d = & $currentDiff
            & $setOverride $state.Preset @($d.Added) @($d.Removed)
        }
        $did = & $promoteOverride $state.Preset
        & $applyPresetToChecks $state.Preset
        $did
    }
    # Three buttons whose labels are the answers. YesNoCancel was the obvious
    # fit and the answers here are not yes and no.
    $askThree = {
        param([string]$Title, [string]$Message, $Options)
        $dlg = New-Object Windows.Window
        $dlg.Title = $Title
        $dlg.SizeToContent = 'WidthAndHeight'
        $dlg.ResizeMode = 'NoResize'
        $dlg.WindowStartupLocation = 'CenterOwner'
        $dlg.ShowInTaskbar = $false
        $dlg.Owner = $win
        # Called rather than captured: these builders are closures, and a
        # closure resolves a variable against the scope it was written in.
        $dlgIcon = Get-WDAppIcon
        if ($dlgIcon) { $dlg.Icon = $dlgIcon }
        # A separate Window is a separate resource scope: a DynamicResource
        # walks up to its own window and stops.
        if (-not $dlg.Resources.MergedDictionaries.Contains($themeDict)) {
            $dlg.Resources.MergedDictionaries.Add($themeDict)
        }
        & $Ref $dlg 'Background' 'Panel'
        $sp = New-Object Windows.Controls.StackPanel
        $sp.Margin = '22,18,22,16'; $sp.MaxWidth = 460
        $t = New-Object Windows.Controls.TextBlock
        $t.Text = $Message; $t.FontSize = 13.5; $t.TextWrapping = 'Wrap'; $t.Margin = '0,0,0,14'
        & $Ref $t 'Foreground' 'Text'
        $null = $sp.Children.Add($t)

        foreach ($o in @($Options)) {
            if (-not [string]$o.D) { continue }
            $line = New-Object Windows.Controls.TextBlock
            $line.FontSize = 12.5; $line.TextWrapping = 'Wrap'; $line.Margin = '0,0,0,6'
            $head = New-Object Windows.Documents.Run ([string]$o.L + '  ')
            $head.FontWeight = 'SemiBold'
            & $Ref $head 'Foreground' 'Text'
            $null = $line.Inlines.Add($head)
            $rest = New-Object Windows.Documents.Run ([string]$o.D)
            & $Ref $rest 'Foreground' 'Sub'
            $null = $line.Inlines.Add($rest)
            $null = $sp.Children.Add($line)
        }

        $row = New-Object Windows.Controls.StackPanel
        $row.Orientation = 'Horizontal'; $row.HorizontalAlignment = 'Right'; $row.Margin = '0,12,0,0'
        $picked = @{ V = '' }
        foreach ($o in @($Options)) {
            $b = New-Object Windows.Controls.Button
            $b.Content = [string]$o.L; $b.Padding = '18,6'; $b.Margin = '8,0,0,0'; $b.MinWidth = 92
            $b.Tag = @{ Label = [string]$o.L; Picked = $picked; Dialog = $dlg }
            $b.Add_Click({
                $d = $this.Tag
                $d.Picked.V = [string]$d.Label
                $d.Dialog.DialogResult = $true
            }.GetNewClosure())
            $null = $row.Children.Add($b)
        }
        $null = $sp.Children.Add($row)
        $dlg.Content = $sp
        $null = $dlg.ShowDialog()
        [string]$picked.V
    }.GetNewClosure()

    $ui.BtnSave.Add_Click({
        if ($state.NoPrompts) { return }
        # Both screens ask this through one function. A file-backed preset gets
        # "the same file" or "another one": Default is meaningless for it.
        if ($loadedPresets.Contains([string]$state.Preset)) {
            # Same file overwrites through $effectiveIds, so the pending
            # tick-box edit has to be recorded before it can be read back.
            if (& $unsavedEdits) {
                $d = & $currentDiff
                & $setOverride $state.Preset @($d.Added) @($d.Removed)
            }
            if ($editActions.SaveLoaded) {
                & $editActions.SaveLoaded ([string]$state.Preset) (& $tickedIds)
            }
            return
        }
        $ans = & $askThree 'Save' "Keep the $($rows.Count) tick boxes as they are now. Which way?" @(
            @{ L = 'Default'; D = "makes this the new $($state.Preset) on this machine, so it opens this way from now on. Undone by Restore factory defaults at the bottom of the page." }
            @{ L = 'File';    D = 'writes the selection to a .json you can carry to another machine and run with -ProfilePath. Nothing on this machine changes.' }
            @{ L = 'Cancel';  D = '' }
        )
        switch ($ans) {
            'Default' {
                if (& $saveAsDefault) {
                    Show-WDMessage ("$($state.Preset) now opens with this selection.", 'Saved', 'OK', 'None') | Out-Null
                } else {
                    Show-WDMessage ("$($state.Preset) already matches this selection - nothing to change.", 'Saved', 'OK', 'None') | Out-Null
                }
            }
            'File' { & $saveToFile }
        }
    }.GetNewClosure())

    # Save, from the mode screen.
    $savedNote = {
        param([string]$Name, [string]$Path, [int]$Count, [string]$Extra)
        if ($state.NoPrompts) { return }
        $msg = "$Name saved - $Count option(s) written to`n`n$Path"
        if ($Extra) { $msg = "$msg`n`n$Extra" }
        Show-WDMessage ($msg, 'Saved', 'OK', 'None') | Out-Null
    }
    # Overwrite the file this preset came from. The edit is consumed: the file
    # now holds what the preset holds.
    $saveLoadedTo = {
        param([string]$Name, [string]$Path)
        $sel = @(& $effectiveIds $Name)
        $res = $null
        try { $res = Save-WDSelection -Selected $sel -Path $Path } catch { $res = $null }
        if (-not $res) {
            Show-WDMessage ("Nothing was written to`n`n$Path", 'Save failed', 'OK', 'Error') | Out-Null
            return
        }
        # Without this the row goes on reading "changed from preset" against a
        # preset the file no longer matches.
        $loadedPresets[$Name].Path  = [string]$Path
        $loadedPresets[$Name].Ids   = $sel
        $loadedPresets[$Name].Total = @($sel).Count
        # Nothing was dropped on the way in this time - the selection came from
        # this session.
        $loadedPresets[$Name].Dropped = @()
        $baseIds[$Name] = $sel
        foreach ($h in @($presetDefaults, $overrides)) { if ($h.ContainsKey($Name)) { $h.Remove($Name) } }
        & $loadedRefresh
        & $selectPreset $Name
        & $savedNote $Name $Path @($sel).Count
    }
    # Writing a new file is three things in one gesture: write it, load it as a
    # preset of its own, select it, and reset the preset it came from.
    # Order matters twice: registering proves there is somewhere for the edit to
    # go, and the reset runs before the select because it re-ticks the boxes.
    $saveOutAndLoad = {
        param([string]$Name, [string]$Path, $Selected)
        $sel = $(if ($null -ne $Selected) { @($Selected) } else { @(& $effectiveIds $Name) })
        $res = $null
        try { $res = Save-WDSelection -Selected $sel -Path $Path } catch { $res = $null }
        if (-not $res) {
            Show-WDMessage ("Nothing was written to`n`n$Path", 'Save failed', 'OK', 'Error') | Out-Null
            return
        }
        # Writing over a file some other preset was loaded from: that preset now
        # names a file holding something else.
        foreach ($k in @($loadedPresets.Keys)) {
            if ([string]$k -eq [string]$Name) { continue }
            if ([string]$loadedPresets[$k].Path -eq [string]$Path) { & $dropLoaded ([string]$k) }
        }
        $new = [string](& $registerLoaded $Path)
        if (-not $new) {
            Show-WDMessage ("$Path was written but could not be read back as a selection.",
                                       'Save failed', 'OK', 'Error') | Out-Null
            return
        }
        # The edit has a home now, so it stops being an edit of the mode it was
        # made on. Only the override goes.
        & $resetOnePreset $Name
        & $loadedRefresh
        & $selectPreset $new
        # And the tick boxes, which $selectPreset does not touch - it paints the
        # mode screen.
        & $applyPresetToChecks $new
        & $savedNote $new $Path @($sel).Count `
            "$Name was reverted to its default state, $new is loaded and selected."
        $new
    }
    $editActions.SaveOut = $saveOutAndLoad
    # A holder entry rather than a name, because the Advanced page's Save is
    # wired two thousand lines above this and a closure captures its scope as it
    # stands.
    $editActions.SaveLoaded = {
        param([string]$Name, $Selected)
        $name = [string]$Name
        if (-not $name -or -not $loadedPresets.Contains($name)) { return }
        $here = [string]$loadedPresets[$name].Path
        $leaf = [IO.Path]::GetFileName($here)
        $ans = & $askThree 'Save' "Keep the changes to $name. Which file?" @(
            @{ L = 'Same file'; D = "overwrites $leaf, where this selection came from." }
            @{ L = 'New file';  D = "writes it to another file, loads that as a preset of its own, and puts $name back to what $leaf holds." }
            @{ L = 'Cancel';    D = '' }
        )
        switch ($ans) {
            'Same file' { & $saveLoadedTo $name $here }
            'New file' {
                $dlg = New-Object Windows.Forms.SaveFileDialog
                $dlg.Filter = 'Windows Setup Toolkit profile (*.json)|*.json'
                $dlg.FileName = $leaf
                try {
                    $seed = Split-Path -Parent $here
                    if ($seed -and (Test-Path -LiteralPath $seed)) { $dlg.InitialDirectory = $seed }
                } catch { }
                if ($dlg.ShowDialog() -ne 'OK') { return }
                # Picking the file it already came from is the other answer,
                # however it was arrived at.
                if ([string]$dlg.FileName -eq $here) { & $saveLoadedTo $name $here }
                else { & $saveOutAndLoad $name ([string]$dlg.FileName) $Selected }
            }
        }
    }
    # Named, not "whatever is selected": each card's Save speaks for its own
    # card.
    $editActions.Save = {
        param([string]$Name, $Selected)
        if ($state.NoPrompts) { return }
        $name = [string]$Name
        if (-not $name) { return }

        # A preset from a file gets "the same file" and "another one" rather
        # than "default" and "file".
        if ($loadedPresets.Contains($name)) {
            & $editActions.SaveLoaded $name $Selected
            return
        }

        # A shipped mode. Default redefines it on this machine; File moves the
        # edit out into a file of its own.
        $ans = & $askThree 'Save' "Keep the changes to $name. Which way?" @(
            @{ L = 'Default'; D = "makes this the new $name on this machine, so it opens this way from now on. Undone by Restore factory defaults on the Advanced page." }
            @{ L = 'File';    D = "writes the selection to a .json, loads it as a preset of its own and selects it, and puts $name back to what it was. The file can be carried to another machine or run with -ProfilePath." }
            @{ L = 'Cancel';  D = '' }
        )
        switch ($ans) {
            'Default' {
                $did = & $promoteOverride $name
                & $recount
                & $repaintModeGrid
                & $saveUiState
                Show-WDMessage (
                    $(if ($did) { "$name now opens with this selection." }
                      else       { "$name already matches this selection - nothing to change." }),
                    'Saved', 'OK', 'None') | Out-Null
            }
            'File' {
                $dlg = New-Object Windows.Forms.SaveFileDialog
                $dlg.Filter = 'Windows Setup Toolkit profile (*.json)|*.json'
                $dlg.FileName = "$name.json"
                try {
                    $seed = Join-Path (Split-Path -Parent $ModulePath) 'profile_saves'
                    if (Test-Path -LiteralPath $seed) { $dlg.InitialDirectory = $seed }
                } catch { }
                if ($dlg.ShowDialog() -ne 'OK') { return }
                & $saveOutAndLoad $name ([string]$dlg.FileName) $Selected
            }
        }
    }.GetNewClosure()

    $ui.BtnFactory.Add_Click({
        if ($state.NoPrompts) { return }
        $n = $presetDefaults.Count
        $msg = if ($n) { "Put all $n redefined mode(s) back to what this toolkit ships with, and drop every unsaved edit?" }
               else    { 'No mode has been redefined. This will still drop every unsaved edit. Continue?' }
        if ((Show-WDMessage ($msg, 'Restore factory defaults', 'YesNo', 'Warning')) -ne 'Yes') { return }
        & $restoreFactory
        & $applyPresetToChecks $state.Preset
        # A destructive action that appears to do nothing is indistinguishable
        # from one that failed.
        Show-WDMessage (
            $(if ($n) { "$n mode(s) put back to what this toolkit ships with, and every unsaved edit dropped." }
              else    { 'Every unsaved edit dropped. No mode had been redefined.' }),
            'Restore factory defaults', 'OK', 'None') | Out-Null
    }.GetNewClosure())

    # One action taken now, not a step in a run, which is why it is a button
    # rather than the manifest row it used to be: a permanent deletion behind a
    # tick that survives a preview is the wrong shape.
    $clearLogs = {
        $ctx = [pscustomobject]@{ Preview = $true; ItemId = 'clear-logs'; Session = $Session; DefaultHive = $null }
        $look = Invoke-WDScriptAction -Action ([pscustomobject]@{ handler = 'ClearRunLogs' }) -Context $ctx
        if ($look.Status -ne 'Removed') {
            Show-WDMessage ($look.Message, 'Delete old run logs', 'OK', 'None') | Out-Null
            return $false
        }
        $ask = "$($look.Message).`n`n" +
               "Each run folder holds that run's rollback script and journal, so anything those runs " +
               "changed can no longer be undone from this tool afterwards. The run in progress is kept.`n`n" +
               'Delete them?'
        if ((Show-WDMessage ($ask, 'Delete old run logs', 'YesNo', 'Warning')) -ne 'Yes') { return $false }
        $ctx.Preview = $false
        $done = Invoke-WDScriptAction -Action ([pscustomobject]@{ handler = 'ClearRunLogs' }) -Context $ctx
        Show-WDMessage ($done.Message, 'Delete old run logs',
                                   'OK', $(if ($done.Status -in @('Removed', 'NotPresent')) { 'None' } else { 'Warning' })) | Out-Null
        $true
    }
    $ui.BtnClearLogs.Add_Click({
        if ($state.NoPrompts) { return }
        $null = & $clearLogs
    }.GetNewClosure())

    # The theme switch is a repaint, not a rebuild: everything carrying a colour
    # points at a theme key.
    $ui.ChkDetailPopup.IsChecked = [bool]$state.DetailPopup
    $ui.ChkDetailPopup.Add_Click({
        $state.DetailPopup = [bool]$ui.ChkDetailPopup.IsChecked
        & $saveUiState
    }.GetNewClosure())

    # Through the holder, because the pass it runs cannot be written until every
    # page's elements exist.
    $ui.ChkTerse.IsChecked = (-not [bool]$state.Terse)
    $ui.ChkTerse.Add_Click({
        $state.Terse = (-not [bool]$ui.ChkTerse.IsChecked)
        & $saveUiState
        if ($terseRef.Do) { & $terseRef.Do }
    }.GetNewClosure())

    $ui.BtnTheme.Add_Click({
        $state.Theme = $(if ($state.Theme -eq 'dark') { 'light' } else { 'dark' })
        & $saveUiState

        $pal = Get-WDPalette -Theme $state.Theme
        & $paintTheme $pal
        # The dialogs read the same dictionary, so their brushes follow on their
        # own; what they cannot work out is the title bar.
        Set-WDDialogHost -Dark ([bool]$pal.Dark)
        $ui.BtnTheme.Content = $(if ($pal.Dark) { 'Switch to light theme' } else { 'Switch to dark theme' })
        # The icon follows the palette, so it is rebuilt and reassigned here.
        # Cached per theme, so switching back is free.
        try {
            $newIcon = Get-WDAppIcon -Theme $state.Theme
            if ($newIcon) { $win.Icon = $newIcon }
        } catch {
            Write-WDLog "Could not re-theme the window icon: $($_.Exception.Message)" -Level Warn
        }
        $win.Tag.Mica = [bool](Set-WDWindowBackdrop -Window $win -Dark ([bool]$pal.Dark))
        if ($win.Tag.Mica) {
            $win.Background     = [Windows.Media.Brushes]::Transparent
            $ui.Root.Background = [Windows.Media.Brushes]::Transparent
        } else {
            & $Ref $ui.Root 'Background' 'Bg'
        }
        if ($win.Tag.Busy) { & $win.Tag.Busy.Retheme $pal }
    }.GetNewClosure())

    # Two doors into the item list, so what opening it means lives in one place.
    $openAdvanced = {
        # The first click is what builds the page. Everything after is the cheap
        # half.
        if ($advRef.Ensure) { & $advRef.Ensure }
        & $applyPresetToChecks $state.Preset
        & $showPage 'PageAdvanced'
        # Everything above ran against a page with no layout, so the rail's
        # offsets describe a page that was never arranged.
        if ($indexRef.Invalidate) { & $indexRef.Invalidate }
        if ($indexRef.Spy) { & $indexRef.Spy }
    }.GetNewClosure()
    # Filled, not wired: there is no $ui.BtnAdvanced to hang a handler on - the
    # button is one of three on whichever mode card is selected.
    $advRef.Open = $openAdvanced
    $ui.BtnBackModes.Add_Click({
        # Edits are kept, no questions asked. What is stored is the whole
        # divergence from the shipped preset.
        if (& $unsavedEdits) {
            $d = & $currentDiff
            & $setOverride $state.Preset @($d.Added) @($d.Removed)
        }
        # Whichever preset was being edited becomes the one selected on the mode
        # screen, so the two views never disagree.
        & $selectPreset $state.Preset
        & $showPage 'PageModes'
    }.GetNewClosure())

    # One mode, the one whose card the button stands on. Resetting every mode at
    # once was a footgun dressed as a convenience.
    $editActions.Reset = {
        param([string]$Name)
        if (-not $overrides.ContainsKey($Name)) { return }
        if ($state.NoPrompts) { & $resetOnePreset $Name; return }
        if ((Show-WDMessage (
                "Restore $Name to default? Any unsaved changes will be lost!",
                "Reset $Name", 'YesNo', 'Warning')) -ne 'Yes') { return }
        & $resetOnePreset $Name
    }.GetNewClosure()

    # The Compare page: two presets side by side, with every difference handed
    # across.
    $cmpButtons = @{ A = @{}; B = @{} }
    # The two picker blocks, built once and placed into the comparison grid by
    # $buildCompare.
    $cmpHead    = @{ A = $null; B = $null }
    $itemName = @{}
    $itemDesc = @{}
    $itemRisk = @{}
    $itemNote = @{}
    # The manifest object itself, for anything needing more than a field of it.
    $itemById = @{}
    # Both here rather than worked out at build time, because this page rebuilds
    # on every keystroke in the search box.
    $itemBand   = @{}
    $itemSearch = @{}
    foreach ($cat in $Categories) {
        foreach ($item in @(Get-Prop $cat 'items' @())) {
            $id = [string]$item.id
            $itemName[$id] = [string](Get-Prop $item 'name' $id)
            $itemDesc[$id] = [string](Get-Prop $item 'desc' '')
            $itemRisk[$id] = [int](Get-Prop $item 'risk' 0)
            $itemNote[$id] = [string](Get-Prop $item 'riskNote' '')
            $itemById[$id] = $item
            # $bandOf reads a row and this page has manifest items, so it gets
            # the three fields it actually looks at.
            $itemBand[$id] = [string](& $bandOf ([pscustomobject]@{
                Bloat   = [int](Get-Prop $item 'bloat' 0)
                CatId   = [string]$cat.id
                Section = [string](Get-WDItemSection -Item $item -Category $cat)
            }))
            $itemSearch[$id] = ("$($itemName[$id]) $($itemDesc[$id]) $($cat.name)").ToLower()
        }
    }

    # The gutter the pinned header must leave for the scrollbar below it, plus
    # the page's own right inset. Without both, a scrollbar appearing moves the
    # cards out from under their heading.
    $CMP_EDGE   = 20
    $CMP_GUTTER = [double]$script:WDVBarWidth + $CMP_EDGE

    # Narrowing and arranging, the same three controls as Advanced.
    $CMP_GROUPS = [ordered]@{
        'category' = 'Category'
        'bloat'    = 'Bloat rating'
        'risk'     = 'Risk'
    }
    $cmpGroup  = @{ Mode = 'category' }
    $cmpSel    = @{
        Risk  = New-Object System.Collections.Generic.HashSet[string]
        Bloat = New-Object System.Collections.Generic.HashSet[string]
        Cat   = New-Object System.Collections.Generic.HashSet[string]
    }
    $CMP_FACETS  = @('Risk', 'Bloat', 'Cat')
    $cmpBoxes    = New-Object System.Collections.Generic.List[psobject]
    $cmpPicked   = {
        $n = 0
        foreach ($g in $CMP_FACETS) { $n += $cmpSel[$g].Count }
        $n
    }.GetNewClosure()
    # Whether an item is something anybody could take here, today. Nothing to do
    # with the filter: applied to both selections before anything is compared,
    # so the counts and the cards agree.
    $cmpLive = {
        param([string]$Id)
        # Every target this item names was looked for and none of them is here.
        if ($Presence -and $Presence.ContainsKey($Id) -and $false -eq $Presence[$Id].Present) { return $false }
        # A row whose whole meaning depends on a live condition.
        if ($rowGate.ContainsKey($Id) -and -not [bool](& $rowGate[$Id])) { return $false }
        $item = $itemById[$Id]
        if ($item) {
            # Already installed, or already set: ticking it queues work that
            # reports nothing to do.
            if ([string](& $alreadyDone $item ([int](Get-WDItemTier -Item $item)))) { return $false }
        }
        $true
    }.GetNewClosure()

    # The other half, per pair rather than per item: two options writing the
    # same policy cannot both be selected, so the card stays and the button is
    # disabled with the reason.
    $cmpExcluded = {
        param([string]$Id, [string]$Target)
        foreach ($x in $EXCLUSIONS) {
            if ([string]$x.Blocks -ne $Id) { continue }
            if (@(& $effectiveIds $Target) -contains [string]$x.When) { return [string]$x.Why }
        }
        ''
    }.GetNewClosure()

    # Within a facet OR, across facets AND - the same rule the Advanced filter
    # follows.
    $cmpKeep = {
        param([string]$Id)
        if ($cmpSel.Risk.Count  -and -not $cmpSel.Risk.Contains([string]$riskLabel[[int]$itemRisk[$Id]])) { return $false }
        if ($cmpSel.Bloat.Count -and -not $cmpSel.Bloat.Contains([string]$bandName[[string]$itemBand[$Id]])) { return $false }
        if ($cmpSel.Cat.Count) {
            $c = [string]$(if ($itemCat.ContainsKey($Id)) { $itemCat[$Id] } else { 'Other' })
            if (-not $cmpSel.Cat.Contains($c)) { return $false }
        }
        $q = [string]$ui.TxtCmpSearch.Text
        if ($q) {
            $q = $q.Trim().ToLower()
            if ($q -and -not ([string]$itemSearch[$Id]).Contains($q)) { return $false }
        }
        $true
    }.GetNewClosure()

    # $buildCompare is a closure and the button it builds has to call back into
    # it.
    $cmpRefs = @{ Build = $null }
    # Every hand-over button on the page, so the self test can click one without
    # digging through nested panels.
    $cmpAddButtons = New-Object System.Collections.Generic.List[psobject]
    # Repaint rather than rebuild. Cards are kept between rebuilds, keyed by the
    # three things that decide what one looks like: item, side, and target mode.
    $cmpCards = @{}
    # The cards outlive a rebuild, so this is added to rather than rebuilt.
    $cmpDescEls = New-Object System.Collections.Generic.List[psobject]
    # The Details chip on each card, handed out rather than found by walking the
    # card.
    $cmpChips = New-Object System.Collections.Generic.List[psobject]

    # The rail's scroll spy.
    $cmpSpyRows = New-Object System.Collections.Generic.List[psobject]
    $spyCompare = {
        if ($cmpSpy.Busy) { return }
        $cmpSpy.Busy = $true
        try {
            if (-not $cmpSpyRows.Count) { return }
            # Measured once into a table and reused: transforming two dozen
            # headings on every scroll tick is how this ships janky.
            if (-not $cmpSpy.Offsets) {
                $ui.CompareGrid.UpdateLayout()
                $tbl = @{}
                foreach ($e in $cmpSpyRows) {
                    try {
                        if (-not $e.Head) { continue }
                        $tbl[[string]$e.Key] = $e.Head.TransformToAncestor($ui.CompareGrid).Transform(
                            (New-Object Windows.Point 0, 0)).Y
                    } catch { }
                }
                if (-not $tbl.Count) { return }
                $cmpSpy.Offsets = $tbl
            }
            # The last heading at or above the top of the viewport, plus slack
            # so one just under the edge counts.
            $y = [double]$ui.CmpScroll.VerticalOffset + 24
            $best = $null; $bestY = [double]::NegativeInfinity
            foreach ($e in $cmpSpyRows) {
                if (-not $cmpSpy.Offsets.ContainsKey([string]$e.Key)) { continue }
                $oy = [double]$cmpSpy.Offsets[[string]$e.Key]
                if ($oy -le $y -and $oy -gt $bestY) { $best = $e; $bestY = $oy }
            }
            if (-not $best) { $best = $cmpSpyRows[0] }
            if ($best -and [string]$cmpSpy.Active -ne [string]$best.Key) {
                foreach ($e in $cmpSpyRows) {
                    $on = ([string]$e.Key -eq [string]$best.Key)
                    $e.Card.Tag.On = $on
                    & $Ref $e.Card 'Background' $(if ($on) { 'CardSel' } else { 'Flat' })
                    $e.Label.FontWeight = $(if ($on) { 'SemiBold' } else { 'Normal' })
                }
                $cmpSpy.Active = [string]$best.Key
            }
        } catch { } finally { $cmpSpy.Busy = $false }
    }.GetNewClosure()
    $cmpSpyRef.Fn = $spyCompare
    $ui.CmpScroll.Add_ScrollChanged({ & $spyCompare }.GetNewClosure())
    # Hand-overs made during this visit, emptied on the way in - a stack that
    # outlived the page would offer to reverse changes nobody can see.
    $cmpDone = New-Object System.Collections.Generic.List[psobject]
    $CHECK = New-WDGlyph 0x2713

    # An edit to the receiving preset, stored exactly as one made in Advanced.
    $compareEdit = {
        param([string]$Id, [string]$Target, [bool]$Undo)
        $cur     = $overrides[$Target]
        $added   = New-WDStringSet $(if ($cur) { @($cur.Added) }   else { @() })
        $removed = New-WDStringSet $(if ($cur) { @($cur.Removed) } else { @() })
        # Against the preset as defined, not as shipped: an override records the
        # distance from what this person calls Balanced.
        $inBase  = (New-WDStringSet (& $defaultIds $Target)).Contains($Id)

        if ($Undo) {
            if ($added.Contains($Id)) { $null = $added.Remove($Id) }
            elseif ($inBase)          { $null = $removed.Add($Id) }
        } else {
            # Two reasons a preset can be missing an item: it never shipped with
            # it, or the user took it out. Always appending to Added leaves both
            # halves naming the same id, and Removed is applied first.
            if ($removed.Contains($Id)) { $null = $removed.Remove($Id) }
            else                        { $null = $added.Add($Id) }
        }
        & $setOverride $Target @($added) @($removed)
    # A closure, because the card buttons fire it from a scope that knows
    # nothing of this function.
    }.GetNewClosure()

    # Note text is set after the rebuild, because the rebuild is what clears it.
    $cmpSayNote = {
        param([string]$Text, $Color)
        $ui.TxtCompareNote.Text = $Text
        & $Ref $ui.TxtCompareNote 'Foreground' $Color
    }.GetNewClosure()

    $compareAdd = {
        param([string]$Id, [string]$Target, [string]$From)
        & $compareEdit $Id $Target $false
        $cmpDone.Add(@{ Id = $Id; From = $From; Target = $Target })
        & $cmpRefs.Build
        $nm = [string]$(if ($itemName.ContainsKey($Id)) { $itemName[$Id] } else { $Id })
        & $cmpSayNote "Added $nm to $Target." 'Ok'
    }.GetNewClosure()

    # By name rather than by position: the button on the card undoes its own
    # hand-over.
    $compareRemove = {
        param([string]$Id, [string]$Target)
        for ($i = $cmpDone.Count - 1; $i -ge 0; $i--) {
            if ($cmpDone[$i].Id -eq $Id -and $cmpDone[$i].Target -eq $Target) { $cmpDone.RemoveAt($i); break }
        }
        & $compareEdit $Id $Target $true
        & $cmpRefs.Build
        $nm = [string]$(if ($itemName.ContainsKey($Id)) { $itemName[$Id] } else { $Id })
        & $cmpSayNote "Took $nm back out of $Target." 'Muted'
    }.GetNewClosure()

    $compareUndo = {
        if (-not $cmpDone.Count) { return }
        $e = $cmpDone[$cmpDone.Count - 1]
        & $compareRemove $e.Id $e.Target
    }.GetNewClosure()

    # What a hand-over button looks like in each direction, in one place,
    # because two things get it there by different routes.
    $paintCmpButton = {
        param($Btn, [bool]$Done)
        $t = $Btn.Tag
        $t.Done = $Done
        if ($Done) {
            # Green because the item is in, and still a button because the next
            # likely thing is changing your mind about this one.
            $Btn.Content = "$CHECK In $($t.Short) - remove"
            & $Ref $Btn 'BorderBrush' 'Ok'
            $Btn.BorderThickness = New-Object Windows.Thickness 1
            $Btn.ClearValue([Windows.Controls.Control]::FontWeightProperty)
            $Btn.ToolTip = "Added to $($t.Target) during this visit. Takes it back out again."
        } else {
            $Btn.Content = "Add to $($t.Short)"
            $Btn.ToolTip = "Adds this to $($t.Target) as an edit of your own. It stays out of every other mode, and Reset puts $($t.Target) back."
            & $paintPresetButton $Btn ([string]$t.Target) $false
        }
    }.GetNewClosure()

    # Render priority rather than Background: it flushes layout and drawing and
    # stops, so nothing at Input priority runs and a second click cannot
    # re-enter the handler.
    $showNowFast = {
        param($El)
        try { $El.Dispatcher.Invoke([action]{}, [Windows.Threading.DispatcherPriority]::Render) } catch { }
    }
    $ui.BtnCompareUndo.Add_Click({ & $compareUndo }.GetNewClosure())

    $buildCompare = {
        # Copied into this scope on purpose: $makeCard runs a scope down and
        # builds handlers of its own.
        $chipFn    = $makeDetailChip
        $itemsById = $itemById
        $cardCache = $cmpCards
        # One entry per heading in page order, filled by whichever layout branch
        # runs.
        $railList  = New-Object System.Collections.Generic.List[psobject]
        $g = $ui.CompareGrid
        $g.Children.Clear(); $g.RowDefinitions.Clear(); $g.ColumnDefinitions.Clear()
        # Any rebuild - a side switch as much as an edit - moves the page past
        # whatever the note was describing.
        $cmpAddButtons.Clear()
        $ui.TxtCompareNote.Text = ''
        $ui.BtnCompareUndo.Content    = $(if ($cmpDone.Count -gt 1) { "Undo ($($cmpDone.Count))" } else { 'Undo' })
        $ui.BtnCompareUndo.Visibility = $(if ($cmpDone.Count) { 'Visible' } else { 'Collapsed' })
        # The pinned header, laid out exactly like the grid under it or a
        # heading stands over the wrong column.
        $head = $ui.CompareHead
        $head.Children.Clear(); $head.RowDefinitions.Clear(); $head.ColumnDefinitions.Clear()
        $head.Margin = New-Object Windows.Thickness -ArgumentList 0, 0, $CMP_GUTTER, 0
        # Three real columns: left half, the rule, right half. Everything below
        # speaks in logical columns 0 and 1 with a span of 2, and $place
        # translates.
        $threeCols = {
            param($Grid)
            foreach ($w in @(1, 0, 1)) {
                $cd = New-Object Windows.Controls.ColumnDefinition
                if ($w) { $cd.Width = New-WDGridLength -Value 1 -Unit 'Star' }
                else    { $cd.Width = New-WDGridLength -Value 0 -Unit 'Auto' }
                $null = $Grid.ColumnDefinitions.Add($cd)
            }
        }
        & $threeCols $g
        & $threeCols $head
        $addRow = {
            $rd = New-Object Windows.Controls.RowDefinition
            $rd.Height = New-WDGridLength -Value 0 -Unit 'Auto'
            $null = $g.RowDefinitions.Add($rd)
            $g.RowDefinitions.Count - 1
        }
        $place = {
            param($El, [int]$Row, [int]$Col, [int]$Span)
            [Windows.Controls.Grid]::SetRow($El, $Row)
            [Windows.Controls.Grid]::SetColumn($El, $(if ($Col -ge 1) { 2 } else { 0 }))
            if ($Span -gt 1) { [Windows.Controls.Grid]::SetColumnSpan($El, 3) }
            $null = $g.Children.Add($El)
        }

        $a = $cmpState.A; $b = $cmpState.B
        # Narrowed to what can actually be selected here before anything is
        # compared.
        $setA = New-WDStringSet @(@(& $effectiveIds $a) | Where-Object { & $cmpLive $_ })
        $setB = New-WDStringSet @(@(& $effectiveIds $b) | Where-Object { & $cmpLive $_ })
        $diffA = @($setA | Where-Object { -not $setB.Contains($_) })
        $diffB = @($setB | Where-Object { -not $setA.Contains($_) })

        # An item handed over stops being a difference, but its card stays put
        # with the button marked done.
        $doneA = New-WDStringSet @($cmpDone | Where-Object { $_.From -eq $a -and $_.Target -eq $b } | ForEach-Object { $_.Id })
        $doneB = New-WDStringSet @($cmpDone | Where-Object { $_.From -eq $b -and $_.Target -eq $a } | ForEach-Object { $_.Id })
        $allA = @($diffA) + @($doneA | Where-Object { $diffA -notcontains $_ })
        $allB = @($diffB) + @($doneB | Where-Object { $diffB -notcontains $_ })
        # What the filter and search leave, kept separate from the real
        # difference so the footer goes on quoting the modes.
        $onlyA = @($allA | Where-Object { & $cmpKeep $_ })
        $onlyB = @($allB | Where-Object { & $cmpKeep $_ })
        $narrowed = ((& $cmpPicked) -gt 0 -or [bool]([string]$ui.TxtCmpSearch.Text).Trim())
        $ui.BtnCmpFilter.Content = $(if ((& $cmpPicked)) { "Filter ($(& $cmpPicked))" } else { 'Filter' })
        $ui.TxtCmpCount.Text = $(if ($narrowed) {
                                     "$($onlyA.Count + $onlyB.Count) of $($allA.Count + $allB.Count) shown"
                                 } else { '' })

        foreach ($k in @('A','B')) {
            foreach ($n in $presetNames) {
                $btn = $cmpButtons[$k][$n]
                if (-not $btn) { continue }
                & $paintPresetButton $btn $n ($cmpState[$k] -eq $n)
            }
        }

        # Items a mode only removes because they were ticked in Advanced: a
        # difference you created yourself is worth flagging.
        $addedIn = @{}
        foreach ($n in @($a, $b)) {
            $addedIn[$n] = New-WDStringSet $(if ($overrides.ContainsKey($n)) { @($overrides[$n].Added) } else { @() })
        }

        # One function, so the two sides and the two layouts cannot file the
        # same item differently.
        $keyOf = {
            param([string]$Id)
            switch ([string]$cmpGroup.Mode) {
                'bloat' { [string]$bandName[[string]$itemBand[$Id]] }
                'risk'  { [string]$riskLabel[[int]$itemRisk[$Id]] }
                default {
                    $c = [string]$(if ($itemCat.ContainsKey($Id)) { $itemCat[$Id] } else { 'Other' })
                    if (-not $c) { 'Other' } else { $c }
                }
            }
        }
        $groupByCat = {
            param([string[]]$Ids)
            $byCat = @{}
            foreach ($id in $Ids) {
                $c = [string](& $keyOf $id)
                if (-not $c) { $c = 'Other' }
                if (-not $byCat.ContainsKey($c)) { $byCat[$c] = New-Object System.Collections.Generic.List[string] }
                $byCat[$c].Add([string]$id)
            }
            $byCat
        }
        $catA = & $groupByCat $onlyA
        $catB = & $groupByCat $onlyB
        # Every heading the two modes touch at all, and separately the ones they
        # actually differ under.
        $coveredKeys = @{}
        foreach ($id in @($setA)) { $coveredKeys[[string](& $keyOf $id)] = $true }
        foreach ($id in @($setB)) { $coveredKeys[[string](& $keyOf $id)] = $true }
        # Before the filter, deliberately: whether the modes agree is a fact
        # about the modes, whether anything is on screen is a fact about the
        # search box.
        $diffKeys = @{}
        foreach ($id in (@($allA) + @($allB))) { $diffKeys[[string](& $keyOf $id)] = $true }
        # Bands and risk levels have a meaningful order that is not
        # alphabetical.
        $keyOrder = @()
        switch ([string]$cmpGroup.Mode) {
            'bloat' { $keyOrder = @($BLOAT_BAND | ForEach-Object { [string]$_.N }) }
            'risk'  { $keyOrder = @('Risky', 'Caution', 'No risk') }
            default { $keyOrder = @($normalCats | ForEach-Object { [string]$_.name }) }
        }
        # Anything the order does not name still has to appear, or a grouping
        # with a gap in its table silently drops rows.
        $orderedKeys = {
            param($Keys)
            $seen = @($Keys)
            @($keyOrder | Where-Object { $seen -contains $_ }) +
            @($seen | Where-Object { $keyOrder -notcontains $_ } | Sort-Object)
        }

        $makeHeading = {
            param([string]$Cat, [int]$Count)
            $sp = New-Object Windows.Controls.StackPanel
            $sp.Orientation = 'Horizontal'; $sp.Margin = '0,12,0,4'
            # A glyph only where there is one to fetch: under the other
            # groupings the heading is a band or a risk level.
            $gid = [string]$(if ($catIdByName.ContainsKey($Cat)) { $catIdByName[$Cat] } else { '' })
            if ([string]$cmpGroup.Mode -eq 'category' -and $gid) {
                $gl = New-Object Windows.Controls.TextBlock
                $gl.Text = Get-WDCategoryGlyph -Id $gid
                $gl.FontFamily = New-Object Windows.Media.FontFamily 'Segoe UI Emoji'
                $gl.FontSize = 13; $gl.Margin = '0,0,7,0'
                & $Ref $gl 'Foreground' 'Text'
                $null = $sp.Children.Add($gl)
            }
            $tx = New-Object Windows.Controls.TextBlock
            $tx.Text = "$Cat  ($Count)"
            $tx.FontSize = 12; $tx.FontWeight = 'SemiBold'; $tx.VerticalAlignment = 'Center'
            & $Ref $tx 'Foreground' 'Muted'
            $null = $sp.Children.Add($tx)
            $sp
        }

        # An Advanced-style row: name over description, edged in the mode's
        # colour, with a green tag when the item is there because of an edit.
        $newCard = {
            param([string]$Id, [string]$Preset, [string]$Target)
            $card = New-Object Windows.Controls.Border
            $card.CornerRadius = 4; $card.Padding = '10,6,10,7'; $card.Margin = '0,0,8,4'
            & $Ref $card 'Background' 'Card'
            # Half strength at rest, full colour under the pointer: eighty
            # saturated stripes down a page is not a comparison.
            & $Ref $card 'BorderBrush' ($presetColor[$Preset] + 'Soft')
            $card.BorderThickness = New-Object Windows.Thickness -ArgumentList 3, 1, 1, 1
            $cardKeys = @{ Soft = $presetColor[$Preset] + 'Soft'; Full = $presetColor[$Preset] }
            $paint = $Ref
            $card.Tag = $cardKeys
            $card.Add_MouseEnter({ & $paint $this 'BorderBrush' $this.Tag.Full }.GetNewClosure())
            $card.Add_MouseLeave({ & $paint $this 'BorderBrush' $this.Tag.Soft }.GetNewClosure())
            $inner = New-Object Windows.Controls.StackPanel

            # WrapPanel, not a horizontal StackPanel - this page is where it
            # showed, two columns inside a window.
            $line = New-Object Windows.Controls.WrapPanel
            $line.Orientation = 'Horizontal'
            $nm = New-Object Windows.Controls.TextBlock
            $nm.Text = [string]$(if ($itemName.ContainsKey($Id)) { $itemName[$Id] } else { $Id })
            $nm.FontSize = 13; $nm.FontWeight = 'SemiBold'; $nm.TextWrapping = 'Wrap'
            & $Ref $nm 'Foreground' 'Text'
            $null = $line.Children.Add($nm)

            $rk = [int]$itemRisk[$Id]
            if ($rk -gt 0) {
                $bd = New-Object Windows.Controls.Border
                $bd.CornerRadius = 3; $bd.Padding = '5,0,5,1'; $bd.Margin = '7,1,0,0'
                $bd.VerticalAlignment = 'Center'
                $bd.BorderThickness = New-Object Windows.Thickness 1
                & $Ref $bd 'BorderBrush' $riskStyle[$rk].Col
                $bt = New-Object Windows.Controls.TextBlock
                $bt.Text = $riskStyle[$rk].Label; $bt.FontSize = 10.5
                & $Ref $bt 'Foreground' $riskStyle[$rk].Col
                $bd.Child = $bt
                # A marker, not a control: it was clickable while the risk note
                # lived nowhere else, and the note is the first thing in the
                # Details panel now.
                $null = $line.Children.Add($bd)
            }

            # There was a "not on this machine" tag here. It is gone because the
            # case is: $cmpLive takes those off the page entirely, and a tag
            # that can never render reads as a guarantee.
            $ad = New-Object Windows.Controls.Border
            $ad.CornerRadius = 3; $ad.Padding = '5,0,5,1'; $ad.Margin = '7,1,0,0'
            $ad.VerticalAlignment = 'Center'
            $ad.BorderThickness = New-Object Windows.Thickness 1
            $ad.Visibility = 'Collapsed'
            & $Ref $ad 'BorderBrush' 'Ok'
            $ad.ToolTip = "Not part of $Preset as shipped - you added it in the options list."
            $at = New-Object Windows.Controls.TextBlock
            $at.Text = 'you added this'; $at.FontSize = 10.5
            & $Ref $at 'Foreground' 'Ok'
            $ad.Child = $at
            $null = $line.Children.Add($ad)
            # The same Details chip every Advanced row carries: this page is
            # where somebody decides whether to take an item on.
            if ($itemsById.ContainsKey($Id)) {
                $chipEl = & $chipFn ([string]$nm.Text) $itemsById[$Id] $inner $state
                $null = $line.Children.Add($chipEl)
                $cmpChips.Add([pscustomobject]@{ Id = [string]$Id; Chip = $chipEl })
            }
            $null = $inner.Children.Add($line)

            # Collapsed rather than skipped under Non-verbose: these cards are
            # cached and repainted, so a description that had to be constructed
            # could not come back.
            $ds = [string]$itemDesc[$Id]
            if ($ds) {
                $dt = New-Object Windows.Controls.TextBlock
                $dt.Text = $ds; $dt.FontSize = 12; $dt.TextWrapping = 'Wrap'; $dt.Margin = '0,2,0,0'
                & $Ref $dt 'Foreground' 'Sub'
                if ($state.Terse) { $dt.Visibility = 'Collapsed' }
                $null = $inner.Children.Add($dt)
                $null = $cmpDescEls.Add($dt)
            }

            # Why the button is refusing. The item stays listed because it is a
            # real difference; hiding the card would hide a fact.
            $gate = New-Object Windows.Controls.TextBlock
            $gate.FontSize = 11.5; $gate.TextWrapping = 'Wrap'; $gate.Margin = '0,3,0,0'
            $gate.Visibility = 'Collapsed'
            & $Ref $gate 'Foreground' 'Warn'
            $null = $inner.Children.Add($gate)

            # The whole point of reading two lists side by side is deciding you
            # want something from the other one.
            $add  = $compareAdd
            $drop = $compareRemove
            # Copied in for the click handler below, which is a closure and sees
            # only this scope.
            $flip = $paintCmpButton
            $now  = $showNowFast
            # The short form on the button, the long one in the tooltip: this
            # button sits inside a card two hundred pixels wide.
            $tgt = [string](& $shortPreset $Target)
            $go = New-Object Windows.Controls.Button
            $go.FontSize = 12; $go.Padding = '10,3'; $go.Margin = '10,0,0,0'
            $go.VerticalAlignment = 'Top'
            # Id, Target, From, and Done are what the rest of the application
            # and the self test read off this button.
            $go.Tag = @{ Id = $Id; Target = $Target; From = $Preset; Done = $false
                         Short = $tgt; Gate = $gate; Mark = $ad }
            $go.Add_Click({
                $t   = $this.Tag
                $was = [bool]$t.Done
                # The button answers before the page does: everything else here
                # follows from a rebuild that takes a fifth of a second.
                & $flip $this (-not $was)
                & $now $this
                if ($was) { & $drop $t.Id $t.Target }
                else      { & $add  $t.Id $t.Target $t.From }
            }.GetNewClosure())

            # DockPanel, not the title line: the name wraps, and a button parked
            # after a wrapping TextBlock lands wherever the text ends.
            $dock = New-Object Windows.Controls.DockPanel
            $dock.LastChildFill = $true
            [Windows.Controls.DockPanel]::SetDock($go, 'Right')
            $null = $dock.Children.Add($go)
            $null = $dock.Children.Add($inner)
            $card.Child = $dock
            # The button is what every repaint and every test reaches for, so it
            # is handed out rather than dug back out of two nested panels.
            $card.Tag.Go = $go
            $card
        }

        # The three things about a card that can differ from one build to the
        # next. Everything here is set on every pass, in both directions.
        $paintCard = {
            param($Card, [string]$Id, [string]$Preset, [string]$Target, [bool]$Done)
            $go = $Card.Tag.Go
            $t  = $go.Tag
            $t.Done = $Done

            $t.Mark.Visibility = $(if ($addedIn[$Preset].Contains($Id)) { 'Visible' } else { 'Collapsed' })

            $blockWhy = [string](& $cmpExcluded $Id $Target)
            if ($blockWhy -and -not $Done) {
                $go.Content   = 'Unavailable'
                $go.IsEnabled = $false
                $go.ToolTip   = $blockWhy
                $t.Gate.Text       = $blockWhy
                $t.Gate.Visibility = 'Visible'
                # ClearValue, not $null: these are the chrome's own defaults,
                # and a Button with BorderBrush set to nothing is a Button with
                # no border.
                $go.ClearValue([Windows.Controls.Control]::BorderBrushProperty)
                $go.ClearValue([Windows.Controls.Control]::BorderThicknessProperty)
                $go.ClearValue([Windows.Controls.Control]::FontWeightProperty)
            } else {
                $t.Gate.Text       = ''
                $t.Gate.Visibility = 'Collapsed'
                $go.IsEnabled      = $true
                # The same function the button's own click handler calls a
                # moment earlier, so the optimistic paint and the authoritative
                # one cannot disagree.
                & $paintCmpButton $go $Done
            }
            # Only the ones that can be pressed: this list exists so the self
            # test can click a real hand-over.
            if ($go.IsEnabled) { $cmpAddButtons.Add($go) }
        }

        # The detach is the same trap the two pickers have: Children.Clear()
        # drops the stack from the grid and does not touch what the stack is
        # holding.
        $makeCard = {
            param([string]$Id, [string]$Preset, [string]$Target, [bool]$Done)
            $key  = "$Id|$Preset|$Target"
            $card = $cardCache[$key]
            if (-not $card) {
                $card = & $newCard $Id $Preset $Target
                $cardCache[$key] = $card
            } elseif ($card.Parent -is [Windows.Controls.Panel]) {
                $card.Parent.Children.Remove($card)
            }
            & $paintCard $card $Id $Preset $Target $Done
            $card
        }

        $makeTitle = {
            param([string]$Preset, [int]$Count, [int]$Handed, [string]$Other, [int]$HiddenByFilter)
            $sp = New-Object Windows.Controls.StackPanel
            # Under the picker now rather than over it, so the space belongs
            # below.
            $sp.Margin = '0,4,0,10'
            $h = New-Object Windows.Controls.TextBlock
            $h.Text = "Only $Preset removes these"
            $h.FontSize = 16; $h.FontWeight = 'SemiBold'; $h.TextWrapping = 'Wrap'
            & $Ref $h 'Foreground' $presetColor[$Preset]
            $null = $sp.Children.Add($h)
            $s = New-Object Windows.Controls.TextBlock
            # Three things this line has to say, and the third is why it takes a
            # filter count.
            $s.Text = $(if ($Count) { "$Count item(s)" }
                        elseif ($HiddenByFilter) { "$HiddenByFilter item(s), all hidden by the filter" }
                        else { "Nothing - $Other removes everything $Preset does" }) +
                      $(if ($Handed) { ", $Handed of them now added to $Other as well" } else { '' })
            $s.FontSize = 12; & $Ref $s 'Foreground' 'Muted'; $s.TextWrapping = 'Wrap'
            $null = $sp.Children.Add($s)
            $sp
        }

        # One layout, always two columns.
        $divideFrom = -1
        $divideTo   = -1

        # The pinned header.
        foreach ($side in @(@{ K = 'A'; P = $a; Col = 0; Cnt = $onlyA.Count; Hid = $allA.Count; Done = $doneA.Count; Other = $b },
                            @{ K = 'B'; P = $b; Col = 1; Cnt = $onlyB.Count; Hid = $allB.Count; Done = $doneB.Count; Other = $a })) {
            $stack = New-Object Windows.Controls.StackPanel
            # Detached from last build's stack first: Children.Clear() does not
            # touch what the stack is holding, and WPF refuses the reparent.
            $held = $cmpHead[[string]$side.K]
            if ($held.Parent -is [Windows.Controls.Panel]) { $held.Parent.Children.Remove($held) }
            $null = $stack.Children.Add($held)
            $null = $stack.Children.Add((& $makeTitle $side.P ([int]$side.Cnt) ([int]$side.Done) ([string]$side.Other) ([int]$side.Hid)))
            [Windows.Controls.Grid]::SetColumn($stack, $(if ([int]$side.Col -ge 1) { 2 } else { 0 }))
            $null = $head.Children.Add($stack)
        }
        # The header's own segment of the rule down the middle, because the
        # header and the cards are two grids now.
        $hdRule = New-Object Windows.Controls.Border
        $hdRule.Width = 1; $hdRule.Margin = '16,4,16,0'
        $hdRule.HorizontalAlignment = 'Center'; $hdRule.VerticalAlignment = 'Stretch'
        & $Ref $hdRule 'Background' 'Line'
        [Windows.Controls.Grid]::SetColumn($hdRule, 1)
        $null = $head.Children.Add($hdRule)

        if (-not ($allA.Count -or $allB.Count)) {
            $r = & $addRow
            $e = New-Object Windows.Controls.TextBlock
            $e.Text = $(if ($a -eq $b) {
                            "$a is being compared with itself, so of course there is nothing between them. Pick a different mode on either side."
                        } else {
                            "$a and $b remove exactly the same things on this machine."
                        })
            $e.FontSize = 14; $e.Margin = '0,16,0,0'; $e.TextWrapping = 'Wrap'
            & $Ref $e 'Foreground' 'Muted'
            & $place $e $r 0 2
            # No rule below the header in this case: what is under it is one
            # sentence spanning both columns, and a hairline through a sentence
            # divides nothing.
        }

        # Every heading either mode could have here, differing or not. The
        # differing ones get cards; the rest get a rail entry.
        $ruleBetween = {
            param([int]$Row)
            foreach ($col in @(0, 1)) {
                $ln = New-Object Windows.Controls.Border
                $ln.Height = 1
                $ln.Margin = '0,18,0,0'
                $ln.VerticalAlignment = 'Bottom'
                & $Ref $ln 'Background' 'Line'
                & $place $ln $Row $col 1
            }
        }
        $firstCardRow = -1
        $anyCards = $false
        foreach ($c in (& $orderedKeys @($coveredKeys.Keys))) {
            $nA = [int]$(if ($catA.ContainsKey($c)) { $catA[$c].Count } else { 0 })
            $nB = [int]$(if ($catB.ContainsKey($c)) { $catB[$c].Count } else { 0 })
            $anchor = $null
            if ($nA -or $nB) {
                if ($anyCards) { & $ruleBetween (& $addRow) }
                $anyCards = $true
                $r = & $addRow
                if ($firstCardRow -lt 0) { $firstCardRow = $r }
                # Both sides get the heading, including the side with nothing
                # under it, which then reads "Games (0)" - and that is the
                # answer to a question somebody reading two columns is asking.
                $hA = & $makeHeading $c $nA
                & $place $hA $r 0 1
                $anchor = $hA
                $hB = & $makeHeading $c $nB
                & $place $hB $r 1 1
                $r = & $addRow
                foreach ($pair in @(@{ Map = $catA; Col = 0; P = $a; Other = $b; Done = $doneA },
                                    @{ Map = $catB; Col = 1; P = $b; Other = $a; Done = $doneB })) {
                    if (-not $pair.Map.ContainsKey($c)) { continue }
                    $stack = New-Object Windows.Controls.StackPanel
                    foreach ($id in ($pair.Map[$c] | Sort-Object { [string]$itemName[$_] })) {
                        $null = $stack.Children.Add((& $makeCard $id $pair.P $pair.Other $pair.Done.Contains($id)))
                    }
                    & $place $stack $r $pair.Col 1
                }
            }
            # Agree is about the modes; hidden is about the filter. Both look
            # like "0 | 0" on the rail and they are not the same statement.
            $railList.Add([pscustomobject]@{
                Title = [string]$c; A = $nA; B = $nB; Head = $anchor
                Agree = (-not $diffKeys.ContainsKey([string]$c)) })
        }
        if ($firstCardRow -ge 0) {
            $divideFrom = $firstCardRow
            $divideTo   = $g.RowDefinitions.Count - 1
        }

        # Only when the whole page is empty for a reason the modes cannot
        # explain.
        if (($allA.Count -or $allB.Count) -and -not $onlyA.Count -and -not $onlyB.Count) {
            $r = & $addRow
            $note = New-Object Windows.Controls.TextBlock
            $note.Text = "Nothing among the $($allA.Count + $allB.Count) difference(s) between $a and $b matches what you are filtering for."
            $note.FontSize = 12.5; $note.Margin = '0,14,0,0'; $note.TextWrapping = 'Wrap'
            & $Ref $note 'Foreground' 'Muted'
            & $place $note $r 0 2
        }

        # The rule down the middle.
        if ($divideFrom -ge 0 -and $divideTo -ge $divideFrom) {
            $div = New-Object Windows.Controls.Border
            $div.Width = 1; $div.Margin = '16,4,16,0'
            $div.HorizontalAlignment = 'Center'; $div.VerticalAlignment = 'Stretch'
            & $Ref $div 'Background' 'Line'
            [Windows.Controls.Grid]::SetColumn($div, 1)
            [Windows.Controls.Grid]::SetRow($div, $divideFrom)
            [Windows.Controls.Grid]::SetRowSpan($div, ($divideTo - $divideFrom + 1))
            $null = $g.Children.Add($div)
        }

        # The index rail.
        $ui.CmpIndexPanel.Children.Clear()
        $cmpSpyRows.Clear()
        $cmpSpy.Offsets = $null
        $cmpSpy.Active  = $null
        $sv = $ui.CmpScroll
        $paintRail = $Ref
        $rowN = 0
        foreach ($e in $railList) {
            $card = New-Object Windows.Controls.Border
            $card.Padding = '8,5,8,5'; $card.CornerRadius = 4; $card.Margin = '0,0,0,2'
            & $paintRail $card 'Background' 'Flat'
            $dp = New-Object Windows.Controls.DockPanel
            $dp.LastChildFill = $true
            $cnt = New-Object Windows.Controls.TextBlock
            $cnt.Text = "$($e.A) | $($e.B)"; $cnt.FontSize = 12; $cnt.Margin = '8,0,0,0'
            [Windows.Controls.DockPanel]::SetDock($cnt, 'Right')
            $null = $dp.Children.Add($cnt)
            $lbl = New-Object Windows.Controls.TextBlock
            $lbl.Text = [string]$e.Title; $lbl.FontSize = 12.5; $lbl.TextTrimming = 'CharacterEllipsis'
            & $paintRail $lbl 'Foreground' 'Sub'
            $null = $dp.Children.Add($lbl)
            $card.Child = $dp

            if ($e.Head) {
                # There is a heading on the page for this one, so the card is a
                # place to go.
                & $paintRail $cnt 'Foreground' 'Accent'
                $card.Cursor = 'Hand'
                $card.ToolTip = "$($e.Title) - $($e.A) only in $a, $($e.B) only in $b"
                # The target and the viewer, both on the Tag, so the handler
                # needs nothing from a scope it cannot see. On is what the hover
                # handlers read so the pointer cannot un-light the active card.
                $card.Tag = @{ Head = $e.Head; View = $sv; On = $false }
                $card.Add_MouseEnter({ if (-not $this.Tag.On) { & $paintRail $this 'Background' 'RowHover' } }.GetNewClosure())
                $card.Add_MouseLeave({ if (-not $this.Tag.On) { & $paintRail $this 'Background' 'Flat' } }.GetNewClosure())
                $card.Add_MouseLeftButtonUp({
                    $t = $this.Tag
                    # Computed live rather than cached: one TransformToAncestor
                    # is cheap and cannot be stale.
                    try {
                        $t.View.UpdateLayout()
                        $y = $t.Head.TransformToAncestor($t.View.Content).Transform(
                                (New-Object Windows.Point 0, 0)).Y
                        $t.View.ScrollToVerticalOffset([Math]::Max(0, $y - 8))
                    } catch { }
                }.GetNewClosure())
                $cmpSpyRows.Add([pscustomobject]@{
                    Key = "rail$rowN"; Card = $card; Head = $e.Head; Label = $lbl })
                $rowN++
            }
            else {
                # Nothing on the page to scroll to, either way. Both stop being
                # cards: no fill, no hand cursor, no hover tint.
                $card.ClearValue([Windows.Controls.Border]::BackgroundProperty)
                & $paintRail $lbl 'Foreground' 'Muted'
                $card.IsHitTestVisible = $false
                # Gray either way: "0 | 0" means there is nothing here to go to,
                # and that is one fact however it came about.
                & $paintRail $cnt 'Foreground' 'Muted'
                if ($e.Agree) {
                    # The two modes handle this category identically.
                    $card.ToolTip = "$a and $b treat $($e.Title) exactly the same way."
                } else {
                    # A real difference, all of it hidden by the filter. Dimmed,
                    # exactly as the Advanced rail dims an emptied block.
                    $card.Opacity = 0.45
                    $card.ToolTip = "$($e.Title) - hidden by the filter"
                }
            }
            $null = $ui.CmpIndexPanel.Children.Add($card)
        }
        # A rail with nothing in it would be a bare column beside the page.
        $hasRail = [bool]$ui.CmpIndexPanel.Children.Count
        $ui.CmpIndexCol.Width = New-Object Windows.GridLength(
            [double]$(if ($hasRail) { $cmpRail.W } else { 0 }))
        $ui.CmpIndexSplit.Visibility = $(if ($hasRail) { 'Visible' } else { 'Collapsed' })
        $ui.CmpIndexRule.Visibility  = $(if ($hasRail) { 'Visible' } else { 'Collapsed' })
        # The page has been relaid, so whatever the highlight was on is gone.
        # Deferred, because nothing has been measured yet.
        $null = $ui.Root.Dispatcher.BeginInvoke(
            [Windows.Threading.DispatcherPriority]::Background, [action]$spyCompare)

        # Counted from the real difference, not from what is on screen: the
        # ticked cards are still shown but no longer differ.
        $shared = $setA.Count - $diffA.Count
        $ui.TxtCompareTally.Text =
            "$a $($setA.Count) items, $b $($setB.Count) - $shared in common, " +
            "$($diffA.Count) only in $a, $($diffB.Count) only in $b" +
            $(if ($cmpDone.Count) { " - $($cmpDone.Count) handed over" } else { '' })
    }.GetNewClosure()
    $cmpRefs.Build = $buildCompare

    # The two pickers, built here rather than declared in the XAML, because they
    # no longer live in the page header.
    $buildCompareRows = {
        $build = $buildCompare
        $st    = $cmpState
        $btns  = $cmpButtons
        # For the click handlers below, which are closures and see only this
        # scope.
        $paint = $paintPresetButton
        $now   = $showNowFast
        # The one event that changes what a kept card should look like without
        # changing its key: the short name printed on its button.
        $cmpCards.Clear()
        # Cleared with them, or every card thrown away leaves its chip on a list
        # nothing can reach.
        $cmpChips.Clear()
        $cmpDescEls.Clear()
        foreach ($k in @('A','B')) {
            # The word sits on the buttons' line and outside the scroller: above
            # them it cost a whole row of height on the one page where vertical
            # space runs out.
            $wrap = New-Object Windows.Controls.Grid
            $wrap.Margin = '0,4,0,2'
            foreach ($w in @((New-WDGridLength 0 'Auto'), (New-WDGridLength 1 'Star'))) {
                $cd = New-Object Windows.Controls.ColumnDefinition
                $cd.Width = $w
                $wrap.ColumnDefinitions.Add($cd)
            }
            $lbl = New-Object Windows.Controls.TextBlock
            $lbl.Text = $(if ($k -eq 'A') { 'Compare' } else { 'against' })
            $lbl.FontSize = 13; $lbl.Margin = '0,0,8,4'
            # Against the buttons rather than the top of the row: the buttons
            # carry their own padding.
            $lbl.VerticalAlignment = 'Center'
            & $Ref $lbl 'Foreground' 'Text'
            [Windows.Controls.Grid]::SetColumn($lbl, 0)
            $null = $wrap.Children.Add($lbl)

            $row = New-Object Windows.Controls.StackPanel
            $row.Orientation = 'Horizontal'
            $btns[$k].Clear()
            foreach ($n in $presetNames) {
                $btn = New-Object Windows.Controls.Button
                # The short form. This is one of the two rows the
                # twelve-character cap exists for.
                $btn.Content = [string](& $shortPreset ([string]$n))
                if ([string]$btn.Content -ne [string]$n) { $btn.ToolTip = [string]$n }
                $btn.Padding = '12,5'; $btn.Margin = '0,0,6,4'; $btn.FontSize = 13
                $btn.Tag = @{ Side = $k; Name = $n }
                $btn.Add_Click({
                    $t = $this.Tag
                    $st[$t.Side] = $t.Name
                    # This row answers before the page behind it is rebuilt, for
                    # the same reason the hand-over button does.
                    foreach ($n in @($btns[$t.Side].Keys)) {
                        & $paint $btns[$t.Side][$n] $n ([string]$n -eq [string]$t.Name)
                    }
                    & $now $this
                    & $build
                }.GetNewClosure())
                $null = $row.Children.Add($btn)
                $btns[$k][$n] = $btn
            }
            # A WrapPanel would be the obvious answer for five buttons, but a
            # wrap changes the row's height as presets are loaded.
            $sv = New-Object Windows.Controls.ScrollViewer
            $sv.HorizontalScrollBarVisibility = 'Auto'
            $sv.VerticalScrollBarVisibility   = 'Disabled'
            # The bar comes from the window's implicit ScrollBar style, the same
            # one the Advanced picker wears.
            $sv.Content = $row
            [Windows.Controls.Grid]::SetColumn($sv, 1)
            $null = $wrap.Children.Add($sv)
            $ui[$(if ($k -eq 'A') { 'CompareARow' } else { 'CompareBRow' })] = $row
            $cmpHead[$k] = $wrap
        }
    }
    & $buildCompareRows

    # The box of loaded selections, under the mode columns.
    $loadedRefresh = {
        & $recount
        if ($loadedRef.Paint) { & $loadedRef.Paint }
        # After the repaint: $recount does this too, but it runs before the box
        # is rebuilt.
        & $syncEditRows
        & $buildAdvPresetRow
        & $buildCompareRows
        if ($cmpRefs.Build) { & $cmpRefs.Build }
        & $saveUiState
    }.GetNewClosure()

    # A plain scriptblock, not a closure: it is called from handlers that
    # resolve against this function's live frame.
    $reKeyLoaded = {
        param([string]$Name, [string]$NewName)
        if ($Name -eq $NewName) { return $Name }
        if (-not $loadedPresets.Contains($Name)) { return $Name }
        if ($presetNames -contains $NewName) { return $Name }

        $rebuilt = [ordered]@{}
        foreach ($k in @($loadedPresets.Keys)) {
            if ($k -eq $Name) { $rebuilt[$NewName] = $loadedPresets[$Name] }
            else              { $rebuilt[$k]       = $loadedPresets[$k] }
        }
        $loadedPresets.Clear()
        foreach ($k in @($rebuilt.Keys)) { $loadedPresets[$k] = $rebuilt[$k] }

        foreach ($h in @($baseIds, $presetColor,
                         $presetDefaults, $overrides, $counts, $consequence, $totDelta,
                         # Carried, not dropped: renaming the file a preset came
                         # from does not un-apply it.
                         $appliedRuns)) {
            if ($h.ContainsKey($Name)) { $h[$NewName] = $h[$Name]; $h.Remove($Name) }
        }
        # Not carried over: the short form is derived from the name, so it has
        # to be derived again from the new one.
        if ($shortOf.ContainsKey($Name)) { $shortOf.Remove($Name) }
        $short = $NewName
        if ($short.Length -gt $PRESET_NAME_MAX) {
            $short = $short.Substring(0, $PRESET_NAME_MAX - 1).TrimEnd() + [char]0x2026
        }
        $stem = $short
        $m = 2
        while (@(@($shortOf.Values) + @($shippedNames)) -contains $short) {
            $suffix = " ($m)"
            $head = $stem
            if ($head.Length + $suffix.Length -gt $PRESET_NAME_MAX) {
                $head = $head.Substring(0, [Math]::Max(1, $PRESET_NAME_MAX - $suffix.Length))
            }
            $short = "$head$suffix"; $m++
        }
        $shortOf[$NewName] = $short
        $at = $presetNames.IndexOf($Name)
        if ($at -ge 0) { $presetNames[$at] = $NewName }
        if ([string]$state.Preset -eq $Name) { $state.Preset = $NewName }
        if ([string]$cmpState.A -eq $Name)   { $cmpState.A   = $NewName }
        if ([string]$cmpState.B -eq $Name)   { $cmpState.B   = $NewName }
        $NewName
    }

    # One line of text back, or null for cancel. A separate Window is a separate
    # resource scope, so the dictionary is merged into it.
    $askName = {
        param([string]$Title, [string]$Message, [string]$Value)
        $dlg = New-Object Windows.Window
        $dlg.Title = $Title
        $dlg.SizeToContent = 'WidthAndHeight'
        $dlg.ResizeMode = 'NoResize'
        $dlg.WindowStartupLocation = 'CenterOwner'
        $dlg.ShowInTaskbar = $false
        $dlg.Owner = $win
        # Called rather than captured: a closure resolves a variable against the
        # scope it was written in.
        $dlgIcon = Get-WDAppIcon
        if ($dlgIcon) { $dlg.Icon = $dlgIcon }
        if (-not $dlg.Resources.MergedDictionaries.Contains($themeDict)) {
            $dlg.Resources.MergedDictionaries.Add($themeDict)
        }
        & $Ref $dlg 'Background' 'Panel'
        $sp = New-Object Windows.Controls.StackPanel
        $sp.Margin = '22,18,22,16'; $sp.MinWidth = 380; $sp.MaxWidth = 460
        $t = New-Object Windows.Controls.TextBlock
        $t.Text = $Message; $t.FontSize = 13.5; $t.TextWrapping = 'Wrap'; $t.Margin = '0,0,0,12'
        & $Ref $t 'Foreground' 'Text'
        $null = $sp.Children.Add($t)
        $box = New-Object Windows.Controls.TextBox
        $box.Text = $Value; $box.FontSize = 13; $box.Padding = '7,5'
        $box.SelectAll()
        $null = $sp.Children.Add($box)
        $row = New-Object Windows.Controls.StackPanel
        $row.Orientation = 'Horizontal'; $row.HorizontalAlignment = 'Right'; $row.Margin = '0,14,0,0'
        $out = @{ V = $null }
        foreach ($o in @(@{ L = 'Cancel'; Ok = $false }, @{ L = 'Rename'; Ok = $true })) {
            $b = New-Object Windows.Controls.Button
            $b.Content = [string]$o.L; $b.Padding = '18,6'; $b.Margin = '8,0,0,0'; $b.MinWidth = 92
            $b.Tag = @{ Ok = [bool]$o.Ok; Out = $out; Box = $box; Dialog = $dlg }
            $b.Add_Click({
                $d = $this.Tag
                if ($d.Ok) { $d.Out.V = [string]$d.Box.Text }
                $d.Dialog.DialogResult = $true
            }.GetNewClosure())
            $null = $row.Children.Add($b)
        }
        $null = $sp.Children.Add($row)
        $dlg.Content = $sp
        $box.Focus() | Out-Null
        $null = $dlg.ShowDialog()
        $out.V
    }

    # Renaming a loaded preset renames its file. The two cannot come apart: the
    # name of one of these is the file's name, and the list is rebuilt from
    # paths at startup.
    # Every refusal is checked before the file moves, or it ends up called one
    # thing while the preset is called another.
    $renameLoadedTo = {
        param([string]$Name, [string]$NewName)
        $name = [string]$Name
        $want = ([string]$NewName).Trim()
        if (-not $loadedPresets.Contains($name)) { return 'that is not a loaded selection' }
        if (-not $want) { return 'a selection needs a name' }
        $here = [string]$loadedPresets[$name].Path
        $stem = [IO.Path]::GetFileNameWithoutExtension($here)
        if ($want -eq $stem) { return $name }
        $bad = @([IO.Path]::GetInvalidFileNameChars() | Where-Object { $want.Contains($_) })
        if ($bad.Count) { return "a file cannot be called that - leave out $($bad -join ' ')" }
        if ($presetNames -contains $want) { return "$want is already the name of a preset here" }
        $target = Join-Path (Split-Path -Parent $here) "$want.json"
        if (Test-Path -LiteralPath $target) { return "there is already a file called $want.json in that folder" }
        try { Move-Item -LiteralPath $here -Destination $target -ErrorAction Stop }
        catch { return "$here could not be renamed: $($_.Exception.Message)" }
        # The entry follows the file whatever happens next: a preset pointing at
        # a path that no longer exists is the dangling-name crash by another
        # route.
        $loadedPresets[$name].Path = $target
        $new = [string](& $reKeyLoaded $name $want)
        & $loadedRefresh
        & $selectPreset $new
        $new
    }
    $renamePreset = {
        param([string]$Name)
        if ($state.NoPrompts) { return }
        $name = [string]$Name
        if (-not $loadedPresets.Contains($name)) { return }
        $stem = [IO.Path]::GetFileNameWithoutExtension([string]$loadedPresets[$name].Path)
        $want = & $askName 'Rename' 'What should this selection be called? Its file is renamed to match.' $stem
        if ($null -eq $want) { return }
        $got = [string](& $renameLoadedTo $name ([string]$want))
        # It answers with the new name or with the reason. Anything that is not
        # a preset name is the reason.
        if (-not ($presetNames -contains $got)) {
            Show-WDMessage ($got, 'Rename', 'OK', 'Error') | Out-Null
        }
    }

    $paintLoaded = {
        $panel = $ui.LoadedPanel
        $panel.Children.Clear()
        # Every row here is rebuilt, so the Save/Reset pairs belonging to loaded
        # presets are rebuilt with them.
        $ui.TxtLoadHint.Text = 'Incompatible options will be dropped.'
        # Remove all acts on the list; Remove and Rename act on the selected
        # preset, so they are grayed while a shipped mode is selected.
        $anyLoaded = [bool]$loadedPresets.Count
        $onLoaded  = $anyLoaded -and $loadedPresets.Contains([string]$state.Preset)
        # Remove all speaks for the list, so it follows whether the list has
        # anything in it and never the selection.
        $ui.BtnRemoveAllPresets.Visibility = $(if ($anyLoaded) { 'Visible' } else { 'Collapsed' })
        # Grayed, not collapsed, and that is a fix rather than a preference:
        # collapsing took 160px out of the middle of the row and Remove all slid
        # across to fill it.
        foreach ($b in @('BtnRemovePreset', 'BtnRenamePreset')) {
            $ui[$b].IsEnabled = $onLoaded
        }
        foreach ($n in @($loadedPresets.Keys)) {
            $info = $loadedPresets[$n]
            $card = New-Object Windows.Controls.Border
            $card.CornerRadius = New-Object Windows.CornerRadius 5
            $card.Padding = '10,7,10,8'; $card.Margin = '0,0,0,5'
            $card.BorderThickness = New-Object Windows.Thickness 1
            $card.Cursor = 'Hand'
            $sel = ($state.Preset -eq [string]$n)
            & $Ref $card 'Background'  $(if ($sel) { 'CardSel' } else { 'Flat' })
            & $Ref $card 'BorderBrush' $(if ($sel) { [string]$info.Key } else { 'Line' })
            # This row prints the long form: it is the one place with a full
            # window's width and nothing beside it to push aside.
            $card.ToolTip = [string]$info.Path

            $dock = New-Object Windows.Controls.DockPanel
            $dock.LastChildFill = $true

            # Remove and Rename were a pair on every one of these rows. They are
            # in the box's header now and act on the selection.
            $mark = New-Object Windows.Controls.TextBlock
            $mark.Text = $(if ($sel) { 'SELECTED' } else { 'click to select' })
            $mark.FontSize = 11; $mark.FontWeight = 'SemiBold'
            $mark.VerticalAlignment = 'Center'; $mark.Margin = '10,0,0,0'
            & $Ref $mark 'Foreground' $(if ($sel) { [string]$info.Key } else { 'Muted' })
            [Windows.Controls.DockPanel]::SetDock($mark, 'Right')
            $null = $dock.Children.Add($mark)

            $stack = New-Object Windows.Controls.StackPanel
            $ttl = New-Object Windows.Controls.TextBlock
            $ttl.Text = [string]$n; $ttl.FontSize = 13.5; $ttl.FontWeight = 'SemiBold'
            $ttl.TextTrimming = 'CharacterEllipsis'
            & $Ref $ttl 'Foreground' ([string]$info.Key)
            $null = $stack.Children.Add($ttl)
            $sub = New-Object Windows.Controls.TextBlock
            $have = @($info.Ids).Count; $said = [int]$info.Total
            $sub.Text = $(if ($said -gt $have) {
                              "$have of the $said options in this file apply to this machine"
                          } else { "$have option(s)" }) + " - $([IO.Path]::GetFileName([string]$info.Path))"
            $sub.FontSize = 12; $sub.TextTrimming = 'CharacterEllipsis'
            & $Ref $sub 'Foreground' 'Sub'
            $null = $stack.Children.Add($sub)
            # And this row's own pair, on the same terms as a mode column's.
            $null = $stack.Children.Add((& $makeEditRow ([string]$n)))

            # The same three things a mode card offers, because a selection
            # loaded from a file is a preset like any other.
            $acts = New-Object Windows.Controls.StackPanel
            $acts.Orientation = 'Horizontal'
            $acts.Margin = '0,8,0,0'
            $acts.Visibility = $(if ($sel) { 'Visible' } else { 'Collapsed' })
            foreach ($a in @(@{ T = 'Show all options'; Go = 'open' },
                             @{ T = 'Compare with...';  Go = 'compare' },
                             @{ T = 'Preview';          Go = 'preview' })) {
                $ab = New-Object Windows.Controls.Button
                $ab.Content = [string]$a.T
                $ab.Padding = '12,4'; $ab.Margin = '0,0,7,0'; $ab.FontSize = 12.5
                if ([string]$a.Go -eq 'preview') {
                    $ab.FontWeight = 'Bold'
                    & $Ref $ab 'Background'  'GoBg'
                    & $Ref $ab 'Foreground'  'GoText'
                    & $Ref $ab 'BorderBrush' 'GoBorder'
                }
                # Everything on the Tag: these are built inside a closure, so a
                # reach up the chain for $advRef or $goRef captures null.
                $ab.Tag = @{ Name = [string]$n; Do = [string]$a.Go
                             Adv = $advRef; Go = $goRef }
                $ab.Add_Click({
                    $t = $this.Tag
                    switch ([string]$t.Do) {
                        'open'    { if ($t.Adv.Open) { & $t.Adv.Open } }
                        'compare' { if ($t.Go.ComparePick) { & $t.Go.ComparePick ([string]$t.Name) } }
                        'preview' { if ($t.Go.Preview) { & $t.Go.Preview } }
                    }
                }.GetNewClosure())
                $null = $acts.Children.Add($ab)
            }
            $null = $stack.Children.Add($acts)
            $null = $dock.Children.Add($stack)
            $card.Child = $dock

            # Everything both handlers need on the Tag, for the same reason.
            $card.Tag = @{ Name = [string]$n; Go = $pickOrSelect; Mark = $mark; Acts = $acts }
            $card.Add_MouseLeftButtonUp({
                if ($args[1].Handled) { return }
                & $this.Tag.Go $this.Tag.Name
            }.GetNewClosure())
            $null = $panel.Children.Add($card)
        }
    }.GetNewClosure()
    $loadedRef.Paint = $paintLoaded

    # The three buttons in the box's header.
    $dropAllLoaded = {
        # Snapshotted before the loop: $dropLoaded rebuilds $loadedPresets, and
        # enumerating while removing throws.
        foreach ($n in @($loadedPresets.Keys)) { & $dropLoaded ([string]$n) }
        & $loadedRefresh
        & $selectPreset ([string]$state.Preset)
    }.GetNewClosure()

    $ui.BtnRemovePreset.Add_Click({
        $n = [string]$state.Preset
        if (-not $loadedPresets.Contains($n)) { return }
        & $dropLoaded $n
        & $loadedRefresh
        & $selectPreset ([string]$state.Preset)
    }.GetNewClosure())

    # $renamePreset does its own refreshing and re-selecting: the name it ends
    # on is not the name it was handed.
    $ui.BtnRenamePreset.Add_Click({
        $n = [string]$state.Preset
        if (-not $loadedPresets.Contains($n)) { return }
        & $renamePreset $n
    }.GetNewClosure())

    # Asked once for the lot rather than once per file. Nothing here touches a
    # file.
    $ui.BtnRemoveAllPresets.Add_Click({
        if (-not $loadedPresets.Count) { return }
        if (-not $state.NoPrompts) {
            $n = $loadedPresets.Count
            $msg = "Take all $n saved preset(s) off this list?" + "`n`n" +
                   'The files themselves are not touched, and Load brings any of them back.'
            if ((Show-WDMessage ($msg, 'Remove all', 'YesNo', 'Warning')) -ne 'Yes') { return }
        }
        & $dropAllLoaded
    }.GetNewClosure())

    # What the load could not honor, said out loud.
    $reportDropped = {
        param($Names)
        $lines = New-Object System.Collections.Generic.List[string]
        $n = 0
        foreach ($nm in @($Names)) {
            if (-not $loadedPresets.Contains([string]$nm)) { continue }
            $lost = @($loadedPresets[[string]$nm].Dropped)
            if (-not $lost.Count) { continue }
            $n += $lost.Count
            if (@($Names).Count -gt 1) { $lines.Add("$nm") }
            foreach ($d in $lost) { $lines.Add("  $($d.Name) - $($d.Why)") }
            $lines.Add('')
        }
        if (-not $n) { return '' }
        $body = "$n option(s) in the file(s) you loaded do not apply to this machine and were dropped:" +
                "`n`n" + ($lines -join "`n") +
                "`nEverything else was kept. The file itself is untouched - load it on the machine it was " +
                'saved on and those options come back.'
        if (-not $state.NoPrompts) {
            Show-WDMessage ($body, 'Some options were dropped', 'OK', 'None') | Out-Null
        }
        $body
    }.GetNewClosure()

    # The folder the toolkit writes to and Setup reads from, for the two Load
    # buttons.
    $savesFolder = { Join-Path (Split-Path -Parent $ModulePath) 'profile_saves' }
    # Everything both Load buttons do once they know which files: register each,
    # refresh the four screens that care, select the last.
    $loadPaths = {
        param($Paths, [string]$Title)
        $bad  = New-Object System.Collections.Generic.List[string]
        $last = ''
        $loadedNow = New-Object System.Collections.Generic.List[string]
        foreach ($f in @($Paths)) {
            $nm = & $registerLoaded ([string]$f)
            if ($nm) { $last = $nm; $loadedNow.Add([string]$nm) } else { $bad.Add([IO.Path]::GetFileName([string]$f)) }
        }
        & $loadedRefresh
        # Selected on the way in: loading a file and then having to find it in a
        # box is two gestures for one intention.
        if ($last) { & $selectPreset $last }
        if ($bad.Count -and -not $state.NoPrompts) {
            Show-WDMessage (
                "These are not saved selections:`n`n$($bad -join "`n")`n`n" +
                'A saved selection is the JSON file written by Save > File on the Advanced page.',
                $Title, 'OK', 'None') | Out-Null
        }
        & $reportDropped $loadedNow
        $loadedNow.Count
    }
    # A dialog rather than a drop-down of profile_saves: a saved selection is a
    # file somebody keeps where they keep files.
    $ui.BtnLoadPreset.Add_Click({
        $dlg = New-Object Microsoft.Win32.OpenFileDialog
        $dlg.Title  = 'Load a saved selection'
        $dlg.Filter = 'Saved selections (*.json)|*.json|All files (*.*)|*.*'
        $dlg.Multiselect = $true
        try {
            $seed = & $savesFolder
            if (Test-Path -LiteralPath $seed) { $dlg.InitialDirectory = $seed }
        } catch { }
        if ($dlg.ShowDialog() -ne $true) { return }
        $null = & $loadPaths @($dlg.FileNames) 'Load a saved selection'
    }.GetNewClosure())

    # Load all. The one folder that is not somebody's own filing: the toolkit
    # writes here and Setup reads from here.
    $ui.BtnLoadAll.Add_Click({
        $folder = & $savesFolder
        $files = @()
        try {
            if (Test-Path -LiteralPath $folder) {
                $files = @(Get-ChildItem -LiteralPath $folder -Filter '*.json' -File -ErrorAction Stop |
                           Sort-Object Name | ForEach-Object { [string]$_.FullName })
            }
        } catch { $files = @() }
        $here = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)
        foreach ($k in @($loadedPresets.Keys)) { $null = $here.Add([string]$loadedPresets[$k].Path) }
        $want = @($files | Where-Object { -not $here.Contains([string]$_) })
        if (-not $want.Count) {
            if ($state.NoPrompts) { return }
            # Three states worth telling apart: no folder, an empty one, and one
            # whose every file is already on the list.
            $msg = if (-not $files.Count) {
                       "No saved selections in`n`n$folder`n`nSave > File on the options list writes them there."
                   } else {
                       "All $($files.Count) saved selection(s) in that folder are already loaded."
                   }
            Show-WDMessage ($msg, 'Load all', 'OK', 'None') | Out-Null
            return
        }
        $null = & $loadPaths $want 'Load all'
    }.GetNewClosure())
    & $paintLoaded
    # Its own panel rather than a shared builder: this filter offers different
    # facets - no Section and no View, because Compare shows differences rather
    # than a selection.
    $buildCmpFilterPanel = {
        $rebuild = $cmpRefs
        $sets    = $cmpSel
        $boxes   = $cmpBoxes
        $panel   = $ui.CmpFilterPanel
        $panel.Children.Clear()
        $boxes.Clear()

        $section = {
            param([string]$Title, [string]$Group, [string[]]$Names)
            $onSel = $rebuild
            $mine  = $sets
            $h = New-Object Windows.Controls.TextBlock
            $h.Text = $Title; $h.FontSize = 12; $h.FontWeight = 'SemiBold'
            & $Ref $h 'Foreground' 'Muted'
            $h.Margin = $(if ($panel.Children.Count) { '0,14,0,4' } else { '0,0,0,4' })
            $null = $panel.Children.Add($h)
            foreach ($nm in $Names) {
                $cb = New-Object Windows.Controls.CheckBox
                $cb.Content = $nm; $cb.FontSize = 13; $cb.Margin = '0,3,0,3'
                & $Ref $cb 'Foreground' 'Text'
                $cb.Tag = @{ Group = $Group; Name = $nm }
                $flip = {
                    $t = $this.Tag
                    if ($this.IsChecked) { $null = $mine[$t.Group].Add($t.Name) }
                    else                 { $null = $mine[$t.Group].Remove($t.Name) }
                    if ($onSel.Build) { & $onSel.Build }
                }.GetNewClosure()
                $cb.Add_Checked($flip); $cb.Add_Unchecked($flip)
                $null = $panel.Children.Add($cb)
                $boxes.Add([pscustomobject]@{ Group = $Group; Name = $nm; Box = $cb })
            }
        }
        & $section 'RISK'  'Risk'  @('No risk', 'Caution', 'Risky')
        & $section 'BLOAT RATING' 'Bloat' @($BLOAT_RATED | ForEach-Object { [string]$_.N })
        & $section 'CATEGORY' 'Cat' @($normalCats | ForEach-Object { [string]$_.name })
    }
    & $buildCmpFilterPanel

    foreach ($k in $CMP_GROUPS.Keys) {
        $it = New-Object Windows.Controls.ComboBoxItem
        $it.Content = $CMP_GROUPS[$k]; $it.Tag = $k
        $null = $ui.CmbCmpGroup.Items.Add($it)
        if ($k -eq [string]$cmpGroup.Mode) { $ui.CmbCmpGroup.SelectedItem = $it }
    }
    if (-not $ui.CmbCmpGroup.SelectedItem) { $ui.CmbCmpGroup.SelectedIndex = 0 }
    $ui.CmbCmpGroup.Add_SelectionChanged({
        $sel = $ui.CmbCmpGroup.SelectedItem
        if (-not $sel) { return }
        if ([string]$sel.Tag -eq [string]$cmpGroup.Mode) { return }
        $cmpGroup.Mode = [string]$sel.Tag
        & $buildCompare
    }.GetNewClosure())

    # Longer than the Advanced box's 180: a keystroke here rebuilds the whole
    # comparison rather than re-filtering rows that exist.
    $ui.TxtCmpSearch.Add_TextChanged((& $newDebounce 260 { & $buildCompare }.GetNewClosure()))
    $clearCmpFilters = {
        foreach ($b in $cmpBoxes) { $b.Box.IsChecked = $false }
        foreach ($g in $CMP_FACETS) { $cmpSel[$g].Clear() }
        $ui.TxtCmpSearch.Text = ''
        & $buildCompare
    }.GetNewClosure()
    $ui.BtnCmpFilterClear.Add_Click($clearCmpFilters.GetNewClosure())
    $ui.BtnCmpFilterDone.Add_Click({ $ui.BtnCmpFilter.IsChecked = $false }.GetNewClosure())

    & $buildCompare

    # Opening the page, with both sides already decided.
    $ui.BtnModesBack.Add_Click({
        # A pick left half-asked would come back the next time this page opened,
        # over a card that is no longer the one it names.
        if ($cmpPickRef.End) { & $cmpPickRef.End }
        & $showPage 'PageHome'
    }.GetNewClosure())

    $goRef.Compare = {
        # A fresh visit starts with an empty stack. The edits stay - they are
        # preset edits like any other.
        $cmpDone.Clear()
        & $buildCompare
        & $showPage 'PageCompare'
    }.GetNewClosure()

    # "Compare this one with which?" - the question goes in the page, not a
    # dialog, because what it wants is a click on one of the cards below it.
    $cmpPick = @{ On = $false; From = $null }
    $endComparePick = {
        $cmpPick.On = $false
        $cmpPick.From = $null
        $ui.CmpPickBar.Visibility = 'Collapsed'
    }.GetNewClosure()
    $goRef.ComparePick = {
        param([string]$From)
        if (-not $From) { $From = [string]$state.Preset }
        $cmpPick.On = $true
        $cmpPick.From = [string]$From
        $ui.TxtCmpPick.Text =
            "Comparing $From with... click another preset to compare it against. " +
            'Nothing is selected or changed by picking one.'
        $ui.CmpPickBar.Visibility = 'Visible'
        # The bar is above the cards and the page may be scrolled away from it.
        $ui.ModeScroll.ScrollToVerticalOffset(0)
    }.GetNewClosure()
    # Answers true when it consumed the click, so $selectPreset knows not to
    # also select it.
    $cmpPickRef.Take = {
        param([string]$Name)
        if (-not $cmpPick.On) { return $false }
        $from = [string]$cmpPick.From
        # Clicking the one being compared cancels rather than opening a page
        # that says two modes are identical.
        if ([string]$Name -eq $from) { & $endComparePick; return $true }
        $cmpState.A = $from
        $cmpState.B = [string]$Name
        & $endComparePick
        if ($goRef.Compare) { & $goRef.Compare }
        $true
    }.GetNewClosure()
    $cmpPickRef.End = $endComparePick
    $ui.BtnCmpPickCancel.Add_Click($endComparePick)
    $ui.BtnCompareBack.Add_Click({ & $showPage 'PageModes' }.GetNewClosure())

    # The Revert page.
    $revertRows = New-Object System.Collections.Generic.List[psobject]

    # The revert page is the rollback script's window built inside the
    # application: same groupings, same sorts, same filter, same rail.

    # Which run the page is showing, and the way back into the builder for the
    # picker's own buttons.
    $revertPick = @{ Sel = 'all'; Build = $null; Runs = @() }

    # Two controls, not one, and every pairing means something - so there is
    # nothing to gray out.
    $REV_GROUPS = @(
        @{ Key = 'category'; Label = 'Category' }
        @{ Key = 'status';   Label = 'What is left' }
        @{ Key = 'kind';     Label = 'Kind of change' }
        @{ Key = 'alpha';    Label = 'Name (A-Z)' }
    )
    $REV_SORTS = @(
        @{ Key = 'name';     Label = 'Name (A-Z)' }
        @{ Key = 'selected'; Label = 'Selected first' }
        @{ Key = 'most';     Label = 'Most changes first' }
    )
    $REV_STATE_LABEL = @{ todo = 'Still in place'; unknown = 'Cannot tell from here'; done = 'Already back' }
    $REV_STATE_RANK  = @{ todo = 0;                unknown = 1;                       done = 2 }
    $REV_KIND_RANK   = @{ 'Registry values' = 0; 'Services' = 1; 'Scheduled tasks' = 2
                          'Windows features' = 3; 'Files and folders' = 4; 'Power settings' = 5
                          'Installed programs' = 6; 'Recurring effects' = 7; 'Other' = 8 }
    $REV_FILTER_GROUPS = @('State', 'View', 'Kind', 'Cat')

    $revState     = @{ Group = 'category'; Sort = 'name'; Booting = $true; Tickable = 0 }
    # Where the wait goes, recorded rather than guessed at. Each number has a
    # different answer if it grows.
    $revBuilt = @{ Ms = 0; Read = 0; Plan = 0; States = 0; Extra = 0; Rows = 0; Layout = 0 }
    $revBlocks    = New-Object System.Collections.Generic.List[psobject]
    $revRailCards = New-Object System.Collections.Generic.List[psobject]
    $revSpy       = @{ Offsets = $null; On = '' }
    $revCatOrder  = @{}
    $revFilterSel = @{}
    foreach ($fg in $REV_FILTER_GROUPS) { $revFilterSel[$fg] = New-Object System.Collections.Generic.List[string] }
    $revFilterBoxes = New-Object System.Collections.Generic.List[psobject]
    # Selected only / Unselected only are a snapshot: a live query deletes the
    # row you just clicked.
    $revViewSnap = @{ Ids = $null }
    # The holder that breaks the cycle: a chip has to un-tick a box and
    # re-filter, and it is built by the filter pass it has to call.
    $revFx = @{ Filter = $null; Pairs = $null }

    # Render priority rather than a DispatcherFrame: it flushes layout and
    # stops, so nothing at Input priority runs.
    $revShowNow = { $win.Dispatcher.Invoke([action]{}, 'Render') }.GetNewClosure()

    # The build reads the machine for the best part of ten seconds on a machine
    # with real runs behind it.
    $revSay = {
        param([string]$Text, [double]$Fraction)
        $ui.TxtRevertSub.Text = $Text
        # The same overlay the Advanced build and the theme switch use: a
        # determinate bar, because this blocks the UI thread between pumps.
        $veil = $win.Tag.Busy
        if ($veil) { & $veil.Set $Text $Fraction }
        if ($state.NoPrompts) { return }
        $frame = New-Object Windows.Threading.DispatcherFrame
        $null = $win.Dispatcher.BeginInvoke(
            [Windows.Threading.DispatcherPriority]::Background,
            [action]{ $frame.Continue = $false })
        [Windows.Threading.Dispatcher]::PushFrame($frame)
    }.GetNewClosure()

    # One scriptblock per row, and that is a cost decision: GetNewClosure copies
    # the locals of the scope it is written in.
    $revMakeRow = {
        param($O, $RefFn, $TagText, $TagInk)
        $Ref = $RefFn
        $card = New-Object Windows.Controls.Border
        $card.CornerRadius = 3; $card.Padding = '8,5,8,6'; $card.Margin = '0,0,0,3'
        & $Ref $card 'Background' 'Flat'

        # The same shape as an Advanced row, which is what makes the two pages
        # line up rather than merely use the same numbers.
        $panel = New-Object Windows.Controls.DockPanel
        $panel.LastChildFill = $true

        $cb = New-Object Windows.Controls.CheckBox
        $cb.VerticalAlignment = 'Top'; $cb.Margin = '0,4,8,0'
        $cb.IsChecked = ($O.State -ne 'done')
        $cb.IsEnabled = ($O.State -ne 'done')
        $cb.Tag = $O.Op
        [Windows.Controls.DockPanel]::SetDock($cb, 'Left')
        $null = $panel.Children.Add($cb)

        $stack = New-Object Windows.Controls.StackPanel

        # A name then some chips is a WrapPanel and never a horizontal
        # StackPanel.
        $line = New-Object Windows.Controls.WrapPanel

        $nm = New-Object Windows.Controls.TextBlock
        # 15 and SemiBold, which is what an Advanced row's name is. This was
        # 13.5 and normal weight, and against the toolkit's own list it looked
        # like a different kind of thing.
        $nm.Text = $O.Name; $nm.FontSize = 15; $nm.FontWeight = 'SemiBold'
        # Wrap. A WrapPanel arranges a child at its desired width, and an
        # unwrapped TextBlock desires all of its text.
        $nm.TextWrapping = 'Wrap'
        # The key in a variable rather than an if-expression: [6] reads the
        # literals handed to $Ref to check each is a real theme key.
        $nmInk = 'Text'
        if ($O.State -eq 'done') {
            $nmInk = 'Muted'
            # Struck through and dimmed, exactly as an Advanced row is when its
            # target is not on this machine.
            $nm.TextDecorations = [Windows.TextDecorations]::Strikethrough
        }
        & $Ref $nm 'Foreground' $nmInk
        $null = $line.Children.Add($nm)

        # Only what has already been put back wears a tag. Still in place is
        # what every row is unless it says otherwise.
        $tagEl = $null
        if ($TagText.ContainsKey($O.State)) {
            $tagEl = New-Object Windows.Controls.TextBlock
            # 11 at '6,4,0,0', which is what every tag on an Advanced row is.
            $tagEl.Text = '  ' + $TagText[$O.State]; $tagEl.FontSize = 11; $tagEl.Margin = '6,4,0,0'
            & $Ref $tagEl 'Foreground' $TagInk[$O.State]
            $null = $line.Children.Add($tagEl)
        }

        $cnt = New-Object Windows.Controls.TextBlock
        $cnt.Text = '  ' + $O.CountText
        $cnt.FontSize = 11; $cnt.Margin = '6,4,0,0'
        & $Ref $cnt 'Foreground' 'Muted'
        $null = $line.Children.Add($cnt)

        # The same chip as an Advanced row's, including the face and border that
        # make it read as a button at rest.
        $chip = New-Object Windows.Controls.Border
        $chip.CornerRadius = 4; $chip.Padding = '9,2,9,3'; $chip.Margin = '8,2,0,0'
        $chip.BorderThickness = New-Object Windows.Thickness 1
        $chip.VerticalAlignment = 'Center'
        & $Ref $chip 'BorderBrush' 'BtnBorder'
        & $Ref $chip 'Background' 'BtnBg'
        $chip.Cursor = 'Hand'
        $ct = New-Object Windows.Controls.TextBlock
        $ct.Text = 'Details'; $ct.FontSize = 11
        & $Ref $ct 'Foreground' 'Text'
        $chip.Child = $ct
        $null = $line.Children.Add($chip)
        $null = $stack.Children.Add($line)

        # The always-on description, in the tense this page is written in - see
        # Get-WDRevertDescription.
        $dsc = [string]$O.Desc
        $dscEl = $null
        if ($dsc) {
            $dt = New-Object Windows.Controls.TextBlock
            $dt.Text = $dsc; $dt.FontSize = 13; $dt.TextWrapping = 'Wrap'
            $dt.Margin = '0,2,0,0'
            & $Ref $dt 'Foreground' 'Sub'
            # Built collapsed under Non-verbose rather than skipped, so turning
            # the option back off does not need a rebuild.
            if ($state.Terse) { $dt.Visibility = 'Collapsed' }
            $null = $stack.Children.Add($dt)
            $dscEl = $dt
        }

        # What an unticked row means, said on the row: every option arrives
        # ticked, so clearing one is an edit. The words are the half a colour
        # cannot carry, because here a tick is what will be undone.
        $skip = New-Object Windows.Controls.TextBlock
        $skip.Text = 'Option will not be reverted'
        $skip.FontSize = 12.5; $skip.TextWrapping = 'Wrap'; $skip.Margin = '0,4,0,0'
        $skip.Visibility = 'Collapsed'
        & $Ref $skip 'Foreground' 'Bad'
        $null = $stack.Children.Add($skip)

        $null = $panel.Children.Add($stack)
        $card.Child = $panel

        # Under the row rather than in a dialog: an answer that covers the
        # question while you read it is the wrong shape.
        $detText = [string]$O.DetailText

        $refL = $RefFn
        # A local of this invocation, never $state: this block is invoked with
        # &, so a closure built in it copies these locals.
        $stateHere = $state
        $hold = @{ Det = $null }
        $chip.Add_MouseLeftButtonUp({
            if ($hold.Det -and $hold.Det.Visibility -eq 'Visible') {
                $hold.Det.Visibility = 'Collapsed'
                return
            }
            if (-not $hold.Det) {
                # 12 at LineHeight 18, as the Advanced panel is. No left indent
                # - the stack starts at the name.
                $d = New-Object Windows.Controls.TextBlock
                $d.FontSize = 12; $d.Margin = '0,4,8,7'
                $d.TextWrapping = 'Wrap'; $d.LineHeight = 18
                $d.LineStackingStrategy = 'BlockLineHeight'
                & $refL $d 'Foreground' 'Sub'
                $null = $stack.Children.Add($d)
                $hold.Det = $d
            }
            # Set on every open, not once: under Non-verbose the row is not
            # showing its description, so the panel carries it.
            $body = $detText
            if ($stateHere.Terse -and $dsc) { $body = $dsc + [Environment]::NewLine + [Environment]::NewLine + $detText }
            $hold.Det.Text = $body
            $hold.Det.Visibility = 'Visible'
        }.GetNewClosure())
        $chip.Add_MouseEnter({ & $refL $ct 'Foreground' 'Accent' }.GetNewClosure())
        $chip.Add_MouseLeave({ & $refL $ct 'Foreground' 'Text' }.GetNewClosure())

        # A row with nothing left to decide is inert: no hand cursor and no
        # hover tint, because the tint is this application's signal for "you can
        # act on this".
        if ($O.State -eq 'done') {
            $card.Cursor  = 'Arrow'
            $card.Opacity = 0.6
        } else {
            $card.Cursor = 'Hand'
            $card.Add_MouseEnter({ & $refL $card 'Background' 'RowHover' }.GetNewClosure())
            $card.Add_MouseLeave({ & $refL $card 'Background' 'Flat'     }.GetNewClosure())
        }

        # Clicking the row ticks it, as the Advanced page has always done.
        # IsEnabled does not block a programmatic set, so the row has to test
        # it.
        $card.Add_MouseLeftButtonUp({
            if (-not $args[1].Handled -and $this.Tag.Box.IsEnabled) {
                $this.Tag.Box.IsChecked = -not [bool]$this.Tag.Box.IsChecked
                if ($this.Tag.After) { & $this.Tag.After }
            }
        }.GetNewClosure())
        $card.Tag = @{ Box = $cb; After = $null }

        [pscustomobject]@{
            Opt = $O; Card = $card; Check = $cb; Tag = $O.Op
            # The name line, handed out rather than walked to: reaching it as
            # Card.Child.Children[0] describes the layout rather than the row.
            Line = $line
            # Name is the string $revSortMembers sorts on, so the element needs
            # a name of its own.
            NameEl = $nm; Skip = $skip
            Detail = $hold; DetailText = $detText; Desc = $dsc; DescEl = $dscEl
            Cat = [string]$O.Cat; Name = [string]$O.Name
            Kinds = @($O.Kinds); Count = [int]$O.Count
            # Declared here rather than added later: a pscustomobject takes a
            # new property only through Add-Member.
            GKey = ''
        }
    }

    $revAlphaOf = {
        param([string]$Name)
        if (-not $Name.Length) { return @{ Key = 'zz'; Label = 'Other' } }
        $c = ([string]$Name.Substring(0, 1)).ToUpper()
        if ($c -notmatch '^[A-Z]$') { return @{ Key = 'zz'; Label = 'Other' } }
        foreach ($b in @(@('A','E'), @('F','J'), @('K','O'), @('P','T'), @('U','Z'))) {
            if ($c -ge $b[0] -and $c -le $b[1]) { return @{ Key = $b[0]; Label = "$($b[0]) - $($b[1])" } }
        }
        @{ Key = 'zz'; Label = 'Other' }
    }

    $revGroupsFor = {
        param([string]$Mode)
        $out   = New-Object System.Collections.Generic.List[psobject]
        $index = @{}
        $add = {
            param([string]$Key, [string]$Label, [int]$Rank, $Row)
            if (-not $index.ContainsKey($Key)) {
                $g = [pscustomobject]@{
                    Key = $Key; Label = $Label; Rank = $Rank
                    Members = (New-Object System.Collections.Generic.List[psobject])
                }
                $index[$Key] = $g
                $out.Add($g)
            }
            $index[$Key].Members.Add($Row)
        }
        foreach ($r in $revertRows) {
            switch ($Mode) {
                'status' { & $add $r.Opt.State $REV_STATE_LABEL[$r.Opt.State] $REV_STATE_RANK[$r.Opt.State] $r }
                'kind'   {
                    # An option can touch more than one kind, so it is filed
                    # under its first.
                    $k = [string]@($r.Kinds)[0]
                    & $add $k $k ([int]$REV_KIND_RANK[$k]) $r
                }
                'alpha'  { $a = & $revAlphaOf $r.Name; & $add $a.Key $a.Label 0 $r }
                default  { & $add $r.Cat $r.Cat ([int]$revCatOrder[$r.Cat]) $r }
            }
        }
        if ($Mode -eq 'alpha') { return ,@($out | Sort-Object @{ E = { $_.Key } }) }
        ,@($out | Sort-Object @{ E = { $_.Rank } }, @{ E = { $_.Label } })
    }.GetNewClosure()

    $revSortMembers = {
        param($Members, [string]$Mode)
        switch ($Mode) {
            'selected' { ,@($Members | Sort-Object @{ E = { if ($_.Check.IsChecked) { 0 } else { 1 } } }, @{ E = { $_.Name } }) }
            'most'     { ,@($Members | Sort-Object @{ E = { -1 * $_.Count } }, @{ E = { $_.Name } }) }
            default    { ,@($Members | Sort-Object @{ E = { $_.Name } }) }
        }
    }

    # One pass over the rows. This asked each rail card for its members and each
    # block again, which is why a tick took a second to appear.
    $revPaintCounts = {
        $on = @{}; $can = @{}; $free = @{}; $all = @{}
        $pickedCount = 0
        $chg = 0
        $pageLive = 0; $pageFree = 0
        foreach ($r in $revertRows) {
            $ticked = [bool]$r.Check.IsChecked
            if ($ticked) { $pickedCount++; $chg += [int]$r.Opt.Pending }

            # Marked in the pass already walking every row - two property sets,
            # and only where the answer moved.
            if (-not $ticked -and $r.Check.IsEnabled) {
                & $Ref $r.NameEl 'Foreground' 'Bad'; $r.NameEl.FontWeight = 'Bold'
                $r.Skip.Visibility = 'Visible'
            } elseif ($r.Skip.Visibility -eq 'Visible') {
                & $Ref $r.NameEl 'Foreground' 'Text'; $r.NameEl.FontWeight = 'SemiBold'
                $r.Skip.Visibility = 'Collapsed'
            }
            if ($r.Check.IsEnabled -and $r.Card.Visibility -eq 'Visible') {
                $pageLive++
                if (-not $ticked) { $pageFree++ }
            }
            $k = [string]$r.GKey
            if (-not $k) { continue }
            if (-not $on.ContainsKey($k)) { $on[$k] = 0; $can[$k] = 0; $free[$k] = 0; $all[$k] = 0 }
            # Counted before the enabled test, because a group can be made
            # entirely of rows that refuse a tick.
            $all[$k]++
            if (-not $r.Check.IsEnabled) { continue }
            $can[$k]++
            if ($ticked) { $on[$k]++ }
            elseif ($r.Card.Visibility -eq 'Visible') { $free[$k]++ }
        }
        foreach ($rc in $revRailCards) {
            $k = [string]$rc.Key
            $rcOn  = 0; if ($on.ContainsKey($k))  { $rcOn  = $on[$k] }
            $rcCan = 0; if ($can.ContainsKey($k)) { $rcCan = $can[$k] }
            $rcAll = 0; if ($all.ContainsKey($k)) { $rcAll = $all[$k] }
            # A fraction is about what is left to decide, and grouped by "What
            # is left" there is a group with nothing left and plenty in it.
            if ($rcAll -gt 0 -and $rcCan -eq 0) {
                $rc.Num.Text = "$rcAll"
                & $Ref $rc.Num 'Foreground' 'Ok'
            } else {
                $rc.Num.Text = "$rcOn/$rcCan"
                if     ($rcCan -eq 0)     { & $Ref $rc.Num 'Foreground' 'Muted' }
                elseif ($rcOn -eq $rcCan) { & $Ref $rc.Num 'Foreground' 'Ok' }
                else                      { & $Ref $rc.Num 'Foreground' 'Accent' }
            }
            $rc.Card.Opacity = $(if ($rc.Live) { 1.0 } else { 0.45 })
        }
        foreach ($b in $revBlocks) {
            $k = [string]$b.Key
            $anyFree = $false; if ($free.ContainsKey($k)) { $anyFree = ($free[$k] -gt 0) }
            # A group with nothing to take reads "Select all" rather than
            # offering to clear a selection that is not there.
            $b.SelAll.Content   = $(if ($anyFree -or -not $b.VisEnabled) { 'Select all' } else { 'Select none' })
            $b.SelAll.IsEnabled = [bool]$b.VisEnabled
        }
        $ui.BtnRevSelectAll.Content   = $(if ($pageFree -or -not $pageLive) { 'Select all' } else { 'Select none' })
        $ui.BtnRevSelectAll.IsEnabled = [bool]$pageLive
        $ui.TxtRevertTally.Text = "$pickedCount of $($revState.Tickable) options selected, $chg change(s) to put back."
        $ui.BtnRevertRun.IsEnabled = [bool]$pickedCount
    }.GetNewClosure()

    # Offsets measured once into a table and thrown away by anything that moves
    # a heading.
    $revSpyRun = {
        if (-not $revBlocks.Count) { return }
        if ($ui.PageRevert.Visibility -ne 'Visible') { return }
        if ($ui.RevScroll.ActualHeight -le 0) { return }
        if (-not $revSpy.Offsets) {
            $ui.RevScroll.UpdateLayout()
            $t = @{}
            foreach ($b in $revBlocks) {
                try {
                    $p = $b.Block.TransformToAncestor($ui.RevScroll.Content).Transform((New-Object Windows.Point 0, 0))
                    $t[$b.Key] = [double]$p.Y
                } catch { $t[$b.Key] = 0.0 }
            }
            $revSpy.Offsets = $t
        }
        $y = [double]$ui.RevScroll.VerticalOffset + 12
        $best = ''
        foreach ($b in $revBlocks) {
            if ($b.Block.Visibility -ne 'Visible') { continue }
            if ($revSpy.Offsets[$b.Key] -le $y) { $best = $b.Key }
        }
        if (-not $best) {
            foreach ($b in $revBlocks) { if ($b.Block.Visibility -eq 'Visible') { $best = $b.Key; break } }
        }
        if ($best -eq $revSpy.On) { return }
        $revSpy.On = $best
        foreach ($rc in $revRailCards) {
            $lit = ($rc.Key -eq $best)
            $rc.Lit = $lit
            & $Ref $rc.Card 'Background' $(if ($lit) { 'CardSel' } else { 'Flat' })
            & $Ref $rc.Label 'Foreground' $(if ($lit) { 'Text' } else { 'Sub' })
        }
    }.GetNewClosure()

    # What is actually narrowing the list, which the button could never say:
    # "Filter (3)" tells you how many, never which.
    $revChipFor = {
        param([string]$Group, [string]$Value, [string]$Text, $Ctx)
        $b = New-Object Windows.Controls.Border
        $b.CornerRadius = 9; $b.Padding = '9,1,8,2'; $b.Margin = '0,0,6,0'
        $b.BorderThickness = New-Object Windows.Thickness 1
        & $Ref $b 'BorderBrush' 'Line'
        & $Ref $b 'Background' 'Card'
        $b.Cursor = 'Hand'
        $b.ToolTip = 'Drop this filter'
        $t = New-Object Windows.Controls.TextBlock
        $t.Text = "$Text  x"; $t.FontSize = 11.5
        & $Ref $t 'Foreground' 'Sub'
        $b.Child = $t
        $b.Tag = @{ G = $Group; V = $Value; Ctx = $Ctx }
        $b.Add_MouseLeftButtonUp({
            $t2 = $this.Tag
            $c  = $t2.Ctx
            foreach ($fb in $c.Boxes) {
                if ($fb.Group -eq $t2.G -and $fb.Value -eq $t2.V) { $fb.Box.IsChecked = $false }
            }
            $null = $c.Sel[$t2.G].Remove($t2.V)
            if ($t2.G -eq 'View' -and -not $c.Sel['View'].Count) { $c.Snap.Ids = $null }
            if ($c.Fx.Pairs)  { & $c.Fx.Pairs }
            if ($c.Fx.Filter) { & $c.Fx.Filter }
        }.GetNewClosure())
        $b
    }.GetNewClosure()

    $revChipCtx = @{ Boxes = $revFilterBoxes; Sel = $revFilterSel; Snap = $revViewSnap; Fx = $revFx }

    # Two columns inside a full-width block, re-filled with what is visible
    # rather than everything.
    $revFillBlock = {
        param($B, $Members)
        $B.ColL.Children.Clear()
        $B.ColR.Children.Clear()
        $list = @($Members)
        $one = ($list.Count -lt 4)
        $gap = $(if ($one) { 0 } else { 30 })
        $B.Grid.ColumnDefinitions[1].Width = New-Object System.Windows.GridLength -ArgumentList $gap, ([System.Windows.GridUnitType]::Pixel)
        if ($one) {
            $B.Grid.ColumnDefinitions[2].Width = New-Object System.Windows.GridLength -ArgumentList 0, ([System.Windows.GridUnitType]::Pixel)
        } else {
            $B.Grid.ColumnDefinitions[2].Width = New-Object System.Windows.GridLength -ArgumentList 1, ([System.Windows.GridUnitType]::Star)
        }
        $half = [Math]::Ceiling($list.Count / 2)
        for ($i = 0; $i -lt $list.Count; $i++) {
            if ($one -or $i -lt $half) { $null = $B.ColL.Children.Add($list[$i].Card) }
            else                       { $null = $B.ColR.Children.Add($list[$i].Card) }
        }
        $B.VisEnabled = @($list | Where-Object { $_.Check.IsEnabled }).Count
    }

    # OR within a group and AND across groups.
    $revApplyFilter = {
        $needle = ([string]$ui.RevFind.Text).Trim()
        foreach ($r in $revertRows) {
            $ok = $true
            if ($ok -and $revFilterSel['State'].Count) { $ok = $revFilterSel['State'].Contains([string]$r.Opt.State) }
            if ($ok -and $revFilterSel['Cat'].Count)   { $ok = $revFilterSel['Cat'].Contains([string]$r.Cat) }
            if ($ok -and $revFilterSel['Kind'].Count) {
                $hit = $false
                foreach ($k in $r.Kinds) { if ($revFilterSel['Kind'].Contains([string]$k)) { $hit = $true } }
                $ok = $hit
            }
            if ($ok -and $revFilterSel['View'].Count) {
                $was = $false
                if ($revViewSnap.Ids) { $was = $revViewSnap.Ids.Contains([string]$r.Opt.Id) }
                $hit = $false
                if ($revFilterSel['View'].Contains('ticked')   -and $was)        { $hit = $true }
                if ($revFilterSel['View'].Contains('unticked') -and (-not $was)) { $hit = $true }
                $ok = $hit
            }
            if ($ok -and $needle) {
                $ok = ($r.Name -like "*$needle*") -or ($r.Cat -like "*$needle*") -or
                      ($r.Desc -like "*$needle*") -or ($r.DetailText -like "*$needle*")
            }
            $r.Card.Visibility = $(if ($ok) { 'Visible' } else { 'Collapsed' })
        }
        $visBy = @{}
        $shown = 0
        foreach ($r in $revertRows) {
            if ($r.Card.Visibility -ne 'Visible') { continue }
            $shown++
            $k = [string]$r.GKey
            if (-not $k) { continue }
            if (-not $visBy.ContainsKey($k)) { $visBy[$k] = 0 }
            $visBy[$k]++
        }
        foreach ($b in $revBlocks) {
            $n = 0; if ($visBy.ContainsKey([string]$b.Key)) { $n = $visBy[[string]$b.Key] }
            $b.Block.Visibility = $(if ($n) { 'Visible' } else { 'Collapsed' })
            & $revFillBlock $b @($b.Ordered | Where-Object { $_.Card.Visibility -eq 'Visible' })
        }
        # A rail entry the filter has emptied is dimmed, never removed.
        foreach ($rc in $revRailCards) {
            $rc.Live = [bool]($visBy.ContainsKey([string]$rc.Key) -and $visBy[[string]$rc.Key])
        }
        $ui.TxtRevCount.Text = $(if ($shown -eq $revertRows.Count) { "$($revertRows.Count) options" } else { "$shown of $($revertRows.Count) options" })

        $ui.RevFilterChips.Children.Clear()
        $facets = 0
        foreach ($fg in $REV_FILTER_GROUPS) {
            foreach ($v in @($revFilterSel[$fg])) {
                $facets++
                $lbl = $v
                if ($fg -eq 'State') { $lbl = $REV_STATE_LABEL[$v] }
                if ($fg -eq 'View')  { $lbl = $(if ($v -eq 'ticked') { 'Selected only' } else { 'Unselected only' }) }
                $null = $ui.RevFilterChips.Children.Add((& $revChipFor $fg $v $lbl $revChipCtx))
            }
        }
        $ui.RevFilterChips.Visibility = $(if ($facets) { 'Visible' } else { 'Collapsed' })
        $ui.BtnRevFilter.Content = $(if ($facets) { "Filter ($facets)" } else { 'Filter' })

        & $revPaintCounts
        $revSpy.Offsets = $null
        $revSpy.On = ''
        & $revSpyRun
    }.GetNewClosure()
    $revFx.Filter = $revApplyFilter

    # Shared, because Collapse all does exactly this to every group and a second
    # copy of "what collapsed looks like" is how the sign and the visibility
    # disagree.
    $revSetGroupOpen = {
        param($Body, $Btn, [bool]$Open, $GroupRows)
        $Body.Visibility = $(if ($Open) { 'Visible' } else { 'Collapsed' })
        $Btn.Content = $(if ($Open) { '-' } else { '+' })
        $Btn.ToolTip = $(if ($Open) { 'Collapse this group' } else { 'Expand this group' })
        if (-not $Open -and $GroupRows) {
            foreach ($r in @($GroupRows)) {
                if ($r.Detail -and $r.Detail.Det) { $r.Detail.Det.Visibility = 'Collapsed' }
            }
        }
    }

    $revApplyOrder = {
        # A child of a panel cannot be added to another - WPF refuses with
        # "already the logical child of another element".
        foreach ($r in $revertRows) {
            if ($r.Card.Parent -is [Windows.Controls.Panel]) { $r.Card.Parent.Children.Remove($r.Card) }
        }
        $ui.RevList.Children.Clear()
        $ui.RevIndexPanel.Children.Clear()
        $revBlocks.Clear()
        $revRailCards.Clear()

        foreach ($g in (& $revGroupsFor $revState.Group)) {
            $block = New-Object Windows.Controls.StackPanel
            $block.Margin = '0,0,0,10'

            # 16 SemiBold over '0,18,0,6', which is what a category heading on
            # the Advanced page is.
            $hp = New-Object Windows.Controls.WrapPanel
            $hp.Margin = '0,18,0,6'
            $ht = New-Object Windows.Controls.TextBlock
            $ht.Text = [string]$g.Label; $ht.FontSize = 16; $ht.FontWeight = 'SemiBold'
            $ht.VerticalAlignment = 'Center'; $ht.TextWrapping = 'Wrap'
            & $Ref $ht 'Foreground' 'Text'
            $null = $hp.Children.Add($ht)

            $body = New-Object Windows.Controls.Grid
            foreach ($w in @((New-Object System.Windows.GridLength -ArgumentList 1, ([System.Windows.GridUnitType]::Star)),
                             (New-Object System.Windows.GridLength -ArgumentList 30, ([System.Windows.GridUnitType]::Pixel)),
                             (New-Object System.Windows.GridLength -ArgumentList 1, ([System.Windows.GridUnitType]::Star)))) {
                $cd = New-Object Windows.Controls.ColumnDefinition
                $cd.Width = $w
                $body.ColumnDefinitions.Add($cd)
            }
            $colL = New-Object Windows.Controls.StackPanel
            $colR = New-Object Windows.Controls.StackPanel
            [Windows.Controls.Grid]::SetColumn($colL, 0)
            [Windows.Controls.Grid]::SetColumn($colR, 2)
            $null = $body.Children.Add($colL)
            $null = $body.Children.Add($colR)

            # The heading itself is inert: with a collapse control on the same
            # line, clicking the name is as likely to mean "fold this away".
            $tg = New-Object Windows.Controls.Button
            $tg.Content = '-'; $tg.Width = 24; $tg.Padding = '0,1'; $tg.FontSize = 13
            $tg.FontWeight = 'Bold'; $tg.Margin = '10,0,0,0'; $tg.VerticalAlignment = 'Center'
            $tg.ToolTip = 'Collapse this group'
            $tg.Tag = @{ Body = $body; Set = $revSetGroupOpen; Spy = $revSpy; Run = $revSpyRun }
            $tg.Add_Click({
                $t = $this.Tag
                & $t.Set $t.Body $this (-not ($t.Body.Visibility -eq 'Visible')) $t.Rows
                # Folding moves every heading below it, so the measured offsets
                # are stale.
                $t.Spy.Offsets = $null
                $t.Spy.On = ''
                & $t.Run
            }.GetNewClosure())
            $null = $hp.Children.Add($tg)

            $sa = New-Object Windows.Controls.Button
            $sa.Content = 'Select all'; $sa.FontSize = 11.5; $sa.Padding = '8,2'
            $sa.Margin = '8,0,0,0'; $sa.VerticalAlignment = 'Center'; $sa.MinWidth = 84
            $sa.ToolTip = 'Selects every option in this group that is on screen and can be reverted. Press again to clear them.'
            $sa.Tag = @{ Members = $g.Members; Paint = $revPaintCounts; Show = $revShowNow }
            $sa.Add_Click({
                $t = $this.Tag
                $vis = @($t.Members | Where-Object { $_.Card.Visibility -eq 'Visible' -and $_.Check.IsEnabled })
                if (-not $vis.Count) { return }
                $want = @($vis | Where-Object { -not $_.Check.IsChecked }).Count -gt 0
                foreach ($r in $vis) { $r.Check.IsChecked = $want }
                & $t.Show
                & $t.Paint
            }.GetNewClosure())
            $null = $hp.Children.Add($sa)
            $null = $block.Children.Add($hp)

            $rule = New-Object Windows.Controls.Border
            $rule.Height = 1; $rule.Margin = '0,0,0,4'; $rule.Opacity = 0.55
            & $Ref $rule 'Background' 'Line'
            $null = $block.Children.Add($rule)

            $null = $block.Children.Add($body)
            $null = $ui.RevList.Children.Add($block)
            # Plain assignment, never @(). $revSortMembers ends in ,@(...), and
            # wrapping gives one element holding the whole list.
            $sorted = & $revSortMembers $g.Members $revState.Sort
            $rec = [pscustomobject]@{
                Key = $g.Key; Group = $g; Block = $block; Body = $body
                Grid = $body; ColL = $colL; ColR = $colR
                Ordered = $sorted
                VisEnabled = 0; Toggle = $tg; SelAll = $sa
            }
            foreach ($m in $rec.Ordered) { $m.GKey = [string]$g.Key }
            # After $sorted exists: folding has to reach this group's rows to
            # shut their Details panels.
            $tg.Tag.Rows = $sorted
            $revBlocks.Add($rec)

            # An index into the list, never a router. Clicking scrolls.
            $c = New-Object Windows.Controls.Border
            $c.CornerRadius = 3; $c.Padding = '8,4,8,5'; $c.Margin = '0,0,0,2'; $c.Cursor = 'Hand'
            & $Ref $c 'Background' 'Flat'
            $dp = New-Object Windows.Controls.DockPanel
            $num = New-Object Windows.Controls.TextBlock
            $num.FontSize = 11.5; $num.Margin = '6,0,0,0'
            & $Ref $num 'Foreground' 'Accent'
            [Windows.Controls.DockPanel]::SetDock($num, 'Right')
            $null = $dp.Children.Add($num)
            $lbl = New-Object Windows.Controls.TextBlock
            $lbl.Text = [string]$g.Label; $lbl.FontSize = 12.5; $lbl.TextTrimming = 'CharacterEllipsis'
            & $Ref $lbl 'Foreground' 'Sub'
            $null = $dp.Children.Add($lbl)
            $c.Child = $dp
            $null = $ui.RevIndexPanel.Children.Add($c)
            $entry = [pscustomobject]@{ Key = $g.Key; Group = $g; Card = $c; Num = $num; Label = $lbl
                                        Block = $block; Live = $true; Lit = $false }
            $revRailCards.Add($entry)

            $refL = $Ref
            $scr  = $ui.RevScroll
            $blk  = $block
            $ent  = $entry
            $c.Add_MouseLeftButtonUp({
                try {
                    $p = $blk.TransformToAncestor($scr.Content).Transform((New-Object Windows.Point 0, 0))
                    $scr.ScrollToVerticalOffset($p.Y)
                } catch { }
            }.GetNewClosure())
            # The highlighted card keeps its highlight rather than dimming to a
            # hover tint as the pointer crosses it.
            $c.Add_MouseEnter({ if (-not $ent.Lit) { & $refL $ent.Card 'Background' 'RowHover' } }.GetNewClosure())
            $c.Add_MouseLeave({ if (-not $ent.Lit) { & $refL $ent.Card 'Background' 'Flat' } }.GetNewClosure())
        }

        # Back to the top: the old offset is a position in an arrangement that
        # no longer exists.
        $ui.RevScroll.ScrollToVerticalOffset(0)
        $revSpy.Offsets = $null
        $revSpy.On = ''
        & $revApplyFilter
    }.GetNewClosure()

    $revAddFilterSection = {
        param([string]$Group, [string]$Heading, $Entries)
        if (-not @($Entries).Count) { return }
        $h = New-Object Windows.Controls.TextBlock
        $h.Text = $Heading.ToUpper(); $h.FontSize = 11; $h.FontWeight = 'SemiBold'
        $h.Margin = '0,10,0,4'
        & $Ref $h 'Foreground' 'Muted'
        $null = $ui.RevFilterPanel.Children.Add($h)
        foreach ($e in @($Entries)) {
            $box = New-Object Windows.Controls.CheckBox
            $box.Content = $e.Label; $box.FontSize = 12.5; $box.Margin = '0,2,0,2'
            # WPF's default CheckBox foreground is the system control-text
            # brush, which is black whatever the Windows theme says.
            & $Ref $box 'Foreground' 'Text'
            $box.Tag = @{ G = $Group; V = [string]$e.Key; Sel = $revFilterSel; Fx = $revFx
                          Snap = $revViewSnap; Rows = $revertRows }
            $box.Add_Click({
                $t = $this.Tag
                if ($this.IsChecked) {
                    if (-not $t.Sel[$t.G].Contains($t.V)) { $t.Sel[$t.G].Add($t.V) }
                    if ($t.G -eq 'View') {
                        $ids = New-Object System.Collections.Generic.List[string]
                        foreach ($r in $t.Rows) { if ($r.Check.IsChecked) { $ids.Add([string]$r.Opt.Id) } }
                        $t.Snap.Ids = $ids
                    }
                } else {
                    $null = $t.Sel[$t.G].Remove($t.V)
                    if ($t.G -eq 'View' -and -not $t.Sel['View'].Count) { $t.Snap.Ids = $null }
                }
                if ($t.Fx.Pairs)  { & $t.Fx.Pairs }
                if ($t.Fx.Filter) { & $t.Fx.Filter }
            }.GetNewClosure())
            $null = $ui.RevFilterPanel.Children.Add($box)
            $revFilterBoxes.Add([pscustomobject]@{ Group = $Group; Value = [string]$e.Key; Box = $box })
        }
    }.GetNewClosure()

    # Selected only and Unselected only together are every row, which is what no
    # filter already says.
    $revSyncPairs = {
        $a = $null; $b = $null
        foreach ($fb in $revFilterBoxes) {
            if ($fb.Group -eq 'View' -and $fb.Value -eq 'ticked')   { $a = $fb.Box }
            if ($fb.Group -eq 'View' -and $fb.Value -eq 'unticked') { $b = $fb.Box }
        }
        if ($a -and $b) {
            $a.IsEnabled = -not [bool]$b.IsChecked
            $b.IsEnabled = -not [bool]$a.IsChecked
        }
    }.GetNewClosure()
    $revFx.Pairs = $revSyncPairs

    $buildRevert = {
        $revertRows.Clear()
        $revBlocks.Clear()
        $revRailCards.Clear()
        $ui.RevList.Children.Clear()
        $ui.RevIndexPanel.Children.Clear()
        $ui.RevFilterPanel.Children.Clear()
        $revFilterBoxes.Clear()
        # A facet naming a category this scope does not have would hide every
        # row with nothing on screen saying why.
        foreach ($fg in $REV_FILTER_GROUPS) { $revFilterSel[$fg].Clear() }
        $revViewSnap.Ids = $null
        $ui.RevertRunRow.Children.Clear()

        # Read fresh: the "already set" probe caches every key it touches for
        # the life of the process, which is right for a window build and wrong
        # here.
        $revClock = [Diagnostics.Stopwatch]::StartNew()
        $revWhole = [Diagnostics.Stopwatch]::StartNew()
        & $revSay 'Looking for past runs on this machine...' 0.04
        Clear-WDRegistryProbeCache
        $runs = @(Get-WDPastRuns -Root (Get-WDSession).Root)
        # Kept for $startRevert, which turns the ticked options into one
        # rollback invocation per run and needs each run's script path.
        $revertPick.Runs = $runs
        # Started the moment the run list exists and collected about a second
        # and a half later, at the point the page wants it.
        $removedJob = Start-WDRemovedScan -ModulePath $ModulePath -Runs $runs
        $revBuilt.Read = [int]$revClock.ElapsedMilliseconds; $revClock.Restart()

        if (-not @($runs | Where-Object { $_.Id -eq [string]$revertPick.Sel }).Count) { $revertPick.Sel = 'all' }
        $sel = [string]$revertPick.Sel

        # The picker reads like the preset row on Advanced because it is the
        # same gesture: one standing choice above a list it governs.
        $pickRef = $revertPick
        $rowRef  = $ui.RevertRunRow
        $refRef  = $Ref
        $mkPick = {
            param([string]$Key, [string]$Label, [string]$Tip, [bool]$On)
            # A local of this invocation: $pickRef is captured by this block's
            # own closure, which puts it at that closure's module scope.
            $pick = $pickRef
            $b = New-Object Windows.Controls.Button
            $b.Content = $Label; $b.Padding = '10,3'; $b.FontSize = 12.5
            $b.Margin = '0,0,6,0'; $b.ToolTip = $Tip
            if ($On) { $b.FontWeight = 'SemiBold'; & $refRef $b 'BorderBrush' 'Accent' }
            $b.Tag = $Key
            $b.Add_Click({
                if ($pick.Sel -eq [string]$this.Tag) { return }
                $pick.Sel = [string]$this.Tag
                & $pick.Build
            }.GetNewClosure())
            $null = $rowRef.Children.Add($b)
        }.GetNewClosure()
        & $mkPick 'all' "All runs ($($runs.Count))" 'Every apply this machine has a record of, undone together.' ($sel -eq 'all')
        foreach ($run in $runs) {
            $lbl = $run.When.ToString('d MMM yyyy, HH:mm')
            $tip = "Run $($run.Id) - $($run.Removed) removed, $($run.Changed) changed."
            if (-not $run.LogPresent) { $tip += ' Its log has been deleted, so nothing from it can be put back.' }
            & $mkPick ([string]$run.Id) $lbl $tip ($sel -eq [string]$run.Id)
        }
        $ui.RevertRunScroll.Visibility = $(if ($runs.Count) { 'Visible' } else { 'Collapsed' })

        # One run selected is that run's own plan with its own previous values;
        # All is the combined one, walked oldest first.
        $scope = @($runs)
        if ($sel -ne 'all') { $scope = @($runs | Where-Object { $_.Id -eq $sel }) }
        # The manifest, so a step reads "Office telemetry" under "Privacy"
        # rather than "office-telemetry" under "Other".
        $planNames = New-Object System.Collections.Generic.List[psobject]
        # And the one-line description each row carries, in the tense this page
        # is written in.
        $revDesc = @{}
        foreach ($cat in $Categories) {
            $cn = [string](Get-Prop $cat 'name' 'Other')
            foreach ($item in @($cat.items)) {
                $planNames.Add([pscustomobject]@{
                    Id = [string]$item.id; Name = [string](Get-Prop $item 'name' ([string]$item.id)); Category = $cn })
                $revDesc[[string]$item.id] = [string](Get-WDRevertDescription -Desc ([string](Get-Prop $item 'desc' '')))
            }
        }
        $plan = $null
        if (@($scope | Where-Object { $_.Journal }).Count) {
            & $revSay $(if (@($scope).Count -eq 1) { 'Reading what that run changed...' }
                        else { "Reading what $(@($scope | Where-Object { $_.Journal }).Count) runs changed..." }) 0.12
            try { $plan = Get-WDCombinedUndoPlan -Runs $scope -Items $planNames } catch { }
        }
        $revBuilt.Plan = [int]$revClock.ElapsedMilliseconds; $revClock.Restart()

        # The options, from three sources into one list - so the filter, the
        # grouping, the sort, and both Select alls speak for them all.
        $opts = New-Object System.Collections.Generic.List[psobject]

        $byOpt = [ordered]@{}
        foreach ($s in @($plan.Steps)) {
            $key = [string]$s.Id
            if (-not $byOpt.Contains($key)) {
                $byOpt[$key] = [pscustomobject]@{
                    Id = $key; Name = [string]$s.ItemName; Cat = [string]$s.Category
                    Steps = (New-Object System.Collections.Generic.List[psobject])
                    Kinds = (New-Object System.Collections.Generic.List[string])
                    Runs  = @{}
                    Todo = 0; Done = 0; Unknown = 0; State = 'done'
                }
            }
            $byOpt[$key].Steps.Add($s)
            $byOpt[$key].Runs[[string]$s.Run] = $true
            $k = Get-WDUndoStepKind -Step $s
            if (-not $byOpt[$key].Kinds.Contains($k)) { $byOpt[$key].Kinds.Add($k) }
        }
        $seenOpt = 0
        $totOpt = @($byOpt.Values).Count
        foreach ($o in @($byOpt.Values)) {
            $seenOpt++
            # Named as it goes, like the rollback window's splash: this is the
            # part that reads the machine once per change.
            & $revSay "Checking what is still in place - $seenOpt of ${totOpt}: $($o.Name)" `
                      (0.20 + 0.38 * ($seenOpt / [Math]::Max(1, $totOpt)))
            $lines = New-Object System.Collections.Generic.List[string]
            foreach ($s in $o.Steps) {
                switch (Get-WDUndoStepState -Step $s) {
                    'todo'  { $o.Todo++ }
                    'done'  { $o.Done++ }
                    default { $o.Unknown++ }
                }
                $lines.Add('- ' + (Get-WDUndoStepText -Step $s))
            }
            # An option is outstanding if any one of its changes is still in
            # place: a half-undone option is not undone.
            if ($o.Todo)        { $o.State = 'todo' }
            elseif ($o.Unknown) { $o.State = 'unknown' }
            else                { $o.State = 'done' }
            $n = $o.Steps.Count
            $ct = "$n change" + $(if ($n -eq 1) { '' } else { 's' })
            if ($sel -eq 'all' -and @($o.Runs.Keys).Count -gt 1) { $ct += " across $(@($o.Runs.Keys).Count) runs" }
            $opts.Add([pscustomobject]@{
                Id = $o.Id; Name = $o.Name; Cat = $o.Cat; State = $o.State
                Desc = [string]$revDesc[[string]$o.Id]
                Kinds = @($o.Kinds); Count = $n; CountText = $ct
                # What pressing the button would do for this option, counted
                # once here rather than by asking the machine again inside the
                # click handler.
                Pending = ($o.Todo + $o.Unknown)
                DetailText = ($lines -join [Environment]::NewLine)
                Op = @{ Kind = 'option'; Id = $o.Id; Runs = @($o.Runs.Keys); Name = $o.Name }
            })
        }

        $revBuilt.States = [int]$revClock.ElapsedMilliseconds; $revClock.Restart()

        # Only what is actually present - listing inactive ones would be a page
        # of things that are not happening.
        & $revSay 'Checking what this toolkit left running...' 0.62
        foreach ($e in @(Get-WDRecurringEffects | Where-Object { $_.Present })) {
            $det = [string]$e.Detail
            if ([string]$e.Overhead) { $det += [Environment]::NewLine + 'Cost: ' + [string]$e.Overhead }
            $opts.Add([pscustomobject]@{
                Id = "effect:$($e.Id)"; Name = [string]$e.Name; Cat = 'Recurring effects'
                # Its own words, untouched and in the present: a recurring
                # effect is described by what it is still doing.
                Desc = [string]$e.Detail
                State = 'todo'; Kinds = @('Recurring effects'); Count = 1
                CountText = 'still running'; Pending = 1
                DetailText = $det
                Op = @{ Kind = 'effect'; Id = $e.Id; Name = "Remove: $($e.Name)" }
            })
        }

        # Nothing puts a program back from a journal, so these are their own
        # kind of row.
        & $revSay 'Checking what was uninstalled, and what could be put back...' 0.68
        foreach ($item in @(Receive-WDRemovedScan -Job $removedJob -Runs $runs)) {
            $can = ($item.Feasibility -ne 'store' -and $item.Feasibility -ne 'done')
            $det = "Removed $($item.When.ToString('d MMM yyyy')) - $($item.Kind)."
            if ([string]$item.Reason) { $det += [Environment]::NewLine + [string]$item.Reason }
            $opts.Add([pscustomobject]@{
                Id = "reinstall:$($item.Name)"; Name = [string]$item.Name; Cat = 'Reinstall removed software'
                # Past tense already, and authored rather than derived: this row
                # is not a manifest item.
                Desc = "Uninstalled on $($item.When.ToString('d MMM yyyy'))." +
                       $(if ($can) { ' This can put it back.' }
                         else { ' Nothing here can put it back - see Details.' })
                State = $(if ($can) { 'todo' } else { 'done' })
                Kinds = @('Installed programs'); Count = 1
                CountText = 'one program'; Pending = 1
                DetailText = $det
                Op = @{ Kind = 'reinstall'; Item = $item; Name = "Reinstall $($item.Name)" }
            })
        }

        $revBuilt.Extra = [int]$revClock.ElapsedMilliseconds; $revClock.Restart()

        # Category order is first-seen, which puts the plan's own categories in
        # manifest order and the two synthetic ones at the end.
        $revCatOrder.Clear()
        $seenCat = 0
        foreach ($o in $opts) {
            if (-not $revCatOrder.ContainsKey([string]$o.Cat)) { $revCatOrder[[string]$o.Cat] = $seenCat; $seenCat++ }
        }

        & $revSay "Building the list - $($opts.Count) option(s)..." 0.88
        $tagText = @{ done = 'already back'; unknown = 'cannot tell from here' }
        $tagInk  = @{ done = 'Ok';           unknown = 'Muted' }
        foreach ($o in $opts) { $revertRows.Add((& $revMakeRow $o $Ref $tagText $tagInk)) }

        # The tick is what the person asked for and the counts are the
        # consequence, so the tick is drawn first.
        $showRef  = $revShowNow
        $paintRef = $revPaintCounts
        $afterTick = { & $showRef; & $paintRef }.GetNewClosure()
        foreach ($r in $revertRows) {
            $r.Check.Add_Click($afterTick)
            # The same block the box runs, handed to the row so a click anywhere
            # does the whole gesture rather than half of it.
            if ($r.Card.Tag) { $r.Card.Tag.After = $afterTick }
        }
        $revState.Tickable = @($revertRows | Where-Object { $_.Check.IsEnabled }).Count
        $revBuilt.Rows = [int]$revClock.ElapsedMilliseconds; $revClock.Restart()

        # The heading, which says what the scope adds up to.
        $tSteps = 0; $tTodo = 0; $tDone = 0; $tHuh = 0
        foreach ($o in $opts) {
            $tSteps += [int]$o.Count
            if ($o.State -eq 'todo')    { $tTodo += [int]$o.Pending }
            elseif ($o.State -eq 'unknown') { $tHuh += [int]$o.Pending }
            else { $tDone += [int]$o.Count }
        }
        $ui.TxtRevertHead.Text = $(if ($sel -eq 'all') {
            'Changes from every run on this machine'
        } else {
            $one = @($runs | Where-Object { $_.Id -eq $sel })
            if ($one.Count) { "Changes from the run of $($one[0].When.ToString('d MMMM yyyy')) at $($one[0].When.ToString('HH:mm'))" }
            else { 'Changes from one run' }
        })
        $bits = New-Object System.Collections.Generic.List[string]
        if ($opts.Count) {
            $bits.Add("$($opts.Count) option(s), $tSteps change(s)")
            if ($tTodo) { $bits.Add("$tTodo still in place") }
            if ($tDone) { $bits.Add("$tDone already back") }
            if ($tHuh)  { $bits.Add("$tHuh could not be checked from here") }
        }
        $noLog = @($scope | Where-Object { -not $_.LogPresent })
        $head = $(if ($bits.Count) { ($bits -join ', ') + '.' } else {
            if ($runs.Count) { 'Nothing here can be put back - none of these runs still has its journal.' }
            else { 'No previous runs found on this machine. Preview runs are not listed, because they change nothing.' }
        })
        $head += ' Nothing happens until you press Revert selected.'
        if ($noLog.Count) {
            $head += $(if ($noLog.Count -eq 1) {
                " The run from $($noLog[0].When.ToString('d MMM yyyy, HH:mm')) had its log deleted, so nothing it changed can be put back."
            } else {
                " $($noLog.Count) of these runs had their logs deleted, so nothing they changed can be put back."
            })
        }
        $ui.TxtRevertSub.Text = $head
        & $Ref $ui.TxtRevertSub 'Foreground' $(if ($noLog.Count) { 'Warn' } else { 'Sub' })

        # The filter panel, rebuilt because its entries are this scope's.
        $stateEntries = New-Object System.Collections.Generic.List[psobject]
        foreach ($k in @('todo', 'unknown', 'done')) {
            if (@($revertRows | Where-Object { $_.Opt.State -eq $k }).Count) {
                $stateEntries.Add([pscustomobject]@{ Key = $k; Label = $REV_STATE_LABEL[$k] })
            }
        }
        & $revAddFilterSection 'State' 'What is left' $stateEntries
        & $revAddFilterSection 'View' 'View' @(
            [pscustomobject]@{ Key = 'ticked';   Label = 'Selected only' }
            [pscustomobject]@{ Key = 'unticked'; Label = 'Unselected only' }
        )
        $kindEntries = New-Object System.Collections.Generic.List[psobject]
        foreach ($k in (@($revertRows | ForEach-Object { $_.Kinds } | Select-Object -Unique) | Sort-Object @{ E = { [int]$REV_KIND_RANK[$_] } })) {
            $kindEntries.Add([pscustomobject]@{ Key = [string]$k; Label = [string]$k })
        }
        & $revAddFilterSection 'Kind' 'Kind of change' $kindEntries
        $catEntries = New-Object System.Collections.Generic.List[psobject]
        foreach ($k in (@($revertRows | ForEach-Object { $_.Cat } | Select-Object -Unique) | Sort-Object @{ E = { [int]$revCatOrder[$_] } })) {
            $catEntries.Add([pscustomobject]@{ Key = [string]$k; Label = [string]$k })
        }
        & $revAddFilterSection 'Cat' 'Category' $catEntries
        & $revSyncPairs

        $ui.RevFind.Text = ''
        $ui.BtnRevFilter.Content = 'Filter'
        # Last, so the bar reaches the end rather than stopping at the step
        # before it and vanishing.
        & $revSay "Arranging the page - $($revertRows.Count) option(s)..." 1.0
        & $revApplyOrder
        $revBuilt.Layout = [int]$revClock.ElapsedMilliseconds
        $revBuilt.Ms = [int]$revWhole.ElapsedMilliseconds
        Write-WDLog ("Revert page built in {0} ms - read {1}, plan {2}, states {3}, extra {4}, rows {5}, layout {6}" -f `
                     $revBuilt.Ms, $revBuilt.Read, $revBuilt.Plan, $revBuilt.States,
                     $revBuilt.Extra, $revBuilt.Rows, $revBuilt.Layout) -Level Debug
    }
    # Behind the same overlay the Advanced build uses: ten seconds of reading
    # the machine with the old page still up reads as a click that missed.
    $revCache = @{ Built = $false; Sel = '' }
    $revertBuildBusy = {
        if ($revCache.Built -and $revCache.Sel -eq [string]$revertPick.Sel) { return }
        $veil = $win.Tag.Busy
        if ($veil) { & $veil.Show 'Reading past runs' }
        try {
            & $buildRevert
            $revCache.Built = $true
            $revCache.Sel   = [string]$revertPick.Sel
        } finally { if ($veil) { & $veil.Hide } }
    }
    # Closed after the fact, and pointed at the wrapper rather than the builder,
    # so the picker goes behind the overlay too.
    $revertPick.Build = $revertBuildBusy

    # Pumps one batch of pending dispatcher work and returns, so a laid-out
    # frame reaches the screen before the thread goes back to work.
    $pumpFrame = {
        $frame = New-Object Windows.Threading.DispatcherFrame
        $null = $win.Dispatcher.BeginInvoke(
            [Windows.Threading.DispatcherPriority]::Background,
            [action]{ $frame.Continue = $false })
        [Windows.Threading.Dispatcher]::PushFrame($frame)
    }.GetNewClosure()

    $revertBusy = {
        $ui.RevList.Children.Clear()
        $ui.RevIndexPanel.Children.Clear()
        $revertRows.Clear()
        $revBlocks.Clear()
        $revRailCards.Clear()
        $ui.TxtRevertHead.Text = 'Reading past runs'
        $ui.TxtRevertSub.Text  = 'Checking which of their changes are still in place, and what is still installed...'
        & $Ref $ui.TxtRevertSub 'Foreground' 'Sub'
        $ui.TxtRevCount.Text = ''
        $ui.TxtRevertTally.Text = 'Working...'
        $ui.BtnRevertRun.IsEnabled = $false
    }

    # The page's own controls, wired once.
    foreach ($g in $REV_GROUPS) {
        $it = New-Object Windows.Controls.ComboBoxItem
        $it.Content = $g.Label; $it.Tag = $g.Key
        $null = $ui.CmbRevOrder.Items.Add($it)
        if ($g.Key -eq $revState.Group) { $ui.CmbRevOrder.SelectedItem = $it }
    }
    foreach ($s in $REV_SORTS) {
        $it = New-Object Windows.Controls.ComboBoxItem
        $it.Content = $s.Label; $it.Tag = $s.Key
        $null = $ui.CmbRevSort.Items.Add($it)
        if ($s.Key -eq $revState.Sort) { $ui.CmbRevSort.SelectedItem = $it }
    }
    $ui.CmbRevOrder.Add_SelectionChanged({
        if ($revState.Booting) { return }
        if (-not $ui.CmbRevOrder.SelectedItem) { return }
        $revState.Group = [string]$ui.CmbRevOrder.SelectedItem.Tag
        & $revApplyOrder
    }.GetNewClosure())
    $ui.CmbRevSort.Add_SelectionChanged({
        if ($revState.Booting) { return }
        if (-not $ui.CmbRevSort.SelectedItem) { return }
        $revState.Sort = [string]$ui.CmbRevSort.SelectedItem.Tag
        & $revApplyOrder
    }.GetNewClosure())

    # The whole page at once, on the same rule the per-group button follows:
    # visible rows only.
    $ui.BtnRevSelectAll.Add_Click({
        $vis = @($revertRows | Where-Object { $_.Card.Visibility -eq 'Visible' -and $_.Check.IsEnabled })
        if (-not $vis.Count) { return }
        $want = @($vis | Where-Object { -not $_.Check.IsChecked }).Count -gt 0
        foreach ($r in $vis) { $r.Check.IsChecked = $want }
        & $revShowNow
        & $revPaintCounts
    }.GetNewClosure())

    $ui.BtnRevCollapseAll.Add_Click({
        foreach ($b in $revBlocks) { & $revSetGroupOpen $b.Body $b.Toggle $false $b.Ordered }
        $revSpy.Offsets = $null; $revSpy.On = ''
        & $revSpyRun
    }.GetNewClosure())
    $ui.BtnRevRefresh.Add_Click({ if ($refreshRef.Rev) { & $refreshRef.Rev } }.GetNewClosure())
    $ui.BtnRevExpandAll.Add_Click({
        foreach ($b in $revBlocks) { & $revSetGroupOpen $b.Body $b.Toggle $true }
        $revSpy.Offsets = $null; $revSpy.On = ''
        & $revSpyRun
    }.GetNewClosure())

    $ui.BtnRevFilterClear.Add_Click({
        foreach ($fb in $revFilterBoxes) { $fb.Box.IsChecked = $false; $fb.Box.IsEnabled = $true }
        foreach ($fg in $REV_FILTER_GROUPS) { $revFilterSel[$fg].Clear() }
        $revViewSnap.Ids = $null
        & $revApplyFilter
    }.GetNewClosure())
    $ui.BtnRevFilterDone.Add_Click({ $ui.BtnRevFilter.IsChecked = $false }.GetNewClosure())

    # A TextChanged handler runs synchronously inside the input event, so a pass
    # over every row is time the character just typed is not on screen.
    $revFindTimer = New-Object Windows.Threading.DispatcherTimer
    $revFindTimer.Interval = [TimeSpan]::FromMilliseconds(180)
    $revFindTimer.Add_Tick({ $revFindTimer.Stop(); & $revApplyFilter }.GetNewClosure())
    $ui.RevFind.Add_TextChanged({
        if ($state.NoPrompts) { & $revApplyFilter; return }
        $revFindTimer.Stop(); $revFindTimer.Start()
    }.GetNewClosure())

    $ui.RevScroll.Add_ScrollChanged({ & $revSpyRun }.GetNewClosure())
    # A narrower list re-wraps every card, so the measured offsets go with it.
    # This handler changes no layout of its own.
    $ui.PageRevert.Add_SizeChanged({ $revSpy.Offsets = $null; & $revSpyRun }.GetNewClosure())

    # The four surfaces on this page that carry a colour of their own.
    & $Ref $ui.TxtRevertHead 'Foreground' 'Text'
    & $Ref $ui.TxtRevertSub  'Foreground' 'Sub'
    & $Ref $ui.TxtRevCount   'Foreground' 'Sub'
    # The footer tally never had one: it predates this page's rework and was
    # WPF's default black on the dark palette the whole time.
    & $Ref $ui.TxtRevertTally 'Foreground' 'Sub'
    foreach ($lb in @($ui.LblRevOrder, $ui.LblRevSort, $ui.LblRevGroups, $ui.LblRevFind)) {
        & $Ref $lb 'Foreground' 'Text'
    }
    & $Ref $ui.RevertBar     'Background'  'Panel'
    & $Ref $ui.RevertBar     'BorderBrush' 'Line'
    & $Ref $ui.RevFilterCard 'Background'  'Panel'
    & $Ref $ui.RevFilterCard 'BorderBrush' 'Line'
    & $Ref $ui.RevIndexRule  'Background'  'Line'
    $revState.Booting = $false

    # The past runs, one card each.
    $openRevertRun = {
        param([string]$Sel, [bool]$RunItNow)
        $revertPick.Sel = [string]$Sel
        # Shown only when the list is what was asked for: "Revert everything"
        # used to switch to it as well, which dropped somebody into two hundred
        # rows before the confirmation.
        if (-not $RunItNow) { & $showPage 'PageRevert' }
        & $revertBusy
        & $pumpFrame
        & $revertBuildBusy
        # Rows arrive ticked, so "revert everything" is the page as it stands.
        # $startRevert asks for confirmation itself.
        if ($RunItNow) { & $startRevert }
    }
    $revHomeRef = @{ Paint = $null }
    $buildRevertHome = {
        $refFn  = $Ref
        $goRun  = $openRevertRun
        $panel  = $ui.RevHomeCards
        $panel.Children.Clear()

        $runs = @(Get-WDPastRuns -Root (Get-WDSession).Root | Sort-Object When -Descending)
        $revertPick.Runs = $runs

        if (-not $runs.Count) {
            $ui.TxtRevHomeHint.Text =
                'This machine has no record of a run by this toolkit. Nothing has been changed, so there is nothing to put back.'
            return
        }
        $ui.TxtRevHomeHint.Text =
            "$($runs.Count) run(s) on this machine. Open one to choose what to put back option by option, or put all of it " +
            'back at once. Nothing is changed until you confirm.'

        # "All runs" first, and only when there is more than one - with a single
        # run it would be the same card twice.
        $spec = New-Object System.Collections.Generic.List[psobject]
        if ($runs.Count -gt 1) {
            $spec.Add([pscustomobject]@{
                Sel = 'all'; Title = 'Everything, together'
                Sub  = "All $($runs.Count) runs, oldest change first, so every value goes back to what it was before any of them."
                Runs = $runs; Can = [bool]@($runs | Where-Object { $_.UndoFile }).Count })
        }
        # Which mode a run was started from, if it was one. A run record is
        # about what changed, not what was picked.
        $presetOf = @{}
        foreach ($pn in @($appliedRuns.Keys)) {
            $f = [string]$appliedRuns[$pn].Folder
            if ($f) { $presetOf[($f -replace '^run-', '')] = [string]$pn }
        }
        foreach ($r in $runs) {
            $bits = New-Object System.Collections.Generic.List[string]
            if ([int]$r.Removed) { $bits.Add("$([int]$r.Removed) removed") }
            if ([int]$r.Changed) { $bits.Add("$([int]$r.Changed) changed") }
            if (-not $bits.Count) { $bits.Add('nothing recorded') }
            $named = [string]$presetOf[[string]$r.Id]
            $spec.Add([pscustomobject]@{
                Sel = [string]$r.Id
                Title = $r.When.ToString('d MMMM yyyy, HH:mm')
                Sub = ($bits -join ', ') + $(if ($named) { " - the $named selection" } else { '' }) + '.'
                Runs = @($r); Can = [bool]$r.UndoFile })
        }

        foreach ($s in $spec) {
            $card = New-Object Windows.Controls.Border
            $card.CornerRadius = New-Object Windows.CornerRadius 10
            $card.BorderThickness = New-Object Windows.Thickness 1
            $card.Padding = '18,16,18,16'
            $card.Margin = '0,0,14,14'
            $card.Width = 330
            # Raised to a common height by $fitRevertCards, not by the panel:
            # VerticalAlignment = Stretch does nothing here.
            & $refFn $card 'Background' 'Card'
            & $refFn $card 'BorderBrush' 'Line'

            # A DockPanel, so the two buttons sit at the foot of every card
            # whatever length the lines above come out at.
            $dp = New-Object Windows.Controls.DockPanel
            $dp.LastChildFill = $true
            $foot = New-Object Windows.Controls.StackPanel
            [Windows.Controls.DockPanel]::SetDock($foot, 'Bottom')
            $null = $dp.Children.Add($foot)
            $top = New-Object Windows.Controls.StackPanel
            $null = $dp.Children.Add($top)

            $ti = New-Object Windows.Controls.TextBlock
            $ti.Text = [string]$s.Title
            $ti.FontSize = 16; $ti.FontWeight = 'Bold'; $ti.TextWrapping = 'Wrap'
            & $refFn $ti 'Foreground' 'Text'
            $null = $top.Children.Add($ti)

            $sb = New-Object Windows.Controls.TextBlock
            $sb.Text = [string]$s.Sub
            $sb.FontSize = 12.5; $sb.TextWrapping = 'Wrap'; $sb.Margin = '0,5,0,0'
            $sb.LineHeight = 17; $sb.LineStackingStrategy = 'BlockLineHeight'
            & $refFn $sb 'Foreground' 'Sub'
            $null = $top.Children.Add($sb)

            # Out of the shared cache. Built on every card whether or not there
            # is an answer yet.
            $st = New-Object Windows.Controls.TextBlock
            $st.FontSize = 12.5; $st.TextWrapping = 'Wrap'; $st.Margin = '0,8,0,0'
            $st.FontWeight = 'SemiBold'
            & $refFn $st 'Foreground' 'Ok'
            $null = $top.Children.Add($st)

            $cardTag = @{ Sel = [string]$s.Sel; Runs = @($s.Runs); State = $st
                          Open = $null; Now = $null; Can = [bool]$s.Can }
            $acts = New-Object Windows.Controls.StackPanel
            $acts.Orientation = 'Horizontal'
            $acts.Margin = '0,14,0,0'
            foreach ($a in @(@{ T = 'Show all options'; Now = $false
                                Tip = 'Lists every change this made, with what is still in place, so you can pick.' },
                             @{ T = 'Revert everything'; Now = $true
                                Tip = 'Puts back everything from this that is still in place. You are asked to confirm, with a count, before anything happens.' })) {
                $b = New-Object Windows.Controls.Button
                $b.Content = [string]$a.T
                $b.Padding = '12,5'; $b.Margin = '0,0,7,0'; $b.FontSize = 12.5
                $b.ToolTip = [string]$a.Tip
                if ($a.Now) {
                    $b.FontWeight = 'Bold'
                    & $refFn $b 'Background'  'GoBg'
                    & $refFn $b 'Foreground'  'GoText'
                    & $refFn $b 'BorderBrush' 'GoBorder'
                }
                $b.IsEnabled = [bool]$s.Can
                $b.Tag = @{ Sel = [string]$s.Sel; Now = [bool]$a.Now; Go = $goRun }
                $b.Add_Click({ & $this.Tag.Go ([string]$this.Tag.Sel) ([bool]$this.Tag.Now) }.GetNewClosure())
                $null = $acts.Children.Add($b)
                # Handed out on the card's own Tag rather than found by walking
                # the visual tree.
                if ($a.Now) { $cardTag.Now = $b } else { $cardTag.Open = $b }
            }
            $null = $foot.Children.Add($acts)

            # A run whose folder has been deleted is still named, because
            # forgetting that the machine was changed is worse than being unable
            # to change it back.
            if (-not $s.Can) {
                $why = New-Object Windows.Controls.TextBlock
                $why.Text = 'Its rollback script has been deleted, so nothing from it can be put back.'
                $why.FontSize = 12; $why.TextWrapping = 'Wrap'; $why.Margin = '0,8,0,0'
                & $refFn $why 'Foreground' 'Warn'
                $null = $foot.Children.Add($why)
            }

            $card.Child = $dp
            $card.Tag = $cardTag
            $null = $panel.Children.Add($card)
        }
        & $revHomeRef.Paint
    }
    # The one line a card cannot have cheaply, filled from the shared cache
    # whenever an answer lands.
    $paintRevertHome = {
        foreach ($card in @($ui.RevHomeCards.Children)) {
            $tag = $card.Tag
            if (-not $tag -or -not $tag.State) { continue }
            $todo = 0; $done = 0; $unknown = 0; $known = $true
            foreach ($r in @($tag.Runs)) {
                $rid = [string]$r.Id
                if ($appliedState.ContainsKey($rid) -and $appliedState[$rid]) {
                    $todo    += [int]$appliedState[$rid].Outstanding
                    $done    += [int]$appliedState[$rid].Done
                    $unknown += [int]$appliedState[$rid].Unknown
                } else {
                    $known = $false
                    if (-not $appliedState.ContainsKey($rid) -and -not $appliedWant.Contains($rid)) {
                        $null = $appliedWant.Add($rid)
                    }
                }
            }
            if (-not $known) {
                $tag.State.Text = 'Reading how much of it is still in place...'
                & $Ref $tag.State 'Foreground' 'Sub'
                continue
            }
            # Three-valued, like Get-WDUndoStatus itself: "nothing left to do"
            # is a claim, and can only be made when nothing was unaskable.
            if ($todo -eq 0 -and $unknown -eq 0) {
                $tag.State.Text = "Nothing left to put back - all $done change(s) have already been reversed."
                & $Ref $tag.State 'Foreground' 'Muted'
            } elseif ($todo -eq 0) {
                $tag.State.Text = "Nothing found still in place, but $unknown change(s) could not be checked from here."
                & $Ref $tag.State 'Foreground' 'Sub'
            } else {
                $tag.State.Text = "$todo change(s) still in place" +
                    $(if ($done) { ", $done already back" } else { '' }) +
                    $(if ($unknown) { ", $unknown not checkable" } else { '' }) + '.'
                & $Ref $tag.State 'Foreground' 'Ok'
            }
        }
        # A card that has just gained or lost a line of text is a card whose
        # height has changed.
        if ($revHomeRef.Fit) { & $revHomeRef.Fit }
    }
    # One height for all of them, measured. A WrapPanel arranges each child at
    # its desired height, so cards holding two lines and four come out ragged.
    # The floor is cleared before measuring, or they ratchet upward.
    $fitRevertCards = {
        $cards = @($ui.RevHomeCards.Children)
        if ($cards.Count -lt 2) { return }
        foreach ($c in $cards) { $c.MinHeight = 0 }
        $ui.RevHomeCards.UpdateLayout()
        $tall = 0.0
        foreach ($c in $cards) { if ([double]$c.ActualHeight -gt $tall) { $tall = [double]$c.ActualHeight } }
        if ($tall -le 0) { return }
        foreach ($c in $cards) { $c.MinHeight = $tall }
    }
    $revHomeRef.Fit   = $fitRevertCards
    $revHomeRef.Paint = $paintRevertHome
    $revHomeRef.Build = $buildRevertHome

    # $ui.BtnRevert is the home page's middle card, so this wiring is unchanged
    # from when it was a footer button.
    $ui.BtnRevert.Add_Click({
        & $showPage 'PageRevertHome'
        & $buildRevertHome
    }.GetNewClosure())
    $ui.BtnRevHomeBack.Add_Click({ & $showPage 'PageHome' }.GetNewClosure())
    # The cards, not the application's home page: this page is one step in now.
    $ui.BtnRevertBack.Add_Click({
        & $showPage 'PageRevertHome'
        & $revHomeRef.Paint
    }.GetNewClosure())

    # The answer file page. Every field on one page with an index, because a
    # tabbed form hides two thirds of the state behind seven tabs.
    $UA_SECTIONS = @(
        # One opening section, not two: the tally is the second half of Note
        # under a rule, because both answer the same question somebody has on
        # arriving.
        @{ K = 'note';     T = 'Note'; N = '' }
        @{ K = 'bypasses'; T = 'Setup questions'; N = '' }
        # Straight after the bypasses, which is where somebody who came to get
        # away from Microsoft's questions is still reading.
        @{ K = 'privacy';  T = 'Privacy and security'; N = '' }
        @{ K = 'account';  T = 'Your account'
           N = 'Windows creates this account during Setup and signs into it. It is also what removes the Microsoft account screen: with an account already defined, that screen has nothing left to ask.' }
        @{ K = 'region';   T = 'Region and keyboard'; N = '' }
        @{ K = 'machine';  T = 'Machine information'
           N = 'If any of these options are left blank, setup will answer it for you.' }
        @{ K = 'wifi';     T = 'Wi-Fi'
           N = 'Only use this for a network you own.' }
        @{ K = 'toolkit';  T = 'Auto-debloat after setup'; N = ''; Toggle = 'RunToolkit' }
        @{ K = 'extra';    T = 'Extra commands'
           N = 'Run in order, as an administrator. This is the hatch for anything the form above does not cover.' }
        @{ K = 'disks';    T = 'Disks'; N = '' }
    )

    # The exact string has to match what the medium calls the edition, so these
    # are the published names.
    $UA_EDITIONS = [ordered]@{
        ''                                = 'Have setup ask me'
        'Windows 11 Home'                 = 'Windows 11 Home'
        'Windows 11 Home N'               = 'Windows 11 Home N'
        'Windows 11 Home Single Language' = 'Windows 11 Home Single Language'
        'Windows 11 Pro'                  = 'Windows 11 Pro'
        'Windows 11 Pro N'                = 'Windows 11 Pro N'
        'Windows 11 Pro Education'        = 'Windows 11 Pro Education'
        'Windows 11 Pro for Workstations' = 'Windows 11 Pro for Workstations'
        'Windows 11 Education'            = 'Windows 11 Education'
        'Windows 11 Education N'          = 'Windows 11 Education N'
        'Windows 11 Enterprise'           = 'Windows 11 Enterprise'
        'Windows 11 Enterprise N'         = 'Windows 11 Enterprise N'
        'Windows 10 Home'                 = 'Windows 10 Home'
        'Windows 10 Pro'                  = 'Windows 10 Pro'
        'Windows 10 Enterprise'           = 'Windows 10 Enterprise'
    }

    # There was a $UA_PROFILES table here: the .json files in profile_saves,
    # read off disk to fill a drop-down. A saved selection is a file somebody
    # keeps where they keep files.

    # The drop-down contents.
    $UA_LANGUAGES = [ordered]@{
        'en-US' = 'English (United States)';   'en-GB' = 'English (United Kingdom)'
        'en-AU' = 'English (Australia)';       'en-CA' = 'English (Canada)'
        'en-IN' = 'English (India)';           'de-DE' = 'German (Germany)'
        'fr-FR' = 'French (France)';           'fr-CA' = 'French (Canada)'
        'es-ES' = 'Spanish (Spain)';           'es-MX' = 'Spanish (Mexico)'
        'it-IT' = 'Italian (Italy)';           'pt-BR' = 'Portuguese (Brazil)'
        'pt-PT' = 'Portuguese (Portugal)';     'nl-NL' = 'Dutch (Netherlands)'
        'sv-SE' = 'Swedish (Sweden)';          'nb-NO' = 'Norwegian (Norway)'
        'da-DK' = 'Danish (Denmark)';          'fi-FI' = 'Finnish (Finland)'
        'pl-PL' = 'Polish (Poland)';           'cs-CZ' = 'Czech (Czechia)'
        'hu-HU' = 'Hungarian (Hungary)';       'ro-RO' = 'Romanian (Romania)'
        'el-GR' = 'Greek (Greece)';            'tr-TR' = 'Turkish (Turkey)'
        'ru-RU' = 'Russian (Russia)';          'uk-UA' = 'Ukrainian (Ukraine)'
        'ja-JP' = 'Japanese (Japan)';          'ko-KR' = 'Korean (Korea)'
        'zh-CN' = 'Chinese (Simplified)';      'zh-TW' = 'Chinese (Traditional)'
        'ar-SA' = 'Arabic (Saudi Arabia)';     'he-IL' = 'Hebrew (Israel)'
        'hi-IN' = 'Hindi (India)';             'th-TH' = 'Thai (Thailand)'
        'vi-VN' = 'Vietnamese (Vietnam)';      'id-ID' = 'Indonesian (Indonesia)'
    }
    # The half before the colon is the input language and the half after is the
    # physical layout, which is why "US keyboard, French language" is
    # expressible.
    $UA_KEYBOARDS = [ordered]@{
        '0409:00000409' = 'US (QWERTY)'
        '0409:00020409' = 'US - International'
        '0409:00000412' = 'US - Dvorak'
        '0809:00000809' = 'United Kingdom'
        '1009:00001009' = 'Canadian Multilingual'
        '0c0c:00000c0c' = 'Canadian French'
        '0407:00000407' = 'German (QWERTZ)'
        '0807:00000807' = 'Swiss German'
        '040c:0000040c' = 'French (AZERTY)'
        '080c:0000080c' = 'Belgian French'
        '0410:00000410' = 'Italian'
        '0c0a:0000040a' = 'Spanish (Spain)'
        '080a:0000080a' = 'Latin American'
        '0416:00000416' = 'Portuguese (Brazil ABNT)'
        '0816:00000816' = 'Portuguese (Portugal)'
        '0413:00020409' = 'Dutch (US International)'
        '041d:0000041d' = 'Swedish'
        '0414:00000414' = 'Norwegian'
        '0406:00000406' = 'Danish'
        '040b:0000040b' = 'Finnish'
        '0415:00000415' = 'Polish (programmers)'
        '0405:00000405' = 'Czech'
        '040e:0000040e' = 'Hungarian'
        '0418:00000418' = 'Romanian'
        '0408:00000408' = 'Greek'
        '041f:0000041f' = 'Turkish Q'
        '0419:00000419' = 'Russian'
        '0422:00000422' = 'Ukrainian'
        '0411:00000411' = 'Japanese'
        '0412:00000412' = 'Korean'
        '0804:00000804' = 'Chinese (Simplified)'
        '0404:00000404' = 'Chinese (Traditional)'
        '0401:00000401' = 'Arabic (101)'
        '040d:0002040d' = 'Hebrew (standard)'
        '0439:00000439' = 'Hindi (Devanagari)'
        '041e:0000041e' = 'Thai Kedmanee'
        '042a:00000042' = 'Vietnamese'
    }
    # Read off this machine, because Windows owns the list and its ids are
    # exactly what <TimeZone> takes.
    $UA_TIMEZONES = [ordered]@{ '' = 'Automatic - let Setup decide' }
    try {
        foreach ($tz in ([System.TimeZoneInfo]::GetSystemTimeZones())) {
            $UA_TIMEZONES[[string]$tz.Id] = [string]$tz.DisplayName
        }
    } catch { }
    # Boxed once at the top of each section that has one, rather than above
    # every password field: repeated in full inside every added account it made
    # the section mostly warning.
    $UA_PWD_WARN = 'DO NOT SET A PASSWORD WITH THIS OPTION UNLESS YOU OWN THE USB DRIVE OR DEVICE THIS PROGRAM WILL RUN OFF OF - your password will be written into the file as plain text in order to apply it and stays readable.'
    # Sections whose options are bare ticks get no separator: a rule between two
    # check boxes is a line drawn through a list.
    $UA_NO_RULES = @('bypasses', 'privacy')

    $UA_FIELDS = @(
        # The bypasses.
        @{ S = 'bypasses'; K = 'BypassMicrosoftAccount'; T = 'check'
           L = 'Bypass Microsoft account requirement'; N = '' }
        @{ S = 'bypasses'; K = 'AcceptEula'; T = 'check'
           L = 'Accept licensing terms automatically'; N = '' }
        @{ S = 'bypasses'; K = 'BypassHardwareChecks'; T = 'check'
           L = 'Bypass Windows 11 hardware requirement'
           N = 'Skips the TPM 2.0, Secure Boot, processor and memory checks. Windows still updates normally afterwards; Microsoft simply does not support the configuration.' }

        # The local account, which is also the Microsoft-account bypass.
        @{ S = 'account'; K = 'AccountName'; T = 'text'; L = 'Account name'; N = '' }
        # The note goes beside the box rather than under it: the explanation is
        # one short sentence and the control is 320px in a box twice that wide.
        @{ S = 'account'; K = 'AccountPassword'; T = 'password'; L = 'Password'
           NoteRight = $true
           N = 'Leave it empty to have no password - you can change this in settings after setup is complete.' }
        @{ S = 'account'; K = 'AccountGroup'; T = 'choice'; L = 'Account type'
           C = @('Administrators', 'Users'); N = '' }
        @{ S = 'account'; K = 'AccountHint'; T = 'text'; L = 'Password hint'; N = '' }
        @{ S = 'account'; K = 'AutoLogon'; T = 'check'; L = 'Bypass password'
           N = 'Make sure you know what you''re doing. The number below defines how many times you can log in without being prompted for your password.' }
        # Inline, so it lands inside the tick's own box rather than starting one
        # of its own: the sentence above is about the number, so they have to
        # share a frame.
        @{ S = 'account'; K = 'AutoLogonCount'; T = 'number'; L = ''; N = ''; Inline = $true }
        @{ S = 'account'; K = 'AdminPassword'; T = 'password'; L = 'Built-in Administrator password'
           NoteRight = $true
           N = 'Leave this empty to keep it disabled - most people should not use this.' }

        # Region.
        @{ S = 'region'; K = 'UILanguage'; T = 'combo'; L = 'Windows display language'
           C = 'languages'; Sync = @('SystemLocale', 'UserLocale'); N = '' }
        # The sync is a control now rather than a rule that quietly stopped
        # applying once one of the two below was set.
        @{ S = 'region'; K = 'SyncLocales'; T = 'check'; Inline = $true
           L = 'Sync with system locale and date, time, and number format'; N = '' }
        @{ S = 'region'; K = 'SystemLocale'; T = 'combo'; L = 'System locale'
           C = 'languages'; N = '' }
        @{ S = 'region'; K = 'UserLocale'; T = 'combo'; L = 'Date, time, and number format'
           C = 'languages'; N = '' }
        @{ S = 'region'; K = 'InputLocale'; T = 'combo'; L = 'Keyboard layout'
           C = 'keyboards'; N = '' }
        @{ S = 'region'; K = 'TimeZone'; T = 'combo'; L = 'Time zone'
           C = 'timezones'; N = '' }

        # Machine.
        @{ S = 'machine'; K = 'ComputerName'; T = 'text'; L = 'Computer name'
           Limit = 15; NoSpaces = $true
           N = 'If left blank, something like "DESKTOP-A1B2C3D" will be generated. 15 characters max, no spaces.' }
        @{ S = 'machine'; K = 'ImageName'; T = 'combo'; L = 'Edition to install'
           C = 'editions'; N = '' }
        @{ S = 'machine'; K = 'ProductKey'; T = 'text'; L = 'Product key'
           N = 'Leave empty on a machine with a key in its firmware, which every PC sold with Windows has. A generic edition key here selects an edition without activating it.' }
        @{ S = 'machine'; K = 'Organization'; T = 'text'; L = 'Organization'; N = '' }
        @{ S = 'machine'; K = 'Owner'; T = 'text'; L = 'Registered owner'; N = '' }
        @{ S = 'machine'; K = 'EnableRdp'; T = 'check'; L = 'Allow Remote Desktop connections'
           N = 'Turns Remote Desktop on and opens its firewall rule. Off unless you know you want it - it is a way into the machine from the network.' }

        # Privacy.
        @{ S = 'privacy'; K = 'PrivacyOff'; T = 'check'
           L = 'Deny all data collection'
           N = 'Diagnostic data, tailored experiences, the advertising ID, location, Find my device, and inking and typing data.' }
        @{ S = 'privacy'; K = 'ApplyToDefaultProfile'; T = 'check'
           L = 'Apply per user settings to future added accounts'
           N = '' }
        @{ S = 'privacy'; K = 'NoDeviceEncryption'; T = 'check'
           L = 'Disable automatic hard drive encryption'
           N = 'Bitlocker runs silently on first sign-in, which can ruin local accounts after a firmware update since the recovery key has nowhere to go. You can turn on bitlocker yourself later if this option is chosen.' }

        # Wi-Fi.
        @{ S = 'wifi'; K = 'BypassInternet'; T = 'check'
           L = 'Bypass internet requirement'; N = ''; Collapses = 'wifi'; InHead = $true }
        @{ S = 'wifi'; K = 'WifiSsid'; T = 'text'; L = 'Network name'; N = '' }
        # No W: the warning is the same one Your account carries and is true of
        # the section rather than of this box.
        @{ S = 'wifi'; K = 'WifiPassword'; T = 'password'; L = 'Network password'; N = '' }
        @{ S = 'wifi'; K = 'WifiAuth'; T = 'choice'; L = 'Security'
           C = @('WPA2PSK', 'WPA3SAE', 'open')
           D = @{ 'WPA2PSK' = 'WPA2 with a password (almost every home network)'
                  'WPA3SAE' = 'WPA3 with a password (newer routers)'
                  'open'    = 'No password at all' }
           N = '' }
        @{ S = 'wifi'; K = 'WifiHidden'; T = 'check'; L = 'This network does not broadcast its name'
           N = 'Tick only if the network is deliberately hidden. On an ordinary network this makes joining slower and no more private.' }
        # Moved out of Machine information, where it had nothing to do with the
        # rest of that section.
        @{ S = 'wifi'; K = 'NetworkLocation'; T = 'choice'; L = 'Network type'
           C = @('Home', 'Work', 'Other')
           D = @{ 'Home' = 'Private - this PC can be discovered by others on the network'
                  'Work'  = 'Work - same as private, filed as a work network'
                  'Other' = 'Public - this PC is hidden from others on the network' }
           N = 'Public is the safer answer on any network you do not control.' }

        # Run the toolkit afterwards.
        @{ S = 'toolkit'; K = 'RunPreset'; T = 'choice'; L = 'Which mode to run'
           C = @('Conservative', 'Balanced', 'Aggressive', 'Extreme', 'profile')
           D = @{ 'Conservative' = 'Conservative'
                  'Balanced'     = 'Balanced'
                  'Aggressive'   = 'Aggressive'
                  'Extreme'      = 'Extreme'
                  'profile'      = 'Preset from file' }
           # No "it needs an Administrator" here: that is a condition on the
           # section, not on which mode runs, and it is enforced on the heading.
           N = 'The machine is a fresh install whose state this file just defined, so the run applies straight away with no preview and nothing to confirm.' }
        # Shown only when the answer above is 'profile': it is the only field
        # meaningless under four of the five answers.
        @{ S = 'toolkit'; K = 'RunProfileFile'; T = 'file'; L = 'Saved selection file'
           ShowWhen = 'RunPreset'; ShowIs = 'profile'
           N = 'The .json written by Save on the Advanced page or the home screen. It has to sit in the toolkit''s profile_saves folder to reach the machine, so choosing one from anywhere else copies it in.' }

        # Extra commands.
        @{ S = 'extra'; K = 'ExtraFirstLogon'; T = 'lines'; L = 'At the first sign-in, one command per line'
           N = 'Anything a command prompt accepts. They run after the removals this file already carries, so a command here can rely on those having happened.' }
        @{ S = 'extra'; K = 'ExtraSpecialize'; T = 'lines'; L = 'Before anybody signs in, one command per line'
           N = 'Run during Setup, as SYSTEM, before any account exists. The right place for machine-wide policy and for anything that has to be true before the first sign-in; the wrong place for anything needing a network, a desktop, or a user profile.' }

        # The two wipe labels name the disk number, and the number is a field
        # above them.
        @{ S = 'disks'; K = 'DiskLayout'; T = 'choice'; L = 'What Setup does with the drive'
           C = @('none', 'wipe-gpt', 'wipe-mbr')
           D = @{ 'none' = 'Ask me, as Setup normally does'
                  'wipe-gpt' = 'Erase disk $0 and install fresh (GPT / UEFI)'
                  'wipe-mbr' = 'Erase disk $0 and install fresh (MBR / BIOS)' }
           DiskNum = $true
           N = 'Erasing happens with no prompt, on whichever machine the medium is booted on, whatever is on the drive. Setup stopping to ask is a cheap price for that not happening by accident, so this is the one field on the page whose default is "do nothing".' }
        @{ S = 'disks'; K = 'DiskId'; T = 'number'; L = 'Disk number'; NoteRight = $true
           N = 'Which disk to erase. 0 is the first one Windows enumerates, which is usually but not always the one you mean.' }
    )

    # $itemById is built with the Compare page's other lookups and holds exactly
    # this - a second copy would be a second thing to keep in step.
    $uaItemById = $itemById

    $uaOptions  = New-WDUnattendOptions
    $uaControls = New-Object System.Collections.Generic.List[psobject]
    # Raised while the display language sets the locales under it, so their own
    # handlers know not to record that as a deliberate choice.
    $uaSync     = @{ On = $false }
    $uaSecPanel = @{}
    # Section key -> its title row, for the one field that renders beside a
    # heading rather than under it.
    $uaSecHead  = @{}
    # A list rather than a fixed second slot: "a second account" made a family
    # machine a thing the form could not express.
    $uaExtraAccts = New-Object System.Collections.Generic.List[psobject]
    $uaHeads    = New-Object System.Collections.Generic.List[psobject]
    # Ms is filled by whichever route built it, so the self test can report what
    # the page really costs.
    $uaBuilt    = @{ Done = $false; Ms = 0 }
    # So the self test can press the real button rather than calling the builder
    # behind it.
    $uaAddBtn   = @{ Btn = $null }
    $uaSummary  = @{ Panel = $null }
    # Section key -> the On/Off pair, the line that says why On is unavailable,
    # and the body it governs.
    $uaGate     = @{}
    # The gate itself, for the self test - it is wired inside $uaBuild and there
    # is no other way to reach it.
    $uaGateSync = @{ Fn = $null }
    # The rail's cards, so their size can follow the window's.
    $uaRailCards = New-Object System.Collections.Generic.List[psobject]

    # The index rail grows with the window.
    $uaSizeRail = {
        $w = [double]$ui.Root.ActualWidth
        if ($w -le 0) { return }
        # 184 at 1000px, growing by a tenth of every pixel past it.
        $railW = [Math]::Round([Math]::Max(184.0, [Math]::Min(300.0, 184.0 + ($w - 1000.0) * 0.1)))
        # Nothing to do if it already is that: this fires from SizeChanged, and
        # a handler that changes layout feeds itself.
        if ([double]$ui.UaIndexScroll.Width -eq $railW -and $uaRailCards.Count) { return }
        $ui.UaIndexScroll.Width = $railW
        # The type follows the width rather than the window, so the two cannot
        # drift apart.
        $font = [Math]::Round([Math]::Max(12.5, [Math]::Min(15.0, 12.5 + ($railW - 184.0) * 0.02)), 1)
        $padY = [Math]::Round([Math]::Max(5.0, [Math]::Min(10.0, 5.0 + ($railW - 184.0) * 0.04)))
        foreach ($c in $uaRailCards) {
            $c.Label.FontSize = $font
            $c.Card.Padding   = New-Object Windows.Thickness -ArgumentList 10.0, $padY, 10.0, $padY
        }
    # A closure, because it is handed to Add_SizeChanged and fires from the
    # dispatcher rather than from here.
    }.GetNewClosure()

    # One labeled field. Everything above the control is the same three lines
    # whatever the control is.
    $uaLastWrap = @{ Panel = $null; Card = $null }
    # Every explanatory line on the setup page, so Non-verbose can reach them.
    $uaNoteEls = New-Object System.Collections.Generic.List[psobject]

    # Non-verbose.
    $applyTerse = {
        $terse = [bool]$state.Terse
        $vis   = $(if ($terse) { 'Collapsed' } else { 'Visible' })
        foreach ($r in $rows) {
            if ($r.Desc)     { $r.Desc.Visibility     = $vis }
            if ($r.Over)     { $r.Over.Visibility     = $vis }
            if ($r.TerseTag) { $r.TerseTag.Visibility = $vis }
        }
        foreach ($r in $revertRows) {
            if ($r.DescEl) { $r.DescEl.Visibility = $vis }
        }
        foreach ($d in $cmpDescEls) { $d.Visibility = $vis }
        foreach ($n in $uaNoteEls)  { $n.Visibility = $vis }
    }.GetNewClosure()
    $terseRef.Do = $applyTerse

    # Refresh: this page is a reading of the machine taken when it was built,
    # and somebody may have changed something in another window.
    $refreshAdvanced = {
        $veil = $win.Tag.Busy
        if ($veil) { & $veil.Show 'Checking this machine again' }
        try {
            Clear-WDRegistryProbeCache
            Clear-WDProgramCache
            & $readInstalled
            # Cleared rather than refilled: $alreadySatisfied falls through to
            # asking the machine when an id is missing.
            if ($satisfiedMap) { $satisfiedMap.Clear() }

            # What changed, named rather than counted where the list is short. A
            # Refresh that reports nothing is the commonest outcome.
            $became = New-Object System.Collections.Generic.List[string]
            $ceased = New-Object System.Collections.Generic.List[string]
            $n = 0
            foreach ($r in $rows) {
                $n++
                if ($veil -and ($n % 25) -eq 0) {
                    & $veil.Set "Re-checking option $n of $($rows.Count)" ($n / [Math]::Max(1, $rows.Count))
                    # This blocks the UI thread between pumps, so a bar nobody
                    # advances is the frozen page it was put there to explain.
                    & $pumpFrame
                }
                if (-not $r.Item) { continue }
                # The answers this row was built with, to compare against.
                $wasApplied = [bool]$r.Applied
                $sat = ''
                if (-not $r.Absent) { $sat = [string](& $alreadySatisfied $r.Item) }
                $word = $(if ([int]$r.Tier -eq 0) {
                              if ($sat -eq 'already applied') { 'already set' } else { $sat }
                          } else { '' })
                # Only tier 0 rows are ever disabled by this: disabling a row a
                # preset selects would take away the only way to drop it.
                if ($word) {
                    $null = $installedIds.Add([string]$r.Id)
                    $r.Check.IsEnabled = $false
                    $r.Check.IsChecked = $false
                    & $Ref $r.Name 'Foreground' 'Muted'
                } elseif ([int]$r.Tier -eq 0 -and -not $r.Absent -and -not $r.Gated) {
                    # It was finished and is not any more - somebody put the
                    # thing back, so the row becomes a decision again.
                    $null = $installedIds.Remove([string]$r.Id)
                    $r.Check.IsEnabled = $true
                    & $Ref $r.Name 'Foreground' 'Text'
                }
                if ($r.PaintStatus) { & $r.PaintStatus $word $sat ([int]$r.Tier) }
                # Recorded before the row's own flags move on, so the next
                # Refresh compares against what this one left.
                $nowApplied = [bool]$sat
                if ($nowApplied -and -not $wasApplied) { $became.Add([string]$r.Name.Text) }
                if ($wasApplied -and -not $nowApplied) { $ceased.Add([string]$r.Name.Text) }
                $r.Applied = $nowApplied
                $r.Done    = [bool]$word
            }
            # The browser row's gate is a live condition rather than a guard, so
            # the sweep behind it has to be re-asked.
            if ($refreshBrowsers.Do) { & $refreshBrowsers.Do }
            & $applyTerse
            & $applyFilter
            & $updateTally

            # And say what it found, including when that is nothing: a button
            # whose only evidence of having worked is that the page looks the
            # same is one nobody trusts.
            $said = New-Object System.Collections.Generic.List[string]
            $said.Add("Checked $($rows.Count) options against this machine.")
            $said.Add('')
            if (-not $became.Count -and -not $ceased.Count) {
                $said.Add('Nothing has changed since this page was built. Every option still reports what it did before.')
            } else {
                $tell = {
                    param($List, [string]$Lead)
                    if (-not $List.Count) { return }
                    $said.Add("$Lead ($($List.Count)):")
                    if ($List.Count -le 12) {
                        foreach ($nm in $List) { $said.Add("    $nm") }
                    } else {
                        foreach ($nm in @($List)[0..11]) { $said.Add("    $nm") }
                        $said.Add("    and $($List.Count - 12) more")
                    }
                    $said.Add('')
                }
                & $tell $became 'Now already done, so a run would find nothing to do'
                & $tell $ceased 'No longer done, so a run would act on these again'
                $said.Add('Your ticks have been kept.')
            }
            if (-not $state.NoPrompts) {
                Show-WDMessage (($said -join [Environment]::NewLine), 'Refresh', 'OK', 'None') | Out-Null
            }
            $refreshRef.LastReport = ($said -join [Environment]::NewLine)
        } finally { if ($veil) { & $veil.Hide } }
    }.GetNewClosure()
    $refreshRef.Adv = $refreshAdvanced

    # The Revert page's is a rebuild rather than a repaint, because that page is
    # its reading - every row's state and which options are listed come out of
    # one pass.
    $refreshRef.Rev = {
        # Counted before and after, because the page is rebuilt wholesale and no
        # row objects survive to be compared.
        $wasRows = $revertRows.Count
        $wasTodo = @($revertRows | Where-Object { $_.Opt.State -eq 'todo' }).Count
        $wasPend = 0
        foreach ($r in $revertRows) { $wasPend += [int]$r.Opt.Pending }

        $revCache.Built = $false
        Clear-WDRegistryProbeCache
        & $revertBuildBusy

        $nowRows = $revertRows.Count
        $nowTodo = @($revertRows | Where-Object { $_.Opt.State -eq 'todo' }).Count
        $nowPend = 0
        foreach ($r in $revertRows) { $nowPend += [int]$r.Opt.Pending }

        $said = New-Object System.Collections.Generic.List[string]
        $said.Add("Read this machine again for $nowRows option(s).")
        $said.Add('')
        if ($wasRows -eq $nowRows -and $wasTodo -eq $nowTodo -and $wasPend -eq $nowPend) {
            $said.Add('Nothing has changed since this page was built. The same options are still in place, with the same changes outstanding.')
        } else {
            if ($wasRows -ne $nowRows) { $said.Add("Options listed: $wasRows to $nowRows") }
            if ($wasTodo -ne $nowTodo) { $said.Add("Still in place:  $wasTodo to $nowTodo") }
            if ($wasPend -ne $nowPend) { $said.Add("Changes to put back: $wasPend to $nowPend") }
            $said.Add('')
            $said.Add('Something on this machine has been put back or changed since the page was opened, and the list now reflects it.')
        }
        if (-not $state.NoPrompts) {
            Show-WDMessage (($said -join [Environment]::NewLine), 'Refresh', 'OK', 'None') | Out-Null
        }
        $refreshRef.LastReport = ($said -join [Environment]::NewLine)
    }.GetNewClosure()

    $uaAddField = {
        param($Field, $Host2)
        # One box per section, not per option: a column of boxes each holding
        # one label and one field is a stack of frames drawn around nothing.
        $kind = [string]$Field.T
        $ctrl = $null

        # In the section's title row rather than the section. Only one field
        # does this and it is a bare tick.
        if ($Field.ContainsKey('InHead') -and [bool]$Field.InHead) {
            $ctrl = New-Object Windows.Controls.CheckBox
            $ctrl.Content = [string]$Field.L
            $ctrl.FontSize = 13; $ctrl.Margin = '14,0,0,0'
            $ctrl.VerticalAlignment = 'Center'
            $ctrl.IsChecked = [bool]$uaOptions.($Field.K)
            & $Ref $ctrl 'Foreground' 'Text'
            $null = $Host2.Children.Add($ctrl)
            $uaControls.Add([pscustomobject]@{ Key = [string]$Field.K; Kind = $kind; Ctrl = $ctrl
                                               Touched = $false; Card = $null })
            return
        }

        $inline = ($Field.ContainsKey('Inline') -and [bool]$Field.Inline -and $uaLastWrap.Panel)
        if ($inline) {
            # Inside the card above, so the sentence that describes this control
            # and the control itself are in one frame.
            $wrap = $uaLastWrap.Panel
            $card = $uaLastWrap.Card
        } else {
            $card = New-Object Windows.Controls.Border
            # A hairline above rather than a frame around: the first option in a
            # section gets none, so the top of the box is the box's own edge.
            $first = ($Host2.Children.Count -eq 0)
            $ruled = ($UA_NO_RULES -notcontains [string]$Field.S)
            $card.BorderThickness = New-Object Windows.Thickness 0, $(if ($first -or -not $ruled) { 0 } else { 1 }), 0, 0
            $card.Padding = $(if ($ruled) { $(if ($first) { '0,0,0,11' } else { '0,11,0,11' }) }
                              else        { $(if ($first) { '0,0,0,7' }  else { '0,7,0,7' }) })
            & $Ref $card 'BorderBrush' 'Line'
            $wrap = New-Object Windows.Controls.StackPanel
            $card.Child = $wrap
            $null = $Host2.Children.Add($card)
            $uaLastWrap.Panel = $wrap
            $uaLastWrap.Card  = $card
        }

        # A note beside the control rather than above it: stacking spends a row
        # of height to leave a row of width empty.
        $noteRight = ($Field.ContainsKey('NoteRight') -and [bool]$Field.NoteRight -and [string]$Field.N)

        if ($kind -eq 'check') {
            $ctrl = New-Object Windows.Controls.CheckBox
            $ctrl.Content = [string]$Field.L
            $ctrl.FontSize = 13.5
            $ctrl.IsChecked = [bool]$uaOptions.($Field.K)
            & $Ref $ctrl 'Foreground' 'Text'
            $null = $wrap.Children.Add($ctrl)
        } elseif ([string]$Field.L) {
            # A field may deliberately have no label - the auto-logon count sits
            # directly under the sentence that describes it.
            $lbl = New-Object Windows.Controls.TextBlock
            $lbl.Text = [string]$Field.L; $lbl.FontSize = 13.5
            & $Ref $lbl 'Foreground' 'Text'
            $null = $wrap.Children.Add($lbl)
        }

        # A warning before the explanation, for the fields whose answer leaves
        # the machine in the file. ContainsKey, not a bare read, because
        # StrictMode throws on a missing key.
        if ($Field.ContainsKey('W') -and [string]$Field.W) {
            $warn = New-Object Windows.Controls.TextBlock
            $warn.Text = [string]$Field.W
            $warn.FontSize = 12.5; $warn.TextWrapping = 'Wrap'; $warn.FontWeight = 'SemiBold'
            $warn.Margin = $(if ($kind -eq 'check') { '24,3,0,0' } else { '0,3,0,0' })
            $warn.MaxWidth = 620
            $warn.HorizontalAlignment = 'Left'
            & $Ref $warn 'Foreground' 'Bad'
            $null = $wrap.Children.Add($warn)
        }
        if ([string]$Field.N -and -not $noteRight) {
            $note = New-Object Windows.Controls.TextBlock
            $note.Text = [string]$Field.N
            $note.FontSize = 12.5; $note.TextWrapping = 'Wrap'
            $note.Margin = $(if ($kind -eq 'check') { '24,2,0,0' } else { '0,2,0,0' })
            $note.MaxWidth = 620
            $note.HorizontalAlignment = 'Left'
            & $Ref $note 'Foreground' 'Sub'
            $null = $wrap.Children.Add($note)
            # The same class of text as an item's description - one line under a
            # control, the same on every visit.
            $null = $uaNoteEls.Add($note)
        }

        # The same panel as everything else, unless the note is riding beside
        # it.
        $holder = $wrap
        if ($noteRight) {
            $holder = New-Object Windows.Controls.StackPanel
            $holder.Orientation = 'Horizontal'
            $null = $wrap.Children.Add($holder)
        }

        switch ($kind) {
            'text' {
                $ctrl = New-Object Windows.Controls.TextBox
                $ctrl.Text = [string]$uaOptions.($Field.K)
                $ctrl.FontSize = 13; $ctrl.Padding = '6,4'; $ctrl.Width = 320
                $ctrl.HorizontalAlignment = 'Left'; $ctrl.Margin = '0,5,0,0'
                # Refused as it is typed rather than reported afterwards: a name
                # Windows will not accept is a Setup that stops on a screen this
                # file was written to skip.
                if ($Field.ContainsKey('Limit') -and [int]$Field.Limit -gt 0) {
                    $ctrl.MaxLength = [int]$Field.Limit
                }
                if ($Field.ContainsKey('NoSpaces') -and [bool]$Field.NoSpaces) {
                    $ctrl.Add_PreviewTextInput({
                        if ([string]$args[1].Text -match '\s') { $args[1].Handled = $true }
                    })
                    # Space does not raise PreviewTextInput on every input path,
                    # and neither does a paste. Both are caught here.
                    $ctrl.Add_PreviewKeyDown({
                        if ($args[1].Key -eq [Windows.Input.Key]::Space) { $args[1].Handled = $true }
                    })
                    $ctrl.Add_TextChanged({
                        $clean = ([string]$this.Text) -replace '\s', ''
                        if ($clean -ne [string]$this.Text) {
                            $at = [Math]::Max(0, $this.CaretIndex - 1)
                            $this.Text = $clean
                            $this.CaretIndex = [Math]::Min($at, $this.Text.Length)
                        }
                    })
                }
                $null = $holder.Children.Add($ctrl)
            }
            'number' {
                $ctrl = New-Object Windows.Controls.TextBox
                $ctrl.Text = [string][int]$uaOptions.($Field.K)
                $ctrl.FontSize = 13; $ctrl.Padding = '6,4'; $ctrl.Width = 80
                $ctrl.HorizontalAlignment = 'Left'; $ctrl.Margin = '0,5,0,0'
                $null = $holder.Children.Add($ctrl)
            }
            'file' {
                # A file picker, not a drop-down of one folder: a saved
                # selection is a file somebody keeps where they keep files.
                # Chosen from elsewhere it is copied into profile_saves, because
                # the generated command runs the toolkit out of a copy of that
                # folder.
                $row = New-Object Windows.Controls.StackPanel
                $row.Orientation = 'Horizontal'
                $ctrl = New-Object Windows.Controls.TextBox
                $ctrl.Text = [string]$uaOptions.($Field.K)
                $ctrl.IsReadOnly = $true
                $ctrl.FontSize = 13; $ctrl.Padding = '6,4'; $ctrl.Width = 320
                $ctrl.Margin = '0,5,0,0'
                $null = $row.Children.Add($ctrl)
                $pick = New-Object Windows.Controls.Button
                $pick.Content = 'Choose'
                $pick.Padding = '14,4'; $pick.Margin = '8,5,0,0'; $pick.FontSize = 12.5
                $pick.VerticalAlignment = 'Top'
                $null = $row.Children.Add($pick)
                $null = $holder.Children.Add($row)
                # Where the picked file ended up, said after the fact rather
                # than as an instruction beforehand.
                $said = New-Object Windows.Controls.TextBlock
                $said.FontSize = 11.5; $said.TextWrapping = 'Wrap'; $said.Margin = '0,4,0,0'
                $said.MaxWidth = 620; $said.HorizontalAlignment = 'Left'
                $said.Visibility = 'Collapsed'
                & $Ref $said 'Foreground' 'Sub'
                $null = $holder.Children.Add($said)
                # Everything the handler needs, copied into this scope first -
                # it is a closure and a reach up the chain captures $null.
                $seed  = Join-Path (Split-Path -Parent $ModulePath) 'profile_saves'
                $box   = $ctrl
                $note2 = $said
                $paint = $Ref
                $pick.Add_Click({
                    $dlg = New-Object Microsoft.Win32.OpenFileDialog
                    $dlg.Title  = 'Choose a saved selection'
                    $dlg.Filter = 'Saved selections (*.json)|*.json|All files (*.*)|*.*'
                    try { if (Test-Path -LiteralPath $seed) { $dlg.InitialDirectory = $seed } } catch { }
                    if ($dlg.ShowDialog() -ne $true) { return }
                    $src  = [string]$dlg.FileName
                    $leaf = [IO.Path]::GetFileName($src)
                    $box.Text = $leaf
                    $note2.Visibility = 'Visible'
                    $here = ''
                    try { $here = [string](Join-Path $seed $leaf) } catch { }
                    if ($here -and ($src -ieq $here)) {
                        $note2.Text = "Using $leaf from the toolkit's profile_saves folder, so it travels with the rest of it."
                        & $paint $note2 'Foreground' 'Sub'
                        return
                    }
                    try {
                        if (-not (Test-Path -LiteralPath $seed)) { $null = New-Item -ItemType Directory -Path $seed -Force }
                        Copy-Item -LiteralPath $src -Destination $here -Force -ErrorAction Stop
                        $note2.Text = "Copied into the toolkit's profile_saves folder, so it travels with the rest of it."
                        & $paint $note2 'Foreground' 'Sub'
                    } catch {
                        $note2.Text = "$leaf could not be copied into the toolkit's profile_saves folder ($($_.Exception.Message)). Put it there by hand, or Setup will find no selection to run."
                        & $paint $note2 'Foreground' 'Bad'
                    }
                }.GetNewClosure())
            }
            'password' {
                # A real PasswordBox rather than a TextBox: this ends up in the
                # file as plain text either way, but the screen is not the file.
                $ctrl = New-Object Windows.Controls.PasswordBox
                $ctrl.Password = [string]$uaOptions.($Field.K)
                $ctrl.FontSize = 13; $ctrl.Padding = '6,4'; $ctrl.Width = 320
                $ctrl.HorizontalAlignment = 'Left'; $ctrl.Margin = '0,5,0,0'
                $null = $holder.Children.Add($ctrl)
            }
            'lines' {
                $ctrl = New-Object Windows.Controls.TextBox
                $ctrl.Text = (@($uaOptions.($Field.K)) -join "`r`n")
                $ctrl.AcceptsReturn = $true; $ctrl.TextWrapping = 'NoWrap'
                $ctrl.VerticalScrollBarVisibility = 'Auto'
                $ctrl.HorizontalScrollBarVisibility = 'Auto'
                $ctrl.FontFamily = New-Object Windows.Media.FontFamily 'Consolas'
                $ctrl.FontSize = 12.5; $ctrl.Padding = '6,4'; $ctrl.Height = 90
                $ctrl.Margin = '0,5,0,0'; $ctrl.MaxWidth = 620
                $ctrl.HorizontalAlignment = 'Left'; $ctrl.MinWidth = 460
                $null = $holder.Children.Add($ctrl)
            }
            'combo' {
                # A drop-down for the fields whose answers are a list too long
                # to write out and too specific to type.
                $ctrl = New-Object Windows.Controls.ComboBox
                $ctrl.FontSize = 13; $ctrl.Padding = '6,4'; $ctrl.Width = 320
                $ctrl.HorizontalAlignment = 'Left'; $ctrl.Margin = '0,5,0,0'
                $ctrl.MaxDropDownHeight = 420
                $table = switch ([string]$Field.C) {
                    'keyboards' { $UA_KEYBOARDS }
                    'timezones' { $UA_TIMEZONES }
                    'editions'  { $UA_EDITIONS }
                    default     { $UA_LANGUAGES }
                }
                $have = [string]$uaOptions.($Field.K)
                foreach ($k in $table.Keys) {
                    $it = New-Object Windows.Controls.ComboBoxItem
                    $it.Content = [string]$table[$k]; $it.Tag = [string]$k
                    $null = $ctrl.Items.Add($it)
                    if ([string]$k -eq $have) { $ctrl.SelectedItem = $it }
                }
                if (-not $ctrl.SelectedItem -and $ctrl.Items.Count) { $ctrl.SelectedIndex = 0 }
                # Picking a display language sets the two locales under it, for
                # as long as the tick under it says to.
                if ($Field.ContainsKey('Sync')) {
                    $follow = @($Field.Sync)
                    $ctrls  = $uaControls
                    $busy   = $uaSync
                    $ctrl.Add_SelectionChanged({
                        $sel = $this.SelectedItem
                        if (-not $sel) { return }
                        $box = @($ctrls | Where-Object { $_.Key -eq 'SyncLocales' })
                        if ($box.Count -and -not $box[0].Ctrl.IsChecked) { return }
                        # Raised while the followers are being set, so their own
                        # handlers can tell this apart from somebody choosing.
                        $busy.On = $true
                        try {
                            foreach ($k in $follow) {
                                $c = @($ctrls | Where-Object { $_.Key -eq $k -and $_.Kind -eq 'combo' })
                                if (-not $c.Count) { continue }
                                foreach ($it in $c[0].Ctrl.Items) {
                                    if ([string]$it.Tag -eq [string]$sel.Tag) { $c[0].Ctrl.SelectedItem = $it }
                                }
                            }
                        } finally { $busy.On = $false }
                    }.GetNewClosure())
                }
                $null = $holder.Children.Add($ctrl)
            }
            'choice' {
                # Radio buttons rather than a drop-down, because every one of
                # these has three or fewer answers.
                $ctrl = New-Object System.Collections.Generic.List[psobject]
                $grp  = 'ua' + [string]$Field.K
                # ContainsKey, not $Field.D: only one of these fields spells its
                # answers out, and StrictMode throws on a missing key.
                $spelt = $null
                if ($Field.ContainsKey('D')) { $spelt = $Field.D }
                foreach ($c in @($Field.C)) {
                    $rb = New-Object Windows.Controls.RadioButton
                    $rb.GroupName = $grp
                    $rb.Content = $(if ($spelt -and $spelt.ContainsKey([string]$c)) { [string]$spelt[[string]$c] } else { [string]$c })
                    $rb.FontSize = 13; $rb.Margin = '0,5,0,0'
                    $rb.IsChecked = ([string]$uaOptions.($Field.K) -eq [string]$c)
                    & $Ref $rb 'Foreground' 'Text'
                    $rb.Tag = [string]$c
                    $null = $wrap.Children.Add($rb)
                    $ctrl.Add($rb)
                }
            }
        }
        if ($noteRight) {
            $note = New-Object Windows.Controls.TextBlock
            $note.Text = [string]$Field.N
            # Smaller than a note above the control, on purpose: beside a field
            # it is an aside.
            $note.FontSize = 11.5; $note.TextWrapping = 'Wrap'
            $note.Margin = '12,9,0,0'; $note.MaxWidth = 320
            $note.VerticalAlignment = 'Top'
            & $Ref $note 'Foreground' 'Sub'
            $null = $holder.Children.Add($note)
        }
        # Card, not $Host2, and for an inline field it is the card it went
        # inside.
        $entry = [pscustomobject]@{ Key = [string]$Field.K; Kind = $kind; Ctrl = $ctrl; Touched = $false
                                    Card = $card }
        if ($kind -eq 'combo') {
            # A locale stops following the display language the moment somebody
            # sets it on purpose, and every route into it raises
            # SelectionChanged.
            $ctrl.Tag = $entry
            $busy2 = $uaSync
            $ctrl.Add_SelectionChanged({
                if (-not $busy2.On) { $this.Tag.Touched = $true }
            }.GetNewClosure())
        }
        $uaControls.Add($entry)
    }.GetNewClosure()

    # One place, walking the same list the builder walked, so a control that
    # exists is a control that is read.
    $uaRead = {
        $o = New-WDUnattendOptions
        foreach ($c in $uaControls) {
            switch ($c.Kind) {
                'check'    { $o.($c.Key) = [bool]$c.Ctrl.IsChecked }
                'text'     { $o.($c.Key) = [string]$c.Ctrl.Text.Trim() }
                # A read-only box holding the leaf name the picker put there.
                'file'     { $o.($c.Key) = [string]$c.Ctrl.Text.Trim() }
                'password' { $o.($c.Key) = [string]$c.Ctrl.Password }
                'number'   {
                    $n = 0
                    if (-not [int]::TryParse([string]$c.Ctrl.Text, [ref]$n)) { $n = 0 }
                    $o.($c.Key) = $n
                }
                'lines' {
                    $o.($c.Key) = @([string]$c.Ctrl.Text -split "`r?`n" |
                                    ForEach-Object { $_.Trim() } | Where-Object { $_ })
                }
                'combo' {
                    if ($c.Ctrl.SelectedItem) { $o.($c.Key) = [string]$c.Ctrl.SelectedItem.Tag }
                }
                'choice' {
                    foreach ($rb in $c.Ctrl) { if ($rb.IsChecked) { $o.($c.Key) = [string]$rb.Tag } }
                }
                # A section's own On/Off. Its Tag is a hashtable rather than the
                # bare value, because the radio also has to know which panel to
                # show.
                'switch' {
                    foreach ($rb in $c.Ctrl) { if ($rb.IsChecked) { $o.($c.Key) = [bool]$rb.Tag.On } }
                }
            }
        }
        # Anything with no name is dropped here rather than in the generator, so
        # what the summary counts and what the file carries are one list.
        $extra = New-Object System.Collections.Generic.List[psobject]
        foreach ($a in $uaExtraAccts) {
            $nm = [string]$a.Name.Text
            if ($nm) { $nm = $nm.Trim() }
            if (-not $nm) { continue }
            $gp = 'Users'
            foreach ($rb in $a.Groups) { if ($rb.IsChecked) { $gp = [string]$rb.Tag } }
            $extra.Add([pscustomobject]@{ Name = $nm; Password = [string]$a.Password.Password; Group = $gp })
        }
        $o.ExtraAccounts = $extra.ToArray()
        # A password with no hint is a password Windows will not accept, and
        # being refused at the sign-in screen of a machine you just built is a
        # bad first minute.
        if ($o.AccountPassword -and -not $o.AccountHint) { $o.AccountHint = 'No hint set' }
        $o
    }.GetNewClosure()

    # The selected items, as manifest objects, for the payload split.
    $uaItems = {
        $ids = @(& $checkedIds)
        $out = New-Object System.Collections.Generic.List[psobject]
        foreach ($id in $ids) { if ($uaItemById.ContainsKey([string]$id)) { $out.Add($uaItemById[[string]$id]) } }
        $out
    }.GetNewClosure()

    # Recomputed on every visit, because the selection moves on the Advanced
    # page in between.
    $uaPaintSummary = {
        $panel = $uaSummary.Panel
        if (-not $panel) { return }
        $panel.Children.Clear()
        $pay = Get-WDUnattendPayload -Items @(& $uaItems)

        $carried = @(
            @{ N = @($pay.Registry).Count;   T = 'registry setting' }
            @{ N = @($pay.Appx).Count;       T = 'app removed before it is ever installed' }
            @{ N = @($pay.Service).Count;    T = 'service change' }
            @{ N = @($pay.Task).Count;       T = 'scheduled task change' }
            @{ N = @($pay.Feature).Count;    T = 'Windows feature change' }
            @{ N = @($pay.Capability).Count; T = 'Windows capability change' }
        )
        foreach ($c in $carried) {
            if (-not $c.N) { continue }
            $t = New-Object Windows.Controls.TextBlock
            $t.Text = "$($c.N) $($c.T)$(if ([int]$c.N -ne 1) { 's' })"
            $t.FontSize = 13; $t.Margin = '0,2,0,0'; $t.TextWrapping = 'Wrap'
            & $Ref $t 'Foreground' 'Text'
            $null = $panel.Children.Add($t)
        }
        # Deprovisioning is the reason to do this at all rather than afterwards,
        # and it is not obvious from a count.
        if (@($pay.Appx).Count) {
            $t = New-Object Windows.Controls.TextBlock
            $t.Text = 'Those apps are deprovisioned rather than uninstalled - they are never staged for any account, so there is nothing left behind and nothing for a later Windows update to put back.'
            $t.FontSize = 12.5; $t.TextWrapping = 'Wrap'; $t.Margin = '0,6,0,0'; $t.MaxWidth = 620
            $t.HorizontalAlignment = 'Left'
            & $Ref $t 'Foreground' 'Sub'
            $null = $panel.Children.Add($t)
        }

        # And what it could not take, named with the reason: a generator that
        # silently drops a tenth of the plan is worse than one that refuses.
        $skip = @($pay.Skipped)
        $h = New-Object Windows.Controls.TextBlock
        $h.FontSize = 13.5; $h.FontWeight = 'SemiBold'; $h.Margin = '0,14,0,2'; $h.TextWrapping = 'Wrap'
        $h.Text = $(if ($skip.Count) {
                        "$($skip.Count) selected item$(if ($skip.Count -ne 1) { 's' }) cannot go in an answer file"
                    } else { 'Everything you have selected fits in the file' })
        & $Ref $h 'Foreground' $(if ($skip.Count) { 'Warn' } else { 'Ok' })
        $null = $panel.Children.Add($h)
        if ($skip.Count) {
            $sub = New-Object Windows.Controls.TextBlock
            $sub.Text = 'Run the toolkit on the finished machine to deal with these. Nothing here is lost - it is work the file cannot do, not work the file is skipping.'
            $sub.FontSize = 12.5; $sub.TextWrapping = 'Wrap'; $sub.Margin = '0,0,0,4'; $sub.MaxWidth = 620
            $sub.HorizontalAlignment = 'Left'
            & $Ref $sub 'Foreground' 'Sub'
            $null = $panel.Children.Add($sub)
            foreach ($s in $skip) {
                $t = New-Object Windows.Controls.TextBlock
                $t.Text = "$($s.Name) - $($s.Why)"
                $t.FontSize = 12.5; $t.TextWrapping = 'Wrap'; $t.Margin = '0,2,0,0'; $t.MaxWidth = 620
                $t.HorizontalAlignment = 'Left'
                & $Ref $t 'Foreground' 'Sub'
                $null = $panel.Children.Add($t)
            }
        }

        $ui.TxtUaTally.Text = "$(@($pay.Registry).Count + @($pay.Appx).Count + @($pay.Service).Count + @($pay.Task).Count) change(s) carried" +
                              $(if ($skip.Count) { ", $($skip.Count) left for a run on the machine" } else { '' })
    }.GetNewClosure()

    $uaBuild = {
        if ($uaBuilt.Done) { return }
        $uaBuilt.Done = $true
        # Timed wherever it runs from: the pre-warm records its own figure, and
        # this covers the click path.
        $uaWatchOwn = [Diagnostics.Stopwatch]::StartNew()

        # No standing header: it said what the page is for, and the first
        # section says that better.
        $ui.TxtUaHint.Text = ''
        $ui.TxtUaHint.Visibility = 'Collapsed'
        # Painted here rather than in the XAML because the colour is a theme
        # key.
        & $Ref $ui.UaIndexRule 'Background' 'Line'
        # On PageUnattend rather than the window: a collapsed element raises no
        # SizeChanged, so this costs nothing on the other pages.
        $ui.PageUnattend.Add_SizeChanged($uaSizeRail)

        foreach ($sec in $UA_SECTIONS) {
            # One box holding the whole section: title, rule, note, options. The
            # box is what says where a section starts and stops.
            $block = New-Object Windows.Controls.Border
            $block.Margin = '0,0,0,14'; $block.Padding = '18,13,18,15'
            $block.CornerRadius = New-Object Windows.CornerRadius 6
            $block.BorderThickness = New-Object Windows.Thickness 1
            $block.MaxWidth = 860; $block.HorizontalAlignment = 'Stretch'
            & $Ref $block 'Background' 'Card'
            & $Ref $block 'BorderBrush' 'Line'
            $stack = New-Object Windows.Controls.StackPanel
            $block.Child = $stack

            # A DockPanel rather than a StackPanel so anything added lands
            # immediately beside the title.
            $headRow = New-Object Windows.Controls.DockPanel
            $headRow.LastChildFill = $false
            $headRow.Margin = '0,0,0,4'
            $head = New-Object Windows.Controls.TextBlock
            $head.Text = [string]$sec.T; $head.FontSize = 16; $head.FontWeight = 'SemiBold'
            $head.TextWrapping = 'Wrap'; $head.VerticalAlignment = 'Center'
            & $Ref $head 'Foreground' 'Text'
            [Windows.Controls.DockPanel]::SetDock($head, 'Left')
            $null = $headRow.Children.Add($head)
            $null = $stack.Children.Add($headRow)

            $rule = New-Object Windows.Controls.Border
            $rule.Height = 1; & $Ref $rule 'Background' 'Line'; $rule.Opacity = 0.55; $rule.Margin = '0,0,0,8'
            $null = $stack.Children.Add($rule)

            if ([string]$sec.N) {
                $note = New-Object Windows.Controls.TextBlock
                $note.Text = [string]$sec.N; $note.FontSize = 12.5; $note.TextWrapping = 'Wrap'
                $note.Margin = '0,0,0,8'; $note.MaxWidth = 640; $note.HorizontalAlignment = 'Left'
                & $Ref $note 'Foreground' 'Sub'
                $null = $stack.Children.Add($note)
            }

            $body = New-Object Windows.Controls.StackPanel
            $null = $stack.Children.Add($body)
            $uaSecPanel[[string]$sec.K] = $body
            # The title row, so a field can ask to be rendered beside the title.
            $uaSecHead[[string]$sec.K] = $headRow
            $null = $ui.UaContent.Children.Add($block)
            $uaHeads.Add([pscustomobject]@{ Key = [string]$sec.K; Name = [string]$sec.T; Head = $head })

            # On/Off beside the title, for a section whose every field is
            # conditional on one answer.
            if ($sec.ContainsKey('Toggle') -and [string]$sec.Toggle) {
                $sw = New-Object Windows.Controls.StackPanel
                $sw.Orientation = 'Horizontal'; $sw.VerticalAlignment = 'Center'
                $sw.Margin = '14,0,0,0'
                $grp = 'uaSec' + [string]$sec.K
                $pair = New-Object System.Collections.Generic.List[psobject]
                foreach ($opt in @(@{ L = 'On'; V = $true }, @{ L = 'Off'; V = $false })) {
                    $rb = New-Object Windows.Controls.RadioButton
                    $rb.GroupName = $grp; $rb.Content = [string]$opt.L
                    $rb.FontSize = 13; $rb.Margin = '0,0,10,0'; $rb.VerticalAlignment = 'Center'
                    $rb.IsChecked = ([bool]$uaOptions.($sec.Toggle) -eq [bool]$opt.V)
                    & $Ref $rb 'Foreground' 'Text'
                    $rb.Tag = [bool]$opt.V
                    $null = $sw.Children.Add($rb)
                    $pair.Add($rb)
                }
                # Everything the handler needs on the Tag, so no closure has to
                # reach two scopes up.
                foreach ($rb in $pair) {
                    $rb.Tag = @{ On = [bool]$rb.Tag; Body = $body }
                    $rb.Add_Checked({
                        $t = $this.Tag
                        $t.Body.Visibility = $(if ($t.On) { 'Visible' } else { 'Collapsed' })
                    })
                }
                $body.Visibility = $(if ([bool]$uaOptions.($sec.Toggle)) { 'Visible' } else { 'Collapsed' })
                $uaControls.Add([pscustomobject]@{ Key = [string]$sec.Toggle; Kind = 'switch'
                                                   Ctrl = $pair; Touched = $false; Card = $null })
                # Added after the title, which is docked left, so it lands
                # directly beside the words it answers.
                $null = $headRow.Children.Add($sw)
                # In the heading row rather than the section body, because the
                # body is exactly what is hidden while the section is Off.
                $why = New-Object Windows.Controls.TextBlock
                $why.FontSize = 12; $why.VerticalAlignment = 'Center'
                $why.Margin = '4,0,0,0'; $why.TextWrapping = 'Wrap'; $why.MaxWidth = 420
                $why.Visibility = 'Collapsed'
                & $Ref $why 'Foreground' 'Warn'
                $null = $headRow.Children.Add($why)
                $uaGate[[string]$sec.K] = @{ Pair = $pair; Why = $why; Body = $body }
            }
        }

        foreach ($f in $UA_FIELDS) {
            if ([string]$f.T -eq 'skip') { continue }
            if ($f.ContainsKey('InHead') -and [bool]$f.InHead) {
                & $uaAddField $f $uaSecHead[[string]$f.S]
            } else {
                & $uaAddField $f $uaSecPanel[[string]$f.S]
            }
        }

        # One tick empties the rest of its own section: telling Setup not to
        # require a network and then filling in a network password is two
        # answers to one question.
        foreach ($f in $UA_FIELDS) {
            if (-not $f.ContainsKey('Collapses') -or -not [string]$f.Collapses) { continue }
            $me = @($uaControls | Where-Object { $_.Key -eq [string]$f.K })
            if (-not $me.Count) { continue }
            $others = @($UA_FIELDS |
                        Where-Object { [string]$_.S -eq [string]$f.Collapses -and [string]$_.K -ne [string]$f.K } |
                        ForEach-Object { $k2 = [string]$_.K
                                         @($uaControls | Where-Object { $_.Key -eq $k2 }) } |
                        Where-Object { $_ -and $_.Card })
            if (-not $others.Count) { continue }
            $apply = {
                param($Box, $Cards)
                foreach ($c in @($Cards)) {
                    $c.Card.Visibility = $(if ($Box.IsChecked) { 'Collapsed' } else { 'Visible' })
                }
            }
            $me[0].Ctrl.Tag = @{ Cards = $others; Apply = $apply }
            $me[0].Ctrl.Add_Click({
                $t = $this.Tag
                & $t.Apply $this $t.Cards
            })
            & $apply $me[0].Ctrl $others
        }

        # A field that only exists under one answer.
        foreach ($f in $UA_FIELDS) {
            if (-not $f.ContainsKey('ShowWhen') -or -not [string]$f.ShowWhen) { continue }
            $mine = @($uaControls | Where-Object { $_.Key -eq [string]$f.K })
            $on   = @($uaControls | Where-Object { $_.Key -eq [string]$f.ShowWhen })
            if (-not $mine.Count -or -not $on.Count -or -not $mine[0].Card) { continue }
            $want = [string]$f.ShowIs
            $gated = $mine[0].Card
            # Not on the Tag, which is the usual trick here and is wrong for
            # this: a choice field's radios carry their own value there, and
            # $uaRead reads it back.
            foreach ($rb in @($on[0].Ctrl)) {
                $mineValue = [string]$rb.Tag
                $rb.Add_Checked({
                    $gated.Visibility = $(if ($mineValue -eq $want) { 'Visible' } else { 'Collapsed' })
                }.GetNewClosure())
                # The starting state, taken from whichever radio is already on.
                if ($rb.IsChecked) {
                    $gated.Visibility = $(if ($mineValue -eq $want) { 'Visible' } else { 'Collapsed' })
                }
            }
        }

        # Auto-debloat needs an administrator, and says so: the account this
        # file creates is the one that would have to undo the run.
        $gate = $uaGate['toolkit']
        $grpBox = @($uaControls | Where-Object { $_.Key -eq 'AccountGroup' })
        if ($gate -and $grpBox.Count) {
            $syncToolkitGate = {
                $admin = $false
                foreach ($rb in @($grpBox[0].Ctrl)) {
                    if ($rb.IsChecked -and [string]$rb.Tag -eq 'Administrators') { $admin = $true }
                }
                $onRb = @($gate.Pair | Where-Object { [bool]$_.Tag.On })
                if (-not $onRb.Count) { return }
                $onRb[0].IsEnabled = $admin
                $gate.Why.Text = $(if ($admin) { '' } else {
                    'Needs an Administrator account. The run itself does not sign in, but the account this file creates is the one that would have to undo it - set Account type to Administrators under Your account.' })
                $gate.Why.Visibility = $(if ($admin) { 'Collapsed' } else { 'Visible' })
                if (-not $admin) {
                    foreach ($rb in @($gate.Pair)) { $rb.IsChecked = (-not [bool]$rb.Tag.On) }
                    $gate.Body.Visibility = 'Collapsed'
                }
            }.GetNewClosure()
            foreach ($rb in @($grpBox[0].Ctrl)) { $rb.Add_Checked($syncToolkitGate) }
            # The starting state. Administrators is the default, so this is
            # normally a no-op.
            & $syncToolkitGate
            $uaGateSync.Fn = $syncToolkitGate
        }

        # Ticking the sync applies it there and then, rather than waiting for
        # the next language change.
        $syncBox = @($uaControls | Where-Object { $_.Key -eq 'SyncLocales' })
        $langBox = @($uaControls | Where-Object { $_.Key -eq 'UILanguage' })
        if ($syncBox.Count -and $langBox.Count) {
            $lang    = $langBox[0].Ctrl
            $ctrls2  = $uaControls
            $busy3   = $uaSync
            $syncBox[0].Ctrl.Add_Click({
                if (-not $this.IsChecked) { return }
                $sel = $lang.SelectedItem
                if (-not $sel) { return }
                $busy3.On = $true
                try {
                    foreach ($k in @('SystemLocale', 'UserLocale')) {
                        $c = @($ctrls2 | Where-Object { $_.Key -eq $k -and $_.Kind -eq 'combo' })
                        if (-not $c.Count) { continue }
                        foreach ($it in $c[0].Ctrl.Items) {
                            if ([string]$it.Tag -eq [string]$sel.Tag) { $c[0].Ctrl.SelectedItem = $it }
                        }
                    }
                } finally { $busy3.On = $false }
            }.GetNewClosure())
        }

        # The two wipe labels follow the disk number.
        $numbered = @($UA_FIELDS | Where-Object { $_.ContainsKey('DiskNum') -and [bool]$_.DiskNum })
        if ($numbered.Count) {
            $diskBox = @($uaControls | Where-Object { $_.Key -eq 'DiskId' })
            $labels  = New-Object System.Collections.Generic.List[psobject]
            foreach ($f in $numbered) {
                $owner = @($uaControls | Where-Object { $_.Key -eq [string]$f.K })
                if (-not $owner.Count) { continue }
                foreach ($rb in @($owner[0].Ctrl)) {
                    $spelt = $f.D[[string]$rb.Tag]
                    if ([string]$spelt -notmatch '\$0') { continue }
                    $labels.Add([pscustomobject]@{ Rb = $rb; Template = [string]$spelt })
                }
            }
            if ($diskBox.Count -and $labels.Count) {
                $renumberDisk = {
                    param($Box, $Labels)
                    $n = 0
                    if (-not [int]::TryParse([string]$Box.Text, [ref]$n)) { $n = 0 }
                    foreach ($l in @($Labels)) { $l.Rb.Content = $l.Template -replace '\$0', [string]$n }
                }
                $diskBox[0].Ctrl.Tag = @{ Labels = $labels; Apply = $renumberDisk }
                $diskBox[0].Ctrl.Add_TextChanged({
                    $t = $this.Tag
                    & $t.Apply $this $t.Labels
                })
                & $renumberDisk $diskBox[0].Ctrl $labels
            }
        }

        # More accounts, as many as somebody wants.
        $acctPanel = New-Object Windows.Controls.StackPanel
        $null = $uaSecPanel['account'].Children.Add($acctPanel)

        $addAcct = New-Object Windows.Controls.Button
        $addAcct.Content = 'Add another account'
        $addAcct.FontSize = 13; $addAcct.Padding = '12,5'; $addAcct.Margin = '0,12,0,0'
        $addAcct.HorizontalAlignment = 'Left'
        $null = $uaSecPanel['account'].Children.Add($addAcct)

        $paintUa  = $Ref
        $acctList = $uaExtraAccts
        $acctHome = $acctPanel
        # Numbered, not named "Another account": three identical boxes all
        # saying the same two words asks somebody to count boxes.
        $renumberAccts = {
            param($List)
            for ($i = 0; $i -lt $List.Count; $i++) { $List[$i].Title.Text = "Account $($i + 2)" }
        }
        $makeAcct = {
            $card = New-Object Windows.Controls.Border
            $card.Margin = '0,0,0,8'; $card.Padding = '12,9,12,11'
            $card.CornerRadius = New-Object Windows.CornerRadius 5
            $card.BorderThickness = New-Object Windows.Thickness 1
            $card.MaxWidth = 660; $card.HorizontalAlignment = 'Left'
            & $paintUa $card 'Background' 'Card'
            & $paintUa $card 'BorderBrush' 'Line'
            $sp = New-Object Windows.Controls.StackPanel
            $card.Child = $sp

            $top = New-Object Windows.Controls.DockPanel
            $top.LastChildFill = $true
            $drop = New-Object Windows.Controls.Button
            $drop.Content = 'Remove'; $drop.FontSize = 12; $drop.Padding = '9,2'
            [Windows.Controls.DockPanel]::SetDock($drop, 'Right')
            $null = $top.Children.Add($drop)
            $ttl = New-Object Windows.Controls.TextBlock
            $ttl.Text = "Account $($acctList.Count + 2)"
            $ttl.FontSize = 13.5; $ttl.FontWeight = 'SemiBold'
            $ttl.VerticalAlignment = 'Center'
            & $paintUa $ttl 'Foreground' 'Text'
            $null = $top.Children.Add($ttl)
            $null = $sp.Children.Add($top)

            $nameLbl = New-Object Windows.Controls.TextBlock
            $nameLbl.Text = 'Account name'; $nameLbl.FontSize = 13.5; $nameLbl.Margin = '0,8,0,0'
            & $paintUa $nameLbl 'Foreground' 'Text'
            $null = $sp.Children.Add($nameLbl)
            $nameBox = New-Object Windows.Controls.TextBox
            $nameBox.FontSize = 13; $nameBox.Padding = '6,4'; $nameBox.Width = 320
            $nameBox.HorizontalAlignment = 'Left'; $nameBox.Margin = '0,5,0,0'
            $null = $sp.Children.Add($nameBox)

            $pwdLbl = New-Object Windows.Controls.TextBlock
            $pwdLbl.Text = 'Password'; $pwdLbl.FontSize = 13.5; $pwdLbl.Margin = '0,10,0,0'
            & $paintUa $pwdLbl 'Foreground' 'Text'
            $null = $sp.Children.Add($pwdLbl)
            # No copy of the warning here: it is boxed once at the top of the
            # section, because something said three times in one box stops being
            # read.
            $pwdBox = New-Object Windows.Controls.PasswordBox
            $pwdBox.FontSize = 13; $pwdBox.Padding = '6,4'; $pwdBox.Width = 320
            $pwdBox.HorizontalAlignment = 'Left'; $pwdBox.Margin = '0,5,0,0'
            $null = $sp.Children.Add($pwdBox)

            $typeLbl = New-Object Windows.Controls.TextBlock
            $typeLbl.Text = 'Account type'; $typeLbl.FontSize = 13.5; $typeLbl.Margin = '0,10,0,0'
            & $paintUa $typeLbl 'Foreground' 'Text'
            $null = $sp.Children.Add($typeLbl)
            $grp = 'uaAcct' + [string]$acctList.Count + '_' + [string]$acctHome.Children.Count
            $radios = New-Object System.Collections.Generic.List[psobject]
            foreach ($g in @('Users', 'Administrators')) {
                $rb = New-Object Windows.Controls.RadioButton
                $rb.GroupName = $grp; $rb.Content = $g; $rb.FontSize = 13; $rb.Margin = '0,5,0,0'
                $rb.IsChecked = ($g -eq 'Users')
                & $paintUa $rb 'Foreground' 'Text'
                $rb.Tag = $g
                $null = $sp.Children.Add($rb)
                $radios.Add($rb)
            }

            $entry = [pscustomobject]@{ Name = $nameBox; Password = $pwdBox; Groups = $radios
                                        Card = $card; Title = $ttl }
            $acctList.Add($entry)
            # The renumber travels on the Tag rather than being reached for: the
            # handler is built inside a closure.
            $drop.Tag = @{ Entry = $entry; List = $acctList; Home = $acctHome; Renumber = $renumberAccts }
            $drop.Add_Click({
                $t = $this.Tag
                $null = $t.List.Remove($t.Entry)
                $t.Home.Children.Remove($t.Entry.Card)
                & $t.Renumber $t.List
            })
            $null = $acctHome.Children.Add($card)
            & $renumberAccts $acctList
        }.GetNewClosure()
        $addAcct.Add_Click($makeAcct)
        $uaAddBtn.Btn = $addAcct

        # What is dangerous is true of the section rather than of one control in
        # it, so it is said once where the section starts.
        $uaWarnBox = {
            param([string]$Where, [string]$Text)
            $b = New-Object Windows.Controls.Border
            $b.BorderThickness = New-Object Windows.Thickness 1
            $b.CornerRadius = New-Object Windows.CornerRadius 4
            $b.Padding = '12,8'; $b.Margin = '0,0,0,10'
            $b.MaxWidth = 780; $b.HorizontalAlignment = 'Left'
            & $Ref $b 'BorderBrush' 'Bad'
            $tb = New-Object Windows.Controls.TextBlock
            $tb.Text = $Text
            $tb.FontSize = 12.5; $tb.TextWrapping = 'Wrap'
            & $Ref $tb 'Foreground' 'Bad'
            $b.Child = $tb
            $uaSecPanel[$Where].Children.Insert(0, $b)
        }
        & $uaWarnBox 'disks' 'Erasing a disk from an answer file happens silently, on whatever machine the medium is booted on. There is no confirmation at install time and no way back. Leave this alone unless the medium will only ever be used on a machine you are deliberately wiping.'
        # Once, at the top, instead of above each password field and again
        # inside every added account.
        & $uaWarnBox 'account' $UA_PWD_WARN
        # And the third, for the same reason: a Wi-Fi password ends up in the
        # file in exactly the same plain text.
        & $uaWarnBox 'wifi' $UA_PWD_WARN

        # One paragraph, and the procedure is in the README. What has to be here
        # is what the page is, that it does nothing to this machine, and why
        # somebody would want one.
        $readmeRun = {
            param($Block)
            $link = New-Object Windows.Documents.Hyperlink
            $null = $link.Inlines.Add((New-Object Windows.Documents.Run 'README.md'))
            $link.ToolTip = 'Opens README.md in whatever this machine uses for .md files.'
            # The path is resolved when the link is built and carried on the
            # Hyperlink itself.
            $where = ''
            try { $where = [string](Join-Path (Split-Path -Parent $ModulePath) 'README.md') } catch { }
            $link.Tag = $where
            $link.Add_Click({
                $p = [string]$this.Tag
                if (-not $p) { return }
                try { Start-Process -FilePath $p -ErrorAction Stop }
                catch {
                    # No .md handler, or the file has moved. Showing the folder
                    # is the useful failure.
                    try { Start-Process -FilePath (Split-Path -Parent $p) -ErrorAction Stop } catch { }
                }
            }.GetNewClosure())
            $null = $Block.Inlines.Add($link)
        }

        $t = New-Object Windows.Controls.TextBlock
        $null = $t.Inlines.Add((New-Object Windows.Documents.Run 'This page sets up an autounattend.xml, a file that goes on a Windows installation USB/media device and automatically completes device setup. It does not affect the current machine at all. Its main benefits are the ability to set up your computer without internet, bypassing the Microsoft account requirement, and the ability to bypass hardware requirements for Windows 11. Fill in the parts you understand, leave the rest as defaults. Detailed instructions are in '))
        & $readmeRun $t
        $t.FontSize = 13; $t.TextWrapping = 'Wrap'; $t.Margin = '0,2,0,0'
        $t.MaxWidth = 780; $t.HorizontalAlignment = 'Left'
        & $Ref $t 'Foreground' 'Sub'
        $null = $uaSecPanel['note'].Children.Add($t)

        # The generated tally, folded in under the paragraph rather than given a
        # heading of its own.
        $sumRule = New-Object Windows.Controls.Border
        $sumRule.Height = 1; & $Ref $sumRule 'Background' 'Line'
        $sumRule.Opacity = 0.55; $sumRule.Margin = '0,13,0,11'
        $null = $uaSecPanel['note'].Children.Add($sumRule)
        # No heading: it read "What this file does" over a list of what the file
        # does.
        $sumPanel = New-Object Windows.Controls.StackPanel
        $null = $uaSecPanel['note'].Children.Add($sumPanel)
        $uaSummary.Panel = $sumPanel

        # What to put on the stick beside the file, said where the option that
        # needs it is.
        $tk = New-Object Windows.Controls.TextBlock
        $null = $tk.Inlines.Add((New-Object Windows.Documents.Run 'To use this option, copy the WinSetupToolkit folder (app, Modules, Manifest, and profile_saves folders) to the top level of the installation USB, beside autounattend.xml. It is copied to the machine during installation, so the USB can be removed as soon as Windows restarts, and it runs at the very end of Setup - before the sign-in screen appears, with nobody signed in and nothing to confirm. Because there is no screen to show it on, it leaves a full write-up on the desktop and offers it to the first person who signs in. Items that need a download may fail if network or App Installer are not yet set up; failures are reported and skipped. More detailed instructions in '))
        & $readmeRun $tk
        $tk.FontSize = 12.5; $tk.TextWrapping = 'Wrap'; $tk.Margin = '0,12,0,0'
        $tk.MaxWidth = 780; $tk.HorizontalAlignment = 'Left'
        & $Ref $tk 'Foreground' 'Sub'
        $null = $uaSecPanel['toolkit'].Children.Add($tk)

        # The rail. Same idea as Advanced's - an index into one page, never a
        # router.
        $uaRailCards.Clear()
        foreach ($h in $uaHeads) {
            $card = New-Object Windows.Controls.Border
            $card.Padding = '8,5'; $card.CornerRadius = New-Object Windows.CornerRadius 4
            $card.Margin = '0,0,0,1'; $card.Cursor = 'Hand'
            & $Ref $card 'Background' 'Flat'
            $lbl = New-Object Windows.Controls.TextBlock
            $lbl.Text = $h.Name; $lbl.FontSize = 12.5; $lbl.TextTrimming = 'CharacterEllipsis'
            & $Ref $lbl 'Foreground' 'Sub'
            $card.Child = $lbl
            $uaRailCards.Add([pscustomobject]@{ Card = $card; Label = $lbl })
            # Copied into this scope for the handlers, which capture only what
            # is local here.
            $setBrush = $Ref
            $sv = $ui.UaScroll
            $content = $ui.UaContent
            $target = $h.Head
            $card.Add_MouseLeftButtonUp({
                try {
                    if (-not $target.IsDescendantOf($content)) { return }
                    $y = $target.TransformToAncestor($content).Transform((New-Object Windows.Point 0, 0)).Y
                    $sv.ScrollToVerticalOffset([Math]::Max(0, $y - 8))
                } catch { }
            }.GetNewClosure())
            $card.Add_MouseEnter({ & $setBrush $this 'Background' 'RowHover' }.GetNewClosure())
            $card.Add_MouseLeave({ & $setBrush $this 'Background' 'Flat' }.GetNewClosure())
            $null = $ui.UaIndexPanel.Children.Add($card)
        }
        & $uaSizeRail
        $uaWatchOwn.Stop()
        $uaBuilt.Ms = [int]$uaWatchOwn.ElapsedMilliseconds
    }.GetNewClosure()

    # Generating is separated from writing so the self test can drive the whole
    # form without a file dialog, and so the two cannot disagree about what they
    # produced.
    $uaGenerate = {
        $o = & $uaRead
        $items = $null
        if ($o.IncludeDebloat) { $items = @(& $uaItems) }
        $pay = $null
        if ($items) { $pay = Get-WDUnattendPayload -Items $items }
        $xml = New-WDUnattendXml -Options $o -Payload $pay
        [pscustomobject]@{ Options = $o; Xml = $xml; Check = (Test-WDUnattendXml -Xml $xml -Options $o) }
    }.GetNewClosure()

    # Built before the page is shown, not after. It used to swap pages, pump a
    # frame, then build - painting the empty page on purpose.
    $ui.BtnUnattend.Add_Click({
        & $uaBuild
        & $uaPaintSummary
        & $showPage 'PageUnattend'
        $ui.UaScroll.ScrollToVerticalOffset(0)
    }.GetNewClosure())
    $ui.BtnUaBack.Add_Click({ & $showPage 'PageHome' }.GetNewClosure())

    $ui.BtnUaShow.Add_Click({
        if ($state.NoPrompts) { return }
        $r = & $uaGenerate
        $body = $r.Xml
        # A MessageBox truncates without saying so, and this is the one control
        # whose whole job is showing the file.
        try {
            $p = Join-Path ([IO.Path]::GetTempPath()) 'autounattend-preview.xml'
            [IO.File]::WriteAllText($p, $body, (New-Object System.Text.UTF8Encoding $false))
            Start-Process -FilePath $p | Out-Null
        } catch {
            Show-WDMessage ("Could not open a preview: $($_.Exception.Message)", 'Windows setup completion file', 'OK', 'Warning') | Out-Null
        }
    }.GetNewClosure())

    $ui.BtnUaWrite.Add_Click({
        if ($state.NoPrompts) { return }
        $r = & $uaGenerate
        if (-not $r.Check.Ok) {
            Show-WDMessage ("The file was not written:`n`n$($r.Check.Problems -join "`n")",
                                       'Windows setup completion file', 'OK', 'Error') | Out-Null
            return
        }
        if ($r.Options.DiskLayout -ne 'none') {
            $ans = Show-WDMessage (
                "This file will ERASE disk $($r.Options.DiskId) on whatever machine it is booted on, with no prompt and no way back." +
                "`n`nEverything on that disk is destroyed the moment Setup starts." +
                "`n`nWrite it anyway?", 'Erase a disk', 'YesNo', 'Warning')
            if ($ans -ne 'Yes') { return }
        }
        $dlg = New-Object Windows.Forms.SaveFileDialog
        $dlg.Filter = 'Windows answer file (autounattend.xml)|autounattend.xml|XML files (*.xml)|*.xml'
        $dlg.FileName = 'autounattend.xml'
        if ($dlg.ShowDialog() -ne 'OK') { return }
        $items = $null
        if ($r.Options.IncludeDebloat) { $items = @(& $uaItems) }
        $res = Export-WDUnattend -Path $dlg.FileName -Options $r.Options -Items $items
        $icon = $(if ([string]$res.Status -eq 'Failed') { 'Error' } else { 'None' })
        Show-WDMessage ("$($res.Message)`n`n$($res.Detail)`n`n" +
                                   'Copy it to the top level of the installation USB stick, next to setup.exe, and leave the name as autounattend.xml.',
                                   'Windows setup completion file', 'OK', $icon) | Out-Null
    }.GetNewClosure())

    # Theme keys, handed to $Ref by the two callers.
    $statusColor = {
        param($s)
        switch ($s) {
            'Removed' { 'Ok' } 'Changed' { 'Ok' }
            # The same gray as "not present", because they mean the same thing
            # to the person reading.
            'AlreadySet' { 'Muted' }
            'NotPresent' { 'Muted' } 'Skipped' { 'Muted' }
            'Obstruction' { 'Obstruct' }
            'Partial' { 'Warn' } 'Blocked' { 'Warn' } 'Found' { 'Warn' }
            'Failed' { 'Bad' } default { 'Sub' }
        }
    }

    foreach ($leg in @(
        @{ C = 'Ok';    T = 'green: success' },
        @{ C = 'Muted'; T = 'gray: nothing to do - not here, or already set that way' },
        @{ C = 'Warn';  T = 'yellow: partial success, Windows refusal, or something to review' },
        @{ C = 'Obstruct'; T = 'violet: something in the way, not a removal that failed' },
        @{ C = 'Bad';   T = 'red: error-type failure' })) {
        $sp = New-Object Windows.Controls.StackPanel
        $sp.Orientation = 'Horizontal'; $sp.Margin = '0,0,26,2'
        $dot = New-Object Windows.Controls.Border
        $dot.Width = 9; $dot.Height = 9; $dot.CornerRadius = 5
        & $Ref $dot 'Background' $leg.C
        $dot.Margin = '0,0,6,0'; $dot.VerticalAlignment = 'Center'
        $null = $sp.Children.Add($dot)
        $tx = New-Object Windows.Controls.TextBlock
        $tx.Text = $leg.T; $tx.FontSize = 12.5
        & $Ref $tx 'Foreground' $leg.C
        $tx.VerticalAlignment = 'Center'
        $null = $sp.Children.Add($tx)
        $null = $ui.LegendPanel.Children.Add($sp)
    }

    # Each counter doubles as a filter toggle for the log below it. Found
    # belongs here even though nothing increments a count for it.
    $statusFilter = @{ Removed=$true; Changed=$true; AlreadySet=$true; NotPresent=$true; Skipped=$true
                       Obstruction=$true; Partial=$true; Blocked=$true; Failed=$true; Found=$true }
    $logRows      = New-Object System.Collections.Generic.List[psobject]
    $statBlocks   = @{}
    $statLabels   = [ordered]@{
        Removed='removed'; Changed='changed'; AlreadySet='nothing to do'; NotPresent='not present'
        Skipped='skipped'; Obstruction='obstruction'; Partial='partial'; Blocked='blocked'; Failed='failed'
        Found='to review'
    }
    # The same set in the tense a simulation is entitled to: nothing has been
    # removed at the end of a preview.
    $statLabelsAhead = [ordered]@{
        Removed='to remove'; Changed='to change'; AlreadySet='nothing to do'; NotPresent='not present'
        Skipped='to skip'; Obstruction='obstruction'; Partial='partial'; Blocked='blocked'; Failed='would fail'
        Found='to review'
    }

    # Deliberately short: the status chips already group by outcome, so a sort
    # by status would be the same question twice.
    $runSortRank = [ordered]@{
        'Order it happened' = 'seq'
        'Name (A-Z)'        = 'name'
        'Worst outcome'     = 'worst'
    }
    # Worst first, so the things that need attention are at the top.
    $runStatusRank = @{
        Failed=0; Blocked=1; Partial=2; Obstruction=3; Found=4
        Removed=5; Changed=6; Skipped=7; AlreadySet=8; NotPresent=9
    }

    $applyLogFilter = {
        # Collapsing the row's content leaves its ListBoxItem container behind,
        # complete with padding, so hidden entries showed as ragged gaps.
        $ui.LogList.Items.Clear()

        $needle = ''
        if ($ui.TxtRunSearch) { $needle = ([string]$ui.TxtRunSearch.Text).Trim() }
        $mode = 'seq'
        if ($ui.CmbRunSort -and $ui.CmbRunSort.SelectedItem) {
            $mode = [string]$ui.CmbRunSort.SelectedItem.Tag
        }

        $keep = New-Object System.Collections.Generic.List[psobject]
        foreach ($lr in $logRows) {
            if (-not $statusFilter[$lr.Status]) { continue }
            if ($needle) {
                # Name and detail both, because half of what somebody searches
                # for after a run is in the detail.
                if (($lr.Name -notlike "*$needle*") -and ($lr.Detail -notlike "*$needle*")) { continue }
            }
            $keep.Add($lr)
        }

        $ordered = $keep
        if ($mode -eq 'name') {
            $ordered = @($keep | Sort-Object @{ E = { $_.Name } }, @{ E = { $_.Seq } })
        } elseif ($mode -eq 'worst') {
            $ordered = @($keep | Sort-Object @{ E = { $runStatusRank[[string]$_.Status] } }, @{ E = { $_.Seq } })
        }
        foreach ($lr in $ordered) { $null = $ui.LogList.Items.Add($lr.Element) }

        if ($ui.TxtRunShown) {
            $shown = @($ordered).Count
            $all   = $logRows.Count
            $ui.TxtRunShown.Text = $(if ($shown -eq $all) { "$all shown" } else { "$shown of $all shown" })
        }

        foreach ($k in @($statBlocks.Keys)) {
            $on = $statusFilter[$k]
            $statBlocks[$k].Text.Opacity = if ($on) { 1.0 } else { 0.4 }
            & $Ref $statBlocks[$k].Box 'BorderBrush' $(if ($on) { 'Line' } else { 'Bg' })
            & $Ref $statBlocks[$k].Box 'Background' $(if ($on) { 'Card' } else { 'Bg' })
        }
    }.GetNewClosure()

    # Locals for the click closures below to capture.
    $filt     = $statusFilter
    $refilter = $applyLogFilter

    # The sort picker and the search box.
    foreach ($label in $runSortRank.Keys) {
        $it = New-Object Windows.Controls.ComboBoxItem
        $it.Content = $label
        $it.Tag = $runSortRank[$label]
        $null = $ui.CmbRunSort.Items.Add($it)
    }
    $ui.CmbRunSort.SelectedIndex = 0
    $ui.CmbRunSort.Add_SelectionChanged({ & $refilter }.GetNewClosure())
    # Debounced for the same reason the other two search boxes are: the letters
    # are what the person is watching.
    $ui.TxtRunSearch.Add_TextChanged((& $newDebounce 180 $applyLogFilter))

    foreach ($k in $statLabels.Keys) {
        $box = New-Object Windows.Controls.Border
        $box.CornerRadius = 4; $box.Padding = '9,3,9,4'; $box.Margin = '0,0,8,4'
        $box.BorderThickness = New-Object Windows.Thickness 1
        & $Ref $box 'BorderBrush' 'Line'
        & $Ref $box 'Background' 'Card'
        $box.Cursor = 'Hand'
        $box.Tag = $k
        $box.ToolTip = 'Click to show or hide these in the list below'
        $tb = New-Object Windows.Controls.TextBlock
        $tb.FontSize = 13
        & $Ref $tb 'Foreground' (& $statusColor $k)
        $tb.Text = "$($statLabels[$k]) 0"
        $box.Child = $tb
        $box.Add_MouseLeftButtonUp({
            $key = $this.Tag
            $filt[$key] = -not $filt[$key]
            & $refilter
        }.GetNewClosure())
        $statBlocks[$k] = @{ Box = $box; Text = $tb; Label = $statLabels[$k] }
        $null = $ui.StatsPanel.Children.Add($box)
    }

    # Rough seconds per action, deliberately coarse - uninstaller speed varies
    # by an order of magnitude.
    $actionCost = @{
        appx = 4; appxPolicy = 1; winget = 50; uninstall = 30
        registry = 0.3; registryKey = 0.5; service = 2; task = 1
        feature = 50; capability = 45; file = 1; shortcut = 1; script = 15
    }
    # Handlers whose cost is dominated by something other than their action
    # type.
    $scriptCost = @{
        'mcafee' = 200; 'norton' = 150; 'remove-edge' = 100; 'od-uninstall' = 45
        'copilot-key' = 60; 'restart-explorer' = 8; 'close-resurrection' = 6
        # Reads every .lnk in the Start menu and on the desktop for every
        # account, and resolves each target.
        'clear-stale-shortcuts' = 5
        'startup-clean' = 6; 'clear-logs' = 4; 'persistence-guard' = 4
        'oem-detect' = 2; 'uninstall-residue' = 20
    }
    # The steps Resolve-WDPlan appends rather than the operator selecting them.
    # They get a row but not the "exclude this" offer, because the exclusion
    # list is applied to the selection and these are not in it.
    $AUTO_STEPS = New-WDStringSet @('close-resurrection', 'clear-stale-shortcuts', 'restart-explorer')
    $restorePointSeconds = 90

    # Longer explanations for the statuses people actually want to chase down.
    $statusAdvice = @{
        'Blocked' = 'Windows refused this step. Either it needs administrator rights - re-run the launcher, which elevates - or the target is protected and cannot be removed even as an administrator. Packages Windows marks non-removable and objects owned by TrustedInstaller fall into the second group, and no amount of privilege changes that.'
        'Failed'  = 'This step errored rather than being refused. Common causes: an uninstaller that did not exit, a file held open by a running process, or a vendor package that only removes cleanly after a restart. The full error is in debloat.log in the run folder.'
        'Partial' = 'Some of this item worked and some did not, so it is deliberately not reported as a clean pass. The detail line lists which parts succeeded. Re-running after a restart often clears the remainder.'
        'NotPresent' = 'Nothing to do - the target is not on this machine. On a fresh install most of the list legitimately is not there, so this is a success, not a miss.'
        'AlreadySet' = 'Nothing to do - the target IS on this machine and is already exactly what this option would make it. Every value, service, or task it names was read and found to be right. That is what most of a run reads like the second time you run it.'
        'Obstruction' = 'Not a step that failed. Something stands in the way of it: either a part of Windows this run leans on is degraded or switched off, or this is a change Windows will not let any program make silently and hands to you instead. The detail says which, and what to do about it. Nothing was refused, because nothing has been attempted yet.'
        'Skipped' = 'Deliberately not attempted, because a guard excluded it. Guards match on things like manufacturer, chassis, Windows edition and whether a touchscreen is present.'
        'Found'   = 'Something worth a look, not something that was done. Nothing was changed for this row and nothing will be: the sweep that produces these reports leftovers rather than deleting them, because "14 suspicious folders" is not a thing anybody can sensibly approve in advance. Read the path, decide for yourself.'
    }

    # Written once so the card on the page and the question on the way out
    # cannot drift.
    $wrapUpLines = {
        $out = New-Object System.Collections.Generic.List[string]
        $keep = [string]$state.Sync.KeepDir
        # The rollback script is a row that can be unticked, so every line below
        # describes the run that happened.
        $undo = [bool]$state.Sync.HasUndo
        $holds = $(if ($undo) { 'the rollback script, a list of every change this run made, and a file to search when something breaks' }
                   else { 'a list of every change this run made, and a file to search when something breaks' })
        if ($keep) {
            $out.Add("A folder named '$(Split-Path -Leaf $keep)' is now on your desktop. It holds $holds. 'Read me first.txt' inside says what each one is for.")
        } else {
            $out.Add("The log and a list of every change are in $([string]$state.Sync.RunDir).")
        }
        $out.Add('If something stops working days or weeks from now, open "Common issues lookup and reversion instructions" from that folder and press ctrl+F for whatever is wrong - "no sound", "camera not working", "updates broken". It names the option responsible and how to undo that one option.')
        if ($undo) {
            $out.Add('To undo the whole run instead: run Undo-WinSetupToolkit.ps1 as an administrator, or open this toolkit and use Revert past changes.')
        } else {
            $out.Add('There is no rollback script for this run - "Generate rollback script" was not selected. To undo the whole run, open this toolkit and use Revert past changes, which reads the same journal the script would have been written from.')
        }
        # Worth naming both when it worked, because nobody thinks to look, and
        # when it did not, because the confirmation promised one.
        switch ([string]$state.Sync.RestorePoint) {
            'ok' {
                $out.Add('Windows also took a system restore point immediately before the run. Search Windows for "Create a restore point" and press System Restore to roll the whole machine back to it - that undoes anything else you did since, so the rollback script above is the narrower and usually better answer.')
            }
            'failed' {
                $out.Add('Windows would NOT create a system restore point for this run - System Protection is off or unavailable on this machine. That means System Restore is not a way back from it, and the rollback script above is. Keep it.')
            }
        }
        ,$out
    }.GetNewClosure()
    # The wrap-up goes in the run footer beside the buttons, so both callers set
    # TxtRunWrap directly.

    # And said once, out loud, when the apply finishes.
    $offerRunFolder = {
        if ($state.NoPrompts) { return }
        $keep = [string]$state.Sync.KeepDir
        $body = (@(& $wrapUpLines) -join "`r`n`r`n")
        if ($keep -and (Test-Path -LiteralPath $keep)) {
            $ans = Show-WDMessage (
                        "$body`r`n`r`nOpen that folder now?",
                        'The run has finished', 'YesNo', 'None')
            if ($ans -eq 'Yes') {
                try { Start-Process explorer.exe -ArgumentList "`"$keep`"" -ErrorAction Stop }
                catch { Write-WDLog "Could not open the run folder: $($_.Exception.Message)" -Level Warn }
            }
        } else {
            # No folder to offer - a machine with no desktop, or a run that
            # could not write there. Still say where everything went.
            Show-WDMessage ($body, 'The run has finished', 'OK', 'None') | Out-Null
        }
        # Reading this is the acknowledgement, so closing the window afterwards
        # does not ask again.
        $state.Acknowledged = $true
    }.GetNewClosure()

    $updateExcludedNote = {
        # Both branches, so putting the last excluded item back also puts the
        # note back.
        $ui.TxtRunNote.Text =
            'Click any line to see exactly what it will change, or to drop it from the run.' +
            $(if ($state.Excluded.Count) { " $($state.Excluded.Count) item(s) excluded so far." } else { '' })
    }.GetNewClosure()

    # Lives out here so the self test can drive it without the MessageBox that
    # gates it in the GUI.
    $logRowByItem = @{}

    # Resolved on first use: the ListBox has no template, and so no ScrollViewer
    # inside it, until the run page has been laid out once.
    $logScroll = @{ Sv = $null }

    # $replayRun is written far below and called from the very end of this
    # function.
    $replayRef = @{ Fn = $null }

    $setRowExcluded = {
        param($Tag, [bool]$Excluded)
        if (-not $Tag.ItemId) { return }
        # Dropping Edge removal from the run drops the browser that was only
        # offered because of it.
        if ($Tag.ItemId -eq $EDGE_ID -and $state.BrowserAuto -and $logRowByItem.ContainsKey($BROWSER_ID)) {
            $mate = $logRowByItem[$BROWSER_ID]
            if ([bool]$state.Excluded.Contains($BROWSER_ID) -ne $Excluded) {
                & $setRowExcluded $mate $Excluded
            }
        }
        # The line goes through the whole row, not just the name: a strike on
        # the name alone left the status word and the detail undecorated.
        $cells = @($Tag.Cells | Where-Object { $_ })
        if (-not $cells.Count) { $cells = @($Tag.Label) }
        if ($Excluded) {
            $null = $state.Excluded.Add($Tag.ItemId)
            $Tag.Label.Text = "$($Tag.Name)  (excluded)"
            foreach ($c in $cells) {
                $c.TextDecorations = [Windows.TextDecorations]::Strikethrough
                & $Ref $c 'Foreground' 'Muted'
            }
        } else {
            $null = $state.Excluded.Remove($Tag.ItemId)
            $Tag.Label.Text = $Tag.Name
            foreach ($c in $cells) {
                $c.TextDecorations = New-Object Windows.TextDecorationCollection
            }
            # Each column back to its own colour rather than all three to Text.
            & $Ref $Tag.Label 'Foreground' 'Text'
            if ($Tag.Cells -and $Tag.Cells[0]) { & $Ref $Tag.Cells[0] 'Foreground' (& $statusColor ([string]$Tag.Status)) }
            if ($Tag.Cells -and $Tag.Cells[2]) { & $Ref $Tag.Cells[2] 'Foreground' 'Sub' }
        }
        & $updateExcludedNote
    }

    $addLogRow = {
        param($status, $name, $detail, $itemId)
        # Locals, because the click handler below is a closure built in this
        # child scope.
        $st         = $state
        $setExcl    = $setRowExcluded
        # The same two things the Advanced page's Details button assembles, so
        # the preview can answer "what exactly will this change" the same way.
        $detailFn   = $itemDetail
        $itemsL     = $itemById

        $g = New-Object Windows.Controls.Grid
        $g.Margin = '8,3,8,3'
        & $Ref $g 'Background' 'Flat'
        foreach ($w in @(@(96,'Pixel'), @(300,'Pixel'), @(1,'Star'))) {
            $cd = New-Object Windows.Controls.ColumnDefinition
            $cd.Width = New-WDGridLength -Value $w[0] -Unit $w[1]
            $null = $g.ColumnDefinitions.Add($cd)
        }
        $s = New-Object Windows.Controls.TextBlock
        # In a simulation nothing has happened yet, so the past tense would be a
        # lie.
        $s.Text = if ($state.Preview) {
            switch ($status) {
                'Removed'    { 'will remove' }
                'Changed'    { 'will change' }
                # Present tense on purpose: "will do nothing" is a promise about
                # the future where this is a fact about now.
                'AlreadySet' { 'nothing to do' }
                'NotPresent' { 'not present' }
                'Skipped'    { 'will skip' }
                'Obstruction'{ 'obstruction' }
                'Partial'    { 'part only' }
                'Blocked'    { 'blocked' }
                'Failed'     { 'would fail' }
                default      { $status.ToLower() }
            }
        } else { $status.ToLower() }
        $s.FontSize = 12; $s.FontWeight = 'SemiBold'
        & $Ref $s 'Foreground' (& $statusColor $status)
        [Windows.Controls.Grid]::SetColumn($s, 0); $null = $g.Children.Add($s)
        $n = New-Object Windows.Controls.TextBlock
        $n.Text = $name; $n.FontSize = 13; & $Ref $n 'Foreground' 'Text'
        $n.TextTrimming = 'CharacterEllipsis'
        [Windows.Controls.Grid]::SetColumn($n, 1); $null = $g.Children.Add($n)
        $d = New-Object Windows.Controls.TextBlock
        $d.Text = $detail; $d.FontSize = 13; & $Ref $d 'Foreground' 'Sub'
        $d.TextTrimming = 'CharacterEllipsis'
        [Windows.Controls.Grid]::SetColumn($d, 2); $null = $g.Children.Add($d)

        $g.Cursor  = 'Hand'
        $g.ToolTip = if ($state.Preview -and $itemId) {
            'Click for the full explanation, or to drop this from the run and put it back'
        } else { 'Click for the full explanation' }
        # Cells is all three columns, because excluding a row strikes the whole
        # of it rather than the name alone.
        $g.Tag = @{ Status = $status; Name = $name; Detail = $detail; ItemId = $itemId
                    Label = $n; Cells = @($s, $n, $d) }
        $g.Add_MouseLeftButtonUp({
            $t = $this.Tag
            $out = New-Object System.Collections.Generic.List[string]
            if ($st.Preview) {
                $out.Add("Simulated outcome: $($t.Status).")
                $out.Add('Nothing has been changed yet - this is what would happen when you press Apply.')
            } else {
                $out.Add("Result: $($t.Status)")
            }
            # The detail under a heading that says what kind of detail it is.
            if ([string]$t.Detail) {
                $out.Add('')
                $out.Add($(switch ([string]$t.Status) {
                    'Blocked'     { 'WHAT WAS REFUSED' }
                    'Failed'      { 'WHAT WENT WRONG' }
                    'Partial'     { 'WHAT DID AND DID NOT HAPPEN' }
                    'Found'       { 'WHAT WAS FOUND' }
                    'Obstruction' { 'WHAT IS IN THE WAY' }
                    'AlreadySet'  { 'WHAT WAS ALREADY SET' }
                    default       { 'DETAIL' }
                }))
                $out.Add("  $($t.Detail)")
            }
            # And the exact values, straight off the item's own actions.
            if ($t.ItemId -and $itemsL.ContainsKey([string]$t.ItemId)) {
                $out.Add('')
                try {
                    $out.Add((& $detailFn $itemsL[[string]$t.ItemId] -Live))
                } catch {
                    $out.Add("The list of exact changes could not be read: $($_.Exception.Message)")
                    try { Write-WDLog "Item detail failed for $($t.ItemId): $($_.Exception.Message)" -Level Warn } catch { }
                }
            }
            $body = ($out -join "`r`n")

            # In a simulation the plan is still editable, so every row can be
            # dropped from the run.
            $isOut = ($t.ItemId -and $st.Excluded.Contains($t.ItemId))
            if ($st.Preview -and $t.ItemId) {
                $body += if ($isOut) {
                    "`n`nThis is excluded from what Apply will do. Put it back into the run?"
                } else {
                    "`n`nExclude this from the changes that will be applied?"
                }
                if ((Show-WDMessage ($body, $t.Name, 'YesNo', 'Question')) -eq 'Yes') {
                    & $setExcl $t (-not $isOut)
                }
            } else {
                if ($isOut) { $body += "`n`nAlready excluded from this run." }
                Show-WDMessage ($body, $t.Name, 'OK', 'None') | Out-Null
            }
            $args[1].Handled = $true
        }.GetNewClosure())

        if ($itemId) { $logRowByItem[[string]$itemId] = $g.Tag }
        # Name and detail are kept so the search box has something to match on
        # and the sort something to order by.
        $logRows.Add([pscustomobject]@{
            Status = $status; Element = $g; Seq = $logRows.Count
            Name = [string]$name; Detail = [string]$detail
        })
        # Appearing with the first row rather than at the end, because the
        # reason to search is usually a row that has just gone past.
        if ($ui.RunFilterBar.Visibility -ne 'Visible') { $ui.RunFilterBar.Visibility = 'Visible' }
        if ($statusFilter[$status]) {
            # Follow the tail only while the operator is already reading the
            # tail.
            if (-not $logScroll.Sv) { $logScroll.Sv = Get-WDChildScrollViewer $ui.LogList }
            $sv = $logScroll.Sv
            $follow = $true
            if ($sv -and $sv.ScrollableHeight -gt 0) {
                # ListBox scrolls by item by default, so both sides of this are
                # in items and the tolerance is a row, not a pixel.
                $follow = ($sv.VerticalOffset -ge ($sv.ScrollableHeight - 1.001))
            }
            $null = $ui.LogList.Items.Add($g)
            if ($follow) { $ui.LogList.ScrollIntoView($g) }
        }
    }

    # The "what is it doing right now" card.
    $showNow = {
        param([string]$Head, [string]$Item, [bool]$Timed)
        $ui.NowCard.Visibility = 'Visible'
        $ui.TxtNowHead.Text = $Head
        $ui.TxtNowItem.Text = $Item
        $state.NowItem = $Item
        $state.NowSince = $(if ($Timed) { [datetime]::UtcNow } else { $null })
        $ui.TxtNowElapsed.Text = ''
        $ui.TxtNowNote.Visibility = 'Collapsed'
        $ui.BtnSkipItem.Visibility = 'Collapsed'
    }.GetNewClosure()

    # Called from the timer, so it must be cheap and must not repaint what has
    # not changed - this runs eight times a second.
    $tickNow = {
        if (-not $state.NowSince) { return }
        $secs = [int]([datetime]::UtcNow - $state.NowSince).TotalSeconds
        $txt = $(if ($secs -ge 60) { '{0}m {1:00}s' -f [int]($secs / 60), ($secs % 60) } else { "${secs}s" })
        if ($ui.TxtNowElapsed.Text -ne $txt) { $ui.TxtNowElapsed.Text = $txt }
        # Past twenty seconds, say so rather than leaving the operator to
        # wonder. The offer to skip is real but limited.
        if ($secs -ge 20 -and $ui.TxtNowNote.Visibility -ne 'Visible' -and -not $state.Preview) {
            $ui.TxtNowNote.Text = 'This one is taking a while. Vendor uninstallers often do - ' +
                                  'each one is given five minutes before it is given up on. ' +
                                  'Skipping abandons whatever this item has left to do.'
            $ui.TxtNowNote.Visibility = 'Visible'
            $ui.BtnSkipItem.Visibility = 'Visible'
            $ui.BtnSkipItem.IsEnabled = $true
        }
    }.GetNewClosure()

    $timer = New-Object Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(120)
    # A named block rather than an anonymous handler, so the harness can push
    # synthetic events into the queue and drain them without a real run.
    $pumpRun = {
      # An exception raised in a WPF handler on the dispatcher thread ends the
      # process.
      try {
        $q = $state.Sync.Queue
        while ($q.Count -gt 0) {
            $e = $q[0]; $q.RemoveAt(0)
            switch ($e.Phase) {
                # The minutes before the first item: modules loading, the
                # restore point, the scan, resolving the plan.
                'Stage' {
                    $ui.TxtPhase.Text   = $(if ($state.Preview) { 'Simulating changes' } else { 'Applying changes' })
                    $ui.TxtCurrent.Text = [string]$e.Text
                    & $showNow $(if ($state.Preview) { 'Simulating' } else { 'Preparing' }) ([string]$e.Text) ([bool]$e.Timed)
                }
                'Start' {
                    $ui.TxtPhase.Text = if ($state.Mode -eq 'revert') { 'Reverting' }
                                        elseif ($state.Preview) { 'Simulating changes...' } else { 'Applying changes' }
                    $ui.BarOverall.IsIndeterminate = $false
                    $ui.BarOverall.Maximum = [Math]::Max(1, $e.Total)
                    $state.RunTotal = [int]$e.Total
                }
                'Item' {
                    $ui.BarOverall.IsIndeterminate = $false
                    $ui.BarOverall.Value = $e.Index
                    $state.RunIndex = [int]$e.Index
                    $state.RunTotal = [int]$e.Total
                    $ui.TxtCurrent.Text  = "[$($e.Index)/$($e.Total)]  $($e.ItemName)"
                    # The engine reports each item twice: once with no result on
                    # the way in, once with one on the way out.
                    if (-not $e.Result) {
                        & $showNow "Working on $($e.Index) of $($e.Total)" ([string]$e.ItemName) $true
                    }
                    if ($e.Result) {
                        $txt = $e.Result.Message
                        if ($e.Result.Detail) { $txt = "$($e.Result.Message) - $($e.Result.Detail)" }
                        # It worked, but not the obvious way. Said on the row
                        # rather than swallowed.
                        if ([string]$e.Result.Recovered) {
                            $txt = "$txt  [done another way: $($e.Result.Recovered)]"
                        }
                        $rowId = [string]$e.Result.Id
                        if ($AUTO_STEPS.Contains($rowId)) { $rowId = $null }
                        & $addLogRow $e.Result.Status $e.Result.Name $txt $rowId
                        if ($state.Counts.ContainsKey($e.Result.Status)) { $state.Counts[$e.Result.Status]++ }
                        foreach ($sk in @($statBlocks.Keys)) {
                            $statBlocks[$sk].Text.Text = "$($statBlocks[$sk].Label) $($state.Counts[$sk])"
                        }
                        # Rough cost model, summed only over items that actually
                        # have work to do.
                        if ($e.Result.Status -in @('Removed','Changed','Partial')) {
                            $secs = 0.0
                            foreach ($ty in @($e.Types)) {
                                $secs += $(if ($actionCost.ContainsKey($ty)) { $actionCost[$ty] } else { 5 })
                            }
                            if ($scriptCost.ContainsKey($e.Result.Id)) { $secs = $scriptCost[$e.Result.Id] }
                            $state.EstimateSeconds += $secs
                        }
                    }
                }
                'Log' {
                    if ($e.Level -in @('Error','Warn')) {
                        & $addLogRow $(if ($e.Level -eq 'Error') { 'Failed' } else { 'Blocked' }) $e.Item $e.Message $null
                    }
                }
                # One row per thing the operator has to look at. Deliberately
                # outside $state.Counts: a finding is not an outcome.
                'Finding' { & $addLogRow 'Found' $e.Name $e.Detail $null }
                # A row for something the run did that is not a plan item.
                # Outside $state.Counts for the same reason.
                'Row' { & $addLogRow ([string]$e.Status) ([string]$e.Name) ([string]$e.Detail) $null }
                'Done' {
                    $ui.BarOverall.IsIndeterminate = $false
                    $ui.BarOverall.Value = $ui.BarOverall.Maximum
                    # Canceled first: a stopped run and a finished one produce
                    # the same Done event and the same full bar.
                    $ui.TxtPhase.Text = if ($state.Sync.Cancel)        { 'Canceled' }
                                        elseif ($state.Mode -eq 'revert') { 'Revert complete' }
                                        elseif ($state.Preview) { 'Simulation complete' } else { 'Finished' }
                    $ui.TxtCurrent.Text = ''
                }
            }
        }

        & $tickNow

        if ($state.Sync.Done) {
            $timer.Stop()
            $ui.BtnCancel.IsEnabled   = $false
            $ui.BtnBackRun.IsEnabled  = $true
            $ui.BtnOpenLogs.IsEnabled = $true
            $ui.BarOverall.IsIndeterminate = $false
            $ui.BarOverall.Value = $ui.BarOverall.Maximum
            $state.NowSince = $null
            if ($state.Sync.Error) { & $addLogRow 'Failed' 'Run aborted' $state.Sync.Error }
            # Built here rather than inside the apply branch, so the simulation
            # gets the same line.
            $tally = @()
            $labelsNow = $(if ($state.Preview) { $statLabelsAhead } else { $statLabels })
            foreach ($sk in @('Removed','Changed','Partial','Blocked','Obstruction','Failed','Skipped','AlreadySet')) {
                if ($state.Counts[$sk] -gt 0) { $tally += "$($state.Counts[$sk]) $($labelsNow[$sk])" }
            }
            $line = $(if ($tally.Count) { $tally -join ', ' } else { 'nothing to do' })

            # The line under the bar, at the end.
            if (-not $state.Sync.Cancel) { & $Ref $ui.BarOverall 'Foreground' 'Ok' }

            if ($state.Mode -eq 'revert') {
                $ui.TxtRunNote.Text = 'Revert finished. A restart is worth doing if services or startup items were restored.'
                $ui.TxtCurrent.Text = 'Revert complete. The changes it could undo have been undone.'
                $ui.NowCard.Visibility = 'Collapsed'
                # Every cached "how much of that run is still in place" answer
                # was read before this, so all of them are now stale.
                $appliedState.Clear()
                # The probe caches every key it reads for the life of the
                # process, and this run has just made it wrong.
                Clear-WDRegistryProbeCache
                # And the Revert page itself, built once per session precisely
                # because nothing else can change the machine while the window
                # is open.
                $revCache.Built = $false
                & $repaintModeGrid
            } elseif ($state.Preview) {
                $ui.TxtCurrent.Text = "Simulation complete - $line. Nothing on this machine has been changed."
                # That card answers "what is it doing right now", which after a
                # simulation is nothing at all.
                $ui.NowCard.Visibility = 'Collapsed'
                $ui.BtnApplyNow.Visibility = 'Visible'

                # Wide band on purpose: the dominant term is third-party
                # uninstallers, which range from two seconds to several minutes.
                $total = $state.EstimateSeconds + $restorePointSeconds
                $lo = [Math]::Max(1, [Math]::Round(($total * 0.6) / 60))
                $hi = [Math]::Max($lo + 1, [Math]::Round(($total * 1.9) / 60))

                & $updateExcludedNote
                $ui.TxtRunEstimate.Text = "Apply time estimate: $lo-$hi minutes"
                $ui.TxtRunEstimate.Visibility = 'Visible'
            } else {
                # Read from the run's own session, published through Sync: the
                # UI thread has a session of its own.
                $reboot = [bool]$state.Sync.Reboot
                # The one artefact worth keeping somewhere the toolkit will not
                # eventually delete.
                if ([string]$state.Sync.NotesFile) { $ui.BtnSaveNotes.Visibility = 'Visible' }

                # The end of a real run is the one place this application has to
                # stop and be read.
                $rc = [int]$state.Sync.RestartCount
                $restartLine = ''
                if ($rc -gt 0) {
                    $restartLine = "$rc change$(if ($rc -ne 1) { 's' }) need$(if ($rc -eq 1) { 's' } else { '' }) a restart to take effect. Everything else is already in force. "
                } elseif ($reboot) {
                    $restartLine = 'A restart is needed to finish. '
                }
                $ui.TxtRunNote.Text = "Done. $restartLine".Trim()
                $ui.TxtCurrent.Text = "Finished - $line. $restartLine".Trim()

                # One bar at the end, not two.
                $ui.NowCard.Visibility = 'Collapsed'
                # Everything somebody would not otherwise know, in the one place
                # they are certainly looking.
                $ui.TxtRunWrap.Text = (@(& $wrapUpLines) -join "  ")
                $ui.TxtRunWrap.Visibility = 'Visible'
                # There is nowhere left to go back to: the run has happened, and
                # the mode screen behind this describes a decision already made.
                $ui.BtnBackRun.Content = 'Close'
                $state.Acknowledged = $false

                # This machine has now had this preset applied, and the card
                # should say so - only when what ran was the preset.
                $where = [string]$state.Sync.KeepDir
                if (-not $where) { $where = [string]$state.Sync.RunDir }
                # The run's own id, taken off the ProgramData directory rather
                # than the desktop copy.
                $ranId = ''
                if ([string]$state.Sync.RunDir) {
                    $ranId = (Split-Path ([string]$state.Sync.RunDir) -Leaf) -replace '^run-', ''
                }
                if (& $recordApplied ([string]$state.Preset) @($state.LastSelection) $where $ranId) {
                    # Painted, not rebuilt: the grid is behind this page and its
                    # five columns have not changed shape.
                    & $repaintModeGrid
                    & $saveUiState
                }

                # Last, so the page behind the dialog is already finished and
                # correct when it is dismissed.
                & $offerRunFolder
            }

            # Said last, over whatever the branches above wrote, because a
            # canceled run reaches every one of them.
            if ($state.Sync.Cancel) {
                $reached = $(if ($state.RunTotal -gt 0) {
                    "Stopped at item $($state.RunIndex) of $($state.RunTotal); the remaining " +
                    "$([Math]::Max(0, $state.RunTotal - $state.RunIndex)) were not attempted."
                } else {
                    'Stopped before any item ran.'
                })
                $ui.TxtRunNote.Text = "Canceled. $reached " +
                    $(if ($state.Preview) { 'Nothing was changed.' }
                      else { 'What had already run is in the log, and the rollback script covers it.' })
                $ui.TxtCurrent.Text = "Canceled - $reached"
                # Shown again, because the preview branch above hides it and a
                # canceled preview goes through both.
                $ui.NowCard.Visibility = 'Visible'
                & $showNow 'Canceled' $reached $false
                $ui.TxtNowNote.Visibility = 'Collapsed'
                if (-not $state.Preview) { $state.Acknowledged = $false }
            }
        }
      } catch {
        $timer.Stop()
        try {
            & $addLogRow 'Failed' 'The progress display stopped' $_.Exception.Message $null
            $ui.TxtPhase.Text = 'The display stopped, but the run did not'
            $ui.TxtRunNote.Text = 'Something went wrong painting this page. The run itself carries on and its log ' +
                                  'is still being written - open the run folder to read it.'
            $ui.BtnOpenLogs.IsEnabled = $true
            $ui.BtnBackRun.IsEnabled  = $true
        } catch { }
      }
    }.GetNewClosure()
    $timer.Add_Tick($pumpRun)

    $enterRunPage = {
        # Everything on this page has to go back to zero here: an apply is
        # reached from a simulation, so the counters are already full when it
        # starts.
        param([bool]$PreviewMode, [string]$Return)
        $state.Preview = $PreviewMode
        $state.ReturnPage = $Return
        $state.Sync.Cancel = $false; $state.Sync.Done = $false; $state.Sync.Error = $null
        $state.Sync.SkipItem = $false; $state.Sync.RunDir = $null; $state.Sync.Reboot = $false
        $state.Sync.NotesFile = $null; $state.Sync.RestartCount = 0; $state.Sync.KeepDir = $null
        $state.Sync.HasUndo = $false
        $state.Sync.RestorePoint = ''
        $state.Counts = @{ Removed=0; Changed=0; AlreadySet=0; NotPresent=0; Skipped=0; Obstruction=0; Partial=0; Blocked=0; Failed=0 }
        $state.Excluded.Clear()
        $state.EstimateSeconds = 0.0
        $state.Acknowledged = $PreviewMode
        $state.NowItem = ''
        $state.NowSince = $null
        $state.RunIndex = 0
        $state.RunTotal = 0
        $logRows.Clear(); $logRowByItem.Clear()
        $ui.LogList.Items.Clear()

        # The bar has no total until the plan is resolved, half a minute into an
        # apply. Indeterminate says "working" honestly.
        $ui.BarOverall.Value = 0
        $ui.BarOverall.Maximum = 100
        $ui.BarOverall.IsIndeterminate = $true
        # Put back to Accent rather than cleared: ClearValue drops the resource
        # reference and the bar stops following the theme.
        & $Ref $ui.BarOverall 'Foreground' 'Accent'

        $ui.TxtPhase.Text   = $(if ($PreviewMode) { 'Preparing the simulation...' } else { 'Preparing to apply changes...' })
        $ui.TxtCurrent.Text = 'Starting up...'

        # A status hidden while reading the simulation would otherwise go on
        # hiding real results during the apply.
        foreach ($k in @($statusFilter.Keys)) { $statusFilter[$k] = $true }
        foreach ($sk in @($statBlocks.Keys)) {
            $statBlocks[$sk].Text.Text = "$($statBlocks[$sk].Label) $($state.Counts[$sk])"
        }
        & $applyLogFilter

        & $showNow $(if ($PreviewMode) { 'Simulating' } else { 'Starting' }) 'Getting ready...' $false

        foreach ($p in @('PageHome','PageModes','PageAdvanced','PageRevert','PageCompare','PageUnattend')) { $ui[$p].Visibility = 'Collapsed' }
        $ui.PageRun.Visibility = 'Visible'
        $ui.BtnCancel.IsEnabled = $true
        $ui.BtnBackRun.IsEnabled = $false
        # Back to "Back" at the start of every visit: it becomes Close only when
        # an apply has finished.
        $ui.BtnBackRun.Content = 'Back'
        $ui.BtnApplyNow.Visibility = 'Collapsed'
        $ui.TxtRunNote.Text = ''
        $ui.TxtRunWrap.Text = ''
        $ui.TxtRunWrap.Visibility = 'Collapsed'
        $ui.TxtRunEstimate.Text = ''
        $ui.TxtRunEstimate.Visibility = 'Collapsed'

        # Whose selection this is. Revert has no preset, and saying "Balanced"
        # over a list of things being put back would be worse than saying
        # nothing.
        $ui.TxtRunSearch.Text = ''
        $ui.CmbRunSort.SelectedIndex = 0
        $ui.RunFilterBar.Visibility = 'Collapsed'
        if ($state.Mode -eq 'revert') {
            $ui.TxtRunPreset.Visibility = 'Collapsed'
        } else {
            $verb = $(if ($PreviewMode) { 'Simulating' } else { 'Applying' })
            $ui.TxtRunPreset.Text = "$verb the $($state.Preset) selection"
            $ui.TxtRunPreset.Visibility = 'Visible'
        }
    }

    # A run that already happened, put back on the page it belongs on. It starts
    # no runspace and touches nothing; the only thing faked is the arrival of
    # results.
    $replayRun = {
        param([string]$Dir)
        $info = Read-WDSetupResult -RunDir $Dir
        if (-not $info) { return $false }

        & $enterRunPage $false 'PageModes'
        # The run is over, so nothing may look live: no cancel, no indeterminate
        # bar, and the guard against closing mid-run has to be off.
        $state.Sync.Done = $true
        $state.Sync.RunDir       = [string]$info.RunDir
        $state.Sync.KeepDir      = [string]$info.KeepDir
        $state.Sync.HasUndo      = [bool]$info.HasUndo
        $state.Sync.RestorePoint = [string]$info.RestorePoint
        $state.Sync.RestartCount = [int]$info.RestartCount
        $state.Sync.Reboot       = [bool]$info.Reboot
        $state.Sync.NotesFile    = ''
        try {
            # .md now, and .txt is still looked for: a replay is pointed at a
            # folder somebody kept, which may have been written by an older
            # build.
            foreach ($leaf in @('What-this-run-did.md', 'What-this-run-did.txt')) {
                $nf = Join-Path ([string]$info.RunDir) $leaf
                if (Test-Path -LiteralPath $nf) { $state.Sync.NotesFile = $nf; break }
            }
        } catch { }

        $items = @(Get-Prop $info.Report 'items' @())
        foreach ($it in $items) {
            $nm  = [string](Get-Prop $it 'Name' (Get-Prop $it 'Id' '?'))
            $msg = [string](Get-Prop $it 'Message' '')
            $det = [string](Get-Prop $it 'Detail' '')
            $txt = $(if ($det) { "$msg - $det".TrimStart(' -') } else { $msg })
            & $addLogRow ([string](Get-Prop $it 'Status' '?')) $nm $txt $null
        }
        # The counters are written by the timer, which is not running. Same
        # table, filled from the report.
        foreach ($k in @($state.Counts.Keys)) { $state.Counts[$k] = 0 }
        foreach ($pair in @(@{ K = 'removed'; C = 'Removed' }, @{ K = 'changed'; C = 'Changed' },
                            @{ K = 'notPresent'; C = 'NotPresent' }, @{ K = 'partial'; C = 'Partial' },
                            @{ K = 'blocked'; C = 'Blocked' }, @{ K = 'skipped'; C = 'Skipped' },
                            @{ K = 'alreadySet'; C = 'AlreadySet' }, @{ K = 'obstruction'; C = 'Obstruction' },
                            @{ K = 'failed'; C = 'Failed' })) {
            $state.Counts[$pair.C] = [int](Get-Prop $info.Counts $pair.K 0)
        }
        foreach ($sk in @($statBlocks.Keys)) {
            $statBlocks[$sk].Text.Text = "$($statBlocks[$sk].Label) $($state.Counts[$sk])"
        }

        $total = [int](Get-Prop $info.Counts 'total' 0)
        $ui.BarOverall.IsIndeterminate = $false
        $ui.BarOverall.Maximum = [Math]::Max(1, $total)
        $ui.BarOverall.Value   = [Math]::Max(1, $total)
        & $Ref $ui.BarOverall 'Foreground' 'Ok'
        $ui.TxtPhase.Text = 'Finished'
        $done = "$($state.Counts.Removed) removed, $($state.Counts.Changed) changed, $($state.Counts.Failed) failed"
        $restart = ''
        if ([int]$info.RestartCount -gt 0) {
            $restart = "$($info.RestartCount) change$(if ([int]$info.RestartCount -ne 1) { 's' }) still need$(if ([int]$info.RestartCount -eq 1) { 's' } else { '' }) a restart. "
        } elseif ($info.Reboot) { $restart = 'A restart is needed to finish. ' }
        $ui.TxtCurrent.Text = "Finished during Windows Setup - $done. $restart".Trim()
        $ui.TxtRunNote.Text = 'This run happened before anybody signed in, so this is a record of it rather than something in progress.'
        # Same single bar a live apply ends on: the card would be a second strip
        # saying "Finished" about a run that finished before this window opened.
        $ui.NowCard.Visibility = 'Collapsed'
        $ui.TxtRunWrap.Text = (@(& $wrapUpLines) -join '  ')
        $ui.TxtRunWrap.Visibility = 'Visible'
        $ui.BtnBackRun.Content = 'Close'
        if ([string]$state.Sync.NotesFile) { $ui.BtnSaveNotes.Visibility = 'Visible' }
        $ui.BtnCancel.IsEnabled  = $false
        $ui.BtnBackRun.IsEnabled = $true
        $ui.BtnOpenLogs.IsEnabled = $true
        # Nothing to acknowledge: the run is history, and that guard exists for
        # one still in progress.
        $state.Acknowledged = $true
        & $applyLogFilter
        $true
    }
    $replayRef.Fn = $replayRun

    $newRunspace = {
        param([hashtable]$Vars, [scriptblock]$Body)
        $rs = [runspacefactory]::CreateRunspace()
        $rs.ApartmentState = 'MTA'; $rs.ThreadOptions = 'ReuseThread'
        $rs.Open()
        foreach ($k in $Vars.Keys) { $rs.SessionStateProxy.SetVariable($k, $Vars[$k]) }
        $ps = [powershell]::Create(); $ps.Runspace = $rs
        $null = $ps.AddScript($Body)
        $state.Runspace = $rs; $state.Shell = $ps
        $state.Handle = $ps.BeginInvoke()
        $timer.Start()
    }

    $startRun = {
        param([bool]$PreviewMode, [string[]]$Selection, [string]$Label, [string]$Return)
        if (-not $Selection -or -not $Selection.Count) {
            Show-WDMessage ('Nothing is selected.', 'Windows Setup Toolkit', 'OK', 'Warning') | Out-Null
            return
        }
        if (-not $PreviewMode) {
            $msg = "About to apply $($Selection.Count) items to $($Profile.ComputerName) using $Label."
            # Asked of the selection, not of the label: the label describes
            # which button was last pressed.
            $risky = $false
            try {
                $below = New-WDStringSet $baseIds['Aggressive']
                foreach ($id in $baseIds['Extreme']) {
                    if (-not $below.Contains($id) -and $Selection -contains $id) { $risky = $true; break }
                }
            } catch { $risky = ($Label -eq 'Extreme') }
            if ($risky) { $msg += "`n`nThis goes beyond bloatware - it switches off services and features other software may depend on." }
            # What this toolkit stands on, checked before the last chance to say
            # no.
            try {
                if (Get-Command Get-WDHealthImpact -ErrorAction SilentlyContinue) {
                    $selSet = New-WDStringSet $Selection
                    $selItems = New-Object System.Collections.Generic.List[psobject]
                    foreach ($c in $Categories) {
                        foreach ($it in @($c.items)) {
                            if ($selSet.Contains([string]$it.id)) { $selItems.Add($it) }
                        }
                    }
                    $hurt = @(Get-WDHealthImpact -Plan $selItems |
                              Where-Object { $_.Health.State -eq 'Unavailable' -and ($_.Count -gt 0 -or $_.Health.Safety) })
                    if ($hurt.Count) {
                        $msg += "`n`nSOMETHING THIS RUN NEEDS IS NOT WORKING:`n"
                        foreach ($h in $hurt) {
                            $msg += "`n  * $($h.Health.Name)"
                            $msg += "`n      $($h.Health.Reason)"
                            if ($h.Count -gt 0) {
                                $msg += "`n      $($h.Count) selected option$(if ($h.Count -ne 1) { 's' }) will fail because of this."
                            }
                            if ($h.Health.Fix) { $msg += "`n      $($h.Health.Fix)" }
                        }
                    }
                }
            } catch {
                Write-WDLog "The tool check could not run before the apply: $($_.Exception.Message)" -Level Warn
            }
            # Asked of the selection rather than asserted: "a rollback script
            # will be created" stopped being unconditionally true when it became
            # a row.
            if ($Selection -contains 'rollback-script') {
                $msg += "`n`nA restore point and a rollback script will be created. Continue?"
            } else {
                $msg += "`n`nA restore point will be taken, but you have unticked Generate rollback script, so there will be no undo script for this run. Continue?"
            }
            if ((Show-WDMessage ($msg, 'Confirm', 'YesNo', 'Warning')) -ne 'Yes') { return }
        }
        $state.Mode = 'debloat'
        if ($PreviewMode) { $state.RunLabel = $Label }
        $state.LastSelection = $Selection
        # The one place the choice is written, reconciled against what is
        # actually about to run, so a file left by an earlier session cannot
        # become a surprise install.
        $want = @()
        if ($Selection -contains $BROWSER_ID) { $want = @($state.BrowserChoices) }
        try {
            $null = Set-WDBrowserChoice -Root (Get-WDSession).Root -Names $want
        } catch {
            if ($want.Count) {
                Show-WDMessage (
                    "Could not record the replacement browser choice:`n`n$($_.Exception.Message)`n`n" +
                    'The run will continue, but no browser will be installed.',
                    'Windows Setup Toolkit', 'OK', 'Warning') | Out-Null
            }
        }
        # The rest of what the GUI collects and the manifest cannot carry. Same
        # file, same moment: this side is elevated and the run is not.
        try {
            $null = Set-WDRunOptions -Root (Get-WDSession).Root -Values @{
                deferFeatureDays = [int]$state.DeferDays.Feature
                deferQualityDays = [int]$state.DeferDays.Quality
                # The handler falls back to picking one itself when this is
                # absent, so the command line behaves as it always did.
                defaultBrowser   = [string]$state.DefaultBrowser
            }
        } catch {
            Write-WDLog "Could not record the run options: $($_.Exception.Message)" -Level Warn
        }
        & $enterRunPage $PreviewMode $Return

        & $newRunspace @{
            Sync = $state.Sync; ModulePath = $ModulePath; ManifestPath = $ManifestPath
            Selected = $Selection; PreviewMode = $PreviewMode
            RunRoot = (Get-WDSession).Root; AllowDl = [bool]$ui.ChkDownloads.IsChecked; AllowOwn = [bool]$ui.ChkOwnership.IsChecked
            Accounts = @(& $accountKeys)
            PresetName = [string]$state.Preset
            Modules = $script:WDRunspaceModules.Run
        } {
            try {
                # Everything from here to the first item used to happen in
                # silence - on an apply that is module loading, a restore point,
                # and a scan.
                $stage = { param([string]$t, [bool]$timed = $false)
                           $null = $Sync.Queue.Add(@{ Phase='Stage'; Text=$t; Timed=$timed }) }
                & $stage 'Loading the toolkit...'
                foreach ($m in $Modules) {
                    Import-Module (Join-Path $ModulePath "$m.psm1") -Force -DisableNameChecking
                }
                $session = Initialize-WDSession -Root $RunRoot -Preview:$PreviewMode
                $Sync.RunDir = [string]$session.RunDir
                & $stage 'Reading this machine...'
                $prof = Get-WDSystemProfile
                Set-WDLogSink {
                    param($lvl, $msg, $item)
                    if ($lvl -eq 'Finding') {
                        $null = $Sync.Queue.Add(@{ Phase='Finding'; Name=$msg.Name; Detail=$msg.Detail; Item=$item })
                    } elseif ($lvl -in @('Warn','Error')) {
                        $null = $Sync.Queue.Add(@{ Phase='Log'; Level=$lvl; Message=$msg; Item=$item })
                    }
                }
                if (-not $PreviewMode) {
                    & $stage 'Creating a system restore point.' $true
                    # The result was thrown away here, which made the promise in
                    # the confirmation dialog one this application could break
                    # in silence.
                    $rp = New-WDRestorePoint
                    $rpOk = ([string]$rp.Status -eq 'Changed')
                    $Sync.RestorePoint = $(if ($rpOk) { 'ok' } else { 'failed' })
                    $null = $Sync.Queue.Add(@{
                        Phase  = 'Row'
                        # A restore point that could not be taken is something
                        # standing in the way of the way back, not a removal
                        # that failed.
                        Status = $(if ($rpOk) { 'Changed' } else { 'Obstruction' })
                        Name   = 'System restore point'
                        Detail = "$($rp.Message)$(if ($rp.Detail) { " - $($rp.Detail)" } else { '' })" })
                }
                & $stage 'Reading the list...'
                $cats = Import-WDManifest -Path $ManifestPath
                & $stage 'Scanning what is installed.' $true
                $scn  = Get-WDDiscoveredSoftware -Categories $cats -Profile $prof
                $cats = Add-WDDiscoveredCategories -Categories $cats -Discovered (New-WDDiscoveredCategories -Scan $scn)
                & $stage 'Working out the plan...'
                $plan = Resolve-WDPlan -Categories $cats -Selected $Selected -Profile $prof

                # As rows on the page, in preview and in apply: the whole value
                # is saying it before rather than after.
                try {
                    foreach ($im in @(Get-WDHealthImpact -Plan $plan)) {
                        $hh = $im.Health
                        if ($hh.State -eq 'Ok') { continue }
                        # Every one of these is an obstruction rather than an
                        # outcome: none is an option somebody ticked.
                        $st = switch ($hh.State) {
                            'Unavailable' { 'Obstruction' }
                            'Degraded'    { 'Obstruction' }
                            default       { 'Skipped' }
                        }
                        $bits = New-Object System.Collections.Generic.List[string]
                        if ($hh.Reason) { $bits.Add([string]$hh.Reason) }
                        if ($im.Count -gt 0) {
                            $bits.Add("$($im.Count) selected option$(if ($im.Count -ne 1) { 's' }) need$(if ($im.Count -eq 1) { 's' }) this: " +
                                      ((@($im.Items | ForEach-Object { $_.Name }) | Select-Object -First 6) -join ', '))
                        }
                        if ($hh.Fix) { $bits.Add("Fix: $($hh.Fix)") }
                        $null = $Sync.Queue.Add(@{
                            Phase  = 'Row'
                            Status = $st
                            Name   = $hh.Name
                            Detail = ($bits -join ' | ') })
                    }
                } catch {
                    Write-WDLog "The tool check could not be shown on the run page: $($_.Exception.Message)" -Level Warn
                }

                $results = Invoke-WDPlan -Plan $plan -Session $session -Profile $prof `
                                         -AllowDownloads:$AllowDl -AllowOwnership:$AllowOwn `
                                         -Accounts $Accounts -CancelToken $Sync -Progress {
                    param($p)
                    $null = $Sync.Queue.Add(@{ Phase = $p.Phase; Index = $p.Index; Total = $p.Total
                        ItemName = $(if ($p.Item) { $p.Item.Name } else { '' })
                        # Action types ride along so the UI can cost the run
                        # without a copy of the plan.
                        Types  = $(if ($p.Item) { @($p.Item.Actions | ForEach-Object { [string]$_.type }) } else { @() })
                        Result = $p.Result })
                }
                # The rollback script is written by the rollback-script plan
                # item, not from here.
                & $stage 'Writing the report...'
                $null = Export-WDReport -Results $results -Session $session -Profile $prof -PresetName $PresetName
                # Only on an apply: a file called "what this run did" describing
                # a preview is the sort of thing somebody finds three weeks
                # later and believes.
                if (-not $PreviewMode) {
                    $Sync.NotesFile = [string](Export-WDRunNotes -Items $plan -PresetName $PresetName)
                    # Asked of the file rather than of the selection, because
                    # the item can be ticked and still fail.
                    try { $Sync.HasUndo = [bool](Test-Path -LiteralPath $session.UndoFile) } catch { $Sync.HasUndo = $false }
                    # Last, because it copies the three files above. The run has
                    # already succeeded, so a failure here is logged rather than
                    # raised.
                    try {
                        $keep = Export-WDRunFolder -Session $session
                        if ($keep) { $Sync.KeepDir = [string]$keep.Path }
                    } catch { }
                }
                # Counted off the results rather than the plan, so an item that
                # changed nothing does not ask for a restart.
                $needRestart = 0
                $byId = @{}
                foreach ($p in @($plan)) { $byId[[string]$p.Id] = $p }
                foreach ($r in @($results)) {
                    if ([string]$r.Status -notin @('Removed','Changed','Partial')) { continue }
                    $pi = $byId[[string]$r.Id]
                    if ($pi -and [bool]$pi.Reboot) { $needRestart++ }
                }
                $Sync.RestartCount = $needRestart
                # The reboot flag belongs to this runspace's session, so this is
                # the only place it can be read.
                try { $Sync.Reboot = [bool](Get-WDSession).RebootNeeded } catch { }
            } catch { $Sync.Error = $_.Exception.Message } finally { $Sync.Done = $true }
        }
    }

    $startRevert = {
        $picked = @($revertRows | Where-Object { $_.Check.IsChecked } | ForEach-Object { $_.Tag })
        if (-not $picked.Count) {
            Show-WDMessage ('Nothing is selected to revert.', 'Windows Setup Toolkit', 'OK', 'Warning') | Out-Null
            return
        }

        # Ticked options become one rollback invocation per run, restricted with
        # that script's own -Only. Its executor is the tested one.
        $ops    = New-Object System.Collections.Generic.List[psobject]
        $byRun  = @{}
        $noScript = New-Object System.Collections.Generic.List[string]
        foreach ($t in $picked) {
            if ([string]$t.Kind -ne 'option') { $ops.Add($t); continue }
            foreach ($r in @($t.Runs)) {
                $rid = [string]$r
                if (-not $byRun.ContainsKey($rid)) { $byRun[$rid] = New-Object System.Collections.Generic.List[string] }
                if (-not $byRun[$rid].Contains([string]$t.Id)) { $byRun[$rid].Add([string]$t.Id) }
            }
        }
        foreach ($run in @(@($revertPick.Runs) | Sort-Object When -Descending)) {
            $rid = [string]$run.Id
            if (-not $byRun.ContainsKey($rid)) { continue }
            if (-not $run.UndoFile) { $noScript.Add($run.When.ToString('d MMM yyyy, HH:mm')); continue }
            $ops.Add(@{
                Kind = 'rollback'; Path = $run.UndoFile; Only = @($byRun[$rid])
                Name = "Put back $($byRun[$rid].Count) option(s) from $($run.When.ToString('d MMM yyyy, HH:mm'))"
            })
        }

        if (-not $ops.Count) {
            Show-WDMessage (("Nothing selected can be put back from here. " +
                             "The runs it belongs to have no rollback script left."),
                            'Windows Setup Toolkit', 'OK', 'Warning') | Out-Null
            return
        }
        # Said before the button rather than discovered in the report.
        $ask = "Revert $($picked.Count) option(s) across $($ops.Count) step(s)?"
        if ($noScript.Count) {
            $ask += "`n`n$($noScript.Count) of the runs involved have no rollback script left, so their share cannot be put back: " +
                    ($noScript -join ', ') + '.'
        }
        if ((Show-WDMessage ($ask, 'Confirm', 'YesNo', 'Warning')) -ne 'Yes') { return }
        $ops = @($ops)
        $state.Mode = 'revert'
        & $enterRunPage $false 'PageRevert'
        & $newRunspace @{
            Sync = $state.Sync; ModulePath = $ModulePath; Ops = $ops; RunRoot = (Get-WDSession).Root
            Modules = $script:WDRunspaceModules.Run
        } {
            try {
                foreach ($m in $Modules) {
                    Import-Module (Join-Path $ModulePath "$m.psm1") -Force -DisableNameChecking
                }
                $session = Initialize-WDSession -Root $RunRoot
                Set-WDLogSink {
                    param($lvl, $msg, $item)
                    if ($lvl -eq 'Finding') {
                        $null = $Sync.Queue.Add(@{ Phase='Finding'; Name=$msg.Name; Detail=$msg.Detail; Item=$item })
                    } elseif ($lvl -in @('Warn','Error')) {
                        $null = $Sync.Queue.Add(@{ Phase='Log'; Level=$lvl; Message=$msg; Item=$item })
                    }
                }
                $null = Invoke-WDRevertPlan -Ops $Ops -Session $session -CancelToken $Sync -Progress {
                    param($p)
                    $null = $Sync.Queue.Add(@{ Phase = $p.Phase; Index = $p.Index; Total = $p.Total
                        ItemName = $(if ($p.Item) { $p.Item.Name } else { '' }); Result = $p.Result; Elapsed = $p.Elapsed })
                }
            } catch { $Sync.Error = $_.Exception.Message } finally { $Sync.Done = $true }
        }
    }

    $presetSelection = { @(& $withBrowser @(& $effectiveIds $state.Preset)) }
    $checkSelection  = { @(& $withBrowser @($rows | Where-Object { $_.Check.IsChecked } | ForEach-Object { $_.Id })) }
    # Anything the operator struck out while reading the simulation.
    $applySelection  = { @($state.LastSelection | Where-Object { -not $state.Excluded.Contains($_) }) }

    # Preview is the only way in. Apply appears once a preview has been read.
    $goRef.Preview = { & $startRun $true (& $presetSelection) $state.Preset 'PageModes' }.GetNewClosure()
    $ui.BtnPreview.Add_Click({    & $startRun $true (& $checkSelection) 'a custom selection' 'PageAdvanced' }.GetNewClosure())
    # Apply is only reachable from a finished simulation, so the label the
    # simulation used is the one that describes what is about to run.
    $ui.BtnApplyNow.Add_Click({
        $lbl = [string]$state.RunLabel
        if (-not $lbl) { $lbl = [string]$state.Preset }
        & $startRun $false (& $applySelection) $lbl $state.ReturnPage
    }.GetNewClosure())
    $ui.BtnRevertRun.Add_Click({  & $startRevert }.GetNewClosure())

    $ui.BtnCancel.Add_Click({
        $state.Sync.Cancel = $true
        $ui.BtnCancel.IsEnabled = $false
        $ui.TxtRunNote.Text = 'Canceling after the current item finishes...'
    }.GetNewClosure())
    $ui.BtnSkipItem.Add_Click({
        $state.Sync.SkipItem = $true
        $ui.BtnSkipItem.IsEnabled = $false
        $ui.TxtNowNote.Text = 'Skipping. It will stop once the step it is inside returns - which for an external ' +
                              'uninstaller can still be several minutes.'
    }.GetNewClosure())
    # The run's own folder, not this thread's: they are different sessions and
    # only one has a report in it.
    $ui.BtnOpenLogs.Add_Click({
        $dir = [string]$state.Sync.RunDir
        if (-not $dir) { $dir = (Get-WDSession).RunDir }
        if ($dir) { Start-Process explorer.exe $dir }
    }.GetNewClosure())
    $ui.BtnSaveNotes.Add_Click({
        if ($state.NoPrompts) { return }
        $src = [string]$state.Sync.NotesFile
        if (-not $src -or -not (Test-Path -LiteralPath $src)) {
            Show-WDMessage ('There is no record to save - this run wrote none.',
                                       'What this run did', 'OK', 'Warning') | Out-Null
            return
        }
        $dlg = New-Object Windows.Forms.SaveFileDialog
        # Whatever the run actually wrote, rather than a fixed extension:
        # offering to save a markdown file as .txt renames it into something no
        # reader will format.
        $ext = [System.IO.Path]::GetExtension($src)
        if (-not $ext) { $ext = '.md' }
        $dlg.Filter = "Markdown file (*.md)|*.md|Text file (*.txt)|*.txt"
        if ($ext -eq '.txt') { $dlg.FilterIndex = 2 }
        $dlg.FileName = "What-WinSetupToolkit-did-$(Split-Path $state.Sync.RunDir -Leaf)$ext"
        if ($dlg.ShowDialog() -ne 'OK') { return }
        try {
            Copy-Item -LiteralPath $src -Destination $dlg.FileName -Force
            Show-WDMessage ("Saved to $($dlg.FileName).`n`nKeep it somewhere you will find it. If something " +
                                       'on this machine stops working weeks from now, searching that file for what is ' +
                                       'wrong will say whether this run is the reason.',
                                       'What this run did', 'OK', 'None') | Out-Null
        } catch {
            Show-WDMessage ("Could not save it: $($_.Exception.Message)", 'What this run did', 'OK', 'Error') | Out-Null
        }
    }.GetNewClosure())
    $ui.BtnBackRun.Add_Click({
        # Leaving the page under your own steam is the acknowledgement.
        $state.Acknowledged = $true
        # It says Close after an apply, and a button that says Close and goes
        # back to the mode screen instead is a button that lied.
        if ([string]$ui.BtnBackRun.Content -eq 'Close') {
            $ui.PageRun.Visibility = 'Collapsed'
            $ui.NowCard.Visibility = 'Collapsed'
            if (-not $state.NoPrompts) { $win.Close() }
            return
        }
        $ui.PageRun.Visibility = 'Collapsed'
        $ui.NowCard.Visibility = 'Collapsed'
        if ($state.ReturnPage -eq 'PageRevert') { & $buildRevert }
        $ui[$state.ReturnPage].Visibility = 'Visible'
    }.GetNewClosure())

    # Registered on the window once and dispatched through the Tag: the window
    # outlives any one build of its contents.
    $win.Tag.Closing = {
        param($e)
        if ($state.Shell -and -not $state.Sync.Done) {
            if ((Show-WDMessage ('A run is still in progress. Close anyway?', 'Windows Setup Toolkit', 'YesNo', 'Warning')) -ne 'Yes') {
                $e.Cancel = $true; return
            }
            $state.Sync.Cancel = $true
        } elseif (-not $state.Acknowledged -and -not $state.NoPrompts) {
            # A run that finished used to sail through this guard, because the
            # guard only asked about runs still going.
            $reboot = [bool]$state.Sync.Reboot
            $rc = [int]$state.Sync.RestartCount
            $restart = $(if ($rc -gt 0) {
                             "`n`n$rc change$(if ($rc -ne 1) { 's' }) still need$(if ($rc -eq 1) { 's' } else { '' }) a restart to take effect."
                         } elseif ($reboot) { "`n`nA restart is still needed to finish applying it." } else { '' })
            # The same three things the card says, because this is the last
            # thing anybody sees.
            $msg = 'The run has finished. Close the toolkit?' + $restart +
                   "`n`n" + (@(& $wrapUpLines) -join "`n`n")
            if ((Show-WDMessage ($msg, 'Windows Setup Toolkit', 'YesNo', 'None')) -ne 'Yes') {
                $e.Cancel = $true; return
            }
            $state.Acknowledged = $true
        }
        $timer.Stop()
        # Reached through the holder, not as a variable: the timer is created
        # after this handler is.
        if ($storage.Timer) { $storage.Timer.Stop() }
        # A drive walk can easily outlive the window that asked for it.
        Stop-WDDiskWalk
        if ($state.Shell)    { try { $state.Shell.Dispose() }    catch { } }
        if ($state.Runspace) { try { $state.Runspace.Dispose() } catch { } }
    }.GetNewClosure()

    & $say 'Building the interface' 'Almost there'
    # Opening state. The boxes and the layout belong to the deferred page; the
    # mode grid is the screen this opens on.
    $advWork.Add({
        if ($advSay.Fn) { & $advSay.Fn 'Laying the page out' }
        & $applyPresetToChecks $state.Preset
        if ($PreSelected) {
            $pre = New-WDStringSet $PreSelected
            foreach ($r in $rows) { $r.Check.IsChecked = $pre.Contains($r.Id) }
        }
        & $updateTally
        & $syncAccounts
        # Unconditionally, because this is what lays the page out and builds the
        # rail. It used to be skipped when the saved order was already
        # 'category', which opened with an empty rail.
        & $applyOrder
    }.GetNewClosure())

    # Everything above only registered work. This is the one place that runs it.
    $ensureAdvanced = {
        if ($advBuilt.Done) { return }
        # Set first, not last: some of the work below asks the page questions
        # about itself.
        $advBuilt.Done = $true
        # Nothing the pre-warm has done is thrown away, and nothing it has half
        # done either: one list, both runners take from the front.
        if ($win.Tag.AdvWarm) { $win.Tag.AdvWarm.Stop() }
        # Raised before the first pump, not after: $veil.Show and the frame
        # under it are dispatcher turns of their own.
        $advBuilt.Busy = $true
        $sw = [Diagnostics.Stopwatch]::StartNew()
        # No overlay before the window has one - a command-line selection forces
        # this build during the build.
        $veil = $win.Tag.Busy
        # The overlay's own setup is inside the try, because Busy is raised
        # above it and a throw would leave the flag standing.
        try {
            $advSay.N = 0
            $advSay.Shown = 0.0
            if ($veil) {
                # Copied in first: this block is a closure, so the reporter
                # built below sees these locals and nothing else.
                $tick = $advSay
                $pump = $pumpFrame
                $work = $advWork
                & $veil.Show 'Opening the item list'
                # The denominator is read, never fixed. It used to be the count
                # of every category, so the bar could only reach (N - already
                # done) / N and stopped part way.
                $advSay.Fn = {
                    param([string]$What)
                    $raw = [double]$tick.N / [double][Math]::Max(1, $tick.N + $work.Count + 1)
                    if ($raw -gt $tick.Shown) { $tick.Shown = $raw }
                    & $veil.Set $What $tick.Shown
                    & $pump
                }.GetNewClosure()
                & $pumpFrame
            }
            # Consumed from the front rather than iterated, so this finishes a
            # list the pre-warm has partly emptied.
            while ($advWork.Count) {
                $w = $advWork[0]
                $advWork.RemoveAt(0)
                # Timed here too, but kept apart from the pre-warm's figure and
                # not the one anything asserts on: this path pumps frames, so a
                # layout pass lands inside the measurement.
                $one = [Diagnostics.Stopwatch]::StartNew()
                try { & $w } finally {
                    $one.Stop()
                    # Counted here rather than in the reporter, because not
                    # every entry reports - a category names itself once and
                    # then puts continuations back.
                    $advSay.N++
                    if ($one.ElapsedMilliseconds -gt $advBuilt.PeakOpen) {
                        $advBuilt.PeakOpen = [int]$one.ElapsedMilliseconds
                    }
                }
            }
            # Full, and only now: every reporter above holds a place for the
            # step it is about to run.
            if ($veil) { $advSay.Shown = 1.0; & $veil.Set '' 1.0 }
        } finally {
            $advBuilt.Busy = $false
            $advSay.Fn = $null
            if ($veil) { & $veil.Hide }
        }
        $advBuilt.Ms = [int]$sw.ElapsedMilliseconds
        # The number that matters is what the click actually cost.
        Write-WDLog ("Item list finished in $([Math]::Round($advBuilt.Ms / 1000, 1))s on first use" +
                     $(if ($advBuilt.Warmed) { ", after $($advBuilt.Warmed) step(s) built ahead of time" } else { '' }) +
                     '.') -Level Info
    }.GetNewClosure()
    $advRef.Ensure = $ensureAdvanced

    # Building it before anybody asks. ApplicationIdle plus a quiet period,
    # because a tick that starts mid-gesture holds the thread for as long as its
    # entry takes.
    $advQuiet = @{ At = [DateTime]::UtcNow }
    $stamp = { $advQuiet.At = [DateTime]::UtcNow }.GetNewClosure()
    foreach ($ev in @('PreviewMouseMove', 'PreviewMouseDown', 'PreviewMouseWheel',
                      'PreviewKeyDown', 'PreviewTextInput')) {
        # Tunnelling handlers on the window see everything on the way down, so
        # one registration per kind covers every control on every page - and a
        # handled event still counts.
        $win."Add_$ev"($stamp)
    }
    $advWarm = New-Object Windows.Threading.DispatcherTimer([Windows.Threading.DispatcherPriority]::ApplicationIdle)
    $advWarm.Interval = [TimeSpan]::FromMilliseconds(15)
    $warmWatch = [Diagnostics.Stopwatch]::new()
    $advWarm.Add_Tick({
        if ($advBuilt.Done -or $advBuilt.Busy) {
            if ($advBuilt.Done) { $advWarm.Stop() }
            return
        }
        # Still being used. Come back later; this costs nothing but the
        # comparison.
        if (([DateTime]::UtcNow - $advQuiet.At).TotalMilliseconds -lt 250) { return }
        if (-not $advWork.Count) {
            # The setup page is the other one built on demand and the other one
            # somebody waits for. Not in $advWork, because $ensureAdvanced would
            # charge an Advanced click for a page nobody asked for.
            if (-not $uaBuilt.Done) {
                $advBuilt.Busy = $true
                try { & $uaBuild }
                catch {
                    Write-WDLog "Building the setup page ahead of time failed, so it will be built on first use: $($_.Exception.Message)" -Level Warn
                }
                finally { $advBuilt.Busy = $false }
                Write-WDLog "Setup page built in the background in $($uaBuilt.Ms)ms, before it was opened." -Level Info
                return
            }
            $advWarm.Stop()
            $advBuilt.Done = $true
            $advBuilt.Ms0  = [int]$warmWatch.ElapsedMilliseconds
            # The peak matters more than the total: the total is how long the
            # pre-warm took, which nobody waits for.
            Write-WDLog ("Item list built in the background in " +
                         "$([Math]::Round($advBuilt.Ms0 / 1000, 1))s, before it was opened. " +
                         "Longest single step $([int]$advBuilt.Peak)ms.") -Level Info
            return
        }
        $warmWatch.Start()
        $advBuilt.Busy = $true
        $w = $advWork[0]
        $advWork.RemoveAt(0)
        $stepWatch = [Diagnostics.Stopwatch]::StartNew()
        try { & $w }
        catch {
            # A pre-warm that throws must not take the window with it, and must
            # not leave the page half built and marked done.
            $advWarm.Stop()
            Write-WDLog "Building the item list ahead of time failed, so it will be built on first use: $($_.Exception.Message)" -Level Warn
        }
        finally {
            $advBuilt.Busy = $false; $warmWatch.Stop(); $stepWatch.Stop()
            if ($stepWatch.ElapsedMilliseconds -gt $advBuilt.Peak) {
                $advBuilt.Peak = [int]$stepWatch.ElapsedMilliseconds
                # The line the scriptblock was written on, which names the slow
                # step without anyone maintaining a table of labels.
                $advBuilt.PeakAt = [int]$w.Ast.Extent.StartLineNumber
            }
        }
        $advBuilt.Warmed++
    }.GetNewClosure())
    $win.Tag.AdvWarm  = $advWarm
    # Handed to the show below, which restamps it: the grace period is measured
    # from the window appearing.
    $win.Tag.AdvQuiet = $advQuiet

    # Separate from $advWarm deliberately: that one builds a page and stops for
    # good, this has to come back whenever the cache is cleared.
    $appliedWarm = New-Object Windows.Threading.DispatcherTimer([Windows.Threading.DispatcherPriority]::ApplicationIdle)
    $appliedWarm.Interval = [TimeSpan]::FromMilliseconds(200)
    $appliedWarm.Add_Tick({
        if (-not $appliedWant.Count) { return }
        if (([DateTime]::UtcNow - $advQuiet.At).TotalMilliseconds -lt 250) { return }
        $runId = [string]$appliedWant[0]
        $appliedWant.RemoveAt(0)
        if (-not $runId -or $appliedState.ContainsKey($runId)) { return }
        # Recorded before the read, so a run that cannot be answered for is not
        # asked about again on every repaint.
        $appliedState[$runId] = $null
        try {
            $run = @(Get-WDPastRuns | Where-Object { $_.Id -eq $runId })
            if ($run.Count -and $run[0].Journal) {
                $appliedState[$runId] = Get-WDUndoStatus -Journal $run[0].Journal
            }
        } catch {
            Write-WDLog "Could not read how much of run $runId is still in place: $($_.Exception.Message)" -Level Warn
        }
        # Painted, not rebuilt: the columns have not changed shape, only what
        # one line of one of them says.
        try { & $repaintModeGrid } catch { }
        try { if ($revHomeRef.Paint) { & $revHomeRef.Paint } } catch { }
    }.GetNewClosure())
    # Started after the window is up and stopped when this build's frame ends: a
    # theme switch drops the frame without closing the window.
    $win.Tag.AppliedWarm = $appliedWarm

    & $selectPreset $state.Preset
    & $say 'Building the interface' 'opening: mode grid'
    # A selection handed in on the command line is a selection, and there is
    # nowhere to keep one but the boxes - the one start that cannot defer.
    if ($PreSelected) {
        & $ensureAdvanced
        & $showPage 'PageAdvanced'
    }
    & $say 'Building the interface' 'opening: preselection'

    # What the drive is full of.
    if ($SelfTestSeconds -le 0) {
        $cap0 = Get-WDDiskCapacity
        $storage.Scan = Start-WDStorageScan -ModulePath $ModulePath `
                            -Cached (Get-WDStorageCache -State $UiState -UsedBytes ($cap0.TotalBytes - $cap0.FreeBytes))
        $seen = @{ V = -1 }
        $diskTimer = New-Object Windows.Threading.DispatcherTimer
        $diskTimer.Interval = [TimeSpan]::FromMilliseconds(400)
        $diskTimer.Add_Tick({
            $sc = $storage.Scan
            if (-not $sc) { return }
            if ($sc.Version -ne $seen.V) {
                $seen.V = $sc.Version
                $storage.Snapshot = $sc.Snapshot
                & $paintStorage
            }
            if (-not $sc.Done) { return }
            $diskTimer.Stop()
            if ($sc.Error) { Write-WDLog "The drive could not be measured: $($sc.Error)" -Level Warn }
            # Buckets are only set when they were actually walked: a run that
            # used last week's answer must not stamp it with today's date, or it
            # never expires.
            if (-not $storage.Saved -and $sc.Buckets -and $storage.Snapshot) {
                $entry = New-WDStorageCacheEntry -Buckets $sc.Buckets -UsedBytes ([int64]$storage.Snapshot.UsedBytes)
                if ($entry) { $storage.Cache = $entry; $storage.Saved = $true; & $saveUiState }
            }
        }.GetNewClosure())
        $storage.Timer = $diskTimer
        $diskTimer.Start()
    } else {
        # A drive with fixed numbers, so the harness draws and clicks the real
        # bar rather than skipping an empty one.
        $storage.Snapshot = New-WDStorageSnapshot -Drive 'C:' -TotalBytes 1000GB -FreeBytes 600GB `
            -Items @{ 'disk-temp' = 6GB; 'disk-recycle-bin' = 20GB; 'disk-update-cache' = 3GB
                      'disk-windows-old' = 0L; 'disk-delivery-opt' = 0L } `
            -Unmeasured @('disk-component-store') `
            -Overlap @{ windows = 9GB; users = 3GB; other = 20GB } `
            -Raw @{ windows = 40GB; apps = 60GB; users = 300GB } `
            -Reserve ([ordered]@{ 'pagefile.sys' = 16GB }) -Denied 3 -Priced
        & $paintStorage
    }

    $selfTest = @{ Failures = 0 }
    if ($SelfTestSeconds -gt 0) {
        # The harness lives in WD.UITest, which nothing else imports: an
        # ordinary launch pays neither the import nor the parse.
        Import-Module (Join-Path $PSScriptRoot 'WD.UITest.psm1') -Force -DisableNameChecking
        $refs = [pscustomobject]@{
            accountChecks          = $accountChecks
            accountKeys            = $accountKeys
            accountTags            = $accountTags
            addLogRow              = $addLogRow
            advBuilt               = $advBuilt
            advPresetButtons       = $advPresetButtons
            advUndo                = $advUndo
            advWork                = $advWork
            appliedNote            = $appliedNote
            appliedRuns            = $appliedRuns
            applyFilter            = $applyFilter
            applyLogFilter         = $applyLogFilter
            applyOrder             = $applyOrder
            bandOf                 = $bandOf
            baseIds                = $baseIds
            BROWSER_ID             = $BROWSER_ID
            BROWSER_NONE           = $BROWSER_NONE
            browserDefault         = $browserDefault
            browserHere            = $browserHere
            browserUi              = $browserUi
            buildGroups            = $buildGroups
            buildRevert            = $buildRevert
            Categories             = $Categories
            catHeaders             = $catHeaders
            checkSelection         = $checkSelection
            clearCmpFilters        = $clearCmpFilters
            clearFilters           = $clearFilters
            clearOverrides         = $clearOverrides
            cmpAddButtons          = $cmpAddButtons
            cmpBoxes               = $cmpBoxes
            cmpButtons             = $cmpButtons
            cmpChips               = $cmpChips
            cmpDone                = $cmpDone
            cmpHead                = $cmpHead
            cmpSpyRef              = $cmpSpyRef
            cmpState               = $cmpState
            consequence            = $consequence
            counts                 = $counts
            currentDiff            = $currentDiff
            CUSTOM_BASE            = $CUSTOM_BASE
            diskImpact             = $diskImpact
            dropLoaded             = $dropLoaded
            EDGE_ID                = $EDGE_ID
            edgeExtIds             = $edgeExtIds
            effectiveIds           = $effectiveIds
            enterRunPage           = $enterRunPage
            EXCLUSIONS             = $EXCLUSIONS
            FILTER_GROUPS          = $FILTER_GROUPS
            filterBoxes            = $filterBoxes
            freeBrowsers           = $freeBrowsers
            groupCache             = $groupCache
            GROUPS                 = $GROUPS
            HIDE_ABSENT            = $HIDE_ABSENT
            HIDE_APPLIED           = $HIDE_APPLIED
            HIDE_OPT_IN            = $HIDE_OPT_IN
            indexEntries           = $indexEntries
            indexSpy               = $indexSpy
            installedIds           = $installedIds
            itemDetail             = $itemDetail
            itemFacts              = $itemFacts
            itemNote               = $itemNote
            knownIds               = $knownIds
            liveGroups             = $liveGroups
            LOADED_KEYS            = $LOADED_KEYS
            loadedPresets          = $loadedPresets
            loadedRefresh          = $loadedRefresh
            logRows                = $logRows
            modeCols               = $modeCols
            OPT_IN_ONLY            = $OPT_IN_ONLY
            overrides              = $overrides
            pal                    = $pal
            perUserIds             = $perUserIds
            phaseMs                = $phaseMs
            presetDefaults         = $presetDefaults
            presetNames            = $presetNames
            presetSelection        = $presetSelection
            pumpRun                = $pumpRun
            recordApplied          = $recordApplied
            registerLoaded         = $registerLoaded
            renameLoadedTo         = $renameLoadedTo
            reportDropped          = $reportDropped
            restoreFactory         = $restoreFactory
            REV_GROUPS             = $REV_GROUPS
            REV_SORTS              = $REV_SORTS
            revApplyOrder          = $revApplyOrder
            revBlocks              = $revBlocks
            revertPick             = $revertPick
            revertRows             = $revertRows
            revFilterBoxes         = $revFilterBoxes
            revFilterSel           = $revFilterSel
            revPaintCounts         = $revPaintCounts
            revRailCards           = $revRailCards
            revState               = $revState
            rowById                = $rowById
            rowBytes               = $rowBytes
            rowGate                = $rowGate
            rows                   = $rows
            rowStrips              = $rowStrips
            saveAsDefault          = $saveAsDefault
            saveLoadedTo           = $saveLoadedTo
            saveOutAndLoad         = $saveOutAndLoad
            savesFolder            = $savesFolder
            selfTest               = $selfTest
            setBrowsers            = $setBrowsers
            setOverride            = $setOverride
            setRowExcluded         = $setRowExcluded
            shippedNames           = $shippedNames
            shortPreset            = $shortPreset
            showPage               = $showPage
            sizeFacts              = $sizeFacts
            SORTS                  = $SORTS
            spyIndex               = $spyIndex
            statBlocks             = $statBlocks
            state                  = $state
            statusFilter           = $statusFilter
            storage                = $storage
            storageRows            = $storageRows
            UA_FIELDS              = $UA_FIELDS
            uaAddBtn               = $uaAddBtn
            uaBuild                = $uaBuild
            uaBuilt                = $uaBuilt
            uaControls             = $uaControls
            uaExtraAccts           = $uaExtraAccts
            uaGenerate             = $uaGenerate
            uaHeads                = $uaHeads
            uaPaintSummary         = $uaPaintSummary
            ui                     = $ui
            uiStateOut             = $uiStateOut
            UNCHECKED              = $UNCHECKED
            updateTally            = $updateTally
            win                    = $win
        }
        $st = New-Object Windows.Threading.DispatcherTimer
        $st.Interval = [TimeSpan]::FromSeconds($SelfTestSeconds)
        # $st.Stop() stays here with the timer. It also stops a collision: the
        # harness reuses $st as a scratch local, and names are case-insensitive.
        $st.Add_Tick({
            $st.Stop()
            Invoke-WDInteractionTest -Refs $refs
        }.GetNewClosure())
        $st.Start()
    }

    # Mount the page in the window.
    & $say 'Building the interface' 'opening: mount'
        $page = $shell.Content
    $shell.Content = $null

    $busy     = New-WDBusyOverlay -Palette $pal -Brush $Brush
    $pageHost = New-Object Windows.Controls.Grid
    $hostGrid = New-Object Windows.Controls.Grid
    $null = $hostGrid.Children.Add($pageHost)
    $null = $hostGrid.Children.Add($busy.Panel)
    $win.Content      = $hostGrid
    $win.Tag.Busy     = $busy
    $win.Tag.PageHost = $pageHost
    $win.Add_Closing({ if ($this.Tag.Closing) { & $this.Tag.Closing $_ } })
    $win.Add_Closed({  if ($this.Tag.Frame)   { $this.Tag.Frame.Continue = $false } })
    # The HWND has to exist before DWM will take an attribute, and the window
    # has to be styled before it is shown or the first frame is the wrong
    # colour.
    $null = (New-Object Windows.Interop.WindowInteropHelper $win).EnsureHandle()
    $pageHost.Children.Clear()
    $null = $pageHost.Children.Add($page)

    # Mica, and the caption colour that goes with it.
    $win.Tag.Mica = [bool](Set-WDWindowBackdrop -Window $win -Dark ([bool]$pal.Dark))
    if ($win.Tag.Mica) {
        $win.Background     = [Windows.Media.Brushes]::Transparent
        $ui.Root.Background = [Windows.Media.Brushes]::Transparent
    }

    Write-WDLog ("Interface built in {0:n1}s." -f $buildClock.Elapsed.TotalSeconds) -Level Info
    if ($Splash) {
        # The splash stays up through the whole build - the slow part on a
        # machine with 190 rows - and goes only once there is something to look
        # at.
        try { & $Splash.Close } catch { }
    }
    & $busy.Hide
    # The build is over: from here a call into $syncBrowser can only have come
    # from something the user did.
    $state.Building = $false

    # Show() and a dispatcher frame rather than ShowDialog(), which is what
    # makes a theme switch possible at all.
    $frame = New-Object Windows.Threading.DispatcherFrame
    $win.Tag.Frame = $frame
    # The self test renders the real window and drives real events through it,
    # but must not steal the foreground while it does.
    if ($state.NoPrompts) { $win.ShowActivated = $false }
    # Before Show, so the window's first frame is already the run page rather
    # than a flash of the mode screen.
    if ($ShowRun -and $replayRef.Fn) {
        try { $null = & $replayRef.Fn $ShowRun } catch { }
    }
    $win.Show()
    # Started only once the window is up, so nothing competes with the first
    # paint.
    if ($win.Tag.AdvQuiet) { $win.Tag.AdvQuiet.At = [DateTime]::UtcNow }
    # What the item list looked like at the moment the window appeared. The
    # original assertion - no rows three seconds in - stopped being true when
    # the pre-warm arrived.
    $win.Tag.RowsAtShow = [int]$rows.Count
    if ($win.Tag.AdvWarm) { $win.Tag.AdvWarm.Start() }
    if ($win.Tag.AppliedWarm) { $win.Tag.AppliedWarm.Start() }
    # $null = because Activate() returns a Boolean, which without this escaped
    # as Show-WDWindow's return value.
    if (-not $state.NoPrompts) {
        $win.Topmost = $true
        $null = $win.Activate()
        $win.Topmost = $false
        # Focus as well as foreground: without it the window is in front and the
        # keyboard is still talking to whatever was there before.
        $null = $win.Focus()
    }
    [Windows.Threading.Dispatcher]::PushFrame($frame)

    # This build's poll timer dies with this build: a theme switch drops the
    # frame without closing the window, so the Closing handler never runs.
    if ($storage.Timer) { $storage.Timer.Stop() }
    if ($win.Tag.AdvWarm) { $win.Tag.AdvWarm.Stop() }
    if ($win.Tag.AppliedWarm) { $win.Tag.AppliedWarm.Stop() }
    # And the runspace, which dies here for the same reason: it holds this
    # build's inventory.
    Stop-WDSatisfiedScan -Job $satisfiedJob

    # Back in the function's own scope, so $script: reaches this module.
    $script:LastSelfTestFailures = [int]$selfTest.Failures

    # Nothing to hand back. A theme switch used to end this function so the
    # caller could call it again in the other palette.
    if ($win.IsVisible) { $win.Close() }
}

$script:SplashXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        WindowStartupLocation="CenterScreen" ShowInTaskbar="True"
        SizeToContent="Manual" Width="470" Height="230" Topmost="True"
        Title="Windows Setup Toolkit">
  <!-- The trigger lives on the Window, not on the Border it animates:
       FrameworkElement.Triggers is only settable in XAML on a root element, and
       putting it on the Border fails to parse outright. -->
  <Window.Triggers>
    <EventTrigger RoutedEvent="FrameworkElement.Loaded">
      <BeginStoryboard>
        <Storyboard RepeatBehavior="Forever" AutoReverse="True">
          <DoubleAnimation Storyboard.TargetName="Shift" Storyboard.TargetProperty="X"
                           From="0" To="290" Duration="0:0:1.1">
            <DoubleAnimation.EasingFunction>
              <SineEase EasingMode="EaseInOut"/>
            </DoubleAnimation.EasingFunction>
          </DoubleAnimation>
          <DoubleAnimation Storyboard.TargetName="Shuttle" Storyboard.TargetProperty="Opacity"
                           From="0.55" To="1.0" Duration="0:0:1.1"/>
        </Storyboard>
      </BeginStoryboard>
    </EventTrigger>
  </Window.Triggers>

  <Border Name="Card" CornerRadius="10" BorderThickness="1" Padding="30,26,30,24">
    <StackPanel>
      <TextBlock Name="Title" Text="Windows Setup Toolkit" FontSize="21" FontWeight="SemiBold"/>
      <TextBlock Name="Machine" FontSize="12.5" Margin="0,5,0,0" TextTrimming="CharacterEllipsis"/>

      <!-- Track plus a shuttle that sweeps across it. A Storyboard rather than
           an indeterminate ProgressBar: that control takes its colors from the
           system theme and renders nearly invisible on the dark card. -->
      <Border Name="Track" Height="4" CornerRadius="2" Margin="0,26,0,0" ClipToBounds="True"
              HorizontalAlignment="Stretch">
        <Border Name="Shuttle" Height="4" Width="120" CornerRadius="2" HorizontalAlignment="Left">
          <Border.RenderTransform>
            <TranslateTransform x:Name="Shift" X="0"/>
          </Border.RenderTransform>
        </Border>
      </Border>

      <TextBlock Name="Status" FontSize="13.5" Margin="0,16,0,0" TextWrapping="NoWrap"
                 TextTrimming="CharacterEllipsis"/>
      <TextBlock Name="Detail" FontSize="11.5" Margin="0,4,0,0" TextWrapping="NoWrap"
                 TextTrimming="CharacterEllipsis"/>
    </StackPanel>
  </Border>
</Window>
'@

function Get-WDSplashMachineLine {
    # The caption under the title. One place, because the splash sets it twice -
    # once at build and once when the profile arrives.
    param($Profile)
    if (-not $Profile) { return '' }
    # The computer's name first, because that is the one fact answering "am I
    # looking at the right machine".
    $line = "$($Profile.Caption) $($Profile.DisplayVersion)  -  $($Profile.Manufacturer) $($Profile.Model)"
    $name = [string]$Profile.ComputerName
    if ($name.Trim()) { $line = "$name  -  $line" }
    $line
}

function New-WDSplash {
    # The window that stands in for the console, on a UI thread of its own: WPF
    # runs the animation clock on the dispatcher that owns the element, and this
    # thread is about to block.
    param($Profile, [switch]$Quiet)

    $sync = [hashtable]::Synchronized(@{
        Status = 'Starting up'; Note = ''
        Close  = $false; Ready = $false; Error = $null
        # Published by the splash's own timer so the caller can see the window
        # is alive without touching an element it does not own.
        Shift  = 0.0
        Text   = ''
        # The machine line arrives late on the launch path: reading the profile
        # is six CIM queries and about a second.
        Machine = ''
    })

    if ($Profile) { $sync.Machine = Get-WDSplashMachineLine -Profile $Profile }

    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'          # WPF refuses to start on an MTA thread
    $rs.ThreadOptions  = 'ReuseThread'
    $rs.Open()
    # Plain data only. The runspace loads no modules, so the palette crosses as
    # the hashtable it already is.
    $rs.SessionStateProxy.SetVariable('Sync',    $sync)
    $rs.SessionStateProxy.SetVariable('Xaml',    $script:SplashXaml)
    $rs.SessionStateProxy.SetVariable('Pal',     (Get-WDPalette))
    $rs.SessionStateProxy.SetVariable('Quiet',   [bool]$Quiet)
    # The splash is the first thing on the taskbar, so it needs the icon - and
    # it has to cross as bytes rather than as a decoded frame.
    $rs.SessionStateProxy.SetVariable('IconBytes', (Get-WDAppIconBytes))

    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    $null = $ps.AddScript({
        try {
            Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
            # A local copy of the variable SessionStateProxy set, because the
            # timer's handler is a closure and [6] cannot know a runspace
            # variable exists.
            $box = $Sync
            $Brush = { param($hex) (New-Object Windows.Media.BrushConverter).ConvertFromString($hex) }
            $win = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader ([xml]$Xaml)))
            # Decoded here, on the thread that owns the window. This runspace
            # loads no modules, so it builds its own decoder from the bytes.
            if ($IconBytes) {
                try {
                    $ims = New-Object System.IO.MemoryStream (,[byte[]]$IconBytes)
                    $idc = New-Object Windows.Media.Imaging.IconBitmapDecoder `
                               $ims, ([Windows.Media.Imaging.BitmapCreateOptions]::None),
                               ([Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
                    $ico = $idc.Frames[0]
                    foreach ($fr in $idc.Frames) { if ($fr.PixelWidth -eq 32) { $ico = $fr } }
                    if ($ico.CanFreeze) { $ico.Freeze() }
                    $win.Icon = $ico
                } catch { }
            }
            $get = { param([string]$n) $win.FindName($n) }

            $card = & $get 'Card'
            $card.Background  = & $Brush $Pal.Panel
            $card.BorderBrush = & $Brush $Pal.Line
            (& $get 'Title').Foreground   = & $Brush $Pal.Text
            (& $get 'Track').Background   = & $Brush $Pal.Line
            (& $get 'Shuttle').Background = & $Brush $Pal.Accent
            $status = & $get 'Status'; $status.Foreground = & $Brush $Pal.Text
            $detail = & $get 'Detail'; $detail.Foreground = & $Brush $Pal.Muted
            $shift  = & $get 'Shift'
            $machine = & $get 'Machine'
            $machine.Foreground = & $Brush $Pal.Sub
            $machine.Text = [string]$box.Machine
            $status.Text  = [string]$box.Status

            # Dragging: there is no title bar to grab.
            $win.Add_MouseLeftButtonDown({ try { $this.DragMove() } catch { } })
            # -Quiet is for the self test: the splash is Topmost and activates
            # itself, which is right when it stands in for a console and wrong
            # in a test.
            if ($Quiet) { $win.Topmost = $false; $win.ShowActivated = $false }
            $win.Show()

            # The only thing that ever writes to these elements. Polling a
            # hashtable at 60ms rather than marshalling each update across.
            $tick = New-Object Windows.Threading.DispatcherTimer
            $tick.Interval = [TimeSpan]::FromMilliseconds(60)
            $tick.Add_Tick({
                try {
                    $s = [string]$box.Status
                    if ($s -and $status.Text -ne $s) { $status.Text = $s }
                    $n = [string]$box.Note
                    if ($detail.Text -ne $n) { $detail.Text = $n }
                    $m = [string]$box.Machine
                    if ($machine.Text -ne $m) { $machine.Text = $m }
                    $box.Text  = [string]$status.Text
                    $box.Shift = [double]$shift.X
                    if ($box.Close) {
                        $tick.Stop()
                        $win.Close()
                        [Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown()
                    }
                } catch { }
            }.GetNewClosure())
            $tick.Start()
            $box.Ready = $true
            # Blocks this runspace's thread and nothing else. Ends when the tick
            # above shuts the dispatcher down.
            [Windows.Threading.Dispatcher]::Run()
        } catch {
            $Sync.Error = $_.Exception.Message
            # Set even on failure, or the caller waits the full timeout for a
            # window that is never coming.
            $Sync.Ready = $true
        }
    })
    $handle = $ps.BeginInvoke()

    # Wait for the window to exist, but never forever: a splash that cannot
    # start is not a reason to refuse to run.
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while (-not $sync.Ready -and $sw.ElapsedMilliseconds -lt 6000) { Start-Sleep -Milliseconds 15 }

    $setText = {
        param([string]$Text, [string]$Note)
        if ($Text) { $sync.Status = $Text }
        $sync.Note = [string]$Note
    }.GetNewClosure()

    $setMachine = {
        param($Profile)
        $sync.Machine = Get-WDSplashMachineLine -Profile $Profile
    }.GetNewClosure()

    @{
        # Not Window. It belongs to another thread and touching it from here
        # throws.
        State   = $sync
        Text    = $setText
        Status  = $setText
        # Fills the caption in after the fact, for the launch path, which puts
        # this window on screen before it reads the machine.
        Machine = $setMachine
        # Kept so the two callers that say "let the splash breathe" go on
        # compiling. There is nothing left to pump.
        Pump   = { }
        Close  = {
            $sync.Close = $true
            try { $null = $ps.EndInvoke($handle) } catch { }
            try { $ps.Dispose() } catch { }
            try { $rs.Close(); $rs.Dispose() } catch { }
        }.GetNewClosure()
    }
}

function Start-WDSatisfiedScan {
    # "Is there anything left for this option to do", asked about every item on
    # a runspace of its own.
    param([string]$ModulePath, $Categories, $Inventory, $Profile)
    # Answer $null rather than throw: every caller copes with an empty map by
    # asking the machine.
    $map = [hashtable]::Synchronized(@{})
    if (-not $ModulePath) { return $null }
    try {
        # Flattened here rather than in the runspace: walking the category
        # objects is this thread's own data structure.
        $items = New-Object System.Collections.Generic.List[psobject]
        foreach ($c in @($Categories)) {
            foreach ($i in @($c.items)) { if ($i) { $items.Add($i) } }
        }
        if (-not $items.Count) { return $null }

        $rs = [runspacefactory]::CreateRunspace()
        $rs.ApartmentState = 'STA'
        $rs.ThreadOptions  = 'ReuseThread'
        $rs.Open()
        $rs.SessionStateProxy.SetVariable('ModulePath', $ModulePath)
        $rs.SessionStateProxy.SetVariable('Items',      $items)
        $rs.SessionStateProxy.SetVariable('Inv',        $Inventory)
        $rs.SessionStateProxy.SetVariable('Prof',       $Profile)
        $rs.SessionStateProxy.SetVariable('Map',        $map)
        $rs.SessionStateProxy.SetVariable('Modules',    $script:WDRunspaceModules.Probe)
        $ps = [powershell]::Create()
        $ps.Runspace = $rs
        $null = $ps.AddScript({
            foreach ($m in $Modules) {
                Import-Module (Join-Path $ModulePath "$m.psm1") -Force -DisableNameChecking
            }
            foreach ($it in $Items) {
                # Per item, so one bad item costs its own answer rather than
                # every answer after it.
                try { $Map[[string]$it.id] = [bool](Test-WDItemSatisfied -Item $it -Inventory $Inv -Profile $Prof) } catch { }
            }
        })
        @{ Map = $map; PS = $ps; RS = $rs; Handle = $ps.BeginInvoke() }
    } catch {
        try { Write-WDLog "Could not start the already-applied read: $($_.Exception.Message)" -Level Warn } catch { }
        $null
    }
}

function Stop-WDSatisfiedScan {
    # Tidies the runspace up. Never throws - it runs from a Closed handler.
    param($Job)
    if (-not $Job) { return }
    try {
        if (-not $Job.Handle.IsCompleted) { $Job.PS.Stop() }
        $Job.PS.Dispose(); $Job.RS.Dispose()
    } catch { }
}

function Start-WDStartupScan {
    # Loads the manifest and runs the scan while the splash animates.
    param(
        [Parameter(Mandatory)][string]$ModulePath,
        [Parameter(Mandatory)][string]$ManifestPath,
        $Splash,
        [switch]$NoScan,
        [switch]$Async
    )

    $sync = [hashtable]::Synchronized(@{
        Status = 'Starting up'; Note = ''; Done = $false; Error = $null; Result = $null
        # Published as soon as it is known rather than with the rest of the
        # result, because the splash's caption is waiting on it.
        Profile = $null
    })

    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.ThreadOptions  = 'ReuseThread'
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('Sync',         $sync)
    $rs.SessionStateProxy.SetVariable('ModulePath',   $ModulePath)
    $rs.SessionStateProxy.SetVariable('ManifestPath', $ManifestPath)
    $rs.SessionStateProxy.SetVariable('DoScan',       (-not $NoScan))
    $rs.SessionStateProxy.SetVariable('Modules',      $script:WDRunspaceModules.Scan)

    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    $null = $ps.AddScript({
        try {
            foreach ($m in $Modules) {
                Import-Module (Join-Path $ModulePath "$m.psm1") -Force -DisableNameChecking
            }
            # The machine profile, first and published straight away: six CIM
            # queries and about a second, which the main thread used to pay
            # before anything could be drawn.
            $Sync.Status  = 'Looking at this machine'
            $Sync.Note    = 'Make, model, and what edition of Windows this is'
            $prof         = Get-WDSystemProfile
            $Sync.Profile = $prof

            $Sync.Status = 'Reading the removal list'
            $Sync.Note   = 'Curated manifest'
            $cats = Import-WDManifest -Path $ManifestPath

            $scn = $null
            $seen = $null
            if ($DoScan) {
                $scn = Get-WDDiscoveredSoftware -Categories $cats -Profile $prof -Progress {
                    param($t, $n)
                    $Sync.Status = $t
                    $Sync.Note   = $n
                }
                $disc = New-WDDiscoveredCategories -Scan $scn
                if (@($disc).Count) { $cats = Add-WDDiscoveredCategories -Categories $cats -Discovered $disc }
                # After the discovered categories are folded in, so anything the
                # scan found is asked about on the same terms.
                $Sync.Status = 'Checking what is on this machine'
                $Sync.Note   = 'Matching the list against what is installed'
                $seen = Get-WDItemPresence -Categories $cats -Inventory $scn.Inventory -Profile $prof
            }
            $Sync.Result = @{ Categories = $cats; Scan = $scn; Presence = $seen }
        } catch {
            $Sync.Error = $_.Exception.Message
        } finally {
            $Sync.Done = $true
        }
    })
    $handle = $ps.BeginInvoke()

    $job = @{ Sync = $sync; PS = $ps; RS = $rs; Handle = $handle; ManifestPath = $ManifestPath }
    if ($Async) { return $job }
    Wait-WDStartupScan -Job $job -Splash $Splash
}

function Wait-WDStartupScan {
    # The other half of Start-WDStartupScan, and the reason it has halves.
    param([Parameter(Mandatory)]$Job, $Splash)

    $sync   = $Job.Sync
    $ps     = $Job.PS
    $rs     = $Job.RS
    $handle = $Job.Handle

    # A plain wait, splash or no splash. This used to pump a DispatcherFrame so
    # the splash could animate; the splash animates on its own thread now, and a
    # message loop here only lets this thread re-enter itself.
    $said = $false
    while (-not $sync.Done) {
        if ($Splash) { & $Splash.Text $sync.Status $sync.Note }
        # Once, not every pass: it is a string comparison in the splash's own
        # timer either way.
        if ($Splash -and -not $said -and $sync.Profile) {
            & $Splash.Machine $sync.Profile
            $said = $true
        }
        Start-Sleep -Milliseconds 50
    }

    try { $null = $ps.EndInvoke($handle) } catch { }
    $ps.Dispose(); $rs.Close(); $rs.Dispose()

    # Profile comes back with the rest so the caller does not read it again.
    # Null when the scan died before it got that far.
    $out = @{ Categories = $null; Scan = $null; Presence = $null
              Profile = $sync.Profile; Error = $sync.Error }
    if ($sync.Result) {
        $out.Categories = $sync.Result.Categories
        $out.Scan       = $sync.Result.Scan
        $out.Presence   = $sync.Result.Presence
    } else {
        if (-not $out.Error) { $out.Error = 'the scan produced no result' }
        $out.Categories = Import-WDManifest -Path $Job.ManifestPath
    }
    $out
}

$script:StorageScan = $null

function Start-WDStorageScan {
    # Measures the drive on a runspace of its own and publishes what it knows as
    # it knows it.
    param([Parameter(Mandatory)][string]$ModulePath, $Cached)

    if ($script:StorageScan) { return $script:StorageScan }

    $sync = [hashtable]::Synchronized(@{
        Snapshot = $null; Buckets = $null; Done = $false; Error = $null; Version = 0
    })

    # A previous walk may have been abandoned when its window closed, and the
    # flag that stopped it is a static on a type this process loaded once.
    Stop-WDDiskWalk -Reset

    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.ThreadOptions  = 'ReuseThread'
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('Sync',       $sync)
    $rs.SessionStateProxy.SetVariable('ModulePath', $ModulePath)
    $rs.SessionStateProxy.SetVariable('Cached',     $Cached)
    $rs.SessionStateProxy.SetVariable('Modules',    $script:WDRunspaceModules.Storage)

    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    $null = $ps.AddScript({
        try {
            foreach ($m in $Modules) {
                Import-Module (Join-Path $ModulePath "$m.psm1") -Force -DisableNameChecking
            }
            $cap = Get-WDDiskCapacity
            $Sync.Snapshot = New-WDStorageSnapshot -Drive $cap.Drive -TotalBytes $cap.TotalBytes -FreeBytes $cap.FreeBytes
            $Sync.Version++

            $rec = Measure-WDReclaimable -Cancellable
            $Sync.Snapshot = New-WDStorageSnapshot -Drive $cap.Drive -TotalBytes $cap.TotalBytes -FreeBytes $cap.FreeBytes `
                                                   -Items $rec.Items -Unmeasured $rec.Unmeasured -Overlap $rec.Overlap -Priced
            $Sync.Version++

            # Buckets are published only when they were actually walked: handing
            # back the cache would let a session that never measured anything
            # restamp it.
            $buckets = $Cached
            if (-not $buckets) {
                $buckets = Measure-WDDiskBuckets -Cancellable
                $Sync.Buckets = $buckets
            }
            # Read again: the walk takes long enough that the free space it was
            # compared against has moved.
            $cap = Get-WDDiskCapacity
            $Sync.Snapshot = New-WDStorageSnapshot -Drive $cap.Drive -TotalBytes $cap.TotalBytes -FreeBytes $cap.FreeBytes `
                                                   -Items $rec.Items -Unmeasured $rec.Unmeasured -Overlap $rec.Overlap `
                                                   -Raw $buckets.Raw -Reserve $buckets.Reserve -Denied $buckets.Denied -Priced
            $Sync.Version++
        } catch {
            $Sync.Error = $_.Exception.Message
        } finally {
            $Sync.Done = $true
        }
    })
    $null = $ps.BeginInvoke()

    # Not disposed here and not waited on: the walk runs on a background thread,
    # so it cannot hold the process open.
    $script:StorageScan = $sync
    $sync
}

function New-WDBusyOverlay {
    # The panel that covers the window while its contents are rebuilt. A
    # determinate bar, because the work blocks the UI thread between pumps.
    param($Palette, [scriptblock]$Brush)

    $veil = New-Object Windows.Controls.Border
    $veil.Background  = & $Brush $(if ($Palette.Dark) { '#D81F1F1F' } else { '#E8F5F5F5' })
    $veil.Visibility  = 'Collapsed'

    $card = New-Object Windows.Controls.Border
    $card.Background      = & $Brush $Palette.Panel
    $card.BorderBrush     = & $Brush $Palette.Line
    $card.BorderThickness = New-Object Windows.Thickness 1
    $card.CornerRadius    = 8
    $card.Padding         = '28,22'
    $card.Width           = 340
    $card.HorizontalAlignment = 'Center'
    $card.VerticalAlignment   = 'Center'

    $sp = New-Object Windows.Controls.StackPanel
    $head = New-Object Windows.Controls.TextBlock
    $head.Text = 'Switching theme'; $head.FontSize = 16; $head.FontWeight = 'SemiBold'
    $head.Foreground = & $Brush $Palette.Text
    $null = $sp.Children.Add($head)

    $note = New-Object Windows.Controls.TextBlock
    $note.FontSize = 12.5; $note.Margin = '0,4,0,12'; $note.TextTrimming = 'CharacterEllipsis'
    $note.Foreground = & $Brush $Palette.Sub
    $null = $sp.Children.Add($note)

    $track = New-Object Windows.Controls.Border
    $track.Height = 6; $track.CornerRadius = 3
    $track.Background = & $Brush $Palette.Line
    $fillHost = New-Object Windows.Controls.Grid
    $fill = New-Object Windows.Controls.Border
    $fill.Height = 6; $fill.CornerRadius = 3; $fill.Width = 0
    $fill.HorizontalAlignment = 'Left'
    $fill.Background = & $Brush $Palette.Accent
    $null = $fillHost.Children.Add($track)
    $null = $fillHost.Children.Add($fill)
    $null = $sp.Children.Add($fillHost)

    $card.Child = $sp
    $veil.Child = $card

    # What the bar actually did, so the self test can tell a bar that filled
    # from one that sat at zero.
    $seen = @{ Shown = $false; MaxWidth = 0.0; Full = $false }

    @{
        Panel = $veil
        Stats = $seen
        Show  = {
            param([string]$Text)
            if ($Text) { $head.Text = $Text }
            $note.Text = 'Starting'
            $fill.Width = 0
            $seen.Shown = $true
            $seen.MaxWidth = 0.0
            $seen.Full = $false
            $veil.Visibility = 'Visible'
        }.GetNewClosure()
        Set = {
            # $Line, not $Note: PowerShell names are case-insensitive, so a
            # parameter called $Note shadows the captured $note TextBlock.
            param([string]$Line, [double]$Fraction)
            if ($Line) { $note.Text = $Line }
            # The card is a fixed width, so the bar can be sized directly rather
            # than measured.
            $fill.Width = [Math]::Max(0, 284 * [Math]::Min(1.0, [Math]::Max(0.0, $Fraction)))
            if ($fill.Width -gt $seen.MaxWidth) { $seen.MaxWidth = [double]$fill.Width }
            if ($Fraction -ge 0.999) { $seen.Full = $true }
        }.GetNewClosure()
        Hide = { $veil.Visibility = 'Collapsed' }.GetNewClosure()
        # The overlay belongs to the window, so it outlives the palette it was
        # built in.
        Retheme = {
            param($P)
            $veil.Background      = & $Brush $(if ($P.Dark) { '#D81F1F1F' } else { '#E8F5F5F5' })
            $card.Background      = & $Brush $P.Panel
            $card.BorderBrush     = & $Brush $P.Line
            $head.Foreground      = & $Brush $P.Text
            $note.Foreground      = & $Brush $P.Sub
            $track.Background     = & $Brush $P.Line
            $fill.Background      = & $Brush $P.Accent
        }.GetNewClosure()
    }
}

function Get-WDSelfTestFailures {
    # Interaction failures from the last -SelfTest GUI pass.
    if ($null -eq $script:LastSelfTestFailures) { return 0 }
    [int]$script:LastSelfTestFailures
}

$script:ThemeXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Windows Setup Toolkit" WindowStartupLocation="CenterScreen"
        SizeToContent="WidthAndHeight" ResizeMode="NoResize" WindowStyle="None"
        AllowsTransparency="True" Background="Transparent" Topmost="True">
  <Border Name="Card" BorderThickness="1" CornerRadius="10" Padding="30,26">
    <StackPanel>
      <TextBlock Name="Head" Text="Dark or light?" FontSize="22" FontWeight="SemiBold" HorizontalAlignment="Center"/>
      <TextBlock Name="Sub" Text="You can change this later, at the bottom of the options list."
                 FontSize="13" Margin="0,6,0,20" HorizontalAlignment="Center"/>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Center">
        <Button Name="BtnDark"  Content="Dark"  Padding="34,9" Margin="0,0,10,0" FontSize="14"/>
        <Button Name="BtnLight" Content="Light" Padding="34,9" FontSize="14"/>
      </StackPanel>
    </StackPanel>
  </Border>
</Window>
'@

function Show-WDThemeChooser {
    # Asked once, on the very first run, before anything else is on screen.
    # Drawn in the Windows theme: picking one to ask the question in would be
    # answering it.
    $pal = Get-WDPalette
    $win = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader ([xml]$script:ThemeXaml)))
    $themeIcon = Get-WDAppIcon
    if ($themeIcon) { $win.Icon = $themeIcon }
    $get = { param([string]$n) $win.FindName($n) }
    $b   = { param($hex) (New-Object Windows.Media.BrushConverter).ConvertFromString($hex) }

    $card = & $get 'Card'
    $card.Background  = & $b $pal.Panel
    $card.BorderBrush = & $b $pal.Line
    (& $get 'Head').Foreground = & $b $pal.Text
    (& $get 'Sub').Foreground  = & $b $pal.Sub

    $picked = @{ Value = $null }
    foreach ($pair in @(@{ N = 'BtnDark'; V = 'dark' }, @{ N = 'BtnLight'; V = 'light' })) {
        $btn = & $get $pair.N
        $btn.Tag = $pair.V
        $btn.Add_Click({ $picked.Value = [string]$this.Tag; $win.Close() }.GetNewClosure())
    }
    $win.Add_MouseLeftButtonDown({ try { $this.DragMove() } catch { } })
    $null = $win.ShowDialog()
    [string]$picked.Value
}

function Show-WDSetupResult {
    # The prompt at the first sign-in after a run that had no interface.
    param([string]$RunDir, [string]$ScriptPath, [string]$Theme = '')

    $info = Read-WDSetupResult -RunDir $RunDir
    if (-not $info) { return $false }
    # No desktop to put a window on - a session with no interactive station.
    if (-not [Environment]::UserInteractive) { return $false }

    $pal = Get-WDPalette -Theme $Theme
    $b   = { param($hex) (New-Object Windows.Media.BrushConverter).ConvertFromString($hex) }

    $win = New-Object Windows.Window
    $win.Title = 'Windows Setup Toolkit'
    $win.SizeToContent = 'WidthAndHeight'
    $win.ResizeMode = 'NoResize'
    $win.WindowStartupLocation = 'CenterScreen'
    $win.Background = & $b $pal.Panel
    # It is the one window somebody meets before they know what this program is,
    # so it wears the mark.
    try { $win.Icon = Get-WDAppIcon } catch { }

    $sp = New-Object Windows.Controls.StackPanel
    $sp.Margin = '26,22,26,20'; $sp.MaxWidth = 520
    $win.Content = $sp

    $head = New-Object Windows.Controls.TextBlock
    $head.Text = 'Windows Setup Toolkit ran while Windows was being set up'
    $head.FontSize = 17; $head.FontWeight = 'SemiBold'; $head.TextWrapping = 'Wrap'
    $head.Foreground = & $b $pal.Text
    $null = $sp.Children.Add($head)

    $body = New-Object Windows.Controls.TextBlock
    $body.FontSize = 13; $body.TextWrapping = 'Wrap'; $body.Margin = '0,10,0,0'
    $body.Foreground = & $b $pal.Sub
    $what = $(if ($info.Label) { "the $($info.Label) selection" } else { 'your selection' })
    $body.Text = "It applied $what before anybody signed in, so there was nothing on screen at the time. " +
                 "$($info.Changed) change(s) were made" +
                 $(if ($info.Failed) { ", and $($info.Failed) item(s) failed" } else { '' }) + '.'
    $null = $sp.Children.Add($body)

    if ($info.RestartCount -gt 0 -or $info.Reboot) {
        $rs = New-Object Windows.Controls.TextBlock
        $rs.FontSize = 13; $rs.TextWrapping = 'Wrap'; $rs.Margin = '0,8,0,0'; $rs.FontWeight = 'SemiBold'
        $rs.Foreground = & $b $pal.Warn
        $rs.Text = $(if ($info.RestartCount -gt 0) {
                         "$($info.RestartCount) of them need a restart to take effect."
                     } else { 'A restart is needed to finish.' })
        $null = $sp.Children.Add($rs)
    }

    # Which of the three states this is, decided once, because the sentence and
    # the button have to agree.
    $canApp   = [bool]($ScriptPath -and (Test-Path -LiteralPath $ScriptPath))
    $canWrite = [bool]($info.KeepDir -or $info.SummaryFile)

    $tail = New-Object Windows.Controls.TextBlock
    $tail.FontSize = 12.5; $tail.TextWrapping = 'Wrap'; $tail.Margin = '0,10,0,0'
    $tail.Foreground = & $b $pal.Sub
    $tail.Text = $(if ($info.KeepDir) {
                       "Everything it did is written up in '$(Split-Path -Leaf $info.KeepDir)' on your desktop, including how to undo it."
                   } elseif ($canApp -or $canWrite) {
                       "Everything it did is written up in $($info.RunDir)."
                   } else {
                       # Nothing left to open, so say where the files are rather
                       # than offering a button that cannot work.
                       "There is nothing here that can open it for you. The files are in $($info.RunDir)."
                   })
    $null = $sp.Children.Add($tail)

    $row = New-Object Windows.Controls.StackPanel
    $row.Orientation = 'Horizontal'; $row.HorizontalAlignment = 'Right'; $row.Margin = '0,18,0,0'
    $null = $sp.Children.Add($row)

    # Everything a handler needs, in this scope, because each is a closure and
    # reaching up the chain captures $null.
    $theWin  = $win
    $theDir  = [string]$info.KeepDir
    $theRun  = [string]$info.RunDir
    $theText = [string]$info.SummaryFile
    $theApp  = [string]$ScriptPath

    $mkBtn = {
        param([string]$Text, [scriptblock]$Act, [bool]$Strong)
        $btn = New-Object Windows.Controls.Button
        $btn.Content = $Text; $btn.Padding = '16,6'; $btn.Margin = '8,0,0,0'; $btn.FontSize = 13
        if ($Strong) { $btn.FontWeight = 'SemiBold' }
        $btn.Add_Click($Act)
        $null = $row.Children.Add($btn)
        $btn
    }

    # One scriptblock because both branches below need it.
    $openWriteUp = {
        foreach ($p in @($theDir, $theText)) {
            if (-not $p) { continue }
            try { Start-Process -FilePath $p -ErrorAction Stop; return $true } catch { }
        }
        $false
    }.GetNewClosure()

    # One offer, never a menu: somebody has just signed into a new machine and
    # been told a program they may never have heard of changed things.
    if ($canApp) {
        $null = & $mkBtn 'Show me what it did' {
            try {
                Start-Process -FilePath 'powershell.exe' -Verb RunAs -ErrorAction Stop -ArgumentList @(
                    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA',
                    '-File', "`"$theApp`"", '-ShowRun', "`"$theRun`"")
                $theWin.Close()
            } catch {
                # Refused at the prompt, or a standard account with no rights to
                # give. Fall through to the write-up rather than leaving the one
                # button having done nothing.
                if (& $openWriteUp) { $theWin.Close() }
            }
        }.GetNewClosure() $true
    } elseif ($canWrite) {
        $null = & $mkBtn 'Show me what it did' {
            if (& $openWriteUp) { $theWin.Close() }
        }.GetNewClosure() $true
    }
    $null = & $mkBtn 'Close' { $theWin.Close() }.GetNewClosure() $false

    try { $null = $win.ShowDialog() } catch { return $false }
    $true
}

Export-ModuleMember -Function Show-WDWindow, Get-WDPalette, New-WDGridLength, Get-WDIconSource,
                              Get-WDAppIcon, Get-WDAppIconBytes, New-WDIconBytes,
                              Set-WDTaskbarIdentity,
                              Get-WDCategoryGlyph, Get-WDSelfTestFailures, New-WDSplash,
                              # Exported for the same reason
                              # Set-WDWindowBackdrop is: a GetNewClosure block
                              # resolves commands against its own module and
                              # then global, never against the one that defined
                              # it.
                              Get-WDSplashMachineLine,
                              # Every dialog goes through these, and most of the
                              # calls are inside GetNewClosure blocks.
                              Show-WDMessage, Set-WDDialogHost,
                              Start-WDStartupScan, Wait-WDStartupScan, Start-WDStorageScan,
                              Start-WDSatisfiedScan, Stop-WDSatisfiedScan,
                              Get-WDChildScrollViewer, Get-WDChildScrollBar, Show-WDThemeChooser,
                              Show-WDSetupResult,
                              # Exported because the theme-switch handler calls
                              # it, and a GetNewClosure scriptblock cannot see
                              # an unexported function.
                              Set-WDWindowBackdrop

