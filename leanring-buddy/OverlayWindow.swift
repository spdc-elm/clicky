//
//  OverlayWindow.swift
//  leanring-buddy
//
//  Transparent overlay window for Clicky's blue cursor companion.
//

import AppKit
import SwiftUI

final class OverlayWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        level = .screenSaver
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        hasShadow = false
        hidesOnDeactivate = false
        setFrame(screen.frame, display: true)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let size = min(rect.width, rect.height)
        let height = size * sqrt(3.0) / 2.0
        path.move(to: CGPoint(x: rect.midX, y: rect.midY - height / 1.5))
        path.addLine(to: CGPoint(x: rect.midX - size / 2, y: rect.midY + height / 3))
        path.addLine(to: CGPoint(x: rect.midX + size / 2, y: rect.midY + height / 3))
        path.closeSubpath()
        return path
    }
}

private struct BubbleSizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

private enum BuddyNavigationMode {
    case followingCursor
    case navigatingToTarget
    case pointingAtTarget
}

private struct BlueCursorView: View {
    let screenFrame: CGRect
    @ObservedObject var companionManager: CompanionManager

    @State private var cursorPosition: CGPoint
    @State private var isCursorOnThisScreen: Bool
    @State private var cursorTrackingTimer: Timer?
    @State private var navigationAnimationTimer: Timer?
    @State private var buddyNavigationMode: BuddyNavigationMode = .followingCursor
    @State private var triangleRotationDegrees = -35.0
    @State private var navigationBubbleText = ""
    @State private var navigationBubbleOpacity = 0.0
    @State private var navigationBubbleSize: CGSize = .zero
    @State private var buddyFlightScale: CGFloat = 1.0
    @State private var cursorPositionWhenNavigationStarted: CGPoint = .zero
    @State private var isReturningToCursor = false

    init(screenFrame: CGRect, companionManager: CompanionManager) {
        self.screenFrame = screenFrame
        self.companionManager = companionManager

        let mouseLocation = NSEvent.mouseLocation
        let localX = mouseLocation.x - screenFrame.origin.x
        let localY = screenFrame.height - (mouseLocation.y - screenFrame.origin.y)
        _cursorPosition = State(initialValue: CGPoint(x: localX + 35, y: localY + 25))
        _isCursorOnThisScreen = State(initialValue: screenFrame.contains(mouseLocation))
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.001)

            if buddyNavigationMode == .pointingAtTarget && !navigationBubbleText.isEmpty {
                Text(navigationBubbleText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(DS.Colors.overlayCursorBlue)
                            .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.6), radius: 10, x: 0, y: 0)
                    )
                    .fixedSize()
                    .overlay(
                        GeometryReader { geometry in
                            Color.clear.preference(key: BubbleSizePreferenceKey.self, value: geometry.size)
                        }
                    )
                    .opacity(navigationBubbleOpacity)
                    .position(
                        x: cursorPosition.x + 10 + (navigationBubbleSize.width / 2),
                        y: cursorPosition.y + 18
                    )
                    .animation(.spring(response: 0.24, dampingFraction: 0.68), value: cursorPosition)
                    .animation(.easeOut(duration: 0.25), value: navigationBubbleOpacity)
                    .onPreferenceChange(BubbleSizePreferenceKey.self) { newBubbleSize in
                        navigationBubbleSize = newBubbleSize
                    }
            }

            Triangle()
                .fill(DS.Colors.overlayCursorBlue)
                .frame(width: 16, height: 16)
                .rotationEffect(.degrees(triangleRotationDegrees))
                .shadow(color: DS.Colors.overlayCursorBlue, radius: 8 + (buddyFlightScale - 1.0) * 20)
                .scaleEffect(buddyFlightScale)
                .opacity(shouldShowTriangle ? 1 : 0)
                .position(cursorPosition)
                .animation(
                    buddyNavigationMode == .followingCursor ? .spring(response: 0.2, dampingFraction: 0.6) : nil,
                    value: cursorPosition
                )

            BlueCursorSpinnerView()
                .opacity(shouldShowSpinner ? 1 : 0)
                .position(cursorPosition)
                .animation(.spring(response: 0.2, dampingFraction: 0.6), value: cursorPosition)
        }
        .frame(width: screenFrame.width, height: screenFrame.height)
        .ignoresSafeArea()
        .onAppear {
            let mouseLocation = NSEvent.mouseLocation
            isCursorOnThisScreen = screenFrame.contains(mouseLocation)
            let swiftUIPosition = convertScreenPointToSwiftUICoordinates(mouseLocation)
            cursorPosition = CGPoint(x: swiftUIPosition.x + 35, y: swiftUIPosition.y + 25)
            startTrackingCursor()
        }
        .onDisappear {
            cursorTrackingTimer?.invalidate()
            navigationAnimationTimer?.invalidate()
        }
        .onChange(of: companionManager.detectedElementScreenLocation) { newLocation in
            guard let newLocation,
                  let displayFrame = companionManager.detectedElementDisplayFrame else {
                return
            }

            guard screenFrame.contains(CGPoint(x: displayFrame.midX, y: displayFrame.midY)) || displayFrame == screenFrame else {
                return
            }

            startNavigatingToElement(screenLocation: newLocation)
        }
    }

    private var shouldShowTriangle: Bool {
        guard buddyIsVisibleOnThisScreen else { return false }
        return companionManager.interfaceState != .processing
    }

    private var shouldShowSpinner: Bool {
        buddyIsVisibleOnThisScreen && companionManager.interfaceState == .processing
    }

    private var buddyIsVisibleOnThisScreen: Bool {
        switch buddyNavigationMode {
        case .followingCursor:
            if companionManager.detectedElementScreenLocation != nil {
                return false
            }
            return isCursorOnThisScreen
        case .navigatingToTarget, .pointingAtTarget:
            return true
        }
    }

    private func startTrackingCursor() {
        cursorTrackingTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { _ in
            let mouseLocation = NSEvent.mouseLocation
            isCursorOnThisScreen = screenFrame.contains(mouseLocation)

            if buddyNavigationMode == .navigatingToTarget && isReturningToCursor {
                let currentMousePosition = convertScreenPointToSwiftUICoordinates(mouseLocation)
                let distanceFromNavigationStart = hypot(
                    currentMousePosition.x - cursorPositionWhenNavigationStarted.x,
                    currentMousePosition.y - cursorPositionWhenNavigationStarted.y
                )
                if distanceFromNavigationStart > 100 {
                    cancelNavigationAndResumeFollowing()
                }
                return
            }

            guard buddyNavigationMode == .followingCursor else { return }
            let swiftUIPosition = convertScreenPointToSwiftUICoordinates(mouseLocation)
            cursorPosition = CGPoint(x: swiftUIPosition.x + 35, y: swiftUIPosition.y + 25)
        }
    }

    private func convertScreenPointToSwiftUICoordinates(_ screenPoint: CGPoint) -> CGPoint {
        CGPoint(
            x: screenPoint.x - screenFrame.origin.x,
            y: (screenFrame.origin.y + screenFrame.height) - screenPoint.y
        )
    }

    private func startNavigatingToElement(screenLocation: CGPoint) {
        let targetInSwiftUI = convertScreenPointToSwiftUICoordinates(screenLocation)
        let offsetTarget = CGPoint(x: targetInSwiftUI.x + 8, y: targetInSwiftUI.y + 12)
        let clampedTarget = CGPoint(
            x: max(20, min(offsetTarget.x, screenFrame.width - 20)),
            y: max(20, min(offsetTarget.y, screenFrame.height - 20))
        )

        let mouseLocation = NSEvent.mouseLocation
        cursorPositionWhenNavigationStarted = convertScreenPointToSwiftUICoordinates(mouseLocation)
        buddyNavigationMode = .navigatingToTarget
        isReturningToCursor = false

        animateBezierFlightArc(to: clampedTarget) {
            guard buddyNavigationMode == .navigatingToTarget else { return }
            startPointingAtElement()
        }
    }

    private func animateBezierFlightArc(to destination: CGPoint, onComplete: @escaping () -> Void) {
        navigationAnimationTimer?.invalidate()

        let startPosition = cursorPosition
        let endPosition = destination
        let distance = hypot(endPosition.x - startPosition.x, endPosition.y - startPosition.y)
        let duration = min(max(distance / 800.0, 0.55), 1.2)
        let frameInterval = 1.0 / 60.0
        let totalFrames = max(1, Int(duration / frameInterval))
        var currentFrame = 0

        let midPoint = CGPoint(x: (startPosition.x + endPosition.x) / 2, y: (startPosition.y + endPosition.y) / 2)
        let arcHeight = min(max(distance * 0.18, 40), 140)
        let controlPoint = CGPoint(x: midPoint.x, y: midPoint.y - arcHeight)

        navigationAnimationTimer = Timer.scheduledTimer(withTimeInterval: frameInterval, repeats: true) { timer in
            currentFrame += 1
            let progress = min(1, Double(currentFrame) / Double(totalFrames))
            let easedProgress = 1 - pow(1 - progress, 3)

            let nextPosition = quadraticBezierPoint(
                progress: easedProgress,
                start: startPosition,
                control: controlPoint,
                end: endPosition
            )

            let tangent = quadraticBezierTangent(
                progress: easedProgress,
                start: startPosition,
                control: controlPoint,
                end: endPosition
            )

            cursorPosition = nextPosition
            triangleRotationDegrees = atan2(tangent.y, tangent.x) * 180 / .pi + 90
            buddyFlightScale = 1.0 + CGFloat(sin(progress * .pi)) * 0.24

            guard progress >= 1 else { return }
            timer.invalidate()
            navigationAnimationTimer = nil
            buddyFlightScale = 1.0
            onComplete()
        }
    }

    private func startPointingAtElement() {
        buddyNavigationMode = .pointingAtTarget
        navigationBubbleText = companionManager.detectedElementBubbleText ?? "right here"
        navigationBubbleOpacity = 1.0

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            guard buddyNavigationMode == .pointingAtTarget else { return }
            navigationBubbleOpacity = 0.0
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                flyBackToCursor()
            }
        }
    }

    private func flyBackToCursor() {
        let mouseLocation = NSEvent.mouseLocation
        let mouseTarget = convertScreenPointToSwiftUICoordinates(mouseLocation)
        isReturningToCursor = true
        buddyNavigationMode = .navigatingToTarget

        animateBezierFlightArc(to: CGPoint(x: mouseTarget.x + 35, y: mouseTarget.y + 25)) {
            cancelNavigationAndResumeFollowing()
        }
    }

    private func cancelNavigationAndResumeFollowing() {
        navigationAnimationTimer?.invalidate()
        navigationAnimationTimer = nil
        companionManager.detectedElementScreenLocation = nil
        companionManager.detectedElementDisplayFrame = nil
        companionManager.detectedElementBubbleText = nil
        navigationBubbleText = ""
        navigationBubbleOpacity = 0
        buddyNavigationMode = .followingCursor
        triangleRotationDegrees = -35
        buddyFlightScale = 1.0
        isReturningToCursor = false
    }

    private func quadraticBezierPoint(progress: Double, start: CGPoint, control: CGPoint, end: CGPoint) -> CGPoint {
        let t = progress
        let oneMinusT = 1 - t
        let x = (oneMinusT * oneMinusT * start.x) + (2 * oneMinusT * t * control.x) + (t * t * end.x)
        let y = (oneMinusT * oneMinusT * start.y) + (2 * oneMinusT * t * control.y) + (t * t * end.y)
        return CGPoint(x: x, y: y)
    }

    private func quadraticBezierTangent(progress: Double, start: CGPoint, control: CGPoint, end: CGPoint) -> CGPoint {
        let t = progress
        let x = 2 * (1 - t) * (control.x - start.x) + 2 * t * (end.x - control.x)
        let y = 2 * (1 - t) * (control.y - start.y) + 2 * t * (end.y - control.y)
        return CGPoint(x: x, y: y)
    }
}

private struct BlueCursorSpinnerView: View {
    @State private var isSpinning = false

    var body: some View {
        Circle()
            .trim(from: 0.08, to: 0.78)
            .stroke(
                AngularGradient(
                    gradient: Gradient(colors: [
                        DS.Colors.overlayCursorBlue.opacity(0.15),
                        DS.Colors.overlayCursorBlue,
                        DS.Colors.overlayCursorBlue.opacity(0.15)
                    ]),
                    center: .center
                ),
                style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
            )
            .frame(width: 14, height: 14)
            .rotationEffect(.degrees(isSpinning ? 360 : 0))
            .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.6), radius: 6)
            .onAppear {
                withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) {
                    isSpinning = true
                }
            }
    }
}

@MainActor
final class OverlayWindowManager {
    private var overlayWindows: [OverlayWindow] = []
    var hasShownOverlayBefore = false

    func showOverlay(onScreens screens: [NSScreen], companionManager: CompanionManager) {
        hideOverlay()

        for screen in screens {
            let window = OverlayWindow(screen: screen)
            let contentView = BlueCursorView(screenFrame: screen.frame, companionManager: companionManager)
            let hostingView = NSHostingView(rootView: contentView)
            hostingView.frame = screen.frame
            window.contentView = hostingView
            overlayWindows.append(window)
            window.orderFrontRegardless()
        }
    }

    func hideOverlay() {
        for window in overlayWindows {
            window.orderOut(nil)
            window.contentView = nil
        }
        overlayWindows.removeAll()
    }
}
