# Forge Logger — In-Game Bug Reporting & Player Feedback for Godot

**Your playtesters press one key, type what broke, and you get a structured bug report — with a screenshot and the exact scene, build, and environment it happened in — instead of a blurry screenshot dumped in Discord.**

A free, open-source Godot 4.x plugin. Drop it in, paste one token, and your game can collect real bug reports from real players. Triage them yourself against your own backend, or connect the optional hosted dashboard for AI summaries and one-click export to GitHub.

<!-- [CLIP] Replace with an animated GIF of the in-game flow: player hits the hotkey → popup → types → "sent" → report shows up on the dashboard. This GIF is the single most important asset on the page — put the 12s loop here. -->
![Forge Logger in-game report flow](docs/demo.gif)

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Godot 4.x](https://img.shields.io/badge/Godot-4.x-478cbf?logo=godotengine&logoColor=white)](https://godotengine.org)
[![Godot Asset Store](https://img.shields.io/badge/Asset_Store-Forge_Logger-478cbf)](https://store.godotengine.org/asset/stoneforge-labs/forge-logger)
[![Free hosted tier](https://img.shields.io/badge/hosted_dashboard-free_tier-ff6a2c)](https://forgelogger.dev/auth)

---

## Why

Playtest feedback is chaos. Testers paste screenshots into Discord with "it crashed lol", you can't tell which build they were on, and triage becomes archaeology. Forge Logger turns that into something you can act on — captured from inside the game, the moment the bug happens.

- **Player-facing, not just a crash logger.** Testers report what *they* noticed, in their words, with a screenshot attached.
- **Context comes for free.** Each play session is stamped with the scene, game version, build hash, and environment, and every report links back to its session — no "which version were you on?" round-trips.
- **Asks players what they think — inside the game.** `show_feedback()` renders your demo feedback form (stars, "would you buy it?", your own questions, an opt-in contact) natively, on mouse, keyboard or gamepad. Change the questions in the dashboard; no new build.
- **Works offline.** Reports and feedback answers that fail to send are queued to disk and sent on the next launch — or whenever you call `retry_queued()` — with idempotency so retries never duplicate.
- **Godot-native.** Built for Godot first, not a Unity tool with Godot bolted on. One autoload, configured in Project Settings.
- **Yours to keep.** MIT-licensed. Point it at your own ingest backend, or use the hosted dashboard — your call.

---

## Install

### From the Godot Asset Store (recommended)
1. In the editor: **AssetLib** tab → search **"Forge Logger"** → **Download** → **Install**.
2. **Project → Project Settings → Plugins** → enable **Forge Logger**.

### Manual
1. Copy the `forge_logger/` folder into your project's `addons/` directory (so it lives at `addons/forge_logger/`).
2. **Project → Project Settings → Plugins** → enable **Forge Logger**.

Enabling the plugin registers the **`ForgeLogger`** autoload singleton. The **`forge_logger_report`** input action (default key **F8**) is registered automatically the first time your game runs — rebind it under Project Settings → Input Map.

---

## Quick start

**1. Point it at a project.** Open **Project → Project Settings**, turn on *Advanced Settings*, and find the **`forge_logger/`** section:

| Setting | What it does |
|---|---|
| `base_url` | Ingest endpoint. Defaults to `https://ingest.forgelogger.dev`. Self-hosting? Put your own URL here. |
| `api_key` | Your project's logger token (`flg_…`). The token identifies your project — no separate project ID needed. Required for the hosted backend; leave it empty only if your self-hosted ingest runs without auth. |
| `game_name` / `game_version` / `build_hash` | Stamped onto the **session** (build + metadata); `build_hash` is omitted when empty. When unset, `game_name` and `game_version` fall back to `application/config/name` and `application/config/version`. |
| `environment` | `development` · `staging` · `production`. |
| `enable_screenshot` | Capture & attach a screenshot with reports (off by default — flip it on). |
| `enable_logs` | Attach engine/game logs to reports. On Godot 4.5+ output is captured in memory (including error backtraces), so logs arrive complete even from release exports, where `godot.log` stays buffered on disk; older engines fall back to reading the log file. |
| `auto_start_session` | Start a session automatically on launch (on by default). |
| `collect_device_info` | Include the device model + locale in session telemetry. Off by default — set it on to opt in. |
| `enable_report_hotkey` | Register the F8 bug-report popup. On by default; turn it off if you only want the web feedback form (`open_feedback()`) and no in-game popup. |
| `feedback_base_url` | Host of the public feedback form opened by `open_feedback()`. Leave empty for the hosted default (`https://forgelogger.dev`); point it at your own frontend if self-hosting. |
| `popup_theme` | A `Theme` resource (`res://….tres`) for the report popup and the in-game feedback form. Empty = built-in look. See *Styling the popups* below. |
| `enable_reports` | Bug reporting (on by default). Off = analytics-only: no F8 action or popup, no log capture, nothing written to `user://` (in-game feedback forms still work, but unsent answers and the form copy stay in memory only). See [Play analytics](#play-analytics). |
| `heartbeat_interval` | Seconds between session heartbeats (play time). `0` (default) = off. |
| `log_requests` | Print every request body to the console. Off by default; failures are always logged. |

Using the hosted dashboard? The token is one click away: [create a free project](https://forgelogger.dev/auth), then mint a logger token under **Project → Tokens** and paste the `flg_…` value into `api_key`.

> **Privacy:** session telemetry carries engine version, platform, and current scene. The device model and locale are sent **only if you turn `collect_device_info` on** — off by default. Point `base_url` at your own backend and no report data reaches Forge Logger's servers.

**2. Let players report.** The smallest possible integration — bind the built-in popup to the report action:

```gdscript
func _unhandled_input(event: InputEvent) -> void:
    if event.is_action_pressed("forge_logger_report"):
        ForgeLogger.show_report_popup()
```

The player types a title and description; the report is sent with runtime context attached automatically — current scene, build version, FPS / frame time / memory, session uptime — plus a screenshot if you've turned on `enable_screenshot`. Done.

**3. Ask for feedback at the end of your demo.** Got a demo out on itch.io or Steam Next
Fest and want star ratings, a price question and an optional contact for a giveaway —
without shipping a new build? Create a form and a link in the dashboard (make one link just
for the game, e.g. "In game"), then show it from a button at the end of your demo:

```gdscript
func _on_feedback_button_pressed() -> void:
    ForgeLogger.show_feedback("AbCdEfGh12345678", {"pause": true})  # the link token from the dashboard
```

The form renders **inside the game** — no browser, no leaving fullscreen — from the questions
on the server, so edits in the dashboard show up on the next open. The D-pad walks it, **A**
picks, **B** closes (even if your project never mapped the pad to `ui_accept`); it scales with
the screen and scrolls on small ones. Buttons, consents and messages are in English (forms are
English-only for now); your questions stay as you wrote them. The answer is
linked to the player's session, build, playtime, scene and checkpoint (the `checkpoint` your
`set_context_provider` callback returns), so the dashboard can compare, say, players who played
over 20 minutes or crashed with the rest (Indie and Studio plans).

- **Offline:** the last fetched form is cached in `user://` — call
  `ForgeLogger.prefetch_feedback(token)` at game start and it opens even without a network
  (festival booth). Answers given offline are queued and sent on the next launch. (With
  `enable_reports = false` nothing is written to `user://`: the copy and unsent answers then
  live in memory until the game quits.)
- **Signals:** `feedback_submitted(link_token, result)` (`result.status` = `"sent"` or
  `"queued"`) and `feedback_closed(link_token, submitted)`.

Prefer the browser? `ForgeLogger.open_feedback(token)` opens the same form on
`forgelogger.dev/f/<token>` with `session`, `build`, `playtime`, `scene` and `checkpoint` in the
URL (a new tab in web exports). Only want feedback, no in-game F8 popup? Set `enable_report_hotkey = false`.

**4. Or wire your own UI / fire reports from code:**

```gdscript
# Submit from your own form (attach_logs, attach_screenshot)
ForgeLogger.submit_ui_report("Stuck in wall", "Walked into the crate near spawn and clipped through.", true, true)

# Capture a bug programmatically — e.g. from an error handler
ForgeLogger.capture_bug({
    "title": "Null inventory",
    "description": "Opened shop with no save loaded",
    "severity": "high",
    "tags": ["inventory"],
    "custom_data": { "scene": get_tree().current_scene.name },
})

# Drop lightweight events onto the session timeline
ForgeLogger.record_event("level_started", { "level": "forest_02" })

# Enrich every report (popup included) with your game state
ForgeLogger.set_context_provider(func() -> Dictionary:
    return {
        "checkpoint": "level_%d" % current_level,
        "playerPosition": { "x": player.position.x, "y": player.position.y },
    })
```

---

## Play analytics

Anonymous play statistics — sessions per day, session length, early quits,
levels started/completed, game completions, web vs. download builds — without
any player or device id. The hosted dashboard aggregates them per UTC day
(`GET /v1/projects/:projectId/play-stats/daily`, readable with a personal access
token).

**1. Settings** (Project Settings → `forge_logger/`):

| Setting | Analytics value |
|---|---|
| `heartbeat_interval` | e.g. `30` — the session reports its elapsed play time every 30 s, and once more with `ended` when it ends. |
| `enable_reports` | `false` if you only want analytics (no F8 popup, no log capture, no files in `user://`). |
| `auto_start_session` | `false` if the game decides when to start (e.g. after a consent toggle). |
| `collect_device_info` | keep `false` (default) for anonymous stats. |

**2. Code:**

```gdscript
# Before the session starts: facts about this build, merged into session metadata.
ForgeLogger.session_metadata = {"build_kind": "demo"}  # "demo" | "full"
await ForgeLogger.start_session()                       # with auto_start_session = false

# Level / run events — batched, sent within ~5 s. Nothing to await.
ForgeLogger.track("play.level_started", {"level": "1"})
ForgeLogger.track("play.level_completed", {"level": "1"})
ForgeLogger.track("play.restarted")
ForgeLogger.track("play.game_completed")

# Player turned stats off, or you want a clean end before quitting:
await ForgeLogger.end_session("opt_out")
```

| Event | Payload |
|---|---|
| `play.level_started` / `play.level_completed` | `{"level": "<id>"}` — required, string or number, 1–32 characters |
| `play.restarted` | — |
| `play.game_completed` | — |

How it behaves:

- **Pause-safe.** The `ForgeLogger` autoload runs with `PROCESS_MODE_ALWAYS`, so
  heartbeats, the event flush and `end_session()` keep working while your game
  is paused (the report hotkey stays inactive while paused).
- **Requests side by side.** Every API call gets its own `HTTPRequest` from a
  small pool, so concurrent calls (a heartbeat racing an event flush or a
  feedback answer) never fail with `ERR_BUSY` — important on web exports.
- **Ending a session.** `end_session()` flushes pending events and sends the
  final heartbeat. With `heartbeat_interval > 0` the plugin also ends the
  session when the game quits or the window closes: a short blocking request
  on desktop, a `fetch(keepalive)` on the page's `pagehide` on web. That last
  part is best effort.
- **Offline.** Undelivered `track()` events are retried on the next flush (up
  to 1,000 buffered, then the oldest are dropped); events the server rejects
  as invalid are dropped with a warning instead of being retried forever.
- **Web builds.** The ingest API answers every request with a CORS-readable
  `Cache-Control` header — Godot's web HTTP client treats a response without
  one as "no response". Keep that in mind if you put your own proxy in front.

---

## Public API

| Call | Does |
|---|---|
| `ForgeLogger.show_report_popup()` | Open the built-in report popup. |
| `ForgeLogger.submit_ui_report(title, description, attach_logs, attach_screenshot=true) -> String` | Send a report from your own UI. |
| `ForgeLogger.capture_bug(data: Dictionary) -> String` | Fire a report from code; returns the report id. |
| `ForgeLogger.record_event(type, payload)` / `send_events()` | Add events to the session timeline. |
| `ForgeLogger.show_feedback(link_token: String, options: Dictionary = {}) -> Control` | Show a feedback form inside the game (rendered from the server's questions, cached for offline). Options: `pause`, `theme`, `ui_scale` (0 = auto), `layer`. |
| `ForgeLogger.prefetch_feedback(link_token: String) -> bool` | Fetch and cache a form ahead of time, so `show_feedback()` works offline. |
| `ForgeLogger.is_feedback_open() -> bool` | Is the in-game feedback form open? |
| `signal feedback_submitted(link_token, result)` / `signal feedback_closed(link_token, submitted)` | The player sent the form (`result.status`: `"sent"` or `"queued"`) / closed it. |
| `ForgeLogger.open_feedback(link_token: String, extra: Dictionary = {})` | Open a public feedback form link in the system browser, tagged with the active `session`, `build`, `playtime`, current `scene` and `checkpoint`. `extra` adds further query params (e.g. `{"lang": "de"}`); never overrides session/build/playtime (an `extra` `scene` / `checkpoint` replaces the automatic one). |
| `ForgeLogger.set_context_provider(provider: Callable)` | Register a callback returning a Dictionary merged into every report's context — including popup reports. Keys matching the context fields (`checkpoint`, `playerPosition`, `sceneName`, …) go top-level; anything else lands in `extra`. Its `checkpoint` is also sent with every feedback answer. |
| `ForgeLogger.start_session() -> bool` / `get_session_id() -> String` | Manage the session manually. |
| `ForgeLogger.retry_queued() -> int` | Send reports and feedback answers queued while offline (also done automatically on the next launch). |
| `ForgeLogger.check_health() -> Dictionary` | Ping the backend. |
| `ForgeLogger.post_event(type, payload) -> bool` | Send a single event immediately, bypassing the buffer. |
| `ForgeLogger.get_event_count() -> int` | How many events are buffered but not yet sent. |
| `ForgeLogger.clear_events()` | Drop buffered events without sending them. |
| `ForgeLogger.await_session_ready()` | `await` until the first session start attempt has finished. |
| `signal session_ready` | Fires once the first session start attempt completes (whether the session started or failed) — the auto start, or your first `start_session()` call. |
| `ForgeLogger.session_metadata: Dictionary` | Extra keys merged into the session's `metadata` on start (e.g. `{"build_kind": "demo"}`). |
| `ForgeLogger.track(event_type: String, payload := {})` | Play analytics: queue an event; batched and sent within ~5 s. |
| `ForgeLogger.flush() -> bool` | Send queued `track()` events now; `true` when nothing is left. |
| `ForgeLogger.end_session(reason := "quit") -> bool` | Flush, send the final heartbeat (`ended`, `reason`), stop heartbeats. `start_session()` opens a new one. |
| `ForgeLogger.is_session_active() -> bool` | A session is running (started, not ended). |

---

## Styling the popups

Point `popup_theme` at a `Theme` resource (or pass `{"theme": my_theme}` to `show_feedback()`).
The report popup takes it as is; the feedback form merges it over its built-in look through
these theme type variations — style only what you want to change:

| Variation | Base type | Used for |
|---|---|---|
| `ForgeLoggerPanel` | PanelContainer | the form's panel |
| `ForgeLoggerTitle` / `ForgeLoggerQuestion` / `ForgeLoggerHint` / `ForgeLoggerError` | Label | title, questions, small print, validation messages |
| `ForgeLoggerConsentText` | Label | the consent wording |
| `ForgeLoggerPrimaryButton` | Button | "Send feedback", wishlist |
| `ForgeLoggerChoice` | Button | answers: yes / no, options, price points, contact type |
| `ForgeLoggerStar` | Button | rating stars (icons `star_filled`, `star_empty`) |
| `ForgeLoggerConsent` | CheckBox | consent boxes (icons `checked`, `unchecked`) |

The layout itself is fixed — one form for every game, so consents and the privacy link always
look the way players expect.

---

## Free plugin + optional hosted dashboard

The **plugin and the Discord bot are free forever** and MIT-licensed. Point `base_url` at your own backend and you never pay a thing.

If you'd rather not run infrastructure, the **hosted dashboard** is optional:

| | Free | Indie — €12/mo | Studio — €39/mo |
|---|---|---|---|
| Reports / month | 100 | 1,000 | 5,000 |
| Triage dashboard, filters, GitHub export | ✓ | ✓ | ✓ |
| AI summary + reproduction steps | first 10 | ✓ | ✓ |
| Jira & Discord export | — | ✓ | ✓ |
| AI dedupe, Linear/Trello/ClickUp, priority support | — | — | ✓ |

→ **[Create a free project](https://forgelogger.dev/auth)** — no card required.

> **Unity & Unreal:** the ingest backend is engine-agnostic and ports are on the roadmap. Want one? **[Join the waitlist](https://forgelogger.dev/auth)** and tell us which engine.

---

## How it talks to the backend

Project scope is carried by the logger token, not the URL. The plugin targets the `forge-logger-ingest-be` service:

| Method | Endpoint | Purpose |
|--------|----------|---------|
| GET    | `/health` | Health check |
| POST   | `/v1/ingest/sessions` | Start session |
| POST   | `/v1/ingest/uploads` | Request signed upload URL |
| POST   | `/v1/ingest/reports` | Submit bug report |
| POST   | `/v1/ingest/events` | Append events (batched, max 500) |
| GET    | `/v1/ingest/feedback/:linkToken` | Feedback form to render in the game (`ETag`, 304 when unchanged) |
| POST   | `/v1/ingest/feedback` | Submit a player's feedback answers |
| POST   | `/v1/ingest/sessions/:sessionId/heartbeat` | Play analytics: elapsed play time / end of session |

Reports and feedback answers carry a client-generated `clientRequestId` (UUID from the OS's secure random source — a game's `seed()` does not repeat it), persisted in the offline queue. Retries with the same key return `{ idempotent: true, ... }` and never create duplicates server-side. A feedback answer is on disk before its request leaves. Offline, `429` and `5xx` never use up an entry's 5 attempts (after a `429` the rest of that kind waits for the next pass); such entries expire after 30 days, and a full queue drops bug reports before players' answers. Concurrent `send_events()` calls are serialized, so an event is never posted twice. Every request in flight has its own `HTTPRequest`, so a report, an event batch, an upload and a feedback answer go out side by side. Feedback answers are never written to the log (they may hold the player's contact).

Every report also ships a `context` block filled in automatically — current scene, platform, build version, performance counters (FPS, frame time, RAM, VRAM, node & orphan-node counts), session uptime, and whatever your `set_context_provider` callback returns — plus `sourceChannel` (`ui_popup` vs `api`) and an optional `fingerprint` dedupe hint passed through `capture_bug`.

**Attachment limits:** screenshots `png/jpeg/webp` ≤ 10 MiB · log bundles ≤ 50 MiB · save states ≤ 100 MiB · video `webm/mp4` ≤ 500 MiB. Aggregate ≤ 600 MiB/report (otherwise `413`).

---

## Roadmap

- Crash dialog: prompt the player to send diagnostics after an unclean shutdown
- Replay / save-file attachments
- Configurable retry backoff
- Unity & Unreal clients (engine-agnostic backend already in place — [waitlist](https://forgelogger.dev/auth))

## Links

- 🌐 Website: https://forgelogger.dev · Dashboard: https://forgelogger.dev/auth · Docs: https://forgelogger.dev/docs/plugins/godot
- 📦 Asset Store: https://store.godotengine.org/asset/stoneforge-labs/forge-logger
- 💻 Source — issues & PRs welcome: https://github.com/stoneforgelabs/forge-logger-godot

## License

MIT. Use it in commercial games, fork it, ship it. See [LICENSE](LICENSE).
