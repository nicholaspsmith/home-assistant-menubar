# Homestead — Home Assistant menu-bar control (design)

**Date:** 2026-09-12
**Status:** approved in brainstorm; awaiting implementation plan
**Repo:** `~/Code/home-assistant-menubar` · **App:** `Homestead.app` · **Bundle id:** `com.nicholaspsmith.Homestead`

## Goal

A Menubarn app that controls Home Assistant devices from a menu-bar dropdown.
The first row is a dashboard picker listing the HA account's Lovelace
dashboards; choosing one fills the rest of the menu with that dashboard's
controllable devices. Lights, switches and fans toggle on/off; lights, fans and
position-capable covers get a slider (brightness / speed / position). The menu
opens on "My Home" by default.

## Decisions made in brainstorm

| Question | Decision |
|---|---|
| Dashboard source | Hand-built (storage/YAML) dashboards, read via the WebSocket `lovelace/config` command. No Areas fallback for auto-generated dashboards in the first cut. |
| Picker granularity | Picker lists **dashboards**; all of a dashboard's views are flattened, devices grouped under card/section headers. |
| Device row shape | Option B: name + value + `NSSwitch`; the slider row appears beneath **only while the device is on**. |
| Entity types | `light`, `switch`, `input_boolean`, `fan`, `cover`; `sensor`/`binary_sensor` as read-only rows behind a **Show Sensors** toggle (off by default). Scenes, scripts, media players: out. |
| Connection | Home LAN + Tailscale (single URL). Unreachable is a normal state, e.g. while Mullvad is connected. |
| Transport | WebSocket only (`URLSessionWebSocketTask`). No REST. |
| Surface | Real `NSMenu` with view-based rows. Spike (2026-09-12) confirmed an open menu re-lays out live for `insertItem`/`removeItem` and for `isHidden` toggling; use pre-created hidden slider items. |
| Icon | House mascot in `CharacterIcon`: windows lit by lights-on count, a fan drawn in a window while any fan runs, dashed when unreachable. **No chimney.** |
| Name | Homestead. |

## Architecture

Swift package with the same shape as KeyLight:

```
Package.swift                 depends on ../StatusItemKit (path), macOS 13+
Sources/HomesteadCore/        pure logic, unit-tested, no AppKit
Sources/Homestead/            AppKit app (main.swift, menu, prefs, keychain)
Tests/HomesteadCoreTests/     fixtures + tests
Resources/bundle/AppIcon.icns house mascot
scripts/make-app.sh           from StatusItemKit conventions (stable signing identity)
```

`Homestead.app` is symlinked into `~/Applications`, runs as `LSUIElement`, with
in-app Start at Login (`SMAppService`) and a `YieldClient` for Barn.

### HomesteadCore

| Unit | Responsibility | Depends on |
|---|---|---|
| `HAMessage` | `Codable` frames for the HA WebSocket protocol: `auth_required`/`auth`/`auth_ok`/`auth_invalid`, `result` (with `success`, `error{code,message}`), `event`. Encoding of commands with an `id`. | Foundation |
| `HASocket` | Actor owning one `URLSessionWebSocketTask`. `connect(url:token:)` does the auth handshake; `send(_:) async throws -> JSON` correlates replies by id; `subscribe(_:) -> AsyncStream<JSON>`; closes → emits `.disconnected(reason)`. Transport is injected behind a protocol so tests can drive it with canned frames. | `HAMessage` |
| `Dashboard` / `DashboardListing` | `id`, `urlPath` (`nil` = built-in Overview), `title`. | — |
| `DashboardParser` | `parse(config: JSON) -> [DeviceGroup]`. Recursive, card-type-agnostic walk (see below). | — |
| `Device` / `DeviceKind` | `entityId`, `displayName`, `kind` (`.light`, `.fan`, `.toggle`, `.cover(positionable)`, `.sensor`), plus live `EntityState`. | — |
| `EntityState` / `StateStore` | `state` string, `attributes` dict; applies `subscribe_entities` compressed diffs (`a` add, `c` change with `+`/`-`, `r` remove). Publishes changes per entity id. | — |
| `ServiceCall` | `toggle(device, on:)`, `setLevel(device, fraction:)` → `{domain, service, serviceData, target}`. Owns the unit math: brightness 0–255 ↔ `brightness_pct`; fan `percentage` snapped to `percentage_step`; cover `position`. | `Device` |
| `LevelMath` | Pure helpers for the above (like KeyLight's `LevelMath`). | — |
| `ConnectionState` | `.unconfigured`, `.connecting`, `.connected`, `.unreachable(String)`, `.authFailed`. | — |

### Homestead (app)

| Unit | Responsibility |
|---|---|
| `main.swift` | `NSApplication` bootstrap, `StatusItemController` from StatusItemKit (`onPoll` unused; menu is event-driven), `YieldClient`. |
| `AppModel` | Owns `HASocket`, `StateStore`, current dashboard, settings. Orchestrates: connect → list dashboards → load selected config → parse → subscribe entities. Reconnect with backoff 1, 2, 4 … 30 s; immediate reconnect on `NWPathMonitor` change. Exposes an observable snapshot for the menu and icon. |
| `MenuController` | Builds the `NSMenu` from the snapshot; keeps a map `entityId → (rowItem, sliderItem?)`; applies live state diffs to rows in place; shows/hides slider items via `isHidden`. |
| `DashboardPickerRow` | View-based item holding an `NSPopUpButton` of dashboard titles. |
| `DeviceRowView` | Name · value label · `NSSwitch` (absent for sensors). Disabled + "Unavailable" when state is `unavailable`/`unknown`. |
| `LevelSliderView` | The slider row (icon + `NSSlider`), modelled on KeyLight's `BrightnessSliderView`. Coalesces drags: one call in flight, latest value queued, final value sent on mouse-up. `update(level:)` ignored while highlighted. |
| `ConnectionWindow` | Prefs window: URL, token (secure field), Test, Save. |
| `Keychain` | Generic-password item, service `com.nicholaspsmith.Homestead`, account = HA URL. Token never lives in UserDefaults. |
| `Settings` | UserDefaults: `HAURL`, `SelectedDashboard` (url_path or `""` for Overview), `ShowSensors` (default false), `MeterStyle`/`MeterColorHex` via StatusItemKit's `MeterAppearance`. |
| `HouseIcon` | Wrapper choosing `CharacterIcon.house(...)` or `MeterIcon.dot` per `MeterAppearance`, from the snapshot. |

## Data flow

```
launch → Settings.url + Keychain.token
   │  (missing → ConnectionState.unconfigured; menu shows "Connect to Home Assistant…")
   ▼
HASocket.connect ──auth_invalid──▶ .authFailed (no retry; status row points at Connection…)
   │ auth_ok
   ▼
lovelace/dashboards/list  + implicit Overview(urlPath: nil)
   ▼
lovelace/config(url_path: selected)  ──config_not_found──▶ drop that dashboard from picker;
   │                                                        fall back to first remaining
   ▼
DashboardParser → [DeviceGroup]   (entity ids in dashboard order, deduped)
   ▼
subscribe_entities(entity_ids)  → StateStore (snapshot, then diffs)
   ▼
MenuController rebuilds rows; HouseIcon redraws on every StateStore change
```

Picker change → unsubscribe, load new config, re-subscribe, rebuild rows **while
the menu stays open**. Socket drop → `.unreachable`, rows greyed with last-known
state, backoff reconnect; on reconnect the whole chain re-runs.

## Dashboard parsing rules

Input is the `lovelace/config` result: `{ views: [...] }`. Each view is either
classic (`cards: [...]`) or `type: "sections"` (`sections: [{title?, cards}]`).

Walk every dictionary recursively:

- `entity: "<id>"` → one reference.
- `entities: [...]` → each element is a string id or `{entity, name?}`; elements without `entity` (section/divider rows) are skipped.
- Recurse into `cards`, `card`, `sections`, and any nested dictionary/array (covers `vertical-stack`, `horizontal-stack`, `grid`, `conditional`, custom cards).
- Header for a reference = nearest ancestor `title` (card → section → view); if none, `"Devices"`. Consecutive references with the same header form one `DeviceGroup`.
- Display name = the reference's `name` override if present, else `friendly_name` from state, else the entity id.
- Duplicate entity ids: keep the first occurrence.
- Filter by domain into `DeviceKind`; unknown domains dropped. `cover` is `.cover(positionable: supported_features & 4 != 0)` — resolved once state arrives.

Unit-tested against fixtures: entities card, tile card, vertical/horizontal
stack, grid, conditional, sections view, `name` override, dedupe, empty
dashboard.

## Menu

Width 280 pt. Top to bottom:

1. **Dashboard picker row.** Default selection: the dashboard titled "My Home"
   if present, else the first listed; last choice persisted.
2. **Status row** (only when not `.connected`): "Connecting…", "Can't reach
   Home Assistant — retrying", or "Token rejected — open Connection…", plus a
   **Retry Now** item for the unreachable case.
3. **Groups.** Small-caps header (disabled item) then device rows in dashboard
   order. Slider items are created for every light, fan and positionable cover
   and hidden unless that device is on (`on`, `open`, `opening`, `closing`).
   State changes from elsewhere show/hide them live.
4. Separator, then **Show Sensors** (✓ toggle), **Start at Login** (✓),
   **Icon ▸** (`AppearanceMenu`: House / Dot + colour), **Connection…**,
   **Quit**.

Row semantics:

| Kind | Value label | Switch | Slider |
|---|---|---|---|
| light | `NN%` when on, blank when off | on/off | brightness 1–100 % |
| fan | `NN%` | on/off | speed, snapped to `percentage_step` |
| toggle (switch, input_boolean) | — | on/off | — |
| cover | `Open`/`Closed`/`Opening`/`Closing` (+ `NN%` if positionable) | open/close | position 0–100 % (positionable only) |
| sensor / binary_sensor | state + unit; binary shown as `On`/`Off` | — | — |
| any, unavailable | `Unavailable` | disabled | hidden |

Empty dashboard → a single disabled row "No controllable devices on this
dashboard". Live updates never move a slider that is being dragged.

## Actions

- Switch flip → `light|switch|input_boolean|fan.turn_on/turn_off`,
  `cover.open_cover/close_cover`. Optimistic: the row updates immediately;
  on a `result.success == false` the row reverts and the failure is logged
  via `os_log` (subsystem `com.nicholaspsmith.Homestead`). No alerts.
- Slider → `light.turn_on {brightness_pct}`, `fan.set_percentage {percentage}`,
  `cover.set_cover_position {position}`. Coalesced: at most one call in
  flight; a newer drag value replaces the queued one; mouse-up always sends the
  final value.

## Icon

New `CharacterIcon.house(lightsOn: Int, fanOn: Bool, reachable: Bool,
configured: Bool)` in StatusItemKit, at the same 22-pt scale as the other
mascots:

- Outline house with two windows and a door. No chimney.
- `lightsOn` counts lights in the **selected dashboard** whose state is `on`:
  0 → both windows dark, 1 → left window lit, ≥2 → both lit (yellow).
- `fanOn` (any fan on) → a three-blade fan glyph drawn inside the right window
  (dark blades on a lit window, light blades on a dark one).
- `!reachable` → dashed, dimmed outline, windows dark.
- `!configured` → solid grey outline, windows dark.
- Icon ▸ Dot falls back to `MeterIcon.dot` coloured by connection state.

After drawing it, regenerate every glyph image with
`~/Code/widgets.nicksmith.software/art/glyphs/render-glyphs.sh` (never
screen-capture the bar) and build `Resources/bundle/AppIcon.icns` from the
house mascot.

## Settings & first run

- **Connection… window** (`NSWindow`, like KeyLight's `PreferencesWindow`):
  URL text field (placeholder `http://homeassistant.local:8123`), token secure
  text field, **Test** (runs the auth handshake; reports "Connected",
  "Token rejected", or "Unreachable: <reason>"), **Save**. Saving stores the
  URL in UserDefaults and the token in the Keychain, then reconnects.
- Until both exist the menu is: **Connect to Home Assistant…** (opens the
  window), separator, Start at Login, Quit. Icon grey.
- Nick pastes the token himself (clipboard → secure field); it is never
  transferred through an assistant session.

## Error handling

| Situation | Behaviour |
|---|---|
| URL unreachable / socket dropped | `.unreachable`, greyed rows with last-known state, dashed icon, backoff reconnect + immediate retry on network change, Retry Now item |
| `auth_invalid` | `.authFailed`, status row, no automatic retry until Connection… is saved |
| `config_not_found` for a dashboard | dashboard removed from picker for this session |
| Malformed card / unknown card type | ignored by the parser (walk is structural, not type-based) |
| Service call error | control reverts, `os_log` error |
| Entity `unavailable`/`unknown` | row disabled, slider hidden |

## Testing

- `HomesteadCoreTests`: `DashboardParser` fixtures (above), `StateStore` diff
  application (`a`/`c`/`r`, attribute removal), `ServiceCall` per kind and the
  brightness/percentage/step math, `HAMessage` decoding of `auth_*`, `result`
  success/error, and `event` frames, `HASocket` handshake + id correlation
  against a fake transport.
- App layer verified manually against the real HA instance: picker, live
  toggle from the HA UI reflecting in the open menu, slider drag, Mullvad
  on/off reachability transitions, Barn reveal via `YieldClient`.

## Out of scope (first cut)

Colour / colour temperature, scenes and scripts, media players, Areas fallback
for auto-generated dashboards, multiple HA URLs with fallback, the Menubarn
site listing (README mascot, "Why not a SwiftBar plugin?" section, and site
capture are a follow-up once the app works).
