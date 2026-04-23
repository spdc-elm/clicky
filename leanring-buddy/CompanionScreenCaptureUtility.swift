//
//  CompanionScreenCaptureUtility.swift
//  leanring-buddy
//
//  Screenshot capture helpers for the current cursor screen.
//

import AppKit
import ScreenCaptureKit

struct CompanionScreenCapture {
    let imageData: Data
    let label: String
    let displayWidthInPoints: Int
    let displayHeightInPoints: Int
    let displayFrame: CGRect
    let screenshotWidthInPixels: Int
    let screenshotHeightInPixels: Int
    let screen: NSScreen
}

@MainActor
enum CompanionScreenCaptureUtility {
    static func captureCursorScreenAsJPEG() async throws -> CompanionScreenCapture {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard !content.displays.isEmpty else {
            throw NSError(
                domain: "CompanionScreenCapture",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "No display available for capture."]
            )
        }

        let mouseLocation = NSEvent.mouseLocation
        guard let targetScreen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) ?? NSScreen.main else {
            throw NSError(
                domain: "CompanionScreenCapture",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Could not determine the cursor screen."]
            )
        }

        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        let ownAppWindows = content.windows.filter { window in
            window.owningApplication?.bundleIdentifier == ownBundleIdentifier
        }

        let displayID = targetScreen.displayID
        guard let targetDisplay = content.displays.first(where: { $0.displayID == displayID }) else {
            throw NSError(
                domain: "CompanionScreenCapture",
                code: -3,
                userInfo: [NSLocalizedDescriptionKey: "Could not match the cursor screen to a shareable display."]
            )
        }

        let filter = SCContentFilter(display: targetDisplay, excludingWindows: ownAppWindows)
        let configuration = SCStreamConfiguration()
        configuration.width = targetDisplay.width
        configuration.height = targetDisplay.height

        let capturedImage = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )

        guard let jpegData = NSBitmapImageRep(cgImage: capturedImage).representation(
            using: .jpeg,
            properties: [.compressionFactor: 0.94]
        ) else {
            throw NSError(
                domain: "CompanionScreenCapture",
                code: -4,
                userInfo: [NSLocalizedDescriptionKey: "Failed to encode the screenshot as JPEG."]
            )
        }

        return CompanionScreenCapture(
            imageData: jpegData,
            label: "current cursor screen",
            displayWidthInPoints: Int(targetScreen.frame.width),
            displayHeightInPoints: Int(targetScreen.frame.height),
            displayFrame: targetScreen.frame,
            screenshotWidthInPixels: configuration.width,
            screenshotHeightInPixels: configuration.height,
            screen: targetScreen
        )
    }
}
