# Discord Voice Overlay for OBS (StreamKit, fixed slots)

Fixed-position Discord voice overlay for up to **10 users**, inspired by [skfix](https://sosq.me/tools/skfix/).
Unlike the stock StreamKit overlay (which reorders participants dynamically), every user gets a **permanent slot** — with an offline placeholder, a talking glow, and a mute indicator.

No JavaScript anywhere: three layered OBS browser sources do all the work.
(There is also a **config-free variant**, `dist/default-overlay.css` — see below.)

## How it works

```
OBS scene (top to bottom):
  1. Foreground browser source ← dist/fg.html (local file)
  2. StreamKit browser source  ← streamkit.discord.com URL + dist/overlay.css as Custom CSS
  3. Background browser source ← dist/bg.html (local file)
```

- `bg.html` draws the offline placeholder per slot: semi-transparent fill + "OFFLINE" text.
- The StreamKit layer pins each online user's avatar exactly over their slot, covering the OFFLINE placeholder.
- `fg.html` draws the slot border, the player name (bottom center, semi-transparent pill) and the role badge (top left) — above the avatar, so they're always visible.
- **Offline** = user absent from the voice channel → placeholder shows through.
- **Talking** = StreamKit marks the avatar as speaking → pulsing glow ring.
- **Muted / deafened** = avatar dimmed + red mic-slash badge (top right).

## Files

| File | Purpose |
|---|---|
| `config.json` | Source of truth: canvas, layout, style, users |
| `generate.ps1` | Generator: reads config, writes `dist/` |
| `templates/` | CSS/HTML templates (edit to restyle) |
| `dist/overlay.css` | Generated → paste into OBS Custom CSS |
| `dist/bg.html` | Generated → OBS local-file browser source (bottom layer) |
| `dist/fg.html` | Generated → OBS local-file browser source (top layer) |
| `dist/default-overlay.css` | Config-free alternative: single StreamKit source, shows **everyone** in the channel (join order) with their Discord nickname in a pill inside the avatar. Uses style/layout settings only, ignores the users list. No bg/fg needed. |

## Quick start

1. **Edit `config.json`** — add your users (see reference below). JSON order = slot order.
2. **Generate:**
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\generate.ps1
   ```
3. **Get your StreamKit URL:** open <https://streamkit.discord.com/overlay>, click *Install for OBS*, pick the **Voice Widget**, select your server + voice channel, and copy the URL. It looks like:
   `https://streamkit.discord.com/overlay/voice/<GUILD_ID>/<CHANNEL_ID>`
4. **OBS — background layer:** add a *Browser* source, check **Local file**, pick `dist/bg.html`, set width/height to the size the generator printed (canvas `"auto"`) or your fixed canvas size.
5. **OBS — StreamKit layer:** add another *Browser* source **above** the background one, paste the StreamKit URL, same width/height, and paste the full contents of `dist/overlay.css` into the **Custom CSS** box.
6. **OBS — foreground layer:** add a third *Browser* source **above** the StreamKit one, check **Local file**, pick `dist/fg.html`, same width/height.
7. Join the voice channel — your avatar fills your slot. Tip: group the three sources in OBS to move/scale them as one.

Re-run `generate.ps1` after any config change, then refresh all three browser sources (or paste the new CSS).

### Config-free variant (`dist/default-overlay.css`)

No fixed slots, no offline placeholders: one *Browser* source with the StreamKit URL, paste `dist/default-overlay.css` into its Custom CSS, done. Shows everyone in the channel in join order, nickname in a pill inside the avatar, same talking/mute styling. Flow follows `layout.mode` (`row`, `column`, or `grid` wrapping at `gridColumns`); the `users` list is ignored.

## Getting user data

- **User ID:** Discord → Settings → Advanced → enable *Developer Mode*, then right-click a user → *Copy User ID*.
- **Avatar URL (optional):** right-click the user's avatar (profile popout) → *Copy image address*, or use `https://cdn.discordapp.com/avatars/<USER_ID>/<AVATAR_HASH>.png?size=256`.
  ⚠ Discord CDN avatar URLs change occasionally — refresh them when an avatar stops loading. Leave empty/omit to use the user's live Discord avatar from StreamKit instead.

## config.json reference

```jsonc
{
  "canvas": "auto",             // "auto": canvas hugs the slot block (top-left origin) so the
                                // OBS sources can be moved/scaled freely; the generator prints
                                // the resulting source size. Or fixed: { "width": 1920, "height": 1080 }
                                // — must match all OBS source sizes; anchor/offset position the block.
  "layout": {
    "mode": "row",              // "row" | "column" | "grid"
    "anchor": "top-left",       // fixed canvas only: combos of top/bottom/left/right/center
    "offsetX": 0,               // fixed canvas only: px shift after anchoring
    "offsetY": 0,
    "gap": 28,                  // px between slots
    "padding": 12,              // auto canvas only: margin around the block (room for glow/badge)
    "gridColumns": 5,           // grid mode only
    "slot": {
      "size": 140,              // avatar box, px
      "borderRadius": 16
    }
  },
  "style": {
    "frameColor": "#ffffff",    // slot border color
    "frameBg": "rgba(255, 255, 255, 0.25)",  // offline slot fill (semi-transparent)
    "borderWidth": 5,           // slot border thickness, px
    "talkColor": "#3ba55c",     // speaking glow
    "muteDim": 0.45,            // avatar brightness when muted (0–1)
    "nameFont": "'Segoe UI', sans-serif",
    "nameColor": "#ffffff",     // player name text
    "nameBg": "rgba(0, 0, 0, 0.45)",         // name pill background (semi-transparent)
    "roleColor": "#ffffff",     // role badge text
    "roleBg": "#5865f2",        // role badge background
    "offlineText": "OFFLINE"
  },
  "users": [                    // max 10; order = slot order
    {
      "id": "111111111111111111",        // Discord user ID (17–20 digits)
      "displayName": "Player One",
      "avatarUrl": "https://cdn.discordapp.com/avatars/…/….png",  // optional — empty/omitted uses the user's live Discord avatar (via StreamKit)
      "roleName": "Host"                 // optional
    }
  ]
}
```

## Requirements & limitations

- The CSS targets StreamKit's **stable class names** (verified against the live bundle): `ul.voice_states > li.voice_state[data-userid] > img.voice_avatar`, with li state classes `wrapper_speaking`, `mute`, `deaf`, `self_mute`, `self_deaf`. No `:has()` — works on older OBS browser engines too.
- **All three browser sources must be set to the canvas size** — the generator prints it after each run. OBS defaults new browser sources to 800×600; at the wrong size slots can sit outside the visible area and the source looks blank.
- Users in the channel but **not in `config.json` are hidden** from the overlay.
- If a future StreamKit redesign renames the classes and a state stops working:
  1. In OBS, right-click the StreamKit source → *Interact*, or open the StreamKit URL in Chrome and use DevTools.
  2. Inspect a participant while speaking / muted and note the classes on the `<li>` and `<img>` elements.
  3. Adjust the selectors in `templates/overlay.template.css` and re-run `generate.ps1`.
