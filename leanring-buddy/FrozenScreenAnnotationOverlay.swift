//
//  FrozenScreenAnnotationOverlay.swift
//  leanring-buddy
//
//  Full-screen frozen screenshot layer with lightweight annotation tools.
//

import AppKit
import SwiftUI

enum FrozenScreenAnnotationTool: String, CaseIterable, Equatable {
    case pen
    case rectangle
    case ellipse
}

struct FrozenScreenAnnotation: Identifiable, Equatable {
    let id: UUID
    let tool: FrozenScreenAnnotationTool
    let points: [CGPoint]
    let strokeWidth: CGFloat

    init(
        id: UUID = UUID(),
        tool: FrozenScreenAnnotationTool,
        points: [CGPoint],
        strokeWidth: CGFloat = 5
    ) {
        self.id = id
        self.tool = tool
        self.points = points
        self.strokeWidth = strokeWidth
    }
}

enum FrozenScreenAnnotationRenderer {
    static func renderAnnotatedScreenCapture(
        _ screenCapture: CompanionScreenCapture,
        annotations: [FrozenScreenAnnotation]
    ) throws -> CompanionScreenCapture {
        guard !annotations.isEmpty else {
            return screenCapture
        }

        guard let sourceImage = NSImage(data: screenCapture.imageData),
              let sourceCGImage = sourceImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw NSError(
                domain: "FrozenScreenAnnotationRenderer",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Could not decode the frozen screenshot."]
            )
        }

        let pixelWidth = screenCapture.screenshotWidthInPixels
        let pixelHeight = screenCapture.screenshotHeightInPixels
        let imageBounds = CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight)

        guard let bitmapRepresentation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelWidth,
            pixelsHigh: pixelHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw NSError(
                domain: "FrozenScreenAnnotationRenderer",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Could not create an annotation canvas."]
            )
        }

        NSGraphicsContext.saveGraphicsState()
        guard let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmapRepresentation) else {
            NSGraphicsContext.restoreGraphicsState()
            throw NSError(
                domain: "FrozenScreenAnnotationRenderer",
                code: -3,
                userInfo: [NSLocalizedDescriptionKey: "Could not draw the annotated screenshot."]
            )
        }

        NSGraphicsContext.current = graphicsContext
        NSColor.black.setFill()
        NSBezierPath(rect: imageBounds).fill()
        NSGraphicsContext.current?.cgContext.draw(sourceCGImage, in: imageBounds)

        for annotation in annotations {
            drawAnnotation(annotation, imageBounds: imageBounds)
        }

        NSGraphicsContext.restoreGraphicsState()

        guard let jpegData = bitmapRepresentation.representation(
            using: .jpeg,
            properties: [.compressionFactor: 0.86]
        ) else {
            throw NSError(
                domain: "FrozenScreenAnnotationRenderer",
                code: -4,
                userInfo: [NSLocalizedDescriptionKey: "Could not encode the annotated screenshot."]
            )
        }

        return CompanionScreenCapture(
            imageData: jpegData,
            label: "\(screenCapture.label) with annotations",
            displayWidthInPoints: screenCapture.displayWidthInPoints,
            displayHeightInPoints: screenCapture.displayHeightInPoints,
            displayFrame: screenCapture.displayFrame,
            screenshotWidthInPixels: screenCapture.screenshotWidthInPixels,
            screenshotHeightInPixels: screenCapture.screenshotHeightInPixels,
            screen: screenCapture.screen
        )
    }

    private static func drawAnnotation(
        _ annotation: FrozenScreenAnnotation,
        imageBounds: CGRect
    ) {
        let path = NSBezierPath()
        path.lineWidth = annotation.strokeWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        NSColor.systemRed.setStroke()

        switch annotation.tool {
        case .pen:
            guard let firstPoint = annotation.points.first else { return }
            path.move(to: firstPoint)
            for point in annotation.points.dropFirst() {
                path.line(to: point)
            }
            path.stroke()
        case .rectangle:
            guard let rect = rect(from: annotation.points, imageBounds: imageBounds) else { return }
            NSBezierPath(rect: rect).withStrokeStyle(width: annotation.strokeWidth).stroke()
        case .ellipse:
            guard let rect = rect(from: annotation.points, imageBounds: imageBounds) else { return }
            NSBezierPath(ovalIn: rect).withStrokeStyle(width: annotation.strokeWidth).stroke()
        }
    }

    private static func rect(
        from points: [CGPoint],
        imageBounds: CGRect
    ) -> CGRect? {
        guard let firstPoint = points.first, let lastPoint = points.last else {
            return nil
        }

        let minX = max(imageBounds.minX, min(firstPoint.x, lastPoint.x))
        let maxX = min(imageBounds.maxX, max(firstPoint.x, lastPoint.x))
        let minY = max(imageBounds.minY, min(firstPoint.y, lastPoint.y))
        let maxY = min(imageBounds.maxY, max(firstPoint.y, lastPoint.y))

        guard maxX > minX, maxY > minY else {
            return nil
        }

        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

private extension NSBezierPath {
    func withStrokeStyle(width: CGFloat) -> NSBezierPath {
        lineWidth = width
        lineCapStyle = .round
        lineJoinStyle = .round
        NSColor.systemRed.setStroke()
        return self
    }
}

private final class FrozenScreenAnnotationPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class FrozenScreenAnnotationPanelManager {
    private var panel: NSPanel?
    private let companionManager: CompanionManager

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
    }

    func show(screenCapture: CompanionScreenCapture) {
        if panel == nil {
            createPanel(screenCapture: screenCapture)
        }

        guard let panel else { return }
        updatePanelContent(panel, screenCapture: screenCapture)
        panel.setFrame(screenCapture.displayFrame, display: true)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func createPanel(screenCapture: CompanionScreenCapture) {
        let rootView = FrozenScreenAnnotationView(
            companionManager: companionManager,
            screenCapture: screenCapture
        )

        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = NSRect(origin: .zero, size: screenCapture.displayFrame.size)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor

        let annotationPanel = FrozenScreenAnnotationPanel(
            contentRect: screenCapture.displayFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // Keep the annotation layer above regular app windows but below the composer,
        // otherwise AppKit can reorder the full-screen panel over the composer after drawing.
        annotationPanel.level = .floating
        annotationPanel.isFloatingPanel = true
        annotationPanel.isOpaque = false
        annotationPanel.backgroundColor = .clear
        annotationPanel.hasShadow = false
        annotationPanel.hidesOnDeactivate = false
        annotationPanel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        annotationPanel.contentView = hostingView

        panel = annotationPanel
    }

    private func updatePanelContent(
        _ panel: NSPanel,
        screenCapture: CompanionScreenCapture
    ) {
        let rootView = FrozenScreenAnnotationView(
            companionManager: companionManager,
            screenCapture: screenCapture
        )

        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = NSRect(origin: .zero, size: screenCapture.displayFrame.size)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = hostingView
    }
}

private struct FrozenScreenAnnotationView: View {
    @ObservedObject var companionManager: CompanionManager
    let screenCapture: CompanionScreenCapture

    @State private var draftAnnotation: FrozenScreenAnnotation?

    var body: some View {
        ZStack(alignment: .topLeading) {
            frozenScreenshotImage

            AnnotationCanvasView(
                annotations: companionManager.frozenScreenAnnotations,
                draftAnnotation: draftAnnotation,
                displaySize: screenCapture.displayFrame.size,
                screenshotPixelSize: CGSize(
                    width: screenCapture.screenshotWidthInPixels,
                    height: screenCapture.screenshotHeightInPixels
                )
            )
            .contentShape(Rectangle())
            .gesture(annotationDragGesture)

            annotationToolbar
                .padding(.top, 16)
                .padding(.leading, 16)
        }
        .frame(width: screenCapture.displayFrame.width, height: screenCapture.displayFrame.height)
        .ignoresSafeArea()
    }

    private var frozenScreenshotImage: some View {
        Group {
            if let image = NSImage(data: screenCapture.imageData) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color.black
            }
        }
        .frame(width: screenCapture.displayFrame.width, height: screenCapture.displayFrame.height)
        .clipped()
    }

    private var annotationToolbar: some View {
        HStack(spacing: 8) {
            Button(action: companionManager.hideFrozenScreenAnnotationEditor) {
                Image(systemName: "minus")
            }
            .dsIconButtonStyle(tooltipAlignment: .leading)
            .nativeTooltip("Hide screenshot editor")
            .pointerCursor()

            Divider()
                .frame(height: 22)
                .overlay(DS.Colors.borderSubtle)

            annotationToolButton(tool: .pen, systemImageName: "pencil.tip", tooltip: "Pen")
            annotationToolButton(tool: .rectangle, systemImageName: "rectangle", tooltip: "Rectangle")
            annotationToolButton(tool: .ellipse, systemImageName: "circle", tooltip: "Ellipse")

            Divider()
                .frame(height: 22)
                .overlay(DS.Colors.borderSubtle)

            Button(action: companionManager.undoFrozenScreenAnnotation) {
                Image(systemName: "arrow.uturn.backward")
            }
            .dsIconButtonStyle(tooltip: "Undo")
            .pointerCursor(isEnabled: !companionManager.frozenScreenAnnotations.isEmpty)
            .disabled(companionManager.frozenScreenAnnotations.isEmpty)

            Button(action: companionManager.clearFrozenScreenAnnotations) {
                Image(systemName: "trash")
            }
            .dsIconButtonStyle(isDestructiveOnHover: true, tooltip: "Clear")
            .pointerCursor(isEnabled: !companionManager.frozenScreenAnnotations.isEmpty)
            .disabled(companionManager.frozenScreenAnnotations.isEmpty)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(DS.Colors.surface1.opacity(0.92))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(DS.Colors.borderSubtle, lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.28), radius: 14, x: 0, y: 8)
        )
    }

    private func annotationToolButton(
        tool: FrozenScreenAnnotationTool,
        systemImageName: String,
        tooltip: String
    ) -> some View {
        Button(action: {
            companionManager.setSelectedFrozenScreenAnnotationTool(tool)
        }) {
            Image(systemName: systemImageName)
                .foregroundColor(
                    companionManager.selectedFrozenScreenAnnotationTool == tool
                        ? DS.Colors.accentText
                        : DS.Colors.textSecondary
                )
        }
        .dsIconButtonStyle(tooltip: tooltip)
        .pointerCursor()
    }

    private var annotationDragGesture: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .local)
            .onChanged { gestureValue in
                let currentPoint = convertDisplayPointToScreenshotPoint(gestureValue.location)
                let startPoint = convertDisplayPointToScreenshotPoint(gestureValue.startLocation)

                switch companionManager.selectedFrozenScreenAnnotationTool {
                case .pen:
                    var points = draftAnnotation?.points ?? [startPoint]
                    points.append(currentPoint)
                    draftAnnotation = FrozenScreenAnnotation(
                        tool: .pen,
                        points: points
                    )
                case .rectangle, .ellipse:
                    draftAnnotation = FrozenScreenAnnotation(
                        tool: companionManager.selectedFrozenScreenAnnotationTool,
                        points: [startPoint, currentPoint]
                    )
                }
            }
            .onEnded { _ in
                guard let draftAnnotation else { return }
                companionManager.appendFrozenScreenAnnotation(draftAnnotation)
                self.draftAnnotation = nil
            }
    }

    private func convertDisplayPointToScreenshotPoint(_ displayPoint: CGPoint) -> CGPoint {
        let pixelWidth = CGFloat(screenCapture.screenshotWidthInPixels)
        let pixelHeight = CGFloat(screenCapture.screenshotHeightInPixels)
        let displayWidth = screenCapture.displayFrame.width
        let displayHeight = screenCapture.displayFrame.height

        return CGPoint(
            x: max(0, min(displayPoint.x * (pixelWidth / displayWidth), pixelWidth)),
            y: max(0, min((displayHeight - displayPoint.y) * (pixelHeight / displayHeight), pixelHeight))
        )
    }
}

private struct AnnotationCanvasView: View {
    let annotations: [FrozenScreenAnnotation]
    let draftAnnotation: FrozenScreenAnnotation?
    let displaySize: CGSize
    let screenshotPixelSize: CGSize

    var body: some View {
        Canvas { context, size in
            for annotation in annotations {
                draw(annotation, in: &context, size: size)
            }

            if let draftAnnotation {
                draw(draftAnnotation, in: &context, size: size)
            }
        }
        .frame(width: displaySize.width, height: displaySize.height)
    }

    private func draw(
        _ annotation: FrozenScreenAnnotation,
        in context: inout GraphicsContext,
        size: CGSize
    ) {
        var path = Path()

        switch annotation.tool {
        case .pen:
            guard let firstPoint = annotation.points.first else { return }
            path.move(to: convertScreenshotPointToDisplayPoint(firstPoint, size: size))
            for point in annotation.points.dropFirst() {
                path.addLine(to: convertScreenshotPointToDisplayPoint(point, size: size))
            }
        case .rectangle:
            guard let rect = displayRect(for: annotation, size: size) else { return }
            path.addRect(rect)
        case .ellipse:
            guard let rect = displayRect(for: annotation, size: size) else { return }
            path.addEllipse(in: rect)
        }

        let scaledStrokeWidth = max(2, annotation.strokeWidth * (size.width / screenshotPixelSize.width))
        context.stroke(
            path,
            with: .color(.red),
            style: StrokeStyle(
                lineWidth: scaledStrokeWidth,
                lineCap: .round,
                lineJoin: .round
            )
        )
    }

    private func displayRect(
        for annotation: FrozenScreenAnnotation,
        size: CGSize
    ) -> CGRect? {
        guard let firstPoint = annotation.points.first,
              let lastPoint = annotation.points.last else {
            return nil
        }

        let firstDisplayPoint = convertScreenshotPointToDisplayPoint(firstPoint, size: size)
        let lastDisplayPoint = convertScreenshotPointToDisplayPoint(lastPoint, size: size)

        let minX = min(firstDisplayPoint.x, lastDisplayPoint.x)
        let minY = min(firstDisplayPoint.y, lastDisplayPoint.y)
        let maxX = max(firstDisplayPoint.x, lastDisplayPoint.x)
        let maxY = max(firstDisplayPoint.y, lastDisplayPoint.y)

        guard maxX > minX, maxY > minY else {
            return nil
        }

        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func convertScreenshotPointToDisplayPoint(
        _ screenshotPoint: CGPoint,
        size: CGSize
    ) -> CGPoint {
        CGPoint(
            x: screenshotPoint.x * (size.width / screenshotPixelSize.width),
            y: size.height - (screenshotPoint.y * (size.height / screenshotPixelSize.height))
        )
    }
}
