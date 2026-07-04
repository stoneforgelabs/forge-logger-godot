# docs/

The root `README.md` embeds `docs/demo.gif` — it is the single most important
asset on the landing page. Record it before the release tag.

**Storyboard** (1280×720, 20–30 s, < 8 MB — GitHub README limit is 10 MB):

| Time   | Shot |
|--------|------|
| 0–5 s  | Game running, a visible bug (object falls through the floor / NPC stuck) |
| 5–12 s | F8 → popup → type "Fell through floor near spawn" → Submit → confirmation with report ID |
| 12–25 s| Cut to dashboard: report in list → detail — screenshot, scene/build/env, AI summary + repro steps |
| 25–30 s| Logo + "Free on the Godot Asset Library" |

Tools: ScreenToGif (free, Windows) or OBS → gifski.

For the AssetLib listing use PNG/JPG previews (not a GIF). Source screenshots
live in the monorepo at `apps/forge-logger-fe/public/screenshots/` (`.webp` —
convert to PNG), icon seed at `apps/forge-logger-fe/public/email/logo.png`
(square 256×256 PNG for the AssetLib icon).
