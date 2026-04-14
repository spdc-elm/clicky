//
//  ClickyPromptStore.swift
//  leanring-buddy
//
//  Resolves prompt overrides from ~/.clicky/prompts with bundled fallbacks.
//

import Foundation

enum ClickyPromptKind: CaseIterable {
    case textResponseSystem
    case elementLocationUser

    var fileName: String {
        switch self {
        case .textResponseSystem:
            return "text-response-system.md"
        case .elementLocationUser:
            return "element-location-user.md"
        }
    }

    var requiredPlaceholderTokens: [String] {
        switch self {
        case .textResponseSystem:
            return []
        case .elementLocationUser:
            return ["{{user_question}}"]
        }
    }
}

enum ClickyPromptSource: Equatable {
    case externalOverride(URL)
    case bundledDefault(URL)
}

struct ResolvedClickyPrompt: Equatable {
    let text: String
    let source: ClickyPromptSource
}

enum ClickyPromptStoreError: LocalizedError {
    case missingBundledDefaultPrompt(fileName: String)
    case invalidBundledDefaultPrompt(fileName: String)

    var errorDescription: String? {
        switch self {
        case .missingBundledDefaultPrompt(let fileName):
            return "Clicky couldn't find the bundled default prompt file \(fileName)."
        case .invalidBundledDefaultPrompt(let fileName):
            return "Clicky found the bundled default prompt file \(fileName), but its contents are invalid."
        }
    }
}

final class ClickyPromptStore {
    private enum ExternalPromptValidationResult {
        case valid(String)
        case missingOrUnreadable
        case invalidContents
    }

    private let fileManager: FileManager
    private let clickyHomePaths: ClickyHomePaths
    private let bundledPromptDefaultsDirectoryURL: URL?
    private let resourceBundle: Bundle

    init(
        fileManager: FileManager = .default,
        clickyHomePaths: ClickyHomePaths = ClickyHomePaths(),
        resourceBundle: Bundle = .main,
        bundledPromptDefaultsDirectoryURL: URL? = nil
    ) {
        self.fileManager = fileManager
        self.clickyHomePaths = clickyHomePaths
        self.resourceBundle = resourceBundle
        self.bundledPromptDefaultsDirectoryURL = bundledPromptDefaultsDirectoryURL
    }

    func promptsDirectoryURLForOpening() throws -> URL {
        try fileManager.createDirectory(at: clickyHomePaths.promptsDirectoryURL, withIntermediateDirectories: true)
        try seedBundledDefaultPromptsIntoOverridesDirectory()
        return clickyHomePaths.promptsDirectoryURL
    }

    func resolvedPrompt(for clickyPromptKind: ClickyPromptKind) throws -> ResolvedClickyPrompt {
        let externalPromptFileURL = clickyHomePaths.promptsDirectoryURL
            .appendingPathComponent(clickyPromptKind.fileName, isDirectory: false)

        switch externalPromptValidationResult(
            from: externalPromptFileURL,
            clickyPromptKind: clickyPromptKind
        ) {
        case .valid(let externalPromptText):
            return ResolvedClickyPrompt(
                text: externalPromptText,
                source: .externalOverride(externalPromptFileURL)
            )
        case .missingOrUnreadable, .invalidContents:
            break
        }

        guard let bundledPromptFileURL = bundledPromptFileURL(for: clickyPromptKind) else {
            throw ClickyPromptStoreError.missingBundledDefaultPrompt(fileName: clickyPromptKind.fileName)
        }

        guard let bundledPromptText = try? String(contentsOf: bundledPromptFileURL, encoding: .utf8),
              let validatedBundledPromptText = validatedPromptText(
                from: bundledPromptText,
                clickyPromptKind: clickyPromptKind
              ) else {
            throw ClickyPromptStoreError.invalidBundledDefaultPrompt(fileName: clickyPromptKind.fileName)
        }

        try seedPromptOverrideFileIfNeeded(
            externalPromptFileURL: externalPromptFileURL,
            bundledPromptText: validatedBundledPromptText
        )

        return ResolvedClickyPrompt(
            text: validatedBundledPromptText,
            source: .bundledDefault(bundledPromptFileURL)
        )
    }

    func renderedPrompt(
        for clickyPromptKind: ClickyPromptKind,
        replacementsByPlaceholderToken: [String: String] = [:]
    ) throws -> ResolvedClickyPrompt {
        let resolvedPrompt = try resolvedPrompt(for: clickyPromptKind)

        var renderedPromptText = resolvedPrompt.text
        for (placeholderToken, replacementValue) in replacementsByPlaceholderToken {
            renderedPromptText = renderedPromptText.replacingOccurrences(
                of: placeholderToken,
                with: replacementValue
            )
        }

        return ResolvedClickyPrompt(
            text: renderedPromptText,
            source: resolvedPrompt.source
        )
    }

    private func externalPromptValidationResult(
        from promptFileURL: URL,
        clickyPromptKind: ClickyPromptKind
    ) -> ExternalPromptValidationResult {
        guard fileManager.fileExists(atPath: promptFileURL.path) else {
            return .missingOrUnreadable
        }

        guard let promptText = try? String(contentsOf: promptFileURL, encoding: .utf8) else {
            return .missingOrUnreadable
        }

        guard let validatedPromptText = validatedPromptText(
            from: promptText,
            clickyPromptKind: clickyPromptKind
        ) else {
            return .invalidContents
        }

        return .valid(validatedPromptText)
    }

    private func validatedPromptText(
        from promptText: String,
        clickyPromptKind: ClickyPromptKind
    ) -> String? {
        let trimmedPromptText = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPromptText.isEmpty else {
            return nil
        }

        for requiredPlaceholderToken in clickyPromptKind.requiredPlaceholderTokens {
            guard trimmedPromptText.contains(requiredPlaceholderToken) else {
                return nil
            }
        }

        return trimmedPromptText
    }

    private func seedBundledDefaultPromptsIntoOverridesDirectory() throws {
        for clickyPromptKind in ClickyPromptKind.allCases {
            let externalPromptFileURL = clickyHomePaths.promptsDirectoryURL
                .appendingPathComponent(clickyPromptKind.fileName, isDirectory: false)

            switch externalPromptValidationResult(
                from: externalPromptFileURL,
                clickyPromptKind: clickyPromptKind
            ) {
            case .valid:
                continue
            case .missingOrUnreadable, .invalidContents:
                guard let bundledPromptFileURL = bundledPromptFileURL(for: clickyPromptKind) else {
                    throw ClickyPromptStoreError.missingBundledDefaultPrompt(fileName: clickyPromptKind.fileName)
                }

                guard let bundledPromptText = try? String(contentsOf: bundledPromptFileURL, encoding: .utf8),
                      let validatedBundledPromptText = validatedPromptText(
                        from: bundledPromptText,
                        clickyPromptKind: clickyPromptKind
                      ) else {
                    throw ClickyPromptStoreError.invalidBundledDefaultPrompt(fileName: clickyPromptKind.fileName)
                }

                try seedPromptOverrideFileIfNeeded(
                    externalPromptFileURL: externalPromptFileURL,
                    bundledPromptText: validatedBundledPromptText
                )
            }
        }
    }

    private func seedPromptOverrideFileIfNeeded(
        externalPromptFileURL: URL,
        bundledPromptText: String
    ) throws {
        try fileManager.createDirectory(at: clickyHomePaths.promptsDirectoryURL, withIntermediateDirectories: true)
        try bundledPromptText.write(to: externalPromptFileURL, atomically: true, encoding: .utf8)
    }

    private func bundledPromptFileURL(for clickyPromptKind: ClickyPromptKind) -> URL? {
        if let bundledPromptDefaultsDirectoryURL {
            return bundledPromptDefaultsDirectoryURL
                .appendingPathComponent(clickyPromptKind.fileName, isDirectory: false)
        }

        let promptFileNameWithoutExtension = URL(fileURLWithPath: clickyPromptKind.fileName).deletingPathExtension().lastPathComponent

        if let resourceURLFromSubdirectory = resourceBundle.url(
            forResource: promptFileNameWithoutExtension,
            withExtension: "md",
            subdirectory: "PromptDefaults"
        ) {
            return resourceURLFromSubdirectory
        }

        if let resourceURLFromPromptDefaultsFolder = resourceBundle.resourceURL?
            .appendingPathComponent("PromptDefaults", isDirectory: true)
            .appendingPathComponent(clickyPromptKind.fileName, isDirectory: false),
           fileManager.fileExists(atPath: resourceURLFromPromptDefaultsFolder.path) {
            return resourceURLFromPromptDefaultsFolder
        }

        return resourceBundle.url(
            forResource: promptFileNameWithoutExtension,
            withExtension: "md"
        )
    }
}
