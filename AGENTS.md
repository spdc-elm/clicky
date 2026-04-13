# Clicky - Agent Instructions

<!-- This is the single source of truth for all AI coding agents. CLAUDE.md is a symlink to this file. -->
<!-- AGENTS.md spec: https://github.com/agentsmd/agents.md — supported by Claude Code, Cursor, Copilot, Gemini CLI, and others. -->

## Overview

macOS menu bar companion app. Lives entirely in the macOS status bar (no dock icon, no main window). Clicking the menu bar icon opens a compact settings panel. A user-configured global shortcut opens a centered prompt composer with a session context preview, persistent session restore flow, and archived conversation history; sending captures the current cursor screen, streams an Anthropic-compatible response into a floating text panel, and keeps the blue cursor buddy available for on-screen pointing.

API credentials are stored locally in Keychain. The app can talk directly to an Anthropic-compatible endpoint. The Cloudflare Worker remains in the repo as an optional proxy, not a runtime requirement.

## Architecture

- **App Type**: Menu bar-only (`LSUIElement=true`), no dock icon or main window
- **Framework**: SwiftUI (macOS native) with AppKit bridging for menu bar panel and cursor overlay
- **Pattern**: MVVM with `@StateObject` / `@Published` state management
- **AI Chat**: Anthropic-compatible Messages API with SSE streaming, configurable endpoint/model/API key
- **Shortcut Handling**: Global shortcut registration and recording via `KeyboardShortcuts`
- **Screen Capture**: ScreenCaptureKit (macOS 14.2+), current cursor screen only
- **Input UX**: Centered prompt composer overlay with a session context sidebar, restorable session chooser, history detail panel, and multiline text input
- **Response UX**: Scrollable floating response panel anchored bottom-center by default, with top fallback when lower-screen content would be obscured
- **Element Pointing**: Claude embeds `[POINT:x,y:label:screenN]` tags in responses. The overlay parses these, maps coordinates to the correct monitor, and animates the blue cursor along a bezier arc to the target.
- **Concurrency**: `@MainActor` isolation, async/await throughout
- **Analytics**: PostHog via `ClickyAnalytics.swift`
- **Session Persistence**: Completed conversation turns are archived as JSON session files under Application Support, separate from the in-memory AI context window.

### Optional API Proxy

The app can call an Anthropic-compatible endpoint directly. A Cloudflare Worker (`worker/src/index.ts`) still exists as an optional proxy for setups that do not want to ship raw provider keys in the client.

| Route | Upstream | Purpose |
|-------|----------|---------|
| `POST /chat` | `api.anthropic.com/v1/messages` | Anthropic-compatible streaming chat |
| `POST /tts` | `api.elevenlabs.io/v1/text-to-speech/{voiceId}` | Legacy TTS proxy route |
Worker secrets: `ANTHROPIC_API_KEY`, `ELEVENLABS_API_KEY`
Worker vars: `ELEVENLABS_VOICE_ID`

### Key Architecture Decisions

**Menu Bar Panel Pattern**: The settings panel uses `NSStatusItem` for the menu bar icon and a custom borderless `NSPanel` for the floating configuration UI. This keeps the app lightweight and lets the primary workflow happen through the global shortcut and overlays, not through a main window.

**Cursor Overlay**: A full-screen transparent `NSPanel` hosts the blue cursor companion. It's non-activating, joins all Spaces, and never steals focus. The cursor follows the mouse, shows a spinner while Clicky is processing, and animates to pointed elements returned by the model.

**Composer-First Workflow**: The primary action is opening a centered prompt composer, optionally choosing whether to resume the previous archived session, reviewing the recent completed turns that will be sent as context, writing a question, and sending it with an automatic screenshot of the current cursor screen. This keeps the interaction low-friction for code and terminal explanation workflows without relying on built-in voice capture.

**Session Archive Split**: Clicky now separates the persistent session archive from the transient AI context window. Full completed turns are saved as JSON session events, while only the most recent configured turns are shown in the composer sidebar and sent back to the model.

**Direct Endpoint Configuration**: Endpoint URL, API key, and model ID are configured at runtime. The API key is stored in Keychain, while the endpoint and model are stored in `UserDefaults`.

## Key Files

| File | Lines | Purpose |
|------|-------|---------|
| `leanring_buddyApp.swift` | ~50 | Menu bar app entry point. Creates `CompanionManager`, launches the cursor overlay, and auto-opens the settings panel when configuration is incomplete. |
| `CompanionManager.swift` | ~657 | Central text-first state machine. Owns prompt composer flow, session restore/new-session behavior, JSON-backed archive integration, screenshot capture, response streaming, context-window derivation, and pointing state. |
| `PromptComposerOverlay.swift` | ~772 | Centered prompt composer overlay built with a key-capable `NSPanel`, a clickable session history sidebar, a restore chooser, a full-turn detail panel, and a custom multiline `NSTextView` bridge. |
| `CompanionResponseOverlay.swift` | ~295 | Scrollable floating response panel that streams text, supports manual scrolling, and anchors bottom-center or top-center based on screen context. |
| `MenuBarPanelManager.swift` | ~236 | NSStatusItem + custom NSPanel lifecycle for the settings dropdown. |
| `CompanionPanelView.swift` | ~357 | SwiftUI settings panel. Edits endpoint URL, API key, model ID, context turn count, the global shortcut, and session archive actions, and surfaces Screen Recording status. |
| `SessionArchiveStore.swift` | ~231 | JSON-backed session persistence layer. Stores active session metadata in `UserDefaults` and full completed conversation turns in Application Support archives. |
| `OverlayWindow.swift` | ~392 | Full-screen transparent overlay hosting the blue cursor, processing spinner, and pointing animation. |
| `CompanionScreenCaptureUtility.swift` | ~96 | Captures the current cursor screen with ScreenCaptureKit while excluding Clicky's own windows. |
| `ClaudeAPI.swift` | ~166 | Anthropic-compatible SSE client with runtime endpoint/API key/model configuration and TLS warmup. |
| `ClickySettingsStore.swift` | ~87 | Runtime settings store for endpoint URL, model ID, and API key-backed validation. Persists non-secret config to `UserDefaults`. |
| `KeychainSecretStore.swift` | ~80 | Minimal Keychain wrapper for storing the API key locally. |
| `KeyboardShortcutDefinitions.swift` | ~12 | Shared `KeyboardShortcuts` names used for the global composer shortcut. |
| `WindowPositionManager.swift` | ~266 | Screen Recording permission flow plus a few legacy window/accessibility helpers still used elsewhere in the codebase. |
| `worker/src/index.ts` | ~114 | Optional Cloudflare Worker proxy. Supports `/chat` and `/tts` routes for proxy-based deployments. |

## Build & Run

```bash
# Open in Xcode
open leanring-buddy.xcodeproj

# Select the leanring-buddy scheme, set signing team, Cmd+R to build and run

# The app now talks directly to an Anthropic-compatible endpoint configured in the menu bar panel.
# Known non-blocking warnings: Swift 6 concurrency warnings. Do NOT attempt to fix these.
```

**Do NOT run `xcodebuild` from the terminal** — it invalidates TCC (Transparency, Consent, and Control) permissions and the app will need to re-request screen recording, accessibility, etc.

## Cloudflare Worker

The Worker is optional. If you want to proxy requests instead of configuring Clicky with a direct endpoint and API key, use the existing `worker/` project and point Clicky at the deployed `/chat` endpoint.

## Code Style & Conventions

### Variable and Method Naming

IMPORTANT: Follow these naming rules strictly. Clarity is the top priority.

- Be as clear and specific with variable and method names as possible
- **Optimize for clarity over concision.** A developer with zero context on the codebase should immediately understand what a variable or method does just from reading its name
- Use longer names when it improves clarity. Do NOT use single-character variable names
- Example: use `originalQuestionLastAnsweredDate` instead of `originalAnswered`
- When passing props or arguments to functions, keep the same names as the original variable. Do not shorten or abbreviate parameter names. If you have `currentCardData`, pass it as `currentCardData`, not `card` or `cardData`

### Code Clarity

- **Clear is better than clever.** Do not write functionality in fewer lines if it makes the code harder to understand
- Write more lines of code if additional lines improve readability and comprehension
- Make things so clear that someone with zero context would completely understand the variable names, method names, what things do, and why they exist
- When a variable or method name alone cannot fully explain something, add a comment explaining what is happening and why

### Swift/SwiftUI Conventions

- Use SwiftUI for all UI unless a feature is only supported in AppKit (e.g., `NSPanel` for floating windows)
- All UI state updates must be on `@MainActor`
- Use async/await for all asynchronous operations
- Comments should explain "why" not just "what", especially for non-obvious AppKit bridging
- AppKit `NSPanel`/`NSWindow` bridged into SwiftUI via `NSHostingView`
- All buttons must show a pointer cursor on hover
- For any interactive element, explicitly think through its hover behavior (cursor, visual feedback, and whether hover should communicate clickability)

### Do NOT

- Do not add features, refactor code, or make "improvements" beyond what was asked
- Do not add docstrings, comments, or type annotations to code you did not change
- Do not try to fix the known non-blocking warnings (Swift 6 concurrency, deprecated onChange)
- Do not rename the project directory or scheme (the "leanring" typo is intentional/legacy)
- Do not run `xcodebuild` from the terminal — it invalidates TCC permissions

## Git Workflow

- Branch naming: `feature/description` or `fix/description`
- Commit messages: imperative mood, concise, explain the "why" not the "what"
- Do not force-push to main

## Self-Update Instructions

<!-- AI agents: follow these instructions to keep this file accurate. -->

When you make changes to this project that affect the information in this file, update this file to reflect those changes. Specifically:

1. **New files**: Add new source files to the "Key Files" table with their purpose and approximate line count
2. **Deleted files**: Remove entries for files that no longer exist
3. **Architecture changes**: Update the architecture section if you introduce new patterns, frameworks, or significant structural changes
4. **Build changes**: Update build commands if the build process changes
5. **New conventions**: If the user establishes a new coding convention during a session, add it to the appropriate conventions section
6. **Line count drift**: If a file's line count changes significantly (>50 lines), update the approximate count in the Key Files table

Do NOT update this file for minor edits, bug fixes, or changes that don't affect the documented architecture or conventions.
