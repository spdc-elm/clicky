# Hi, this is Clicky.
It's an AI buddy that lives next to your cursor. It sees your current screen when you ask a question, streams back a text answer in a floating panel, and can point at UI elements on screen.

Download it [here](https://www.clicky.so/) for free.

Here's the [original tweet](https://x.com/FarzaTV/status/2041314633978659092) that kinda blew up for a demo for more context.

![Clicky — an ai buddy that lives on your mac](clicky-demo.gif)

This is the open-source version of Clicky for those that want to hack on it, build their own features, or just see how it works under the hood.

## Get started with Claude Code

The fastest way to get this running is with [Claude Code](https://docs.anthropic.com/en/docs/claude-code).

Once you get Claude running, paste this:

```
Hi Claude.

Clone https://github.com/farzaa/clicky.git into my current directory.

Then read the CLAUDE.md. I want to get Clicky running locally on my Mac.

Help me set up Clicky with my own Anthropic or OpenAI endpoint, API key, and model in Xcode. Walk me through it.
```

That's it. It'll clone the repo, read the docs, and walk you through the whole setup. Once you're running you can just keep talking to it — build features, fix bugs, whatever. Go crazy.

## Manual setup

If you want to do it yourself, here's the deal.

### Prerequisites

- macOS 14.2+ (for ScreenCaptureKit)
- Xcode 15+
- API key for an Anthropic-compatible or OpenAI-compatible endpoint

### 1. Open in Xcode and run

```bash
open leanring-buddy.xcodeproj
```

In Xcode:
1. Select the `leanring-buddy` scheme (yes, the typo is intentional, long story)
2. Set your signing team under Signing & Capabilities
3. Hit **Cmd + R** to build and run

The app will appear in your menu bar (not the dock). Click the icon to open the settings panel, then fill in:

- Provider
- Endpoint URL or full provider-specific API URL
- API key
- Model ID
- Global shortcut

Once those are set, use your shortcut to open the centered prompt composer, type a question, and send it. Clicky captures the current cursor screen automatically.

### Permissions the app needs

- **Screen Recording** — for taking screenshots when you use the hotkey

## Architecture

If you want the full technical breakdown, read `CLAUDE.md`. But here's the short version:

**Menu bar app** (no dock icon) with three `NSPanel` surfaces — one for settings, one centered prompt composer, and one floating response panel — plus a full-screen transparent cursor overlay. Sending a prompt captures the current cursor screen, then streams either an Anthropic Messages response or an OpenAI Chat Completions response based on the selected provider, while keeping Clicky's pointing behavior via terminal `[POINT:x,y:label]` tags.

## Project structure

```
leanring-buddy/          # Swift source (yes, the typo stays)
  CompanionManager.swift    # Central state machine
  CompanionPanelView.swift  # Settings panel UI
  PromptComposerOverlay.swift # Centered input overlay
  CompanionResponseOverlay.swift # Scrollable response panel
  ClaudeAPI.swift           # Claude streaming client
  OpenAIAPI.swift           # OpenAI streaming client
  OverlayWindow.swift       # Blue cursor overlay
  ClickySettingsStore.swift # Provider-specific endpoint/model/API-key config
worker/                  # Optional Cloudflare Worker proxy
  src/index.ts              # Legacy /chat and /tts routes
CLAUDE.md                # Full architecture doc (agents read this)
```

## Contributing

PRs welcome. If you're using Claude Code, it already knows the codebase — just tell it what you want to build and point it at `CLAUDE.md`.

Got feedback? DM me on X [@farzatv](https://x.com/farzatv).
