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

private final class PromptComposerResizeContainerView: NSView {
    private let resizeHitThickness: CGFloat = 10
    private var resizeTrackingArea: NSTrackingArea?
    private var activeResizeEdges: ResizeEdges = []
    private var resizeStartMouseLocationInScreen: CGPoint = .zero
    private var resizeStartWindowFrame: CGRect = .zero

    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let resizeTrackingArea {
            removeTrackingArea(resizeTrackingArea)
        }

        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .inVisibleRect, .mouseMoved, .cursorUpdate],
            owner: self
        )
        addTrackingArea(trackingArea)
        resizeTrackingArea = trackingArea
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if !resizeEdges(at: point).isEmpty {
            return self
        }

        return super.hitTest(point)
    }

    override func cursorUpdate(with event: NSEvent) {
        updateResizeCursor(for: convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        updateResizeCursor(for: convert(event.locationInWindow, from: nil))
    }

    override func mouseDown(with event: NSEvent) {
        let resizeEdges = resizeEdges(at: convert(event.locationInWindow, from: nil))
        guard !resizeEdges.isEmpty, let window else {
            super.mouseDown(with: event)
            return
        }

        activeResizeEdges = resizeEdges
        resizeStartMouseLocationInScreen = NSEvent.mouseLocation
        resizeStartWindowFrame = window.frame
    }

    override func mouseDragged(with event: NSEvent) {
        guard !activeResizeEdges.isEmpty, let window else {
            super.mouseDragged(with: event)
            return
        }

        let currentMouseLocationInScreen = NSEvent.mouseLocation
        let mouseDelta = CGPoint(
            x: currentMouseLocationInScreen.x - resizeStartMouseLocationInScreen.x,
            y: currentMouseLocationInScreen.y - resizeStartMouseLocationInScreen.y
        )

        window.setFrame(
            resizedWindowFrame(
                from: resizeStartWindowFrame,
                mouseDelta: mouseDelta,
                resizeEdges: activeResizeEdges,
                minimumSize: window.minSize,
                maximumSize: window.maxSize
            ),
            display: true
        )
    }

    override func mouseUp(with event: NSEvent) {
        activeResizeEdges = []
    }

    private func updateResizeCursor(for point: NSPoint) {
        let resizeEdges = resizeEdges(at: point)

        if resizeEdges.contains(.left) || resizeEdges.contains(.right) {
            NSCursor.resizeLeftRight.set()
        } else if resizeEdges.contains(.top) || resizeEdges.contains(.bottom) {
            NSCursor.resizeUpDown.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    private func resizeEdges(at point: NSPoint) -> ResizeEdges {
        var resizeEdges: ResizeEdges = []

        if point.x <= resizeHitThickness {
            resizeEdges.insert(.left)
        } else if point.x >= bounds.width - resizeHitThickness {
            resizeEdges.insert(.right)
        }

        if point.y <= resizeHitThickness {
            resizeEdges.insert(.bottom)
        } else if point.y >= bounds.height - resizeHitThickness {
            resizeEdges.insert(.top)
        }

        return resizeEdges
    }

    private func resizedWindowFrame(
        from originalWindowFrame: CGRect,
        mouseDelta: CGPoint,
        resizeEdges: ResizeEdges,
        minimumSize: CGSize,
        maximumSize: CGSize
    ) -> CGRect {
        var resizedWindowFrame = originalWindowFrame

        if resizeEdges.contains(.left) {
            let resizedWidth = clamped(
                originalWindowFrame.width - mouseDelta.x,
                minimum: minimumSize.width,
                maximum: maximumSize.width
            )
            resizedWindowFrame.origin.x = originalWindowFrame.maxX - resizedWidth
            resizedWindowFrame.size.width = resizedWidth
        } else if resizeEdges.contains(.right) {
            resizedWindowFrame.size.width = clamped(
                originalWindowFrame.width + mouseDelta.x,
                minimum: minimumSize.width,
                maximum: maximumSize.width
            )
        }

        if resizeEdges.contains(.bottom) {
            let resizedHeight = clamped(
                originalWindowFrame.height - mouseDelta.y,
                minimum: minimumSize.height,
                maximum: maximumSize.height
            )
            resizedWindowFrame.origin.y = originalWindowFrame.maxY - resizedHeight
            resizedWindowFrame.size.height = resizedHeight
        } else if resizeEdges.contains(.top) {
            resizedWindowFrame.size.height = clamped(
                originalWindowFrame.height + mouseDelta.y,
                minimum: minimumSize.height,
                maximum: maximumSize.height
            )
        }

        return resizedWindowFrame
    }

    private func clamped(_ value: CGFloat, minimum: CGFloat, maximum: CGFloat) -> CGFloat {
        min(max(value, minimum), maximum)
    }

    private struct ResizeEdges: OptionSet {
        let rawValue: Int

        static let left = ResizeEdges(rawValue: 1 << 0)
        static let right = ResizeEdges(rawValue: 1 << 1)
        static let top = ResizeEdges(rawValue: 1 << 2)
        static let bottom = ResizeEdges(rawValue: 1 << 3)
    }
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

        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = NSRect(origin: .zero, size: panelSize)
        hostingView.autoresizingMask = [.width, .height]
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor

        let resizeContainerView = PromptComposerResizeContainerView(frame: NSRect(origin: .zero, size: panelSize))
        resizeContainerView.autoresizesSubviews = true
        resizeContainerView.addSubview(hostingView)

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
        promptPanel.contentView = resizeContainerView

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
    @State private var conversationHistorySidebarWidth: CGFloat = 236
    @State private var conversationHistorySidebarWidthAtDragStart: CGFloat?
    @State private var preferredConversationDetailCardHeight: CGFloat?
    @State private var conversationDetailCardHeightAtDragStart: CGFloat?

    private let splitHandleThickness: CGFloat = 10
    private let minimumComposerEditorHeight: CGFloat = 36
    private let minimumConversationDetailCardHeight: CGFloat = 96
    private let minimumConversationHistorySidebarWidth: CGFloat = 180
    private let maximumConversationHistorySidebarWidth: CGFloat = 360
    private let minimumComposerMainColumnWidth: CGFloat = 360

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        self._settingsStore = ObservedObject(wrappedValue: companionManager.settingsStore)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            composerHeader

            composerMainContent
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

    private var composerMainContent: some View {
        GeometryReader { geometryProxy in
            HStack(alignment: .top, spacing: 0) {
                ConversationHistorySidebar(companionManager: companionManager)
                    .frame(
                        width: clampedConversationHistorySidebarWidth(
                            conversationHistorySidebarWidth,
                            availableWidth: geometryProxy.size.width
                        )
                    )
                    .frame(maxHeight: .infinity)

                ComposerSplitHandle(
                    axis: .vertical,
                    onDragChanged: { dragTranslation in
                        if conversationHistorySidebarWidthAtDragStart == nil {
                            conversationHistorySidebarWidthAtDragStart = conversationHistorySidebarWidth
                        }

                        let startingSidebarWidth = conversationHistorySidebarWidthAtDragStart ?? conversationHistorySidebarWidth
                        conversationHistorySidebarWidth = clampedConversationHistorySidebarWidth(
                            startingSidebarWidth + dragTranslation.width,
                            availableWidth: geometryProxy.size.width
                        )
                    },
                    onDragEnded: {
                        conversationHistorySidebarWidthAtDragStart = nil
                    }
                )
                    .frame(width: splitHandleThickness)

                VStack(alignment: .leading, spacing: 12) {
                    composerPrimaryContent
                    composerFooter
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(
                width: geometryProxy.size.width,
                height: geometryProxy.size.height,
                alignment: .topLeading
            )
        }
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
                GeometryReader { geometryProxy in
                    VStack(alignment: .leading, spacing: 0) {
                        if let conversationTurnDetailDisplay {
                            ConversationTurnDetailCard(
                                detailDisplay: conversationTurnDetailDisplay,
                                onClose: companionManager.clearSelectedConversationHistorySelection
                            )
                            .frame(
                                height: conversationDetailCardHeight(
                                    availableHeight: geometryProxy.size.height
                                )
                            )

                            ComposerSplitHandle(
                                axis: .horizontal,
                                onDragChanged: { dragTranslation in
                                    if conversationDetailCardHeightAtDragStart == nil {
                                        conversationDetailCardHeightAtDragStart = conversationDetailCardHeight(
                                            availableHeight: geometryProxy.size.height
                                        )
                                    }

                                    let startingDetailCardHeight = conversationDetailCardHeightAtDragStart
                                        ?? conversationDetailCardHeight(availableHeight: geometryProxy.size.height)
                                    preferredConversationDetailCardHeight = clampedConversationDetailCardHeight(
                                        startingDetailCardHeight + dragTranslation.height,
                                        availableHeight: geometryProxy.size.height
                                    )
                                },
                                onDragEnded: {
                                    conversationDetailCardHeightAtDragStart = nil
                                }
                            )
                                .frame(height: splitHandleThickness)
                        }

                        composerEditor
                            .frame(minHeight: minimumComposerEditorHeight)
                    }
                    .frame(
                        width: geometryProxy.size.width,
                        height: geometryProxy.size.height,
                        alignment: .topLeading
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func clampedConversationHistorySidebarWidth(
        _ proposedSidebarWidth: CGFloat,
        availableWidth: CGFloat
    ) -> CGFloat {
        let maximumSidebarWidthAllowedByMainColumn = availableWidth
            - splitHandleThickness
            - minimumComposerMainColumnWidth
        let maximumUsableSidebarWidth = max(0, maximumSidebarWidthAllowedByMainColumn)
        let effectiveMaximumSidebarWidth = min(
            maximumConversationHistorySidebarWidth,
            max(minimumConversationHistorySidebarWidth, maximumUsableSidebarWidth)
        )
        let effectiveMinimumSidebarWidth = min(
            minimumConversationHistorySidebarWidth,
            effectiveMaximumSidebarWidth
        )

        return min(
            max(proposedSidebarWidth, effectiveMinimumSidebarWidth),
            effectiveMaximumSidebarWidth
        )
    }

    private func conversationDetailCardHeight(availableHeight: CGFloat) -> CGFloat {
        if let preferredConversationDetailCardHeight {
            return clampedConversationDetailCardHeight(
                preferredConversationDetailCardHeight,
                availableHeight: availableHeight
            )
        }

        return maximumConversationDetailCardHeight(availableHeight: availableHeight)
    }

    private func clampedConversationDetailCardHeight(
        _ proposedDetailCardHeight: CGFloat,
        availableHeight: CGFloat
    ) -> CGFloat {
        let effectiveMaximumDetailCardHeight = maximumConversationDetailCardHeight(
            availableHeight: availableHeight
        )
        let effectiveMinimumDetailCardHeight = min(
            minimumConversationDetailCardHeight,
            effectiveMaximumDetailCardHeight
        )

        return min(
            max(proposedDetailCardHeight, effectiveMinimumDetailCardHeight),
            effectiveMaximumDetailCardHeight
        )
    }

    private func maximumConversationDetailCardHeight(availableHeight: CGFloat) -> CGFloat {
        max(
            0,
            availableHeight
                - minimumComposerEditorHeight
                - splitHandleThickness
        )
    }

    private var conversationTurnDetailDisplay: ConversationTurnDetailDisplay? {
        if let currentConversationTurn = companionManager.currentConversationTurn,
           companionManager.isCurrentConversationTurnSelected {
            return ConversationTurnDetailDisplay(currentConversationTurn: currentConversationTurn)
        }

        if let selectedConversationTurnDetail = companionManager.selectedArchivedConversationTurnDetail,
           let selectedConversationTurnNumber = companionManager.selectedArchivedConversationTurnNumber {
            return ConversationTurnDetailDisplay(
                selectedConversationTurnNumber: selectedConversationTurnNumber,
                selectedConversationTurnDetail: selectedConversationTurnDetail
            )
        }

        return nil
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

private enum ComposerSplitHandleAxis {
    case vertical
    case horizontal

    var cursor: NSCursor {
        switch self {
        case .vertical:
            return .resizeLeftRight
        case .horizontal:
            return .resizeUpDown
        }
    }
}

private struct ComposerSplitHandle: View {
    let axis: ComposerSplitHandleAxis
    let onDragChanged: (CGSize) -> Void
    let onDragEnded: () -> Void

    var body: some View {
        ComposerSplitHandleRepresentable(
            axis: axis,
            onDragChanged: onDragChanged,
            onDragEnded: onDragEnded
        )
    }
}

private struct ComposerSplitHandleRepresentable: NSViewRepresentable {
    let axis: ComposerSplitHandleAxis
    let onDragChanged: (CGSize) -> Void
    let onDragEnded: () -> Void

    func makeNSView(context: Context) -> ComposerSplitHandleNSView {
        let view = ComposerSplitHandleNSView()
        view.axis = axis
        view.onDragChanged = onDragChanged
        view.onDragEnded = onDragEnded
        return view
    }

    func updateNSView(_ nsView: ComposerSplitHandleNSView, context: Context) {
        nsView.axis = axis
        nsView.onDragChanged = onDragChanged
        nsView.onDragEnded = onDragEnded
        nsView.needsDisplay = true
        nsView.window?.invalidateCursorRects(for: nsView)
    }
}

private final class ComposerSplitHandleNSView: NSView {
    var axis: ComposerSplitHandleAxis = .vertical
    var onDragChanged: ((CGSize) -> Void)?
    var onDragEnded: (() -> Void)?
    private var dragStartLocationInWindow: CGPoint?

    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: axis.cursor)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let markerSize = CGSize(
            width: axis == .vertical ? 1 : min(36, bounds.width),
            height: axis == .vertical ? min(36, bounds.height) : 1
        )
        let markerRect = CGRect(
            x: bounds.midX - markerSize.width / 2,
            y: bounds.midY - markerSize.height / 2,
            width: markerSize.width,
            height: markerSize.height
        )

        NSColor(DS.Colors.borderSubtle)
            .withAlphaComponent(0.65)
            .setFill()
        NSBezierPath(roundedRect: markerRect, xRadius: 1, yRadius: 1).fill()
    }

    override func mouseDown(with event: NSEvent) {
        dragStartLocationInWindow = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStartLocationInWindow else {
            return
        }

        let currentLocationInWindow = event.locationInWindow
        onDragChanged?(
            CGSize(
                width: currentLocationInWindow.x - dragStartLocationInWindow.x,
                height: dragStartLocationInWindow.y - currentLocationInWindow.y
            )
        )
    }

    override func mouseUp(with event: NSEvent) {
        dragStartLocationInWindow = nil
        onDragEnded?()
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

private struct ConversationTurnDetailCard: View {
    let detailDisplay: ConversationTurnDetailDisplay
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(detailDisplay.titleText)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)

                    Text(detailDisplay.subtitleText)
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

            ConversationTurnTranscriptTextView(
                transcriptIdentity: detailDisplay.transcriptIdentity,
                userPromptText: detailDisplay.userPromptText,
                assistantResponseText: detailDisplay.assistantResponseText,
                assistantResponseTone: detailDisplay.assistantResponseTone
            )
            .frame(maxHeight: .infinity)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

private struct ConversationTurnDetailDisplay {
    let transcriptIdentity: String
    let titleText: String
    let subtitleText: String
    let userPromptText: String
    let assistantResponseText: String
    let assistantResponseTone: ConversationTurnTranscriptResponseTone

    init(currentConversationTurn: CurrentConversationTurn) {
        transcriptIdentity = "current-turn"
        titleText = "Current Turn"
        userPromptText = currentConversationTurn.promptText
        assistantResponseText = currentConversationTurn.responseText

        switch currentConversationTurn.phase {
        case .processing:
            subtitleText = "Preparing the screenshot request for this unsaved turn."
            assistantResponseTone = .normal
        case .streaming:
            subtitleText = "Streaming the latest reply. This turn will join session history only after it finishes."
            assistantResponseTone = .normal
        case .completed:
            subtitleText = "Reply received, but this turn is still temporary until it can be saved."
            assistantResponseTone = .normal
        case .failed:
            subtitleText = "This turn failed and was not added to session history."
            assistantResponseTone = .error
        }
    }

    init(
        selectedConversationTurnNumber: Int,
        selectedConversationTurnDetail: ClickyConversationTurnRecord
    ) {
        transcriptIdentity = selectedConversationTurnDetail.turnID.uuidString
        titleText = "Turn \(selectedConversationTurnNumber)"
        subtitleText = "Reviewing the full saved exchange for this context turn."
        userPromptText = selectedConversationTurnDetail.userPromptText
        assistantResponseText = selectedConversationTurnDetail.assistantResponseText
        assistantResponseTone = .normal
    }
}

private enum ConversationTurnTranscriptResponseTone: Equatable {
    case normal
    case error

    var color: NSColor {
        switch self {
        case .normal:
            return NSColor(DS.Colors.info)
        case .error:
            return NSColor(DS.Colors.destructiveText)
        }
    }
}

private struct ConversationTurnTranscriptTextView: NSViewRepresentable {
    let transcriptIdentity: String
    let userPromptText: String
    let assistantResponseText: String
    let assistantResponseTone: ConversationTurnTranscriptResponseTone

    private var plainTranscriptText: String {
        "You\n\(userPromptText)\n\nClicky\n\(assistantResponseText)"
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let textView = NSTextView()
        textView.drawsBackground = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsUndo = false
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: .greatestFiniteMagnitude
        )
        textView.insertionPointColor = NSColor(DS.Colors.textPrimary)

        scrollView.documentView = textView
        updateTextView(textView, in: scrollView, context: context)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        updateTextView(textView, in: nsView, context: context)
    }

    private func updateTextView(
        _ textView: NSTextView,
        in scrollView: NSScrollView,
        context: Context
    ) {
        let updatedPlainTranscriptText = plainTranscriptText
        let isFirstTranscriptRender = context.coordinator.lastTranscriptIdentity == nil
        let didTranscriptChange = context.coordinator.lastPlainTranscriptText != updatedPlainTranscriptText
            || context.coordinator.lastAssistantResponseTone != assistantResponseTone
        let didSwitchToDifferentTranscript = context.coordinator.lastTranscriptIdentity != nil
            && context.coordinator.lastTranscriptIdentity != transcriptIdentity
            && context.coordinator.lastPlainTranscriptText != updatedPlainTranscriptText

        guard didTranscriptChange else {
            context.coordinator.lastTranscriptIdentity = transcriptIdentity
            return
        }

        let clipView = scrollView.contentView
        let previousVisibleOrigin = clipView.bounds.origin

        textView.textStorage?.setAttributedString(attributedTranscript())
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: .greatestFiniteMagnitude
        )

        context.coordinator.lastTranscriptIdentity = transcriptIdentity
        context.coordinator.lastPlainTranscriptText = updatedPlainTranscriptText
        context.coordinator.lastAssistantResponseTone = assistantResponseTone

        DispatchQueue.main.async {
            if isFirstTranscriptRender || didSwitchToDifferentTranscript {
                clipView.scroll(to: .zero)
            } else {
                clipView.scroll(to: clampedVisibleOrigin(previousVisibleOrigin, in: scrollView))
            }
            scrollView.reflectScrolledClipView(clipView)
        }
    }

    private func attributedTranscript() -> NSAttributedString {
        let transcript = NSMutableAttributedString()
        let speakerParagraphStyle = NSMutableParagraphStyle()
        speakerParagraphStyle.lineSpacing = 0
        speakerParagraphStyle.paragraphSpacing = 0

        let bodyParagraphStyle = NSMutableParagraphStyle()
        bodyParagraphStyle.lineSpacing = 0
        bodyParagraphStyle.paragraphSpacing = 0

        append(
            "You\n",
            to: transcript,
            font: .systemFont(ofSize: 11, weight: .semibold),
            color: NSColor(DS.Colors.accentText),
            paragraphStyle: speakerParagraphStyle
        )
        append(
            userPromptText + "\n\n",
            to: transcript,
            font: .systemFont(ofSize: 12),
            color: NSColor(DS.Colors.textPrimary),
            paragraphStyle: bodyParagraphStyle
        )
        append(
            "Clicky\n",
            to: transcript,
            font: .systemFont(ofSize: 11, weight: .semibold),
            color: assistantResponseTone.color,
            paragraphStyle: speakerParagraphStyle
        )
        append(
            assistantResponseText,
            to: transcript,
            font: .systemFont(ofSize: 12),
            color: NSColor(DS.Colors.textPrimary),
            paragraphStyle: bodyParagraphStyle
        )

        return transcript
    }

    private func append(
        _ string: String,
        to transcript: NSMutableAttributedString,
        font: NSFont,
        color: NSColor,
        paragraphStyle: NSParagraphStyle
    ) {
        transcript.append(
            NSAttributedString(
                string: string,
                attributes: [
                    .font: font,
                    .foregroundColor: color,
                    .paragraphStyle: paragraphStyle
                ]
            )
        )
    }

    private func clampedVisibleOrigin(_ visibleOrigin: CGPoint, in scrollView: NSScrollView) -> CGPoint {
        guard let documentView = scrollView.documentView else {
            return .zero
        }

        let maximumY = max(0, documentView.bounds.height - scrollView.contentView.bounds.height)
        return CGPoint(
            x: 0,
            y: min(max(0, visibleOrigin.y), maximumY)
        )
    }

    final class Coordinator {
        var lastTranscriptIdentity: String?
        var lastPlainTranscriptText: String?
        var lastAssistantResponseTone: ConversationTurnTranscriptResponseTone?
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
