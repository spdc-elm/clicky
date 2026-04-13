//
//  ClaudeAPI.swift
//  leanring-buddy
//
//  Anthropic-compatible streaming vision client used by Clicky.
//

import Foundation

final class ClaudeAPI {
    private static let tlsWarmupLock = NSLock()
    private static var warmedHosts = Set<String>()

    private let endpointURL: URL
    private let apiKey: String
    let modelID: String
    private let session: URLSession

    init(endpointURL: URL, apiKey: String, modelID: String) {
        self.endpointURL = endpointURL
        self.apiKey = apiKey
        self.modelID = modelID

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 300
        configuration.waitsForConnectivity = true
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        self.session = URLSession(configuration: configuration)

        warmUpTLSConnectionIfNeeded()
    }

    func analyzeImageStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPrompt: String, assistantResponse: String)] = [],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> String {
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        var messages: [[String: Any]] = []
        for historyEntry in conversationHistory {
            messages.append(["role": "user", "content": historyEntry.userPrompt])
            messages.append(["role": "assistant", "content": historyEntry.assistantResponse])
        }

        var contentBlocks: [[String: Any]] = []
        for image in images {
            contentBlocks.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": detectImageMediaType(for: image.data),
                    "data": image.data.base64EncodedString()
                ]
            ])
            contentBlocks.append([
                "type": "text",
                "text": image.label
            ])
        }
        contentBlocks.append([
            "type": "text",
            "text": userPrompt
        ])
        messages.append(["role": "user", "content": contentBlocks])

        let body: [String: Any] = [
            "model": modelID,
            "max_tokens": 1024,
            "stream": true,
            "system": systemPrompt,
            "messages": messages
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (byteStream, response) = try await session.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(
                domain: "ClaudeAPI",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response."]
            )
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            var errorLines: [String] = []
            for try await line in byteStream.lines {
                errorLines.append(line)
            }
            throw NSError(
                domain: "ClaudeAPI",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: errorLines.joined(separator: "\n")]
            )
        }

        var accumulatedResponseText = ""
        for try await line in byteStream.lines {
            guard line.hasPrefix("data: ") else { continue }
            let jsonString = String(line.dropFirst(6))
            guard jsonString != "[DONE]" else { break }

            guard let jsonData = jsonString.data(using: .utf8),
                  let payload = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let type = payload["type"] as? String else {
                continue
            }

            if type == "content_block_delta",
               let delta = payload["delta"] as? [String: Any],
               let deltaType = delta["type"] as? String,
               deltaType == "text_delta",
               let textChunk = delta["text"] as? String {
                accumulatedResponseText += textChunk
                await onTextChunk(accumulatedResponseText)
            }
        }

        return accumulatedResponseText
    }

    private func warmUpTLSConnectionIfNeeded() {
        guard let host = endpointURL.host else { return }

        Self.tlsWarmupLock.lock()
        let shouldWarmHost = !Self.warmedHosts.contains(host)
        if shouldWarmHost {
            Self.warmedHosts.insert(host)
        }
        Self.tlsWarmupLock.unlock()

        guard shouldWarmHost else { return }
        guard var warmupComponents = URLComponents(url: endpointURL, resolvingAgainstBaseURL: false) else { return }
        warmupComponents.path = "/"
        warmupComponents.query = nil
        warmupComponents.fragment = nil
        guard let warmupURL = warmupComponents.url else { return }

        var request = URLRequest(url: warmupURL)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 10

        session.dataTask(with: request) { _, _, _ in }.resume()
    }

    private func detectImageMediaType(for imageData: Data) -> String {
        if imageData.count >= 4 {
            let pngSignature = [UInt8](imageData.prefix(4))
            if pngSignature == [0x89, 0x50, 0x4E, 0x47] {
                return "image/png"
            }
        }

        return "image/jpeg"
    }
}
