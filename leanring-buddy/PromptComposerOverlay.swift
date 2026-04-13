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
    private var panelSize = CGSize(width: 640, height: 320)
    private let minimumPanelSize = CGSize(width: 520, height: 260)
    private let maximumPanelSize = CGSize(width: 900, height: 560)

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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Ask Clicky")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)

                    Text("Type a prompt. Clicky will capture your current screen when you send.")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                }

                Spacer()

                Text("Drag to move or resize")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)

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
                        .stroke(companionManager.composerValidationMessage == nil ? DS.Colors.borderSubtle : DS.Colors.destructive, lineWidth: 1)
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

            HStack(alignment: .center, spacing: 12) {
                if let composerValidationMessage = companionManager.composerValidationMessage {
                    Text(composerValidationMessage)
                        .font(.system(size: 12))
                        .foregroundColor(DS.Colors.destructiveText)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Enter adds a new line. Command+Enter sends.")
                        .font(.system(size: 12))
                        .foregroundColor(DS.Colors.textTertiary)
                }

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

                Button(action: companionManager.sendCurrentPromptDraft) {
                    Text("Send")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(
                            Capsule()
                                .fill(companionManager.canSendPromptDraft ? DS.Colors.accent : DS.Colors.accent.opacity(0.4))
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .disabled(!companionManager.canSendPromptDraft)
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
