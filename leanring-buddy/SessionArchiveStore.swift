//
//  SessionArchiveStore.swift
//  leanring-buddy
//
//  JSON-backed session archive storage used for persistent conversation sessions.
//

import Foundation

enum ClickySessionMode: String, Codable {
    case conversation
    case historian
}

struct ClickyConversationTurnRecord: Codable, Equatable, Identifiable {
    let turnID: UUID
    let createdAt: Date
    let userPromptText: String
    let assistantResponseText: String

    var id: UUID { turnID }
}

struct ClickySessionEvent: Codable, Equatable, Identifiable {
    enum EventType: String, Codable {
        case conversationTurn
        case activitySummary
    }

    let eventID: UUID
    let createdAt: Date
    let eventType: EventType
    let conversationTurn: ClickyConversationTurnRecord?

    var id: UUID { eventID }

    static func makeConversationTurnEvent(
        userPromptText: String,
        assistantResponseText: String,
        createdAt: Date = Date()
    ) -> ClickySessionEvent {
        let conversationTurn = ClickyConversationTurnRecord(
            turnID: UUID(),
            createdAt: createdAt,
            userPromptText: userPromptText,
            assistantResponseText: assistantResponseText
        )

        return ClickySessionEvent(
            eventID: UUID(),
            createdAt: createdAt,
            eventType: .conversationTurn,
            conversationTurn: conversationTurn
        )
    }
}

struct ClickySessionArchive: Codable, Equatable, Identifiable {
    let sessionID: UUID
    let createdAt: Date
    var updatedAt: Date
    let mode: ClickySessionMode
    var events: [ClickySessionEvent]

    var id: UUID { sessionID }

    var completedConversationTurns: [ClickyConversationTurnRecord] {
        events.compactMap(\.conversationTurn)
    }

    static func emptyConversationSession(createdAt: Date = Date()) -> ClickySessionArchive {
        ClickySessionArchive(
            sessionID: UUID(),
            createdAt: createdAt,
            updatedAt: createdAt,
            mode: .conversation,
            events: []
        )
    }

    func appendingConversationTurn(
        userPromptText: String,
        assistantResponseText: String,
        createdAt: Date = Date()
    ) -> ClickySessionArchive {
        var updatedArchive = self
        updatedArchive.events.append(
            .makeConversationTurnEvent(
                userPromptText: userPromptText,
                assistantResponseText: assistantResponseText,
                createdAt: createdAt
            )
        )
        updatedArchive.updatedAt = createdAt
        return updatedArchive
    }
}

final class SessionArchiveStore {
    private enum UserDefaultsKey {
        static let activeSessionID = "clicky.activeSessionID"
        static let hasPendingSessionRestoreDecision = "clicky.hasPendingSessionRestoreDecision"
        static let hasMigratedLegacySessionsToClickyHome = "clicky.hasMigratedLegacySessionsToClickyHome"
    }

    private let fileManager: FileManager
    private let userDefaults: UserDefaults
    private let sessionsDirectoryURL: URL
    private let legacySessionsDirectoryURL: URL
    private let jsonEncoder: JSONEncoder
    private let jsonDecoder: JSONDecoder
    private var hasEnsuredSessionDirectoriesAreReady = false

    init(
        fileManager: FileManager = .default,
        userDefaults: UserDefaults = .standard,
        clickyHomePaths: ClickyHomePaths = ClickyHomePaths(),
        sessionsDirectoryURL: URL? = nil,
        legacySessionsDirectoryURL: URL? = nil
    ) {
        self.fileManager = fileManager
        self.userDefaults = userDefaults
        self.sessionsDirectoryURL = sessionsDirectoryURL
            ?? Self.defaultSessionsDirectoryURL(fileManager: fileManager, clickyHomePaths: clickyHomePaths)
        self.legacySessionsDirectoryURL = legacySessionsDirectoryURL
            ?? Self.legacySessionsDirectoryURL(fileManager: fileManager, clickyHomePaths: clickyHomePaths)

        let jsonEncoder = JSONEncoder()
        jsonEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        jsonEncoder.dateEncodingStrategy = .iso8601
        self.jsonEncoder = jsonEncoder

        let jsonDecoder = JSONDecoder()
        jsonDecoder.dateDecodingStrategy = .iso8601
        self.jsonDecoder = jsonDecoder
    }

    var activeSessionID: UUID? {
        get {
            guard let activeSessionIDString = userDefaults.string(forKey: UserDefaultsKey.activeSessionID) else {
                return nil
            }

            return UUID(uuidString: activeSessionIDString)
        }
        set {
            if let newValue {
                userDefaults.set(newValue.uuidString, forKey: UserDefaultsKey.activeSessionID)
            } else {
                userDefaults.removeObject(forKey: UserDefaultsKey.activeSessionID)
            }
        }
    }

    var hasPendingSessionRestoreDecision: Bool {
        get {
            userDefaults.bool(forKey: UserDefaultsKey.hasPendingSessionRestoreDecision)
        }
        set {
            userDefaults.set(newValue, forKey: UserDefaultsKey.hasPendingSessionRestoreDecision)
        }
    }

    func prepareSessionRestoreDecisionForCurrentLaunch() {
        try? ensureSessionDirectoriesAreReady()

        guard let activeSessionID else {
            hasPendingSessionRestoreDecision = false
            return
        }

        guard archiveExists(for: activeSessionID) else {
            self.activeSessionID = nil
            hasPendingSessionRestoreDecision = false
            return
        }

        hasPendingSessionRestoreDecision = true
    }

    func createNewConversationSession(createdAt: Date = Date()) throws -> ClickySessionArchive {
        try ensureSessionDirectoriesAreReady()
        let conversationSession = ClickySessionArchive.emptyConversationSession(createdAt: createdAt)
        try saveArchive(conversationSession)
        activeSessionID = conversationSession.sessionID
        hasPendingSessionRestoreDecision = false
        return conversationSession
    }

    func loadRecoverableActiveSessionArchive() throws -> ClickySessionArchive? {
        try ensureSessionDirectoriesAreReady()
        guard hasPendingSessionRestoreDecision, let activeSessionID else {
            return nil
        }

        return try loadArchive(for: activeSessionID)
    }

    func loadActiveSessionArchiveIfAvailable() throws -> ClickySessionArchive? {
        try ensureSessionDirectoriesAreReady()
        guard let activeSessionID else {
            return nil
        }

        return try loadArchive(for: activeSessionID)
    }

    func loadArchive(for sessionID: UUID) throws -> ClickySessionArchive? {
        try ensureSessionDirectoriesAreReady()
        let archiveURL = archiveFileURL(for: sessionID)
        guard fileManager.fileExists(atPath: archiveURL.path) else {
            return nil
        }

        let archiveData = try Data(contentsOf: archiveURL)
        return try jsonDecoder.decode(ClickySessionArchive.self, from: archiveData)
    }

    func saveArchive(_ archive: ClickySessionArchive) throws {
        try ensureSessionDirectoriesAreReady()
        try ensureSessionsDirectoryExists()
        let archiveData = try jsonEncoder.encode(archive)
        try archiveData.write(to: archiveFileURL(for: archive.sessionID), options: .atomic)
    }

    func sessionsDirectoryURLForOpening() throws -> URL {
        try ensureSessionDirectoriesAreReady()
        try ensureSessionsDirectoryExists()
        return sessionsDirectoryURL
    }

    func clearAllSessionArchives() throws {
        if fileManager.fileExists(atPath: sessionsDirectoryURL.path) {
            try fileManager.removeItem(at: sessionsDirectoryURL)
        }

        activeSessionID = nil
        hasPendingSessionRestoreDecision = false
        userDefaults.set(true, forKey: UserDefaultsKey.hasMigratedLegacySessionsToClickyHome)
        hasEnsuredSessionDirectoriesAreReady = true
    }

    func archiveExists(for sessionID: UUID) -> Bool {
        try? ensureSessionDirectoriesAreReady()
        return fileManager.fileExists(atPath: archiveFileURL(for: sessionID).path)
    }

    private func ensureSessionsDirectoryExists() throws {
        try fileManager.createDirectory(at: sessionsDirectoryURL, withIntermediateDirectories: true)
    }

    private func archiveFileURL(for sessionID: UUID) -> URL {
        sessionsDirectoryURL.appendingPathComponent("\(sessionID.uuidString).json", isDirectory: false)
    }

    private func ensureSessionDirectoriesAreReady() throws {
        guard !hasEnsuredSessionDirectoriesAreReady else {
            return
        }

        if userDefaults.bool(forKey: UserDefaultsKey.hasMigratedLegacySessionsToClickyHome) {
            hasEnsuredSessionDirectoriesAreReady = true
            return
        }

        if sessionsDirectoryContainsArchivedSessionFiles() {
            userDefaults.set(true, forKey: UserDefaultsKey.hasMigratedLegacySessionsToClickyHome)
            hasEnsuredSessionDirectoriesAreReady = true
            return
        }

        let legacyArchiveFileURLs = try legacyArchiveFileURLsForMigration()
        guard !legacyArchiveFileURLs.isEmpty else {
            userDefaults.set(true, forKey: UserDefaultsKey.hasMigratedLegacySessionsToClickyHome)
            hasEnsuredSessionDirectoriesAreReady = true
            return
        }

        try ensureSessionsDirectoryExists()
        for legacyArchiveFileURL in legacyArchiveFileURLs {
            let destinationArchiveFileURL = sessionsDirectoryURL
                .appendingPathComponent(legacyArchiveFileURL.lastPathComponent, isDirectory: false)

            guard !fileManager.fileExists(atPath: destinationArchiveFileURL.path) else {
                continue
            }

            try fileManager.copyItem(at: legacyArchiveFileURL, to: destinationArchiveFileURL)
        }

        userDefaults.set(true, forKey: UserDefaultsKey.hasMigratedLegacySessionsToClickyHome)
        hasEnsuredSessionDirectoriesAreReady = true
    }

    private func sessionsDirectoryContainsArchivedSessionFiles() -> Bool {
        guard let archivedSessionFileNames = try? fileManager.contentsOfDirectory(atPath: sessionsDirectoryURL.path) else {
            return false
        }

        return archivedSessionFileNames.contains { archivedSessionFileName in
            archivedSessionFileName.hasSuffix(".json")
        }
    }

    private func legacyArchiveFileURLsForMigration() throws -> [URL] {
        guard fileManager.fileExists(atPath: legacySessionsDirectoryURL.path) else {
            return []
        }

        let legacyDirectoryContents = try fileManager.contentsOfDirectory(
            at: legacySessionsDirectoryURL,
            includingPropertiesForKeys: nil
        )

        return legacyDirectoryContents.filter { legacyDirectoryEntryURL in
            legacyDirectoryEntryURL.pathExtension == "json"
        }
    }

    static func defaultSessionsDirectoryURL(
        fileManager: FileManager = .default,
        clickyHomePaths: ClickyHomePaths? = nil
    ) -> URL {
        (clickyHomePaths ?? ClickyHomePaths(fileManager: fileManager)).sessionsDirectoryURL
    }

    static func legacySessionsDirectoryURL(
        fileManager: FileManager = .default,
        clickyHomePaths: ClickyHomePaths? = nil
    ) -> URL {
        (clickyHomePaths ?? ClickyHomePaths(fileManager: fileManager)).legacySessionsDirectoryURL
    }
}
