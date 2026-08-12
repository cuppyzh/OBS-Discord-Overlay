<#
.SYNOPSIS
  Generates overlay.css (StreamKit custom CSS), bg.html and fg.html from a
  preset in ./presets, into dist/<preset-name>/.

.DESCRIPTION
  Reads a preset JSON (canvas, layout, style, users), computes a fixed slot
  position for every configured user (JSON order = slot order), and renders
  the templates in ./templates via simple {{TOKEN}} replacement plus a
  repeated {{#USERS}}...{{/USERS}} block.

.PARAMETER ConfigPath
  Preset to render. Accepts a bare preset name ("duo") resolved against
  ./presets with or without the .config.json / .json extension, or an explicit
  path. Defaults to the "default" preset (presets/default.config.json).

.PARAMETER OutDir
  Output directory. Defaults to dist/<preset-name>, where <preset-name> is the
  file name with the .config.json / .json extension stripped.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\generate.ps1
  powershell -ExecutionPolicy Bypass -File .\generate.ps1 duo
  powershell -ExecutionPolicy Bypass -File .\generate.ps1 -ConfigPath presets\dota.json
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$ConfigPath,
    [string]$TemplateDir,
    [string]$OutDir
)

$ErrorActionPreference = 'Stop'

$scriptRoot = $PSScriptRoot
if (-not $scriptRoot) { $scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path }
$presetDir = Join-Path $scriptRoot 'presets'

function Get-PresetName {
    # "duo.config.json" / "duo.json" -> "duo"
    param([string]$Path)
    $name = [System.IO.Path]::GetFileName($Path)
    if ($name -match '\.config\.json$') { return $name.Substring(0, $name.Length - 12) }
    return [System.IO.Path]::GetFileNameWithoutExtension($name)
}

function Resolve-ConfigPath {
    # Turns a preset name ("duo") or a path ("presets\duo.config.json") into a real file.
    param([string]$Name)

    $candidates = @($Name)
    if (-not [System.IO.Path]::IsPathRooted($Name)) {
        $candidates += (Join-Path $presetDir $Name)
        $candidates += (Join-Path $scriptRoot $Name)
    }
    if ([System.IO.Path]::GetExtension($Name) -eq '') {
        foreach ($c in @($candidates)) { $candidates += "$c.config.json"; $candidates += "$c.json" }
    }

    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c -PathType Leaf) { return (Resolve-Path -LiteralPath $c).Path }
    }

    $known = @()
    if (Test-Path $presetDir) {
        $known = @(Get-ChildItem -Path $presetDir -Filter '*.json' | ForEach-Object { Get-PresetName $_.Name } | Sort-Object)
    }
    $hint = if ($known.Count) { " Available presets: $($known -join ', ')." } else { '' }
    throw "Preset not found: '$Name'.$hint"
}

if (-not $ConfigPath) { $ConfigPath = 'default' }
$ConfigPath = Resolve-ConfigPath $ConfigPath
$presetName = Get-PresetName $ConfigPath
if (-not $TemplateDir) { $TemplateDir = Join-Path $scriptRoot 'templates' }
if (-not $OutDir) { $OutDir = Join-Path $scriptRoot (Join-Path 'dist' $presetName) }

# ---------- helpers ----------

function Get-Prop {
    # Safe property access with default (ConvertFrom-Json yields PSCustomObject).
    param($Object, [string]$Name, $Default)
    if ($null -ne $Object -and $Object.PSObject.Properties[$Name] -and $null -ne $Object.$Name) {
        return $Object.$Name
    }
    return $Default
}

function Expand-Tokens {
    param([string]$Text, [hashtable]$Tokens)
    foreach ($key in $Tokens.Keys) {
        $Text = $Text.Replace('{{' + $key + '}}', [string]$Tokens[$key])
    }
    return $Text
}

function New-PlaceholderAvatar {
    # Preview-only stand-in avatar: flat colored square with the slot number,
    # used when a user has no avatarUrl. '#' must be %23-escaped in a data URI.
    param([int]$SlotIndex)
    $palette = @('5865f2', 'eb459e', '3ba55c', 'faa81a', 'ed4245', '9b59b6', '1abc9c', 'e67e22', '2c3e50', '16a085')
    $fill = $palette[($SlotIndex - 1) % $palette.Count]
    return "data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 100 100'><rect width='100' height='100' fill='%23$fill'/><text x='50' y='54' text-anchor='middle' dominant-baseline='middle' font-family='sans-serif' font-size='46' font-weight='700' fill='%23ffffff'>$SlotIndex</text></svg>"
}

function ConvertTo-CssUrl {
    # Quote + escape a URL for use inside CSS url(...)
    param([string]$Url)
    $escaped = $Url.Replace('\', '\\').Replace('"', '\"')
    return '"' + $escaped + '"'
}

function Write-Utf8File {
    param([string]$Path, [string]$Content)
    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($false)))
}

function New-AxisValue {
    # One slot coordinate as a complete CSS length, resolved against the
    # browser source viewport rather than the canvas: the alignment constant
    # is folded into every slot, so no wrapper element is needed and the three
    # layers stay in register whatever width/height OBS is given.
    #   Step  distance of this slot from the start of the block
    #   Pad   edge inset; an edge concept, so it is skipped when centering
    param([string]$Align, [int]$Step, [int]$BlockSize, [int]$Pad, [int]$Offset)
    switch ($Align) {
        { $_ -in 'left', 'top' } { return "$($Pad + $Offset + $Step)px" }
        'center' {
            $k = $Offset + $Step - [int]($BlockSize / 2)
            if ($k -lt 0) { return "calc(50% - $([Math]::Abs($k))px)" }
            return "calc(50% + ${k}px)"
        }
        { $_ -in 'right', 'bottom' } { return "calc(100% - $($BlockSize + $Pad - $Offset - $Step)px)" }
    }
}

function ConvertTo-FlexAlign {
    param([string]$Align)
    switch ($Align) {
        'center' { return 'center' }
        { $_ -in 'right', 'bottom' } { return 'flex-end' }
        default { return 'flex-start' }
    }
}

# ---------- load + validate config ----------

$config = [System.IO.File]::ReadAllText($ConfigPath) | ConvertFrom-Json

$users = @(Get-Prop $config 'users' @())
if ($users.Count -lt 1) { throw "${presetName}: 'users' must contain at least 1 user." }
if ($users.Count -gt 10) { throw "${presetName}: max 10 users supported, found $($users.Count)." }

for ($i = 0; $i -lt $users.Count; $i++) {
    $u = $users[$i]
    $id = [string](Get-Prop $u 'id' '')
    if ($id -notmatch '^\d{17,20}$') { throw "users[$i]: 'id' must be a 17-20 digit Discord user ID (got '$id')." }
    if ([string]::IsNullOrWhiteSpace((Get-Prop $u 'displayName' ''))) { throw "users[$i]: 'displayName' is required." }
    $avatar = [string](Get-Prop $u 'avatarUrl' '')
    if ($avatar -ne '' -and $avatar -notmatch '^https?://') { throw "users[$i]: 'avatarUrl' must be empty or an http(s) URL." }
}
$ids = $users | ForEach-Object { $_.id }
if (($ids | Select-Object -Unique).Count -ne $ids.Count) { throw "${presetName}: duplicate user ids found." }

$canvas = Get-Prop $config 'canvas' $null
# "canvas": "auto" (or width: "auto") sizes the canvas to the slot block,
# anchored top-left, so the OBS sources can be positioned freely.
$canvasAuto = $false
if ($canvas -is [string]) {
    if ($canvas -ne 'auto') { throw "canvas: expected 'auto' or an object with width/height." }
    $canvasAuto = $true
} elseif ([string](Get-Prop $canvas 'width' '') -eq 'auto') {
    $canvasAuto = $true
}
$canvasW = 0; $canvasH = 0
if (-not $canvasAuto) {
    $canvasW = [int](Get-Prop $canvas 'width' 1920)
    $canvasH = [int](Get-Prop $canvas 'height' 1080)
}
# Preview only: the size preview.html pretends the OBS browser source is, so
# xalignment/yalignment are visible there. A fixed canvas is its own preview.
$previewW = [int](Get-Prop $canvas 'previewWidth' 1920)
$previewH = [int](Get-Prop $canvas 'previewHeight' 1080)

$layout = Get-Prop $config 'layout' $null
$mode = [string](Get-Prop $layout 'mode' 'row')
if ($mode -notin @('row', 'column', 'grid')) { throw "layout.mode must be 'row', 'column' or 'grid' (got '$mode')." }
$offsetX = [int](Get-Prop $layout 'offsetX' 0)
$offsetY = [int](Get-Prop $layout 'offsetY' 0)
$gap = [int](Get-Prop $layout 'gap' 24)
$padding = [int](Get-Prop $layout 'padding' 12)
$gridColumns = [int](Get-Prop $layout 'gridColumns' 5)
if ($gridColumns -lt 1) { throw 'layout.gridColumns must be >= 1.' }

# Alignment of the slot block inside the browser source viewport.
# layout.anchor is the superseded spelling, still honored per axis when the
# xalignment / yalignment it maps to are absent.
$anchor = [string](Get-Prop $layout 'anchor' 'top-left')
$hAlign = 'center'; $vAlign = 'center'
foreach ($part in $anchor.ToLower().Split('-')) {
    switch ($part) {
        'left' { $hAlign = 'left' }
        'right' { $hAlign = 'right' }
        'top' { $vAlign = 'top' }
        'bottom' { $vAlign = 'bottom' }
        'center' { }
        default { throw "layout.anchor: unknown token '$part' (use combinations of top/bottom/left/right/center)." }
    }
}
$xalignment = [string](Get-Prop $layout 'xalignment' '')
if ($xalignment -ne '') {
    $hAlign = $xalignment.ToLower()
    if ($hAlign -notin @('left', 'center', 'right')) { throw "layout.xalignment must be 'left', 'center' or 'right' (got '$xalignment')." }
}
$yalignment = [string](Get-Prop $layout 'yalignment' '')
if ($yalignment -ne '') {
    $vAlign = $yalignment.ToLower()
    if ($vAlign -notin @('top', 'center', 'bottom')) { throw "layout.yalignment must be 'top', 'center' or 'bottom' (got '$yalignment')." }
}

$slot = Get-Prop $layout 'slot' $null
$slotSize = [int](Get-Prop $slot 'size' 140)
$borderRadius = [int](Get-Prop $slot 'borderRadius' 16)
if ($slotSize -lt 16) { throw 'layout.slot.size must be >= 16.' }

$style = Get-Prop $config 'style' $null
$frameColor = [string](Get-Prop $style 'frameColor' '#ffffff')
$frameBg = [string](Get-Prop $style 'frameBg' 'rgba(255, 255, 255, 0.25)')
$borderWidth = [int](Get-Prop $style 'borderWidth' 5)
$talkColor = [string](Get-Prop $style 'talkColor' '#3ba55c')
$muteDim = [double](Get-Prop $style 'muteDim' 0.45)
if ($muteDim -le 0 -or $muteDim -gt 1) { throw 'style.muteDim must be in (0, 1].' }
$nameFont = [string](Get-Prop $style 'nameFont' "'Segoe UI', sans-serif")
$nameColor = [string](Get-Prop $style 'nameColor' '#ffffff')
$nameBg = [string](Get-Prop $style 'nameBg' 'rgba(0, 0, 0, 0.45)')
$roleColor = [string](Get-Prop $style 'roleColor' '#ffffff')
$roleBg = [string](Get-Prop $style 'roleBg' '#5865f2')
$offlineText = [string](Get-Prop $style 'offlineText' 'OFFLINE')

# ---------- compute slot coordinates ----------

$n = $users.Count
switch ($mode) {
    'row' { $cols = $n }
    'column' { $cols = 1 }
    'grid' { $cols = [Math]::Min($gridColumns, $n) }
}
$rows = [int][Math]::Ceiling($n / $cols)

$cellW = $slotSize
$cellH = $slotSize
$blockW = $cols * $cellW + ($cols - 1) * $gap
$blockH = $rows * $cellH + ($rows - 1) * $gap

if ($canvasAuto) {
    # Canvas hugs the slot block; padding leaves room for the talking glow
    # and the mute badge, which stick out past the slot edge.
    $canvasW = $blockW + 2 * $padding
    $canvasH = $blockH + 2 * $padding
} elseif ($blockW -gt $canvasW -or $blockH -gt $canvasH) {
    Write-Warning "Layout block ${blockW}x${blockH} exceeds canvas ${canvasW}x${canvasH}; slots will overflow. Reduce slot size or gap."
}

# The preview stage stands in for the OBS browser source.
$stageW = $(if ($canvasAuto) { $previewW } else { $canvasW })
$stageH = $(if ($canvasAuto) { $previewH } else { $canvasH })

# Coordinates are CSS lengths, not numbers: 'center' and 'right'/'bottom'
# resolve against the viewport at render time, so the same files work at any
# browser source size.
$slots = @()
for ($i = 0; $i -lt $n; $i++) {
    $r = [int][Math]::Floor($i / $cols)
    $c = $i % $cols
    $slots += [pscustomobject]@{
        X = New-AxisValue $hAlign ($c * ($cellW + $gap)) $blockW $padding $offsetX
        Y = New-AxisValue $vAlign ($r * ($cellH + $gap)) $blockH $padding $offsetY
    }
}

# ---------- render templates ----------

$inv = [System.Globalization.CultureInfo]::InvariantCulture
# preview.html scales the stage down so a full 1920-wide source still fits.
$stageScale = [Math]::Min(1.0, 1100 / [double]$stageW)
# In column mode the flex main axis is vertical, so the two alignments swap.
$mainAlign = $(if ($mode -eq 'column') { $vAlign } else { $hAlign })
$crossAlign = $(if ($mode -eq 'column') { $hAlign } else { $vAlign })

$globalTokens = @{
    PRESET_NAME       = $presetName
    USER_COUNT        = $users.Count
    CANVAS_W          = $canvasW
    CANVAS_H          = $canvasH
    SLOT_SIZE         = $slotSize
    BORDER_RADIUS     = $borderRadius
    BORDER_WIDTH      = $borderWidth
    FRAME_COLOR       = $frameColor
    FRAME_BG          = $frameBg
    TALK_COLOR        = $talkColor
    MUTE_DIM          = $muteDim.ToString([System.Globalization.CultureInfo]::InvariantCulture)
    NAME_FONT         = $nameFont
    NAME_COLOR        = $nameColor
    NAME_BG           = $nameBg
    ROLE_COLOR        = $roleColor
    ROLE_BG           = $roleBg
    ROLE_RADIUS       = [Math]::Max(0, $borderRadius - $borderWidth)
    OFFLINE_TEXT      = [System.Net.WebUtility]::HtmlEncode($offlineText)
    GAP               = $gap
    PADDING           = $padding
    FLEX_DIRECTION    = $(if ($mode -eq 'column') { 'column' } else { 'row' })
    FLEX_WRAP         = $(if ($mode -eq 'grid') { 'wrap' } else { 'nowrap' })
    LIST_MAX_WIDTH    = $(if ($mode -eq 'grid') { "$($gridColumns * $cellW + ($gridColumns - 1) * $gap + 2 * $padding)px" } else { 'none' })
    STAGE_W           = $stageW
    STAGE_H           = $stageH
    STAGE_SCALE       = $stageScale.ToString('0.####', $inv)
    STAGE_SCALED_W    = [int]($stageW * $stageScale)
    STAGE_SCALED_H    = [int]($stageH * $stageScale)
    JUSTIFY_CONTENT   = ConvertTo-FlexAlign $mainAlign
    ALIGN_ITEMS       = ConvertTo-FlexAlign $crossAlign
    LIST_MARGIN       = $(switch ($hAlign) {
            'center' { '0 auto' }
            'right' { '0 0 0 auto' }
            default { '0 auto 0 0' }
        })
    NAME_FONT_SIZE    = [Math]::Max(11, [int]($slotSize * 0.12))
    ROLE_FONT_SIZE    = [Math]::Max(10, [int]($slotSize * 0.09))
    OFFLINE_FONT_SIZE = [Math]::Max(10, [int]($slotSize * 0.12))
}

function Invoke-Render {
    param([string]$TemplatePath)
    # ReadAllText, not Get-Content: Windows PowerShell decodes BOM-less files as
    # ANSI, which mangles the non-ASCII characters in the templates.
    $template = [System.IO.File]::ReadAllText($TemplatePath)
    $match = [regex]::Match($template, '(?s)\{\{#USERS\}\}(.*?)\{\{/USERS\}\}')
    if (-not $match.Success) {
        # No per-user block: template uses only global tokens.
        return Expand-Tokens $template $globalTokens
    }
    $block = $match.Groups[1].Value

    $rendered = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt $users.Count; $i++) {
        $u = $users[$i]
        $avatarUrl = [string](Get-Prop $u 'avatarUrl' '')
        # Empty avatarUrl: emit no override rule, so StreamKit's own
        # img.voice_avatar (the user's real, live Discord avatar) shows through.
        $avatarRule = ''
        if ($avatarUrl -ne '') {
            $avatarRule = @"
li.voice_state[data-userid="$($u.id)"] img.voice_avatar,
li.voice-state[data-userid="$($u.id)"] img.avatar {
  content: url($(ConvertTo-CssUrl $avatarUrl));
}
"@
        }
        # Per-user role colors override style.roleColor / style.roleBg;
        # emitted as an inline style so the global .role rule stays the fallback.
        $userRoleColor = [string](Get-Prop $u 'roleColor' '')
        $userRoleBg = [string](Get-Prop $u 'roleBg' '')
        $roleStyle = ''
        if ($userRoleBg -ne '') { $roleStyle += "background: $userRoleBg;" }
        if ($userRoleColor -ne '') {
            if ($roleStyle -ne '') { $roleStyle += ' ' }
            $roleStyle += "color: $userRoleColor;"
        }
        if ($roleStyle -ne '') { $roleStyle = ' style="' + $roleStyle + '"' }
        $userTokens = @{
            SLOT_INDEX     = $i + 1
            USER_ID        = $u.id
            DISPLAY_NAME   = [System.Net.WebUtility]::HtmlEncode([string]$u.displayName)
            ROLE_NAME      = [System.Net.WebUtility]::HtmlEncode([string](Get-Prop $u 'roleName' ''))
            ROLE_STYLE     = $roleStyle
            AVATAR_RULE    = $avatarRule
            # Preview only: StreamKit serves the live avatar, so fall back to a
            # numbered placeholder when the preset has no avatarUrl.
            AVATAR_SRC     = $(if ($avatarUrl -ne '') { $avatarUrl } else { New-PlaceholderAvatar ($i + 1) })
            SLOT_X         = $slots[$i].X
            SLOT_Y         = $slots[$i].Y
        }
        [void]$rendered.Append((Expand-Tokens $block $userTokens))
    }

    $out = $template.Substring(0, $match.Index) + $rendered.ToString() + $template.Substring($match.Index + $match.Length)
    return Expand-Tokens $out $globalTokens
}

if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir | Out-Null }

$cssPath = Join-Path $OutDir 'overlay.css'
$bgPath = Join-Path $OutDir 'bg.html'
$fgPath = Join-Path $OutDir 'fg.html'
$defaultCssPath = Join-Path $OutDir 'default-overlay.css'
$previewPath = Join-Path $OutDir 'preview.html'
$previewSkPath = Join-Path $OutDir 'preview-streamkit.html'
Write-Utf8File $cssPath (Invoke-Render (Join-Path $TemplateDir 'overlay.template.css'))
Write-Utf8File $bgPath (Invoke-Render (Join-Path $TemplateDir 'bg.template.html'))
Write-Utf8File $fgPath (Invoke-Render (Join-Path $TemplateDir 'fg.template.html'))
Write-Utf8File $defaultCssPath (Invoke-Render (Join-Path $TemplateDir 'default-overlay.template.css'))
Write-Utf8File $previewPath (Invoke-Render (Join-Path $TemplateDir 'preview.template.html'))
Write-Utf8File $previewSkPath (Invoke-Render (Join-Path $TemplateDir 'preview-streamkit.template.html'))

Write-Host "Preset '$presetName' ($ConfigPath)"
Write-Host "Generated for $n user(s), layout '$mode' ($cols x $rows), aligned $hAlign/${vAlign}:"
Write-Host "  block is ${blockW}x${blockH}px plus ${padding}px padding; give all three sources the SAME size,"
Write-Host "  at least that big -- ${stageW}x${stageH} recommended. The block aligns itself inside it."
Write-Host "  $bgPath  -> OBS Browser Source (Local file), BOTTOM layer"
Write-Host "  $cssPath -> paste into 'Custom CSS' of the StreamKit Browser Source, MIDDLE layer"
Write-Host "  $fgPath  -> OBS Browser Source (Local file), TOP layer"
Write-Host "  $defaultCssPath -> config-free alternative: single StreamKit source, shows everyone with nickname"
Write-Host "  $previewPath -> open in a browser to test all $n slot(s) solo (offline/online/talking/muted)"

