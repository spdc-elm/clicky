# Clicky - Agent Instructions

<!-- This is the single source of truth for all AI coding agents. CLAUDE.md is a symlink to this file. -->
<!-- AGENTS.md spec: https://github.com/agentsmd/agents.md — supported by Claude Code, Cursor, Copilot, Gemini CLI, and others. -->

## Overview

macOS menu bar companion app. Lives entirely in the macOS status bar (no dock icon, no main window). Clicking the menu bar icon opens a compact settings panel. A user-configured global shortcut freezes the current cursor screen and opens a centered prompt composer with a session context preview, persistent session restore flow, archived conversation history, inline live-response viewing, and an on-demand full-screen annotation layer; sending flattens any annotations into that frozen screenshot, streams either an Anthropic Messages response or an OpenAI Chat Completions response inside the composer, and keeps the blue cursor buddy available for on-screen pointing.

API credentials are stored locally in Keychain. The app can talk directly to either an Anthropic-compatible endpoint or an OpenAI-compatible endpoint, selected at runtime in the settings panel. The Cloudflare Worker remains in the repo as an optional Anthropic proxy, not a runtime requirement.

## Architecture

- **App Type**: Menu bar-only (`LSUIElement=true`), no dock icon or main window
- **Framework**: SwiftUI (macOS native) with AppKit bridging for menu bar panel and cursor overlay
- **Pattern**: MVVM with `@StateObject` / `@Published` state management
- **AI Chat**: Provider-selectable Anthropic Messages API or OpenAI Chat Completions API, both with streaming text responses and configurable endpoint/model/API key
- **Shortcut Handling**: Global shortcut registration and recording via `KeyboardShortcuts`
- **Screen Capture**: ScreenCaptureKit (macOS 14.2+), current cursor screen only, captured when the composer opens and reused when sending
- **Input UX**: Centered prompt composer overlay with a session context sidebar, restorable session chooser, history detail panel, inline current-turn detail, multiline text input, and an on-demand full-screen frozen screenshot annotation layer with pen/rectangle/ellipse tools
- **Response UX**: Live responses stay inside the composer as a temporary current turn until the round completes and gets archived
- **Element Pointing**: Claude embeds `[POINT:x,y:label:screenN]` tags in responses. The overlay parses these, maps coordinates to the correct monitor, and animates the blue cursor along a bezier arc to the target.
- **Concurrency**: `@MainActor` isolation, async/await throughout
- **Analytics**: PostHog via `ClickyAnalytics.swift`
- **Prompt Management**: Bundled default Markdown prompts live in the app bundle and can be overridden at runtime from `~/.clicky/prompts/`
- **Session Persistence**: Completed conversation turns are archived as JSON session files under `~/.clicky/sessions`, separate from the in-memory AI context window. Legacy Application Support archives are migrated there on first use.

### Optional API Proxy

The app can call Anthropic-compatible or OpenAI-compatible endpoints directly. A Cloudflare Worker (`worker/src/index.ts`) still exists as an optional Anthropic proxy for setups that do not want to ship raw provider keys in the client.

| Route | Upstream | Purpose |
|-------|----------|---------|
| `POST /chat` | `api.anthropic.com/v1/messages` | Anthropic-compatible streaming chat |
| `POST /tts` | `api.elevenlabs.io/v1/text-to-speech/{voiceId}` | Legacy TTS proxy route |
Worker secrets: `ANTHROPIC_API_KEY`, `ELEVENLABS_API_KEY`
Worker vars: `ELEVENLABS_VOICE_ID`

### Key Architecture Decisions

**Menu Bar Panel Pattern**: The settings panel uses `NSStatusItem` for the menu bar icon and a custom borderless `NSPanel` for the floating configuration UI. This keeps the app lightweight and lets the primary workflow happen through the global shortcut and overlays, not through a main window.

**Cursor Overlay**: A full-screen transparent `NSPanel` hosts the blue cursor companion. It's non-activating, joins all Spaces, and never steals focus. The cursor follows the mouse, shows a spinner while Clicky is processing, and animates to pointed elements returned by the model.

**Composer-First Workflow**: The primary action is opening a centered prompt composer, freezing the current cursor screen, optionally choosing whether to resume the previous archived session, reviewing the recent completed turns that will be sent as context, writing a question, and sending it with the frozen screenshot. The composer stays open while the current turn streams so the user can inspect the reply inline and draft the next prompt without leaving the same surface.

**Frozen Annotation Layer**: A full-screen non-activating `NSPanel` can be opened from the composer to display the captured cursor screen under the composer. It accepts lightweight pen, rectangle, and ellipse annotations, can be hidden from its toolbar, and flattens those marks into the screenshot JPEG immediately before a prompt is sent.

**Session Archive Split**: Clicky now separates the persistent session archive from the transient AI context window. Full completed turns are saved as JSON session events, while only the most recent configured turns are shown in the composer sidebar and sent back to the model.

**Prompt Override Home**: Prompt files now follow a fixed `~/.clicky` home convention. Clicky reads `~/.clicky/prompts/*.md` on each request, seeds that folder with bundled defaults for direct editing, rewrites invalid prompt files back to the default template, and exposes the prompt directory from the settings panel for quick editing.

**Direct Endpoint Configuration**: Provider, endpoint URL, API key, and model ID are configured at runtime. Each provider keeps its own endpoint/model/API-key settings so users can switch between Anthropic and OpenAI without re-entering credentials.

## Key Files

| File | Lines | Purpose |
|------|-------|---------|
| `leanring_buddyApp.swift` | ~50 | Menu bar app entry point. Creates `CompanionManager`, launches the cursor overlay, and auto-opens the settings panel when configuration is incomplete. |
| `CompanionManager.swift` | ~1050 | Central text-first state machine. Owns prompt composer flow, frozen screenshot state, session restore/new-session behavior, temporary current-turn state, JSON-backed archive integration, provider-based response streaming, context-window derivation, and pointing state. |
| `PromptComposerOverlay.swift` | ~970 | Centered prompt composer overlay built with a key-capable `NSPanel`, a clickable session history sidebar, inline current-turn/detail cards, a restore chooser, and a custom multiline `NSTextView` bridge. |
| `FrozenScreenAnnotationOverlay.swift` | ~482 | Full-screen frozen screenshot annotation layer. Displays the captured screen, handles pen/rectangle/ellipse annotations, and renders annotations into the screenshot sent with a prompt. |
| `MenuBarPanelManager.swift` | ~236 | NSStatusItem + custom NSPanel lifecycle for the settings dropdown. |
| `CompanionPanelView.swift` | ~404 | SwiftUI settings panel. Edits provider-specific endpoint URL, API key, model ID, context turn count, the global shortcut, and actions for prompt overrides and session archives, and surfaces Screen Recording status. |
| `SessionArchiveStore.swift` | ~333 | JSON-backed session persistence layer. Stores active session metadata in `UserDefaults`, writes full completed conversation turns under `~/.clicky/sessions`, and migrates legacy Application Support archives on first use. |
| `ClickyHomePaths.swift` | ~42 | Shared path conventions for Clicky's `~/.clicky` home, prompt overrides, session archives, and legacy archive migration source. |
| `ClickyPromptStore.swift` | ~182 | Prompt resolver that prefers `~/.clicky/prompts` overrides and falls back to bundled Markdown defaults with validation. |
| `OverlayWindow.swift` | ~392 | Full-screen transparent overlay hosting the blue cursor, processing spinner, and pointing animation. |
| `CompanionScreenCaptureUtility.swift` | ~96 | Captures the current cursor screen with ScreenCaptureKit while excluding Clicky's own windows. |
| `ClaudeAPI.swift` | ~166 | Anthropic-compatible SSE client with runtime endpoint/API key/model configuration and TLS warmup. |
| `OpenAIAPI.swift` | ~170 | OpenAI-compatible chat completions streaming client with runtime endpoint/API key/model configuration and TLS warmup. |
| `ClickySettingsStore.swift` | ~230 | Runtime settings store for provider-specific endpoint URL, model ID, and API key-backed validation. Persists non-secret config to `UserDefaults`. |
| `KeychainSecretStore.swift` | ~80 | Minimal Keychain wrapper for storing the API key locally. |
| `KeyboardShortcutDefinitions.swift` | ~12 | Shared `KeyboardShortcuts` names used for the global composer shortcut. |
| `WindowPositionManager.swift` | ~266 | Screen Recording permission flow plus a few legacy window/accessibility helpers still used elsewhere in the codebase. |
| `worker/src/index.ts` | ~114 | Optional Cloudflare Worker proxy. Supports `/chat` and `/tts` routes for proxy-based deployments. |

## Build & Run

```bash
# Open in Xcode
open leanring-buddy.xcodeproj

# Select the leanring-buddy scheme, set signing team, Cmd+R to build and run

# The app now talks directly to either an Anthropic-compatible or OpenAI-compatible endpoint configured in the menu bar panel.
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
