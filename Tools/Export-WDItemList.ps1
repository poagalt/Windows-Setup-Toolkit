<#
    Publishes the whole removal list as one self-contained HTML page.

    The point is that somebody can decide whether to trust this without running
    it, and without reading PowerShell. Everything on the page is generated from
    the manifest and from Get-WDItemMechanics - the same function the Details
    panel uses - so it cannot describe something the tool does not do. An
    authored marketing page about what the tool removes is a second copy of the
    list, and the copy is what goes stale.

    One file, no assets, no network. Search and the filters are a few lines of
    inline script so the page works from a file:// URL, out of a release zip, or
    served from GitHub Pages.

    Imports the modules read-only and touches nothing: it reads the manifest and
    formats it. It does NOT read the machine - no presence checks, no "already
    applied" - because this page describes the toolkit rather than any one
    computer, and a page whose contents depended on whoever generated it would
    be worthless as a reference.
#>
[CmdletBinding()]
param(
    [string]$OutFile = '',
    [string]$Source  = ''
)

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
if (-not $here) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $Source)  { $Source  = Split-Path -Parent $here }
if (-not $OutFile) { $OutFile = Join-Path $Source 'dist\item-list.html' }

foreach ($mod in 'WD.Core','WD.Detect','WD.Actions','WD.Custom','WD.Persist','WD.Discover','WD.Revert','WD.Engine') {
    Import-Module (Join-Path $Source "Modules\$mod.psm1") -Force -DisableNameChecking 3>$null 4>$null
}

$cats = Import-WDManifest -Path (Join-Path $Source 'Manifest')

$TIERS = @{ 0 = 'Opt-in only'; 1 = 'Conservative'; 2 = 'Balanced'; 3 = 'Aggressive'; 4 = 'Extreme' }
$RISKS = @{ 0 = ''; 1 = 'caution'; 2 = 'risky' }
$BANDS = @{ 1 = 'Sends your data out'; 2 = 'Advertising and nagging'; 3 = 'Bloatware'
            4 = 'Legacy and leftovers'; 5 = 'Sometimes useful'; 6 = 'Not recommended' }

function Get-Esc {
    param([string]$Text)
    if (-not $Text) { return '' }
    $Text.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace('"', '&quot;')
}

# --- collect, so the counts in the header are of what actually got rendered --
$rows  = New-Object System.Collections.Generic.List[psobject]
foreach ($cat in $cats) {
    foreach ($item in @($cat.items)) {
        $tier = [int](Get-Prop $item 'tier' 0)
        $mech = @()
        # Never let one malformed item take the whole page down: the page is
        # worth more with a gap in it than not built at all.
        try { $mech = @(Get-WDItemMechanics -Item $item) } catch { $mech = @("(could not be described: $($_.Exception.Message))") }
        $rows.Add([pscustomobject]@{
            Id        = [string]$item.id
            Name      = [string](Get-Prop $item 'name' ([string]$item.id))
            Desc      = [string](Get-Prop $item 'desc' '')
            RiskNote  = [string](Get-Prop $item 'riskNote' '')
            Settings  = [string](Get-Prop $item 'settingsPath' '')
            Tier      = $tier
            TierName  = [string]$TIERS[$tier]
            Risk      = [int](Get-Prop $item 'risk' 0)
            RiskName  = [string]$RISKS[[int](Get-Prop $item 'risk' 0)]
            Bloat     = [string]$BANDS[[int](Get-Prop $item 'bloat' 0)]
            Section   = [string](Get-WDItemSection -Item $item -Category $cat)
            Category  = [string](Get-Prop $cat 'name' 'Other')
            CatOrder  = [int](Get-Prop $cat 'order' 500)
            Mechanics = @($mech)
        })
    }
}

$byCat = $rows | Group-Object Category | Sort-Object { ($_.Group | Select-Object -First 1).CatOrder }, Name

$sb = New-Object System.Text.StringBuilder
$add = { param([string]$Line) $null = $sb.AppendLine($Line) }

& $add '<!DOCTYPE html>'
& $add '<html lang="en"><head><meta charset="utf-8">'
& $add '<meta name="viewport" content="width=device-width,initial-scale=1">'
& $add '<title>Windows Setup Toolkit - every option</title>'
& $add @'
<style>
:root{--bg:#16181d;--panel:#1e2128;--edge:#2c313b;--text:#e7e9ee;--sub:#9aa3b2;
      --accent:#5aa2ff;--warn:#e0b341;--bad:#e0655f;--ok:#5fbf7f}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--text);
     font:15px/1.55 "Segoe UI",system-ui,sans-serif}
.wrap{max-width:1080px;margin:0 auto;padding:32px 20px 80px}
h1{font-size:26px;margin:0 0 6px}
.lede{color:var(--sub);margin:0 0 26px;max-width:70ch}
.bar{position:sticky;top:0;background:var(--bg);padding:14px 0;border-bottom:1px solid var(--edge);
     margin-bottom:26px;z-index:5;display:flex;gap:10px;flex-wrap:wrap;align-items:center}
input[type=search],select{background:var(--panel);color:var(--text);border:1px solid var(--edge);
     border-radius:7px;padding:8px 11px;font:inherit}
input[type=search]{flex:1;min-width:220px}
.count{color:var(--sub);font-size:13px;white-space:nowrap}
h2{font-size:18px;margin:34px 0 4px;padding-bottom:6px;border-bottom:1px solid var(--edge)}
h2 .n{color:var(--sub);font-weight:400;font-size:14px}
.item{background:var(--panel);border:1px solid var(--edge);border-radius:9px;
      padding:13px 15px;margin:9px 0}
.item.hide{display:none}
.nm{font-weight:600}
.chip{display:inline-block;font-size:11px;border-radius:20px;padding:1px 9px;
      margin-left:7px;border:1px solid var(--edge);color:var(--sub);vertical-align:1px}
.chip.t0{border-color:#3a4150}
.chip.t1,.chip.t2{border-color:var(--ok);color:var(--ok)}
.chip.t3,.chip.t4{border-color:var(--warn);color:var(--warn)}
.chip.caution{border-color:var(--warn);color:var(--warn)}
.chip.risky{border-color:var(--bad);color:var(--bad)}
.d{color:var(--sub);margin-top:5px}
.rn{margin-top:7px;color:var(--warn);font-size:13.5px}
.sp{margin-top:6px;color:var(--sub);font-size:13px}
details{margin-top:9px}
summary{cursor:pointer;color:var(--accent);font-size:13px;width:max-content}
pre{background:#12141a;border:1px solid var(--edge);border-radius:7px;padding:11px;
    overflow-x:auto;font:12.5px/1.5 Consolas,ui-monospace,monospace;color:#cfd5e0;margin:8px 0 0}
.id{color:#6b7484;font:12px Consolas,monospace}
footer{margin-top:52px;padding-top:18px;border-top:1px solid var(--edge);color:var(--sub);font-size:13px}
a{color:var(--accent)}
</style>
'@
& $add '</head><body><div class="wrap">'
& $add '<h1>Windows Setup Toolkit &mdash; every option</h1>'
& $add ('<p class="lede">Generated from the toolkit''s own manifest, so this is exactly what it does ' +
        'rather than a description of it. Each entry shows which mode selects it and every registry value, ' +
        'service, scheduled task, package, and file it touches. Nothing here reads your machine.</p>')

& $add '<div class="bar">'
& $add '<input type="search" id="q" placeholder="Search names, descriptions, registry paths, service names...">'
& $add '<select id="tier"><option value="">Any mode</option>'
foreach ($t in 0..4) { & $add ('<option value="{0}">{1}</option>' -f $t, (Get-Esc $TIERS[$t])) }
& $add '</select>'
& $add '<select id="risk"><option value="">Any risk</option><option value="0">No risk</option><option value="1">Caution</option><option value="2">Risky</option></select>'
& $add ('<span class="count" id="count">{0} options</span>' -f $rows.Count)
& $add '</div>'

foreach ($grp in $byCat) {
    $first = $grp.Group | Select-Object -First 1
    & $add ('<h2 data-cat="1">{0} <span class="n">{1} option{2} &middot; {3}</span></h2>' -f `
            (Get-Esc $grp.Name), $grp.Count, $(if ($grp.Count -ne 1) { 's' } else { '' }),
            (Get-Esc $first.Section))
    foreach ($r in ($grp.Group | Sort-Object Tier, Name)) {
        $hay = (@($r.Name, $r.Desc, $r.RiskNote, $r.Id, $r.Category, $r.Bloat) + $r.Mechanics) -join ' '
        & $add ('<div class="item" data-tier="{0}" data-risk="{1}" data-hay="{2}">' -f `
                $r.Tier, $r.Risk, (Get-Esc $hay.ToLowerInvariant()))
        $chips = ('<span class="chip t{0}">{1}</span>' -f $r.Tier, (Get-Esc $r.TierName))
        if ($r.RiskName) { $chips += ('<span class="chip {0}">{0}</span>' -f $r.RiskName) }
        if ($r.Bloat)    { $chips += ('<span class="chip">{0}</span>' -f (Get-Esc $r.Bloat)) }
        & $add ('<div><span class="nm">{0}</span>{1}</div>' -f (Get-Esc $r.Name), $chips)
        if ($r.Desc)     { & $add ('<div class="d">{0}</div>' -f (Get-Esc $r.Desc)) }
        if ($r.RiskNote) { & $add ('<div class="rn"><b>{0}:</b> {1}</div>' -f (Get-Esc $r.RiskName), (Get-Esc $r.RiskNote)) }
        if ($r.Settings) { & $add ('<div class="sp">Undo by hand: {0}</div>' -f (Get-Esc $r.Settings)) }
        if ($r.Mechanics.Count) {
            & $add '<details><summary>What this changes</summary>'
            & $add ('<pre>{0}</pre>' -f (Get-Esc (($r.Mechanics | ForEach-Object { [string]$_ }) -join "`n")))
            & $add '</details>'
        }
        & $add ('<div class="id">{0}</div>' -f (Get-Esc $r.Id))
        & $add '</div>'
    }
}

& $add '<footer>'
& $add ('{0} options across {1} categories. Free for personal use under the ' -f $rows.Count, @($byCat).Count)
& $add '<a href="https://polyformproject.org/licenses/noncommercial/1.0.0">PolyForm Noncommercial License 1.0.0</a>. '
& $add 'Not affiliated with or endorsed by Microsoft.'
& $add '</footer>'
& $add '</div>'
& $add @'
<script>
var items = [].slice.call(document.querySelectorAll('.item'));
var heads = [].slice.call(document.querySelectorAll('h2[data-cat]'));
var q = document.getElementById('q'), t = document.getElementById('tier'),
    r = document.getElementById('risk'), c = document.getElementById('count');
function apply() {
  var s = q.value.toLowerCase().trim(), tv = t.value, rv = r.value, n = 0;
  items.forEach(function (el) {
    // A mode is a ladder, so "Balanced" means tier 1 and 2, not tier 2 alone -
    // and tier 0 is opt-in, which no mode selects, so it only matches itself.
    var it = +el.dataset.tier, ok = true;
    if (tv !== '') { ok = (tv === '0') ? (it === 0) : (it !== 0 && it <= +tv); }
    if (ok && rv !== '') { ok = el.dataset.risk === rv; }
    if (ok && s) { ok = el.dataset.hay.indexOf(s) !== -1; }
    el.classList.toggle('hide', !ok);
    if (ok) { n++; }
  });
  // A heading over nothing reads as a category that failed to render.
  heads.forEach(function (h) {
    var any = false, el = h.nextElementSibling;
    while (el && el.tagName !== 'H2') {
      if (el.classList.contains('item') && !el.classList.contains('hide')) { any = true; break; }
      el = el.nextElementSibling;
    }
    h.style.display = any ? '' : 'none';
  });
  c.textContent = n + (n === 1 ? ' option' : ' options') +
                  (n === items.length ? '' : ' of ' + items.length);
}
[q, t, r].forEach(function (el) { el.addEventListener('input', apply); });
apply();
</script>
'@
& $add '</body></html>'

$null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $OutFile)
[IO.File]::WriteAllText($OutFile, $sb.ToString(), (New-Object System.Text.UTF8Encoding $false))

$kb = [Math]::Round((Get-Item $OutFile).Length / 1KB, 1)
Write-Host ("Wrote {0}" -f $OutFile) -ForegroundColor Cyan
Write-Host ("  {0} options, {1} categories, {2} KB, no external assets" -f $rows.Count, @($byCat).Count, $kb)
$described = @($rows | Where-Object { $_.Mechanics.Count }).Count
Write-Host ("  {0} of {1} carry a 'what this changes' block" -f $described, $rows.Count)
