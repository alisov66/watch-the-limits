# Figma menu bar assets

Source: https://www.figma.com/design/zCrkvUn8WyWUKH3YYn6QB0?node-id=9-1648

- `usage-icon.svg` is the original design-context export of Usage Icon (`9:1807`), variant `duo-tone=true, type=3 bars bold`, with its 24 × 24 viewport unchanged.
- `usage-icon.pdf` is a PDF export of that same component via the Figma Plugin API, used by AppKit for native vector rendering. It preserves the badge's 25% alpha and the chart's solid alpha.
- `menu-bar-tokens.json` mirrors the Typography and Colors collections and the `Menu bar/Label` text style. The approved icon has a native 24-point canvas. The status button limits icon size to its available height so shorter menu bars do not clip it.

The system-font family maps to the public AppKit system font when the separately installed SF Pro Text face is unavailable. The composed menu bar image is a template image: macOS supplies its contrast-appropriate foreground, and the exported alpha values retain the Figma two-tone treatment.

To review the same native rendering used by the status button:

```sh
swift run WatchTheLimits --render-indicators /tmp/codex-indicator-previews
```

This exports all three display modes in light and dark preview colors at Retina resolution, using synthetic data matching Figma (68% and 92%).

## Usage panel

Source: https://www.figma.com/design/zCrkvUn8WyWUKH3YYn6QB0?node-id=128-9461

Reset scenarios: https://www.figma.com/design/zCrkvUn8WyWUKH3YYn6QB0?node-id=176-8943

Reset behavior: https://www.figma.com/design/zCrkvUn8WyWUKH3YYn6QB0?node-id=176-8941

- `panel-tokens.json` records the approved layout, resolved light/dark color variables, and six `Panel` text styles. SF Pro maps to the public system font at the design's explicit sizes and weights; font files are not distributed.
- `panel-nav-arrow.svg` is the original 16 × 16 design-context export used by the Settings disclosure. `panel-refresh.svg` is the original 10 × 10 retry icon. Both retain their exported geometry and render as system-tinted templates.
- Named panel colors live in `Resources/PanelColors.xcassets`. The checked-in `PanelColors.bundle` contains their compiled asset catalog for Swift package builds. After changing the source catalog, run `bash scripts/build-panel-colors.sh`; normal builds verify its source checksum.
- The shell/background and switch variables in Figma are design-only emulations. On macOS 26 and later, the app uses `NSGlassEffectView` with regular glass and a 20-point corner radius in an arrow-free panel. The transparent root also clips to that radius, and AppKit's window shadow is recalculated after layout and resizing. Earlier systems use `NSPopover`'s native background. The standard macOS switch follows the running OS and accessibility settings. Build against the current SDK to enable the current system control design.
- `--render-panels OUTPUT_DIRECTORY` validates all named colors against the JSON values in both appearances, checks original icon dimensions, and exports panel-state previews including reset availability, confirmation, processing, error, success, and ready-state hover. Hover previews use the same button styles and fill selection as normal pointer interaction. The offscreen review uses a native material but cannot reproduce the live wallpaper backdrop or the active-window tint of a switch.
- The latest approved fills are black 6% / white 12% for controls, selectors, and progress tracks, and black 10% / white 20% for primary-button and Settings hover. The unselected selector item's hover uses `panel/control/fill`, layered over `panel/selector/fill`, matching the component. Selected items retain their solid fill.
- `--demo --panel-state ready --settings-expanded` opens the interactive panel with both sections expanded and synthetic data. Supported scenarios are `loading`, `ready`, `refresh-failed`, `refresh-failed-empty`, `retrying`, `retrying-empty`, `codex-missing`, `sign-in-required`, `expired`, `no-resets`, `reset-confirm`, `reset-processing`, `reset-error`, and `reset-success`. Preview reset interactions use synthetic data and never consume account resets. Preview interactions do not save preferences or register login items.

The panel keeps old readings on refresh failures and retries. Unavailable readings use dashes; passed reset timestamps invalidate that window instead of claiming a fresh quota reset. Refreshing normally retains the ready layout, without a persistent refresh control.
