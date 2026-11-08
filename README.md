![Watch the Limits — Your Codex usage, at a glance.](docs/images/watch-the-limits-banner.png)

[**Download Latest Release**](https://github.com/alisov66/watch-the-limits/releases/latest)

# Watch the Limits

A small native macOS app that keeps your remaining Codex quota in the menu bar.

Previously named **Codex Usage Bar**. The rename preserves existing preferences and the app's macOS identity. See [the rename notes](docs/rename.md) for upgrade details.

**`5h 68% · 7d 92%`** — click to see each usage window and its reset time.

- Remaining quota and reset countdowns for your account's Codex limit windows.
- Automatic refresh every minute, on opening the popover, and after waking your Mac.
- Optional launch at login.
- Available earned resets, with inline confirmation, processing, and recovery after an uncertain result.
- Independently remembered Settings and Available resets expansion across launches.
- Choose both limits, five-hour only, or weekly only in Settings.
- Original Figma artwork and typography, with a 24-point icon target that fits shorter menu bars and system-tinted two-tone artwork.
- Native interface that follows your Mac's light or dark appearance.
- Figma-designed panel with native macOS background effects and launch-at-login switch, plus explicit loading, retry, and setup states.
- Free and open source under the [MIT license](LICENSE).

Independent community project. Not affiliated with or endorsed by OpenAI.

## Download

Download the app from the [latest release](https://github.com/alisov66/watch-the-limits/releases/latest), unzip it, and move the app to Applications.

Starting with **v0.5.0**, the download is **Watch-the-Limits-macOS.zip**, containing **Watch the Limits.app**. Existing releases through **v0.4.1** retain their original names. When updating from Codex Usage Bar, quit the old app first, install the renamed app in Applications, and remove the old copy after verifying the new one works.

Requires **macOS 13 Ventura or newer**. Release builds include both Apple Silicon and Intel support. You also need a local Codex installation signed in with your ChatGPT account.

Early releases are ad-hoc signed, without Apple notarization. macOS may block a downloaded copy. After checking that you trust the release, use **System Settings → Privacy & Security → Open Anyway**, when available. No scripts that disable Gatekeeper are needed. You can also build the app from source.

## Setup

1. Install [Codex CLI](https://developers.openai.com/codex/cli), or use the executable bundled with a supported Codex desktop installation.
2. Sign in with your ChatGPT account:

   ```sh
   codex login
   ```

3. Open Watch the Limits. Its icon appears in the menu bar.

The app looks in your environment's PATH, standard Homebrew locations, and known desktop-app locations. If it cannot find Codex, click **Locate Codex**, or **Settings → Codex location → Choose**, and select the `codex` executable. For version-managed Node installations, select the executable inside your active Node version's bin directory.

An API-key-only login does not provide your ChatGPT subscription quota. Usage windows vary by account; the app displays what Codex returns rather than assuming a particular plan or quota.

## What the percentage means

The menu bar shows **remaining quota** for your five-hour (`5h`) and weekly (`7d`) limits. By default both are visible. Open the panel, expand Settings, and use **Menu bar** to show either limit on its own. Your selection is saved across launches.

These are account quota percentages, not token counts or dollar spending. Reset times come from Codex. The menu bar shows a dash when readings are stale or unavailable. The panel retains older readings with a last-update timestamp and offers **Try again** after a failed refresh. Once a reset time passes, that quota shows a dash and **Awaiting refresh** until a new reading arrives. Missing data never appears as 0% or 100% remaining. The panel and menu bar use the same Codex account bucket.

## Privacy

The app starts a local `codex app-server` process to initialize the connection and call `account/rateLimits/read`. Only after you choose **Use reset** and then **Confirm reset**, it calls `account/rateLimitResetCredit/consume` for that selected reset. Codex handles authentication and contacts its own service. Older Codex versions or accounts that do not return reset information show **No data** for reset availability.

The app does not open your authentication files, run model prompts, inspect your projects or conversations, or upload usage to a separate server. There is no app analytics or third-party library dependency. Its saved settings contain an optional Codex executable path, your menu bar display choice, section expansion preferences, and reset identifiers with retry keys to avoid consuming another reset after an uncertain attempt. Launch-at-login is managed by macOS. Codex itself still uses its existing local configuration and storage.

Settings and Available resets initially start collapsed, then remember your choices. Reset confirmation has no automatic timeout. Escape closes the panel and cancels an unconfirmed selection. A submitted reset finishes in the background if the panel closes; usage and reset availability refresh immediately afterward. A timeout is an unknown outcome, so the app refreshes to reconcile it and reuses the same retry key if you retry that selected reset. Reset errors remain visible until you submit another attempt, close the panel, or collapse Available resets.

The integration uses the [documented Codex app-server protocol](https://learn.chatgpt.com/docs/app-server#6-rate-limits-chatgpt). That interface may evolve; update Codex if you encounter an unsupported response.

## Build from source

Install Xcode 26 or newer and finish its first-launch setup, then:

```sh
git clone https://github.com/alisov66/watch-the-limits.git
cd watch-the-limits
swift test
bash scripts/build.sh
open "dist/Watch the Limits.app"
```

Build for both Apple Silicon and Intel:

```sh
bash scripts/build.sh universal
```

The script creates a locally signed app, a zip archive, and SHA-256 checksums in `dist/`.

Current Command Line Tools with the macOS 26 SDK or newer can also build the app, but running the XCTest suite requires Xcode's test frameworks. The build records the actual SDK version in both architectures so modern macOS controls are enabled, while retaining macOS 13 as the minimum supported system.

On macOS 26 and later, the dropdown uses Apple's native Liquid Glass container in a rounded, arrow-free panel. Earlier versions retain the native popover. The launch-at-login switch uses the standard system appearance for the running OS.

Preview the interface using sample data:

```sh
swift run WatchTheLimits --demo
```

On macOS 26 or newer, verify the actual panel with synthetic data (opening,
queued-click handling, Settings resizing, Escape, outside-click dismissal, and reopening):

```sh
"dist/Watch the Limits.app/Contents/MacOS/WatchTheLimits" --verify-panel
```

Check the live connection without opening the interface:

```sh
swift run WatchTheLimits --check
```

## Contributing

Issues and pull requests are welcome. Run `swift test` and build the app before submitting changes. Please use synthetic quota examples in tests and screenshots, and keep account IDs, credentials, and private Codex files out of issues and commits. See [CONTRIBUTING.md](CONTRIBUTING.md).

## Releases

GitHub Actions tests and builds a universal app on pushes and pull requests, then verifies real panel presentation on macOS 26. Releases require the owner's separate confirmation and curated notes in `docs/releases/vX.Y.Z.md`. After approval and successful checks, pushing the matching `v*` tag publishes the release with those notes, the app zip, and checksums. The build has read-only repository permissions; only the release job receives permission to publish release assets.
