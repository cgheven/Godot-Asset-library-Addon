# CGHEVEN Asset Library — Godot Editor Plugin

Browse, download and import **CGHEVEN** CG/VFX assets — 3D models, HDRIs, materials and
flipbook VFX — directly inside the Godot editor. Assets stream from `api.cgheven.com`
using the same account, library and freemium access you get in the CGHEVEN addons for
Blender, After Effects, Premiere Pro and DaVinci Resolve.

A dark dock styled to match the CGHEVEN desktop addons, written entirely in GDScript
(`@tool` `EditorPlugin`) — no native builds, so the same install runs on Windows, macOS
and Linux.

## Requirements
- **Godot 4.x** (built and tested on 4.6; uses 4.2+ APIs)
- Internet access (asset CDN + `api.cgheven.com`)

## Install

**From the Godot Asset Library (recommended):**
1. In the Godot editor, open the **AssetLib** tab.
2. Search **"CGHEVEN"** → open the asset → **Download** → **Install**.
3. **Project → Project Settings → Plugins** → enable **CGHEVEN Asset Library**.
4. The **CGHEVEN** dock appears on the right. No editor restart needed.

**Manual:** copy the `addons/cgheven/` folder into your project's `addons/` folder, then
enable it in Project Settings → Plugins.

Godot plugins are per-project (there is no global install), so the addon lives inside
each project's `addons/` folder.

## Features
- Dark UI matched to the CGHEVEN desktop addons
- Asset grid with responsive columns, cached thumbnails, category + subcategory filters, search and sort
- Categories: 3D Models, HDRI, Flipbooks
- Guest browsing + one-click account login (web broker) or license-key activation
- Live plan refresh via heartbeat (Free → Pro without re-login)
- Server-side freemium gating (Download vs Upgrade)
- Asset cards: NEW / Premium / resolution badges, downloaded tick, favourite, per-card format/resolution picker, on-card progress bar
- One-click **download → auto-import**: glTF/FBX → scene, HDRI → world environment, flipbook → AnimatedSprite3D (auto-unpacks `.zip`)
- Favourites (persisted) + Downloads history
- Settings: account details, plan/version, check for updates, upgrade, Discord
- Built-in self-update with changelog

## Configuration (optional)
Environment variables, for development / self-hosting:
- `CGHEVEN_API_BASE` — API base (default `https://api.cgheven.com`)
- `CGHEVEN_WEB_BASE` — website base (default `https://cgheven.com`)
- `CGHEVEN_POSTHOG_KEY` — analytics key (empty = analytics off)

The addon ships **no secrets** — analytics run server-side and all endpoints are public.

## Notes & limits
Godot is a game engine, so a few DCC-only asset types are intentionally surfaced as
unavailable: VDB volumetrics, `.mp4` video previews (Godot plays only Ogg Theora `.ogv`),
and Blender node-shader graphs (only baked PBR imports). Auto-update applies after an
editor restart.

## License
See [LICENSE](LICENSE). © CGHEVEN.

## Links
- Website: https://cgheven.com
- Discord: https://discord.gg/cgheven
