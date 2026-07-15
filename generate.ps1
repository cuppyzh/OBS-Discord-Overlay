<#
.SYNOPSIS
  Generates dist/overlay.css (StreamKit custom CSS) and dist/bg.html
  (static background layer) from config.json.

.DESCRIPTION
  Reads config.json (canvas, layout, style, users), computes a fixed slot
  position for every configured user (JSON order = slot order), and renders
  the two templates in ./templates via simple {{TOKEN}} replacement plus a
  repeated {{#USERS}}...{{/USERS}} block.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\generate.ps1
  powershell -ExecutionPolicy Bypass -File .\generate.ps1 -ConfigPath other.json
#>
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$TemplateDir,
    [string]$OutDir
)

$ErrorActionPreference = 'Stop'

$scriptRoot = $PSScriptRoot
if (-not $scriptRoot) { $scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $ConfigPath) { $ConfigPath = Join-Path $scriptRoot 'config.json' }
if (-not $TemplateDir) { $TemplateDir = Join-Path $scriptRoot 'templates' }
if (-not $OutDir) { $OutDir = Join-Path $scriptRoot 'dist' }

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

# ---------- load + validate config ----------

if (-not (Test-Path $ConfigPath)) { throw "Config not found: $ConfigPath" }
$config = Get-Content -Raw -Path $ConfigPath | ConvertFrom-Json

$users = @(Get-Prop $config 'users' @())
if ($users.Count -lt 1) { throw 'config.json: "users" must contain at least 1 user.' }
if ($users.Count -gt 10) { throw "config.json: max 10 users supported, found $($users.Count)." }

for ($i = 0; $i -lt $users.Count; $i++) {
    $u = $users[$i]
    $id = [string](Get-Prop $u 'id' '')
    if ($id -notmatch '^\d{17,20}$') { throw "users[$i]: 'id' must be a 17-20 digit Discord user ID (got '$id')." }
    if ([string]::IsNullOrWhiteSpace((Get-Prop $u 'displayName' ''))) { throw "users[$i]: 'displayName' is required." }
    $avatar = [string](Get-Prop $u 'avatarUrl' '')
    if ($avatar -ne '' -and $avatar -notmatch '^https?://') { throw "users[$i]: 'avatarUrl' must be empty or an http(s) URL." }
}
$ids = $users | ForEach-Object { $_.id }
if (($ids | Select-Object -Unique).Count -ne $ids.Count) { throw 'config.json: duplicate user ids found.' }

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

$layout = Get-Prop $config 'layout' $null
$mode = [string](Get-Prop $layout 'mode' 'row')
if ($mode -notin @('row', 'column', 'grid')) { throw "layout.mode must be 'row', 'column' or 'grid' (got '$mode')." }
$anchor = [string](Get-Prop $layout 'anchor' 'bottom-center')
$offsetX = [int](Get-Prop $layout 'offsetX' 0)
$offsetY = [int](Get-Prop $layout 'offsetY' 0)
$gap = [int](Get-Prop $layout 'gap' 24)
$padding = [int](Get-Prop $layout 'padding' 12)
$gridColumns = [int](Get-Prop $layout 'gridColumns' 5)
if ($gridColumns -lt 1) { throw 'layout.gridColumns must be >= 1.' }

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
    $originX = $padding
    $originY = $padding
} else {
    if ($blockW -gt $canvasW -or $blockH -gt $canvasH) {
        Write-Warning "Layout block ${blockW}x${blockH} exceeds canvas ${canvasW}x${canvasH}; slots will overflow. Reduce slot size or gap."
    }

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
    switch ($hAlign) {
        'left' { $originX = 0 }
        'center' { $originX = [int](($canvasW - $blockW) / 2) }
        'right' { $originX = $canvasW - $blockW }
    }
    switch ($vAlign) {
        'top' { $originY = 0 }
        'center' { $originY = [int](($canvasH - $blockH) / 2) }
        'bottom' { $originY = $canvasH - $blockH }
    }
    $originX += $offsetX
    $originY += $offsetY
}

$slots = @()
for ($i = 0; $i -lt $n; $i++) {
    $r = [int][Math]::Floor($i / $cols)
    $c = $i % $cols
    $slots += [pscustomobject]@{
        X = $originX + $c * ($cellW + $gap)
        Y = $originY + $r * ($cellH + $gap)
    }
}

# ---------- render templates ----------

$globalTokens = @{
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
    NAME_FONT_SIZE    = [Math]::Max(11, [int]($slotSize * 0.12))
    ROLE_FONT_SIZE    = [Math]::Max(10, [int]($slotSize * 0.09))
    OFFLINE_FONT_SIZE = [Math]::Max(10, [int]($slotSize * 0.12))
}

function Invoke-Render {
    param([string]$TemplatePath)
    $template = Get-Content -Raw -Path $TemplatePath
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
Write-Utf8File $cssPath (Invoke-Render (Join-Path $TemplateDir 'overlay.template.css'))
Write-Utf8File $bgPath (Invoke-Render (Join-Path $TemplateDir 'bg.template.html'))
Write-Utf8File $fgPath (Invoke-Render (Join-Path $TemplateDir 'fg.template.html'))
Write-Utf8File $defaultCssPath (Invoke-Render (Join-Path $TemplateDir 'default-overlay.template.css'))

Write-Host "Generated for $n user(s), layout '$mode' ($cols x $rows), anchor '$anchor':"
Write-Host "  $bgPath  -> OBS Browser Source (Local file), ${canvasW}x${canvasH}, BOTTOM layer"
Write-Host "  $cssPath -> paste into 'Custom CSS' of the StreamKit Browser Source, MIDDLE layer"
Write-Host "  $fgPath  -> OBS Browser Source (Local file), ${canvasW}x${canvasH}, TOP layer"
Write-Host "  $defaultCssPath -> config-free alternative: single StreamKit source, shows everyone with nickname"
