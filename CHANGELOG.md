# Changelog

Every push to `main` is a release. Before pushing, add a `## [X.Y.Z] - YYYY-MM-DD`
section at the top with `- ` entries (minor for features, patch for fixes); if an
`## [Unreleased]` section is waiting, turn it into that section. GitHub tags it
and publishes the section as the release notes; a push or pull request
without one is refused (`[no release]` in the tip commit is the only exception).
Versions follow [Semantic Versioning](https://semver.org/). The full rule:
[StatusItemKit — Releases](https://github.com/nicholaspsmith/StatusItemKit#releases-every-push-is-one).

## [1.3.0] - 2026-10-05

- The house shows the weather outside: sun or moon behind the roof, clouds, rain, heavy rain, thunderstorms, snow, sleet, fog and wind, drawn around the house so the lit windows still count your lights. The moon replaces the sun after sunset.
- Hover the icon for the conditions and temperature ("Rainy · 69°F").
- **Weather ▸** chooses which weather entity to follow — Automatic (Forecast Home, when there is one), any other, or None. It only appears when Home Assistant has a weather entity.

## [1.2.0] - 2026-10-05

### Controls that match the device

- Dashboard buttons are buttons. A card that sends a command when tapped — a remote's Back key, "switch to YouTube", a restart — now presses that command instead of showing the entity's on/off switch. The Studio TV remote, fifteen keys on one remote entity, used to collapse into a single "Back" switch.
- Button cards with no `entity` of their own (the Master TV remote) used to be left out entirely; they now appear.
- Buttons from one dashboard grid stay together in its columns, so a D-pad reads as a D-pad. Arrows, transport, volume and power show as their glyph; anything else by name.
- A card that asks for confirmation asks inline: the first press shows **Confirm?**, the second acts.
- Thermostats show the current reading and what they are doing (Heating, Cooling, Idle), a mode picker (Off / Heat / Cool / Heat·Cool, from the thermostat's own modes) in place of the switch, and the target — or both ends of the heat/cool band — as buttons. Click one, then use the arrows to move it a degree (or the thermostat's own step) at a time. Quick presses go as one change.
- Shades get open / stop / close instead of a switch, and their position slider stays visible while they are closed.
- Media players: volume down / mute / up for players that step their volume (Roku, Xbox), mute for players with a volume slider, and no power switch on a player that cannot be turned on or off.
- `button`, `input_button`, `script` and `scene` entities appear with a Press / Run / Activate button; automations and groups appear with a switch.

### Tidier menu

- Heading cards title the rows after them, so a dashboard's Kitchen / Living Room / Hall sections appear as such instead of one block.
- Sensors read the way Home Assistant words them: a drive's health is OK, not Off; a backup was 6 h ago, not an ISO timestamp; uptime is 14 d.
- A dashboard is only suffixed with its URL path when another *visible* dashboard shares its title ("Hot Tub", not "Hot Tub (hot-tub)").
- A light that has just been switched on no longer shows 1% before it reports its brightness.

## [1.1.0] - 2026-09-30

### Sign in with your browser

- Connection… now signs in through Home Assistant's own login page: enter the server address (or pick one Homestead found on your network), press Sign In with Browser, and log in there. No long-lived token to create and paste.
- Homestead keeps the refresh token it is given and gets a new access token whenever it reconnects. Sign Out deletes both and revokes the refresh token on the server.
- A long-lived token saved by an earlier version keeps working until you sign in again.
- One menu item to connect: **Connect to Home Assistant…** at the top while signed out (including after a refused refresh token), **Connection…** in the settings section once signed in. Previously both showed while signed out.
- Closing the Connection window no longer cancels a sign-in in progress, so finishing the login in the browser still connects. While it waits, the button reads **Reopen Login Page** and reopens the same page rather than starting over.
- A callback from an older login tab gets an "Out of date" page and no longer aborts the sign-in that is waiting.
- The menu-bar icon no longer goes missing when the Keychain asks for your password at launch (it does after every local build). The read now happens off the main thread, so the icon appears at once and the menu says Connecting… until the prompt is answered.

## [1.0.1] - 2026-09-28

- `install.sh` now asks whether to turn on Start at Login (skipped when it is already on, or when there is no terminal to ask in), then relaunches the app, quitting any running copy first so the new build takes over
- `Homestead --login on|off|status` turns Start at Login on or off from the shell, or reports it, and exits without opening the app

## [1.0.0] - 2026-09-23

- feat: the menu shows the version it was built from
- LICENSE: name the copyright holder above the MPL text
- License: Mozilla Public License 2.0
- docs: bring the README in line with what shipped
- fix: hide the colour swatch when a light has no colour to show
- security: pre-publication review fixes
- docs: take the states strip from the shared glyph pipeline
- docs: the glyph's new states strip, drawn at 2x
- feat: generated app icon and mascot, solid menu-bar glyph
- docs: README, mascot, and the app icon
- feat: developer escape hatch for the per-rebuild keychain prompt
- feat: media players and remotes
- fix: stop the keychain asking for a password on every rebuild
- feat: warmth slider for tunable-white bulbs; thermostat sliders always shown
- feat: thermostats — current reading, target, and a temperature slider
- feat: reorderable dashboards, colour control for lights
- fix: the Dashboards window laid itself out to nothing
- feat: choose which dashboards the picker offers, and expand it in place
- fix: submenu dashboard picker, and draw the house glyph
- fix: install a main menu so ⌘V works in the Connection window
- feat: keychain token, connection window, connection lifecycle, and menu
- feat: app scaffold, settings, and build scripts
- feat: Home Assistant WebSocket client with reconnect policy
- feat: device kinds, level math, and service calls
- feat: entity state and compressed state diffs
- feat: parse dashboard listings and dashboard configs
- feat: package scaffold and HA WebSocket frame decoding
- Add Homestead implementation plan
- Add Homestead design spec
