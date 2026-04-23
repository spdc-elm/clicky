//
//  PromptComposerOverlay.swift
//  leanring-buddy
//
//  Centered prompt composer overlay shown when the user triggers the global shortcut.
//

import AppKit
import SwiftUI

private final class FocusableOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PromptComposerPanelManager: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private var clickOutsideMonitor: Any?
    private let companionManager: CompanionManager
    private var panelSize = CGSize(width: 860, height: 420)
    private let minimumPanelSize = CGSize(width: 720, height: 340)
    private let maximumPanelSize = CGSize(width: 1080, height: 700)

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        super.init()
    }

    var isVisible: Bool {
        panel?.isVisible == true
    }

    func show(on screen: NSScreen?) {
        if panel == nil {
            createPanel()
        }

        guard let panel else { return }
        positionPanel(panel, on: screen)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        installClickOutsideMonitor()
        companionManager.requestPromptEditorFocus()
    }

    func bringToFront() {
        guard let panel, panel.isVisible else { return }
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        companionManager.requestPromptEditorFocus()
    }

    func hide() {
        panel?.orderOut(nil)
        removeClickOutsideMonitor()
    }

    private func createPanel() {
        let rootView = PromptComposerView(companionManager: companionManager)
            .frame(width: panelSize.width, height: panelSize.height)

        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = NSRect(origin: .zero, size: panelSize)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor

        let promptPanel = FocusableOverlayPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )

        promptPanel.level = .statusBar
        promptPanel.isFloatingPanel = true
        promptPanel.isOpaque = false
        promptPanel.backgroundColor = .clear
        promptPanel.hasShadow = false
        promptPanel.hidesOnDeactivate = false
        promptPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        promptPanel.isMovableByWindowBackground = true
        promptPanel.titleVisibility = .hidden
        promptPanel.titlebarAppearsTransparent = true
        promptPanel.minSize = minimumPanelSize
        promptPanel.maxSize = maximumPanelSize
        promptPanel.delegate = self
        promptPanel.contentView = hostingView

        self.panel = promptPanel
    }

    private func positionPanel(_ panel: NSPanel, on screen: NSScreen?) {
        let targetScreen = screen ?? NSScreen.main
        let visibleFrame = targetScreen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero

        let origin = CGPoint(
            x: visibleFrame.midX - (panelSize.width / 2),
            y: visibleFrame.midY - (panelSize.height / 2)
        )

        panel.setFrame(NSRect(origin: origin, size: panelSize), display: true)
    }

    func windowDidResize(_ notification: Notification) {
        guard let resizedPanel = notification.object as? NSPanel else { return }
        panelSize = resizedPanel.frame.size
    }

    private func installClickOutsideMonitor() {
        removeClickOutsideMonitor()

        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, let panel = self.panel, panel.isVisible else { return }
            let clickLocation = NSEvent.mouseLocation
            guard !panel.frame.contains(clickLocation) else { return }
            guard !self.companionManager.hasFrozenScreenCapture else { return }
            self.companionManager.dismissPromptComposer()
        }
    }

    private func removeClickOutsideMonitor() {
        if let clickOutsideMonitor {
            NSEvent.removeMonitor(clickOutsideMonitor)
            self.clickOutsideMonitor = nil
        }
    }
}

private struct PromptComposerView: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject private var settingsStore: ClickySettingsStore

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        self._settingsStore = ObservedObject(wrappedValue: companionManager.settingsStore)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            composerHeader

            HStack(alignment: .top, spacing: 12) {
                ConversationHistorySidebar(companionManager: companionManager)
                    .frame(width: 236)
                    .frame(maxHeight: .infinity)

                VStack(alignment: .leading, spacing: 12) {
                    composerPrimaryContent
                    composerFooter
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(DS.Colors.surface1.opacity(0.98))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(DS.Colors.borderSubtle, lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.35), radius: 18, x: 0, y: 10)
        )
    }

    private var composerHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("Ask Clicky")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)

                Text("Type a prompt. Clicky froze your current screen when this opened.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
            }

            Spacer()

            Text("Drag to move or resize")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)

            Button(action: companionManager.showFrozenScreenAnnotationEditor) {
                Image(systemName: "square.and.pencil")
            }
            .dsIconButtonStyle(size: 24)
            .nativeTooltip("Edit screenshot")
            .pointerCursor(isEnabled: companionManager.hasFrozenScreenCapture)
            .disabled(!companionManager.hasFrozenScreenCapture)

            Button(action: companionManager.dismissPromptComposer) {
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
    }

    private var composerPrimaryContent: some View {
        Group {
            if companionManager.needsSessionRestoreDecision {
                SessionRestoreDecisionCard(companionManager: companionManager)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    if let currentConversationTurn = companionManager.currentConversationTurn,
                       companionManager.isCurrentConversationTurnSelected {
                        CurrentConversationTurnDetailCard(
                            currentConversationTurn: currentConversationTurn,
                            onClose: companionManager.clearSelectedConversationHistorySelection
                        )
                    } else if let selectedConversationTurnDetail = companionManager.selectedArchivedConversationTurnDetail,
                              let selectedConversationTurnNumber = companionManager.selectedArchivedConversationTurnNumber {
                        ConversationTurnDetailCard(
                            selectedConversationTurnNumber: selectedConversationTurnNumber,
                            selectedConversationTurnDetail: selectedConversationTurnDetail,
                            onClose: companionManager.clearSelectedConversationHistorySelection
                        )
                    }

                    composerEditor
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var composerEditor: some View {
        ZStack(alignment: .topLeading) {
            PromptComposerTextEditor(
                text: $companionManager.promptDraft,
                focusToken: companionManager.promptEditorFocusToken,
                onSubmit: companionManager.sendCurrentPromptDraft,
                onCancel: companionManager.dismissPromptComposer
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(DS.Colors.surface2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(
                        companionManager.composerValidationMessage == nil ? DS.Colors.borderSubtle : DS.Colors.destructive,
                        lineWidth: 1
                    )
            )

            if companionManager.promptDraft.isEmpty {
                Text("Ask about the code, the command output, or whatever is on screen...")
                    .font(.system(size: 13))
                    .foregroundColor(DS.Colors.textTertiary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var composerFooter: some View {
        HStack(alignment: .center, spacing: 12) {
            footerStatusText

            Spacer()

            Button(action: companionManager.dismissPromptComposer) {
                Text("Cancel")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        Capsule()
                            .stroke(DS.Colors.borderSubtle, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .pointerCursor()

            if !companionManager.needsSessionRestoreDecision {
                Button(action: companionManager.sendCurrentPromptDraft) {
                    Text(companionManager.interfaceState == .streaming ? "Streaming..." : "Send")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(
                            Capsule()
                                .fill(companionManager.canSubmitCurrentPromptDraft ? DS.Colors.accent : DS.Colors.accent.opacity(0.4))
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .disabled(!companionManager.canSubmitCurrentPromptDraft)
            }
        }
    }

    @ViewBuilder
    private var footerStatusText: some View {
        if let composerValidationMessage = companionManager.composerValidationMessage {
            Text(composerValidationMessage)
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.destructiveText)
                .fixedSize(horizontal: false, vertical: true)
        } else if companionManager.needsSessionRestoreDecision {
            Text("Choose whether to resume the previous session before writing a new prompt.")
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textTertiary)
        } else if companionManager.interfaceState == .processing || companionManager.interfaceState == .streaming {
            Text("Current reply is still in progress. You can draft the next prompt, but Send stays disabled until this round finishes.")
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textTertiary)
        } else {
            Text("Enter adds a new line. Command+Enter sends.")
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textTertiary)
        }
    }
}

private struct ConversationHistorySidebar: View {
    @ObservedObject var companionManager: CompanionManager

    private var conversationHistorySidebarItems: [ConversationHistorySidebarItem] {
        companionManager.conversationHistorySidebarItems
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Session Context")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)

                    Text(historySidebarSummaryText)
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !companionManager.needsSessionRestoreDecision {
                    Button(action: companionManager.startNewSession) {
                        HStack(spacing: 8) {
                            Image(systemName: "plus")
                                .font(.system(size: 11, weight: .semibold))
                            Text("New Session")
                                .font(.system(size: 12, weight: .semibold))
                            Spacer()
                        }
                        .foregroundColor(DS.Colors.textSecondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(DS.Colors.surface3)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .stroke(DS.Colors.borderSubtle, lineWidth: 1)
                                )
                        )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .disabled(!companionManager.canStartNewSession)
                }
            }

            Group {
                if conversationHistorySidebarItems.isEmpty {
                    emptyHistoryState
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(conversationHistorySidebarItems) { sidebarItem in
                                sidebarItemButton(for: sidebarItem)
                            }
                        }
                        .padding(.trailing, 2)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(DS.Colors.surface2)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(DS.Colors.borderSubtle.opacity(0.75), lineWidth: 1)
                )
        )
    }

    private var emptyHistoryState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(emptyHistoryTitleText)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(DS.Colors.textSecondary)

            Text(emptyHistoryBodyText)
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(DS.Colors.surface1.opacity(0.92))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(DS.Colors.borderSubtle.opacity(0.75), lineWidth: 1)
                )
        )
    }

    private var historySidebarSummaryText: String {
        if companionManager.needsSessionRestoreDecision {
            return "Choose whether to resume the previous session before loading any session context."
        }

        if companionManager.currentConversationTurn != nil && companionManager.recentConversationHistoryPreviewTurns.isEmpty {
            return "Current Turn is still temporary and stays out of session context until the round is saved."
        }

        if companionManager.recentConversationHistoryPreviewTurns.isEmpty {
            return "Your next request will start with a fresh context."
        }

        let contextTurnLimit = companionManager.settingsStore.conversationContextTurnLimit
        if companionManager.currentConversationTurn != nil {
            return "Current Turn is unsaved. Only the completed turns below count toward Clicky's latest \(contextTurnLimit)-turn context."
        }

        return "These completed turns are the latest \(contextTurnLimit)-turn context Clicky will include with your next request."
    }

    private var emptyHistoryTitleText: String {
        if companionManager.needsSessionRestoreDecision {
            return "Previous session available."
        }

        return "No completed turns yet."
    }

    private var emptyHistoryBodyText: String {
        if companionManager.needsSessionRestoreDecision {
            return "Resume the previous session to bring its saved context back, or start a fresh session instead."
        }

        return "Drafts and streaming replies stay out of session context until the round finishes."
    }

    @ViewBuilder
    private func sidebarItemButton(for sidebarItem: ConversationHistorySidebarItem) -> some View {
        switch sidebarItem {
        case .currentTurn(let previewTurn):
            Button(action: companionManager.selectCurrentConversationTurn) {
                CurrentConversationHistoryTurnPreviewCard(
                    previewTurn: previewTurn,
                    isSelected: companionManager.isCurrentConversationTurnSelected
                )
            }
            .buttonStyle(.plain)
            .pointerCursor()
        case .archivedTurn(let previewTurn):
            Button(action: {
                companionManager.selectArchivedConversationTurn(turnID: previewTurn.turnID)
            }) {
                ConversationHistoryTurnPreviewCard(
                    previewTurn: previewTurn,
                    isSelected: companionManager.selectedConversationHistorySelection == .archivedTurn(previewTurn.turnID)
                )
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
    }
}

private struct CurrentConversationHistoryTurnPreviewCard: View {
    let previewTurn: CurrentConversationPreviewTurn
    let isSelected: Bool

    private var statusText: String {
        switch previewTurn.phase {
        case .processing:
            return "Capturing screen"
        case .streaming:
            return "Streaming reply"
        case .completed:
            return "Unsaved reply"
        case .failed:
            return "Reply failed"
        }
    }

    private var statusColor: Color {
        switch previewTurn.phase {
        case .processing, .streaming:
            return DS.Colors.accentText
        case .completed:
            return DS.Colors.warningText
        case .failed:
            return DS.Colors.destructiveText
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Current Turn")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)

                Spacer()

                Text(statusText)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(statusColor)
            }

            ConversationHistorySpeakerPreview(
                speakerLabel: "You",
                previewText: previewTurn.promptPreviewText,
                speakerColor: DS.Colors.accentText
            )

            Divider()
                .overlay(DS.Colors.borderSubtle.opacity(0.6))

            ConversationHistorySpeakerPreview(
                speakerLabel: "Clicky",
                previewText: previewTurn.responsePreviewText,
                speakerColor: statusColor
            )
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? DS.Colors.surface3 : DS.Colors.surface1.opacity(0.92))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(
                            isSelected ? DS.Colors.accent : statusColor.opacity(0.6),
                            lineWidth: 1
                        )
                )
        )
    }
}

private struct ConversationHistoryTurnPreviewCard: View {
    let previewTurn: ConversationHistoryPreviewTurn
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Turn \(previewTurn.turnNumber)")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(DS.Colors.textTertiary)

            ConversationHistorySpeakerPreview(
                speakerLabel: "You",
                previewText: previewTurn.userPreviewText,
                speakerColor: DS.Colors.accentText
            )

            Divider()
                .overlay(DS.Colors.borderSubtle.opacity(0.6))

            ConversationHistorySpeakerPreview(
                speakerLabel: "Clicky",
                previewText: previewTurn.assistantPreviewText,
                speakerColor: DS.Colors.info
            )
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? DS.Colors.surface3 : DS.Colors.surface1.opacity(0.92))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(
                            isSelected ? DS.Colors.accent : DS.Colors.borderSubtle.opacity(0.75),
                            lineWidth: 1
                        )
                )
        )
    }
}

private struct ConversationHistorySpeakerPreview: View {
    let speakerLabel: String
    let previewText: String
    let speakerColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(speakerLabel)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(speakerColor)

            Text(previewText)
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct CurrentConversationTurnDetailCard: View {
    let currentConversationTurn: CurrentConversationTurn
    let onClose: () -> Void

    private var subtitleText: String {
        switch currentConversationTurn.phase {
        case .processing:
            return "Preparing the screenshot request for this unsaved turn."
        case .streaming:
            return "Streaming the latest reply. This turn will join session history only after it finishes."
        case .completed:
            return "Reply received, but this turn is still temporary until it can be saved."
        case .failed:
            return "This turn failed and was not added to session history."
        }
    }

    private var responseSpeakerColor: Color {
        switch currentConversationTurn.phase {
        case .failed:
            return DS.Colors.destructiveText
        default:
            return DS.Colors.info
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Current Turn")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)

                    Text(subtitleText)
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                }

                Spacer()

                Button(action: onClose) {
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

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ConversationTurnDetailSection(
                        speakerLabel: "You",
                        contentText: currentConversationTurn.promptText,
                        speakerColor: DS.Colors.accentText
                    )

                    Divider()
                        .overlay(DS.Colors.borderSubtle.opacity(0.6))

                    ConversationTurnDetailSection(
                        speakerLabel: "Clicky",
                        contentText: currentConversationTurn.responseText,
                        speakerColor: responseSpeakerColor
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 180)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(DS.Colors.surface2)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(DS.Colors.borderSubtle.opacity(0.75), lineWidth: 1)
                )
        )
    }
}

private struct ConversationTurnDetailCard: View {
    let selectedConversationTurnNumber: Int
    let selectedConversationTurnDetail: ClickyConversationTurnRecord
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Turn \(selectedConversationTurnNumber)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)

                    Text("Reviewing the full saved exchange for this context turn.")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                }

                Spacer()

                Button(action: onClose) {
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

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ConversationTurnDetailSection(
                        speakerLabel: "You",
                        contentText: selectedConversationTurnDetail.userPromptText,
                        speakerColor: DS.Colors.accentText
                    )

                    Divider()
                        .overlay(DS.Colors.borderSubtle.opacity(0.6))

                    ConversationTurnDetailSection(
                        speakerLabel: "Clicky",
                        contentText: selectedConversationTurnDetail.assistantResponseText,
                        speakerColor: DS.Colors.info
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 180)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(DS.Colors.surface2)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(DS.Colors.borderSubtle.opacity(0.75), lineWidth: 1)
                )
        )
    }
}

private struct ConversationTurnDetailSection: View {
    let speakerLabel: String
    let contentText: String
    let speakerColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(speakerLabel)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(speakerColor)

            Text(contentText)
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct SessionRestoreDecisionCard: View {
    @ObservedObject var companionManager: CompanionManager

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Previous Session Found")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)

                Text(sessionRestoreSummaryText)
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Resume the saved session context, or start a brand-new session and leave the old archive untouched.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Button(action: companionManager.resumePendingSession) {
                    Text("Resume Last Session")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(
                            Capsule()
                                .fill(DS.Colors.accent)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()

                Button(action: companionManager.startNewSession) {
                    Text("Start New Session")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(
                            Capsule()
                                .stroke(DS.Colors.borderSubtle, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(DS.Colors.surface2)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(DS.Colors.borderSubtle.opacity(0.75), lineWidth: 1)
                )
        )
    }

    private var sessionRestoreSummaryText: String {
        if companionManager.recoverableSessionTurnCount == 0 {
            return "You have a saved empty session from the last launch."
        }

        if companionManager.recoverableSessionTurnCount == 1 {
            return "You have 1 saved completed turn ready to resume."
        }

        return "You have \(companionManager.recoverableSessionTurnCount) saved completed turns ready to resume."
    }
}

private struct PromptComposerTextEditor: NSViewRepresentable {
    @Binding var text: String
    let focusToken: Int
    let onSubmit: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let textView = PromptNSTextView()
        textView.promptDelegate = context.coordinator
        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: 14)
        textView.textColor = .white
        textView.insertionPointColor = .white
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.delegate = context.coordinator
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: scrollView.contentSize.width, height: .greatestFiniteMagnitude)
        textView.string = text
        textView.onCommandReturn = onSubmit
        textView.onEscape = onCancel

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? PromptNSTextView else { return }

        if textView.string != text {
            textView.string = text
        }

        textView.onCommandReturn = onSubmit
        textView.onEscape = onCancel

        if context.coordinator.lastFocusToken != focusToken {
            context.coordinator.lastFocusToken = focusToken
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate, PromptNSTextViewDelegate {
        @Binding var text: String
        var lastFocusToken = -1

        init(text: Binding<String>) {
            self._text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text = textView.string
        }

        func promptTextViewDidPressCommandReturn() {}
        func promptTextViewDidPressEscape() {}
    }
}

private protocol PromptNSTextViewDelegate: AnyObject {
    func promptTextViewDidPressCommandReturn()
    func promptTextViewDidPressEscape()
}

private final class PromptNSTextView: NSTextView {
    weak var promptDelegate: PromptNSTextViewDelegate?
    var onCommandReturn: (() -> Void)?
    var onEscape: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            promptDelegate?.promptTextViewDidPressEscape()
            onEscape?()
            return
        }

        let isReturnKey = event.keyCode == 36 || event.keyCode == 76
        if isReturnKey && event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command) {
            promptDelegate?.promptTextViewDidPressCommandReturn()
            onCommandReturn?()
            return
        }

        super.keyDown(with: event)
    }
}
