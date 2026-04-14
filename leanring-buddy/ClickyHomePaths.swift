//
//  ClickyHomePaths.swift
//  leanring-buddy
//
//  Shared filesystem paths rooted under ~/.clicky.
//

import Foundation

struct ClickyHomePaths {
    private let homeDirectoryURL: URL
    private let fileManager: FileManager

    init(
        fileManager: FileManager = .default,
        homeDirectoryURL: URL? = nil
    ) {
        self.fileManager = fileManager
        self.homeDirectoryURL = homeDirectoryURL ?? fileManager.homeDirectoryForCurrentUser
    }

    var clickyHomeDirectoryURL: URL {
        homeDirectoryURL.appendingPathComponent(".clicky", isDirectory: true)
    }

    var promptsDirectoryURL: URL {
        clickyHomeDirectoryURL.appendingPathComponent("prompts", isDirectory: true)
    }

    var sessionsDirectoryURL: URL {
        clickyHomeDirectoryURL.appendingPathComponent("sessions", isDirectory: true)
    }

    var legacySessionsDirectoryURL: URL {
        let applicationSupportDirectoryURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory

        return applicationSupportDirectoryURL
            .appendingPathComponent("Clicky", isDirectory: true)
            .appendingPathComponent("Sessions", isDirectory: true)
    }
}
