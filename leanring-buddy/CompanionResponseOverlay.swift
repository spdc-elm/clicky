//
//  CompanionResponseOverlay.swift
//  leanring-buddy
//
//  Anchored response panel for streaming AI output.
//

import AppKit
import Combine
import SwiftUI

private final class FocusableResponsePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class CompanionResponseOverlayViewModel: ObservableObject {
    @Published var responseText: String = ""
    @Published var isStreamingResponse = false
    @Published var responseIdentifier = UUID()
}

@MainActor
final class CompanionResponseOverlayManager: NSObject, NSWindowDelegate {
    private let overlayViewModel = CompanionResponseOverlayViewModel()
    private var overlayPanel: NSPanel?
    private var targetScreen: NSScreen?
    private var currentResponseIdentifier = UUID()
    private var panelSize = CGSize(width: 680, height: 320)
    private let minimumPanelSize = CGSize(width: 440, height: 220)

    func beginStreaming(on screen: NSScreen) {
        currentResponseIdentifier = UUID()
        overlayViewModel.responseText = ""
        overlayViewModel.isStreamingResponse = true
        overlayViewModel.responseIdentifier = currentResponseIdentifier
        targetScreen = screen
        createOverlayPanelIfNeeded()
        resizeAndPositionPanel()
        overlayPanel?.alphaValue = 1
        overlayPanel?.orderFrontRegardless()
    }

    func updateStreamingText(_ responseText: String) {
        overlayViewModel.responseText = responseText
    }

    func finishStreaming(finalText: String) {
        overlayViewModel.responseText = finalText
        overlayViewModel.isStreamingResponse = false
    }

    func presentError(_ errorText: String, on screen: NSScreen) {
        beginStreaming(on: screen)
        overlayViewModel.responseText = errorText
        overlayViewModel.isStreamingResponse = false
    }

    func hideOverlay() {
        overlayPanel?.orderOut(nil)
        overlayViewModel.responseText = ""
        overlayViewModel.isStreamingResponse = false
    }

    private func createOverlayPanelIfNeeded() {
        guard overlayPanel == nil else { return }

        let responseOverlayPanel = FocusableResponsePanel(
            contentRect: CGRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )

        responseOverlayPanel.level = .statusBar
        responseOverlayPanel.isOpaque = false
        responseOverlayPanel.backgroundColor = .clear
        responseOverlayPanel.hasShadow = false
        responseOverlayPanel.hidesOnDeactivate = false
        responseOverlayPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        responseOverlayPanel.isExcludedFromWindowsMenu = true
        responseOverlayPanel.isMovableByWindowBackground = true
        responseOverlayPanel.minSize = minimumPanelSize
        responseOverlayPanel.delegate = self

        let hostingView = NSHostingView(
            rootView: CompanionResponseOverlayView(
                viewModel: overlayViewModel,
                onClose: { [weak self] in
                    self?.hideOverlay()
                }
            )
        )

        responseOverlayPanel.contentView = hostingView
        overlayPanel = responseOverlayPanel
    }

    private func resizeAndPositionPanel() {
        guard let overlayPanel, let targetScreen else { return }

        let visibleFrame = targetScreen.visibleFrame
        let panelWidth = min(panelSize.width, visibleFrame.width * 0.82)
        let panelHeight = min(panelSize.height, visibleFrame.height * 0.6)
        let verticalMargin: CGFloat = 20

        let panelOriginY = visibleFrame.minY + verticalMargin
        let panelOriginX = visibleFrame.midX - (panelWidth / 2)
        let panelFrame = CGRect(x: panelOriginX, y: panelOriginY, width: panelWidth, height: panelHeight)
        overlayPanel.setFrame(panelFrame, display: true)
        overlayPanel.contentView?.frame = CGRect(origin: .zero, size: panelFrame.size)
    }

    func windowDidResize(_ notification: Notification) {
        guard let resizedPanel = notification.object as? NSPanel else { return }
        panelSize = resizedPanel.frame.size
    }
}

private struct CompanionResponseOverlayView: View {
    @ObservedObject var viewModel: CompanionResponseOverlayViewModel
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Clicky")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)

                    Text(viewModel.isStreamingResponse ? "Streaming response..." : "Latest response")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                }

                Spacer()

                Text("Drag to move")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)

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

            StreamingResponseTextView(
                text: viewModel.responseText,
                responseIdentifier: viewModel.responseIdentifier
            )
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

private struct StreamingResponseTextView: NSViewRepresentable {
    let text: String
    let responseIdentifier: UUID

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
        scrollView.contentView.postsBoundsChangedNotifications = true

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 13)
        textView.textColor = .white
        textView.textContainerInset = NSSize(width: 14, height: 14)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: scrollView.contentSize.width, height: .greatestFiniteMagnitude)

        scrollView.documentView = textView

        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.didScroll(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        context.coordinator.scrollView = scrollView
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }

        if context.coordinator.lastResponseIdentifier != responseIdentifier {
            context.coordinator.lastResponseIdentifier = responseIdentifier
            context.coordinator.shouldAutoScroll = true
        }

        if textView.string != text {
            textView.string = text
            if context.coordinator.shouldAutoScroll {
                context.coordinator.scrollToBottom()
            }
        }
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
    }

    final class Coordinator: NSObject {
        weak var scrollView: NSScrollView?
        weak var textView: NSTextView?
        var shouldAutoScroll = true
        var isPerformingProgrammaticScroll = false
        var lastResponseIdentifier = UUID()

        @objc func didScroll(_ notification: Notification) {
            guard !isPerformingProgrammaticScroll,
                  let scrollView,
                  let documentView = scrollView.documentView else {
                return
            }

            let visibleRect = scrollView.contentView.bounds
            let maximumOffsetY = max(0, documentView.bounds.height - visibleRect.height)
            let distanceFromBottom = maximumOffsetY - visibleRect.origin.y
            shouldAutoScroll = distanceFromBottom < 24
        }

        func scrollToBottom() {
            guard let scrollView, let documentView = scrollView.documentView else { return }

            let visibleRect = scrollView.contentView.bounds
            let maximumOffsetY = max(0, documentView.bounds.height - visibleRect.height)
            let newOrigin = CGPoint(x: 0, y: maximumOffsetY)

            isPerformingProgrammaticScroll = true
            scrollView.contentView.scroll(to: newOrigin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            DispatchQueue.main.async {
                self.isPerformingProgrammaticScroll = false
            }
        }
    }
}
