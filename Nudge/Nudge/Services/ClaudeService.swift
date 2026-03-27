//
//  ClaudeService.swift
//  Nudge
//
//  Every AI call goes through here. Never call the Anthropic API from a View.
//

import Foundation

class ClaudeService {
    static let shared = ClaudeService()
    private let apiKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? ""
    private let model = "claude-haiku-4-5-20251001"
    private let baseURL = "https://api.anthropic.com/v1/messages"

    private let systemPrompt = """
    You are Nudge, a warm and energetic productivity companion for people with ADHD.

    Personality:
    - Warm, friendly, like a supportive organized friend
    - Light humor, never clinical
    - NEVER shame for missed tasks — always offer to reschedule
    - Onboarding: high energy. Day-to-day: calm and concise.
    - Celebrate wins genuinely

    Rules:
    - Short responses — 1-2 sentences max
    - No bullet points in conversation
    - No clinical language (optimize, leverage, maximize)
    - Always return JSON with message + data changes
    - One response = one API call. Never chain.

    Always return valid JSON:
    {
      "message": "conversational response",
      "task_updates": [],
      "new_tasks": [],
      "settings_updates": {}
    }
    """

    func send(userMessage: String, context: String = "") async throws -> ClaudeResponse {
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1000,
            "system": systemPrompt,
            "messages": [
                [
                    "role": "user",
                    "content": context.isEmpty
                        ? userMessage
                        : "\(context)\nUser: \(userMessage)"
                ]
            ]
        ]
        var req = URLRequest(url: URL(string: baseURL)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: req)
        let resp = try JSONDecoder().decode(AnthropicResponse.self, from: data)
        guard let text = resp.content.first?.text else {
            throw ClaudeError.emptyResponse
        }
        return try parseResponse(text)
    }

    func captureWordVomit(_ text: String) async throws -> [TaskData] {
        let prompt = """
        Parse this brain dump into tasks. Today is \(Date().formatted()).
        Brain dump: "\(text)"
        Return ONLY JSON:
        {"message": "Got it! Found X tasks.", "new_tasks": [{"title": "", "dueDate": "YYYY-MM-DD", "dueTime": "afternoon", "priority": "high", "category": "school"}]}
        """
        return try await send(userMessage: prompt).newTasks
    }

    private func parseResponse(_ text: String) throws -> ClaudeResponse {
        var t = text
        if t.hasPrefix("```json") { t = String(t.dropFirst(7)) }
        if t.hasPrefix("```") { t = String(t.dropFirst(3)) }
        if t.hasSuffix("```") { t = String(t.dropLast(3)) }
        guard let d = t.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8) else {
            throw ClaudeError.parseError
        }
        return try JSONDecoder().decode(ClaudeResponse.self, from: d)
    }
}

// MARK: - API Response Types

struct AnthropicResponse: Codable {
    let content: [ContentBlock]

    struct ContentBlock: Codable {
        let text: String
    }
}

struct ClaudeResponse: Codable {
    let message: String
    let taskUpdates: [TaskUpdate]?
    let newTasks: [TaskData]
    let settingsUpdates: [String: String]?

    enum CodingKeys: String, CodingKey {
        case message
        case taskUpdates = "task_updates"
        case newTasks = "new_tasks"
        case settingsUpdates = "settings_updates"
    }
}

/// Codable DTO for tasks returned by the Claude API
struct TaskData: Codable {
    let title: String
    let dueDate: String?
    let dueTime: String?
    let priority: String?
    let category: String?

    enum CodingKeys: String, CodingKey {
        case title
        case dueDate = "dueDate"
        case dueTime = "dueTime"
        case priority
        case category
    }
}

/// Codable DTO for task updates returned by the Claude API
struct TaskUpdate: Codable {
    let id: String?
    let title: String?
    let isComplete: Bool?
    let dueDate: String?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case isComplete = "is_complete"
        case dueDate = "due_date"
    }
}

enum ClaudeError: Error {
    case emptyResponse
    case parseError
    case rateLimitExceeded
}
