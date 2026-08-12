# Discord Voice Overlay for OBS (StreamKit, fixed slots)

Fixed-position Discord voice overlay for up to **10 users**, inspired by [skfix](https://sosq.me/tools/skfix/).
Unlike the stock StreamKit overlay (which reorders participants dynamically), every user gets a **permanent slot** — with an offline placeholder, a talking glow, and a mute indicator.

No JavaScript anywhere: three layered OBS browser sources do all the work.
(There is also a **config-free variant**, `dist/<preset>/default-overlay.css` — see below.)

## How it works

```
OBS scene (top to bottom):
  1. Foreground browser source ← dist/<preset>/fg.html (local file)
  2. StreamKit browser source  ← streamkit.discord.com URL + dist/<preset>/overlay.css as Custom CSS
  3. Background browser source ← dist/<preset>/bg.html (local file)
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
| `presets/<preset>.config.json` | Source of truth: canvas, layout, style, users. One file per preset; `default.config.json` is used when no preset is given |
| `generate.ps1` | Generator: reads a preset, writes `dist/<preset>/` |
| `templates/` | CSS/HTML templates (edit to restyle) |
| `dist/<preset>/overlay.css` | Generated → paste into OBS Custom CSS |
| `dist/<preset>/bg.html` | Generated → OBS local-file browser source (bottom layer) |
| `dist/<preset>/fg.html` | Generated → OBS local-file browser source (top layer) |
| `dist/<preset>/preview.html` | Generated → open in a browser to test every slot solo (offline/online/talking/muted). Preview only, not an OBS source; `preview-streamkit.html` is its StreamKit stand-in |
| `dist/<preset>/default-overlay.css` | Config-free alternative: single StreamKit source, shows **everyone** in the channel (join order) with their Discord nickname in a pill inside the avatar. Uses style/layout settings only, ignores the users list. No bg/fg needed. |

## Quick start

1. **Edit `presets/default.config.json`** — add your users (see reference below). JSON order = slot order.
2. **Generate:**
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\generate.ps1          # default preset -> dist/default/
   ```
3. **Get your StreamKit URL:** open <https://streamkit.discord.com/overlay>, click *Install for OBS*, pick the **Voice Widget**, select your server + voice channel, and copy the URL. It looks like:
   `https://streamkit.discord.com/overlay/voice/<GUILD_ID>/<CHANNEL_ID>`
4. **OBS — background layer:** add a *Browser* source, check **Local file**, pick `dist/<preset>/bg.html`, set width/height per [Sizing the OBS Browser Sources](#sizing-the-obs-browser-sources) (1920×1080 is the safe default).
5. **OBS — StreamKit layer:** add another *Browser* source **above** the background one, paste the StreamKit URL, same width/height, and paste the full contents of `dist/<preset>/overlay.css` into the **Custom CSS** box.
6. **OBS — foreground layer:** add a third *Browser* source **above** the StreamKit one, check **Local file**, pick `dist/<preset>/fg.html`, same width/height.
7. Join the voice channel — your avatar fills your slot. Tip: group the three sources in OBS to move/scale them as one.

Re-run `generate.ps1` after any config change, then refresh all three browser sources (or paste the new CSS).

### Sizing the OBS Browser Sources

The slot block is positioned **inside** the browser source by `layout.xalignment` / `layout.yalignment`, so the size you type into the browser source dialog is the frame it aligns against.

**Recommended: give all three sources 1920×1080** (or whatever *Settings → Video → Base (Canvas) Resolution* says), leave them at position `0, 0`, and don't scale them. Then the alignments mean what they say — `"center"` is the middle of your stream, `"bottom"` is the bottom of it — and nothing has to be dragged into place by hand.

- **All three sources must be the same size as each other.** That shared box is the alignment frame; mismatched sizes pull the border, avatar and name layers out of register.
- **Height matters more than people expect.** OBS defaults new browser sources to 800×600, and the generator prints a block height that is often small (e.g. 152px for a single row). If you size a source to the block height, there is no vertical room left and `"top"`, `"center"` and `"bottom"` all render identically. Height must cover the distance you want to push the block down — full canvas height for `"center"` or `"bottom"`.
- Width follows the same rule: at least the block width, full canvas width for `"center"` / `"right"`.
- **Prefer positioning by hand?** Size the sources to the block instead (the dimensions the generator prints), keep `xalignment: "left"` / `yalignment: "top"`, and drag the group in OBS. That's the old behavior and still works.
- **Resizing needs no re-run.** The coordinates are percentage-based, so changing all three sources to e.g. 2560×1440 re-aligns the block on refresh. Only changes to the block itself (slot size, gap, padding, user count, mode) need `generate.ps1` again.
- Set `canvas.previewWidth` / `previewHeight` in the preset to the size you used in OBS so `preview.html` frames it the same way (defaults to 1920×1080).

### Presets

Every config lives in `presets/` as `<name>.config.json` (plain `<name>.json` also works). The generator writes to `dist/<name>/`, so each preset keeps its own set of files and OBS scenes can point at different presets.

```powershell
.\generate.ps1                       # presets/default.config.json -> dist/default/
.\generate.ps1 duo                   # presets/duo.config.json     -> dist/duo/
.\generate.ps1 dota                  # presets/dota.json           -> dist/dota/
.\generate.ps1 -ConfigPath C:\x.json # explicit path               -> dist/x/
.\generate.ps1 duo -OutDir .\out     # override the output dir
```

New preset: copy an existing file in `presets/`, rename it, edit, run `.\generate.ps1 <name>`. An unknown name lists the available presets.

Shipped presets: `default` (1 slot), `duo` (2 slots), `squad8` (8 slots, 4×2 grid, placeholder IDs — swap in real ones).

### Previewing solo (`dist/<preset>/preview.html`)

You don't need 7 other people to check an 8-slot layout. Every run also writes `preview.html`: it stacks the **real** generated `bg.html`, `overlay.css` and `fg.html` in the same order OBS does, over fake StreamKit markup, on a transparency checkerboard. Open it in a browser and put any slot into **offline / online / talking / muted** — what renders there is what OBS renders.

```powershell
.\generate.ps1 squad8
start .\dist\squad8\preview.html
```

- Buttons per slot, plus all-offline / all-online / all-talking / all-muted, and a *toggle background* button to check contrast against gameplay-ish colors.
- Placeholder avatars (numbered squares) stand in for users without an `avatarUrl`; a set `avatarUrl` is loaded for real.
- A state can be linked or screenshotted: `preview.html?online=1,3,5,7&talking=3&mute=5` (slot numbers are 1-based, `all` works too).
- `preview.html` and `preview-streamkit.html` are preview-only — do **not** add them to OBS.

Live sanity check afterwards: put your real Discord ID in slot 1, regenerate, load the three sources in OBS, join the channel — that slot should light up exactly as the preview showed, the other slots stay OFFLINE until those users join.

### Config-free variant (`dist/<preset>/default-overlay.css`)

No fixed slots, no offline placeholders: one *Browser* source with the StreamKit URL, paste `dist/<preset>/default-overlay.css` into its Custom CSS, done. Shows everyone in the channel in join order, nickname in a pill inside the avatar, same talking/mute styling. Flow follows `layout.mode` (`row`, `column`, or `grid` wrapping at `gridColumns`); the `users` list is ignored.

## Getting user data

- **User ID:** Discord → Settings → Advanced → enable *Developer Mode*, then right-click a user → *Copy User ID*.
- **Avatar URL (optional):** right-click the user's avatar (profile popout) → *Copy image address*, or use `https://cdn.discordapp.com/avatars/<USER_ID>/<AVATAR_HASH>.png?size=256`.
  ⚠ Discord CDN avatar URLs change occasionally — refresh them when an avatar stops loading. Leave empty/omit to use the user's live Discord avatar from StreamKit instead.

## Preset file reference

```jsonc
{
  "canvas": "auto",             // "auto": the generator reports the block size and nothing more —
                                // the sources are sized in OBS and the block aligns inside them.
                                // Or fixed: { "width": 1920, "height": 1080 } to also drive
                                // the preview stage. Either way the OBS source size is what
                                // xalignment/yalignment resolve against at render time.
                                // Optional, auto only: "previewWidth" / "previewHeight"
                                // (default 1920×1080) — the size preview.html mimics.
  "layout": {
    "mode": "row",              // "row" | "column" | "grid"
    "xalignment": "left",       // "left" | "center" | "right"  — default "left"
    "yalignment": "top",        // "top" | "center" | "bottom"  — default "top"
                                // Both align the block inside the OBS browser source; see
                                // "Sizing the OBS Browser Sources" above.
    "offsetX": 0,               // px nudge applied after aligning
    "offsetY": 0,
    "gap": 28,                  // px between slots
    "padding": 12,              // inset from the aligned edge (room for glow/badge);
                                // ignored on an axis set to "center"
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
    "roleColor": "#ffffff",     // role badge text (fallback; per-user roleColor wins)
    "roleBg": "#5865f2",        // role badge background (fallback; per-user roleBg wins)
    "offlineText": "OFFLINE"
  },
  "users": [                    // max 10; order = slot order
    {
      "id": "111111111111111111",        // Discord user ID (17–20 digits)
      "displayName": "Player One",
      "avatarUrl": "https://cdn.discordapp.com/avatars/…/….png",  // optional — empty/omitted uses the user's live Discord avatar (via StreamKit)
      "roleName": "Host",                // optional
      "roleColor": "#ffffff",            // optional — overrides style.roleColor for this user
      "roleBg": "#e91e63"                // optional — overrides style.roleBg for this user
    }
  ]
}
```

`layout.anchor` (`"top-left"`, `"bottom-center"`, …) is the superseded spelling of the same thing. It is still honored per axis when `xalignment` / `yalignment` are absent, so older presets keep working, but new ones should use the two keys above.

## Requirements & limitations

- The CSS targets StreamKit's **stable class names** (verified against the live bundle): `ul.voice_states > li.voice_state[data-userid] > img.voice_avatar`, with li state classes `wrapper_speaking`, `mute`, `deaf`, `self_mute`, `self_deaf`. No `:has()` — works on older OBS browser engines too.
- **All three browser sources must be set to the same size**, and at least as large as the block the generator prints. OBS defaults new browser sources to 800×600; too small and slots sit outside the visible area, making the source look blank or cropped. See [Sizing the OBS Browser Sources](#sizing-the-obs-browser-sources).
- Users in the channel but **not in the preset's `users` list are hidden** from the overlay.
- If a future StreamKit redesign renames the classes and a state stops working:
  1. In OBS, right-click the StreamKit source → *Interact*, or open the StreamKit URL in Chrome and use DevTools.
  2. Inspect a participant while speaking / muted and note the classes on the `<li>` and `<img>` elements.
  3. Adjust the selectors in `templates/overlay.template.css` and re-run `generate.ps1`.
