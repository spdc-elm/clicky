//
//  OpenAIAPI.swift
//  leanring-buddy
//
//  OpenAI-compatible streaming vision client used by Clicky.
//

import Foundation

final class OpenAIAPI {
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
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var messages: [[String: Any]] = [
            [
                "role": "system",
                "content": systemPrompt
            ]
        ]

        for historyEntry in conversationHistory {
            messages.append(["role": "user", "content": historyEntry.userPrompt])
            messages.append(["role": "assistant", "content": historyEntry.assistantResponse])
        }

        var contentBlocks: [[String: Any]] = []
        for image in images {
            contentBlocks.append([
                "type": "text",
                "text": image.label
            ])
            contentBlocks.append([
                "type": "image_url",
                "image_url": [
                    "url": "data:\(detectImageMediaType(for: image.data));base64,\(image.data.base64EncodedString())"
                ]
            ])
        }
        contentBlocks.append([
            "type": "text",
            "text": userPrompt
        ])
        messages.append(["role": "user", "content": contentBlocks])

        let body: [String: Any] = [
            "model": modelID,
            "max_completion_tokens": 600,
            "stream": true,
            "messages": messages
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (byteStream, response) = try await session.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(
                domain: "OpenAIAPI",
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
                domain: "OpenAIAPI",
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
                  let choices = payload["choices"] as? [[String: Any]],
                  let firstChoice = choices.first,
                  let delta = firstChoice["delta"] as? [String: Any] else {
                continue
            }

            let responseTextChunk = extractResponseTextChunk(from: delta)
            guard !responseTextChunk.isEmpty else {
                continue
            }

            accumulatedResponseText += responseTextChunk
            await onTextChunk(accumulatedResponseText)
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

    private func extractResponseTextChunk(from delta: [String: Any]) -> String {
        if let content = delta["content"] as? String {
            return content
        }

        if let contentBlocks = delta["content"] as? [[String: Any]] {
            return contentBlocks.compactMap { contentBlock in
                contentBlock["text"] as? String
            }.joined()
        }

        return ""
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
