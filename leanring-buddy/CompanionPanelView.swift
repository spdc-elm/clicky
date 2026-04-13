//
//  CompanionPanelView.swift
//  leanring-buddy
//
//  Lean settings panel for configuring Clicky's direct Anthropic-compatible workflow.
//

import KeyboardShortcuts
import SwiftUI

struct CompanionPanelView: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject private var settingsStore: ClickySettingsStore

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        self._settingsStore = ObservedObject(wrappedValue: companionManager.settingsStore)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()
                .background(DS.Colors.borderSubtle)
                .padding(.horizontal, 16)

            content
                .padding(16)

            Divider()
                .background(DS.Colors.borderSubtle)
                .padding(.horizontal, 16)

            footer
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
        .frame(width: 360)
        .background(panelBackground)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(statusDotColor)
                        .frame(width: 8, height: 8)
                        .shadow(color: statusDotColor.opacity(0.6), radius: 4)

                    Text("Clicky")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                }

                Text(companionManager.statusText)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
            }

            Spacer()

            Button(action: {
                NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 20, height: 20)
                    .background(
                        Circle()
                            .fill(Color.white.opacity(0.08))
                    )
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Endpoint")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)

                TextField(
                    "https://api.anthropic.com or a full /v1/messages URL",
                    text: Binding(
                        get: { settingsStore.endpointURLString },
                        set: { settingsStore.endpointURLString = $0 }
                    )
                )
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(DS.Colors.textPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(inputBackground)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("API Key")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)

                SecureField(
                    "sk-ant-...",
                    text: Binding(
                        get: { settingsStore.apiKey },
                        set: { settingsStore.apiKey = $0 }
                    )
                )
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundColor(DS.Colors.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(inputBackground)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Model")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)

                TextField(
                    "claude-sonnet-4-6",
                    text: Binding(
                        get: { settingsStore.modelID },
                        set: { settingsStore.modelID = $0 }
                    )
                )
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundColor(DS.Colors.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(inputBackground)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Shortcut")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)

                KeyboardShortcuts.Recorder("Record Shortcut", name: .openPromptComposer)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(inputBackground)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Context Turns")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)

                TextField(
                    "4",
                    value: Binding(
                        get: { settingsStore.conversationContextTurnLimit },
                        set: { settingsStore.conversationContextTurnLimit = $0 }
                    ),
                    format: .number
                )
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(DS.Colors.textPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(inputBackground)

                helperCopy(
                    "Controls how many completed turns Clicky sends as AI context and previews in Session Context. Full session archives keep every saved turn."
                )
            }

            if !companionManager.hasScreenRecordingPermission {
                permissionWarning
            } else if !settingsStore.isConfigurationComplete {
                helperCopy("Fill in the endpoint, API key, and model, then use your shortcut to open the prompt composer.")
            } else if !settingsStore.hasConfiguredShortcut {
                helperCopy("Record a shortcut so you can open the prompt composer from anywhere.")
            } else {
                helperCopy("Clicky will capture your current cursor screen only when you send a prompt.")
            }
        }
    }

    private var permissionWarning: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Screen Recording Required")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(DS.Colors.warningText)

            Text("Grant Screen Recording so Clicky can attach your current screen when you send a prompt.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Button(action: {
                _ = WindowPositionManager.requestScreenRecordingPermission()
                companionManager.refreshPermissions()
            }) {
                Text("Grant Screen Recording")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Colors.textOnAccent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(
                        Capsule()
                            .fill(DS.Colors.accent)
                    )
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(DS.Colors.surface2)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(DS.Colors.warningText.opacity(0.45), lineWidth: 1)
                )
        )
    }

    private func helperCopy(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundColor(DS.Colors.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var footer: some View {
        HStack {
            Text("Anthropic-compatible endpoint")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)

            Spacer()

            Button(action: {
                NSApplication.shared.terminate(nil)
            }) {
                Text("Quit")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
    }

    private var inputBackground: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(DS.Colors.surface2)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 1)
            )
    }

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(DS.Colors.surface1.opacity(0.98))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.24), radius: 16, x: 0, y: 10)
    }

    private var statusDotColor: Color {
        if !settingsStore.isConfigurationComplete || !settingsStore.hasConfiguredShortcut {
            return DS.Colors.warningText
        }

        if !companionManager.hasScreenRecordingPermission {
            return DS.Colors.warning
        }

        switch companionManager.interfaceState {
        case .idle:
            return DS.Colors.success
        case .composing:
            return DS.Colors.info
        case .processing, .streaming:
            return DS.Colors.accent
        }
    }
}
