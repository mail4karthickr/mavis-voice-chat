import Foundation

/// Stands in for the chat bot's HTTP backend: takes the user's question as text and
/// returns a JSON document after a network-like delay.
struct MockBackend {
    func answer(question: String) async throws -> String {
        try await Task.sleep(for: .milliseconds(400))
        let payload: [String: Any] = [
            "request_id": UUID().uuidString,
            "question": question,
            "received_at": ISO8601DateFormatter().string(from: .now),
            "result": Self.result(for: question),
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private static func result(for question: String) -> [String: Any] {
        let text = question.lowercased()
        if text.contains("weather") || text.contains("rain") || text.contains("temperature") {
            return [
                "type": "weather",
                "location": "Chennai",
                "condition": "Partly cloudy",
                "temperature_c": 31,
                "humidity_percent": 68,
                "rain_chance_percent": 20,
                "forecast": [
                    ["day": "Tomorrow", "high_c": 33, "low_c": 26, "condition": "Sunny"],
                    ["day": "Day after", "high_c": 30, "low_c": 25, "condition": "Thunderstorms"],
                ],
            ]
        }
        if text.contains("order") || text.contains("delivery") || text.contains("package") {
            return [
                "type": "order",
                "order_id": "A1B2-7731",
                "status": "out_for_delivery",
                "carrier": "BlueDart",
                "estimated_delivery": "today between 4 pm and 6 pm",
                "items": [
                    ["name": "USB-C cable", "quantity": 2],
                    ["name": "Phone case", "quantity": 1],
                ],
            ]
        }
        if text.contains("balance") || text.contains("account") || text.contains("spent") {
            return [
                "type": "account",
                "account": "Savings ending 4821",
                "currency": "INR",
                "balance": 48215.50,
                "recent_transactions": [
                    ["merchant": "Grocery Mart", "amount": -2450.0, "date": "2026-10-28"],
                    ["merchant": "Salary credit", "amount": 85000.0, "date": "2026-10-25"],
                    ["merchant": "Metro card top-up", "amount": -500.0, "date": "2026-10-24"],
                ],
            ]
        }
        return [
            "type": "faq",
            "topic": question,
            "answer": "Support is available every day from 8 am to 10 pm. Most requests are resolved within one business day, and you can track progress from the Help tab.",
            "related": ["Reset password", "Update phone number", "Report a lost card"],
        ]
    }
}
