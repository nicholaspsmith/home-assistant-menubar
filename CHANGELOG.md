# Changelog

Every push to `main` is a release. Before pushing, add a `## [X.Y.Z] - YYYY-MM-DD`
section at the top with `- ` entries (minor for features, patch for fixes); if an
`## [Unreleased]` section is waiting, turn it into that section. GitHub tags it
and publishes the section as the release notes; a push without one is refused.
Versions follow [Semantic Versioning](https://semver.org/). The full rule:
[StatusItemKit — Releases](https://github.com/nicholaspsmith/StatusItemKit#releases-every-push-is-one).

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
