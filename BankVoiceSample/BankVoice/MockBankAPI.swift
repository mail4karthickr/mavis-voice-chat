import Foundation

enum BankScenario: String, CaseIterable, Identifiable, Sendable {
    case balance, transactions, card, payment

    var id: String { rawValue }

    var title: String {
        switch self {
        case .balance: "Account balance"
        case .transactions: "Recent transactions"
        case .card: "Card details"
        case .payment: "Payment status"
        }
    }

    var query: String {
        switch self {
        case .balance: "How much money is available in my account?"
        case .transactions: "What are my three most recent transactions?"
        case .card: "Is my card active, and how much credit is available?"
        case .payment: "Did my payment to Asha go through?"
        }
    }

    var symbol: String {
        switch self {
        case .balance: "indianrupeesign.circle"
        case .transactions: "list.bullet.rectangle"
        case .card: "creditcard"
        case .payment: "checkmark.circle"
        }
    }

    var endpoint: String {
        switch self {
        case .balance: "/mock/v1/accounts/demo-savings/balance"
        case .transactions: "/mock/v1/accounts/demo-savings/transactions"
        case .card: "/mock/v1/cards/demo-credit-card"
        case .payment: "/mock/v1/payments/DEMO-PAY-20260917-01"
        }
    }

    /// A deliberately small read-only router. It never treats an action as a successful API call.
    static func route(_ query: String) -> BankScenario? {
        let words = query.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let tokens = Set(words.map(String.init))
        let text = " " + words.joined(separator: " ") + " "
        guard !tokens.isEmpty else { return nil }

        let mutationWords: Set<String> = [
            "send", "pay", "repay", "withdraw", "deposit", "move", "borrow", "apply",
            "open", "close", "block", "unblock", "freeze", "unfreeze", "activate",
            "deactivate", "increase", "decrease", "change", "update", "reset", "cancel",
            "reverse", "refund", "dispute", "delete", "add", "remove", "buy", "sell",
            "invest", "schedule", "make", "initiate", "execute", "create"
        ]
        guard tokens.isDisjoint(with: mutationWords) else { return nil }
        guard tokens.isDisjoint(with: ["loan", "loans", "mortgage", "mortgages", "insurance", "investment", "investments"]) else {
            return nil
        }

        let paymentInquiry = tokens.contains("status") || tokens.contains("completed")
            || tokens.contains("successful") || tokens.contains("pending")
            || text.contains(" go through ") || text.contains(" went through ")
        // "Transfer" can be an action or the name of an existing payment.
        if tokens.contains("transfer") || tokens.contains("transfers") {
            let referencesExistingTransfer = [
                " my transfer ", " the transfer ", " this transfer ", " that transfer ",
                " existing transfer ", " previous transfer ", " last transfer ", " earlier transfer "
            ].contains(where: text.contains) || text == " transfer status "
            guard paymentInquiry,
                  referencesExistingTransfer,
                  !(words.first == "transfer" && text != " transfer status "),
                  !text.contains(" transfer money "),
                  !text.contains(" transfer funds "),
                  !text.contains(" you transfer "),
                  !text.contains(" to transfer "),
                  !text.contains(" and transfer "),
                  !text.contains(" then transfer ") else { return nil }
        }
        if !tokens.isDisjoint(with: ["payment", "payments", "transfer", "transfers"]) {
            return paymentInquiry ? .payment : nil
        }
        if !tokens.isDisjoint(with: ["card", "cards"]) || text.contains(" credit limit ") {
            return .card
        }
        if !tokens.isDisjoint(with: ["transaction", "transactions", "statement", "purchases"]) || text.contains(" recent spending ") {
            return .transactions
        }
        if tokens.contains("balance") || text.contains(" money is available ")
            || text.contains(" money do i have ") || text.contains(" available funds ") {
            return .balance
        }
        return nil
    }
}

struct BankReply: Sendable {
    let scenario: BankScenario
    let json: String
    /// Deterministically formatted from decoded JSON; these remain the authoritative facts.
    let facts: [String]
    var directSpeech: String { facts.joined(separator: " ") }
}

/// Entirely fictional read-only endpoints. No URLSession, real accounts, or banking actions.
struct MockBankAPI: Sendable {
    private let delay: Duration

    init(delay: Duration = .seconds(2)) {
        self.delay = delay
    }

    func fetch(_ scenario: BankScenario) async throws -> BankReply {
        try await Task.sleep(for: delay)
        try Task.checkCancellation()

        switch scenario {
        case .balance:
            let data = BalanceData(
                account: Account(id: "demo-savings", type: "savings", lastFour: "4821"),
                availableBalance: Money(minorUnits: 4_825_075),
                currentBalance: Money(minorUnits: 5_125_075),
                asOf: "2026-09-18"
            )
            return try decodeFixture(scenario, data: data) { value in
                [
                    "Your demo savings account ending in \(spokenDigits(value.account.lastFour)) has \(value.availableBalance.spoken) available as of \(spokenDate(value.asOf)).",
                    "Your current balance is \(value.currentBalance.spoken)."
                ]
            }
        case .transactions:
            let data = TransactionsData(
                account: Account(id: "demo-savings", type: "savings", lastFour: "4821"),
                transactions: [
                    Transaction(id: "DEMO-TXN-003", date: "2026-09-17", description: "Grocerlane Demo", direction: .debit, amount: Money(minorUnits: 184_550)),
                    Transaction(id: "DEMO-TXN-002", date: "2026-09-16", description: "CloudTel Demo", direction: .debit, amount: Money(minorUnits: 79_900)),
                    Transaction(id: "DEMO-TXN-001", date: "2026-09-15", description: "Example Employer", direction: .credit, amount: Money(minorUnits: 7_500_000))
                ]
            )
            return try decodeFixture(scenario, data: data) { value in
                ["Your demo account's three recent transactions are:"]
                    + value.transactions.map { transaction in
                        let movement = transaction.direction == .debit
                            ? "you spent \(transaction.amount.spoken) at \(transaction.description)"
                            : "you received \(transaction.amount.spoken) from \(transaction.description)"
                        return "On \(spokenDate(transaction.date)), \(movement)."
                    }
            }
        case .card:
            let data = CardData(
                card: Card(id: "demo-credit-card", type: "credit", lastFour: "9012", status: "active"),
                limits: CardLimits(total: Money(minorUnits: 20_000_000), available: Money(minorUnits: 17_245_025))
            )
            return try decodeFixture(scenario, data: data) { value in
                [
                    "Your demo credit card ending in \(spokenDigits(value.card.lastFour)) is \(value.card.status).",
                    "The total credit limit is \(value.limits.total.spoken).",
                    "Your available credit is \(value.limits.available.spoken)."
                ]
            }
        case .payment:
            let data = PaymentData(
                payment: Payment(
                    id: "DEMO-PAY-20260917-01", beneficiary: "Asha Demo", amount: Money(minorUnits: 1_250_000),
                    status: "completed", completedOn: "2026-09-17", channel: "IMPS"
                )
            )
            return try decodeFixture(scenario, data: data) { value in
                [
                    "Your existing demo payment of \(value.payment.amount.spoken) to \(value.payment.beneficiary) \(value.payment.status) on \(spokenDate(value.payment.completedOn)).",
                    "This is the status of an existing payment. No new payment was made."
                ]
            }
        }
    }

    private func decodeFixture<Value: Codable & Sendable>(
        _ scenario: BankScenario,
        data: Value,
        facts: (Value) -> [String]
    ) throws -> BankReply {
        let fixture = APIEnvelope(
            demo: true,
            endpoint: scenario.endpoint,
            customer: Customer(id: "demo-customer-001", alias: "Sample Customer"),
            data: data
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let payload = try encoder.encode(fixture)
        // Exercise the same typed decoding boundary that a real HTTP response would use.
        let decoded = try JSONDecoder().decode(APIEnvelope<Value>.self, from: payload)
        try Task.checkCancellation()
        return BankReply(scenario: scenario, json: String(decoding: payload, as: UTF8.self), facts: facts(decoded.data))
    }
}

private struct APIEnvelope<Value: Codable & Sendable>: Codable, Sendable {
    let demo: Bool
    let endpoint: String
    let customer: Customer
    let data: Value
}

private struct Customer: Codable, Sendable {
    let id: String
    let alias: String
}

private struct Account: Codable, Sendable {
    let id: String
    let type: String
    let lastFour: String
}

private struct Money: Codable, Sendable {
    let currency: String
    let minorUnits: Int

    init(minorUnits: Int) {
        self.currency = "INR"
        self.minorUnits = minorUnits
    }

    var spoken: String {
        let rupees = minorUnits / 100
        let paise = minorUnits % 100
        let digits = Array(String(rupees))
        let grouped = digits.enumerated().map { index, digit in
            (index > 0 && (digits.count - index).isMultiple(of: 3) ? "," : "") + String(digit)
        }.joined()
        let amount = "\(grouped) \(rupees == 1 ? "rupee" : "rupees")"
        return paise == 0 ? amount : "\(amount) and \(paise) \(paise == 1 ? "paisa" : "paise")"
    }
}

private struct BalanceData: Codable, Sendable {
    let account: Account
    let availableBalance: Money
    let currentBalance: Money
    let asOf: String
}

private struct TransactionsData: Codable, Sendable {
    let account: Account
    let transactions: [Transaction]
}

private struct Transaction: Codable, Sendable {
    enum Direction: String, Codable, Sendable { case debit, credit }
    let id: String
    let date: String
    let description: String
    let direction: Direction
    let amount: Money
}

private struct CardData: Codable, Sendable {
    let card: Card
    let limits: CardLimits
}

private struct Card: Codable, Sendable {
    let id: String
    let type: String
    let lastFour: String
    let status: String
}

private struct CardLimits: Codable, Sendable {
    let total: Money
    let available: Money
}

private struct PaymentData: Codable, Sendable {
    let payment: Payment
}

private struct Payment: Codable, Sendable {
    let id: String
    let beneficiary: String
    let amount: Money
    let status: String
    let completedOn: String
    let channel: String
}

private func spokenDigits(_ text: String) -> String {
    text.map(String.init).joined(separator: " ")
}

private func spokenDate(_ isoDate: String) -> String {
    let components = isoDate.split(separator: "-")
    let months = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
    guard components.count == 3, let month = Int(components[1]), (1...12).contains(month),
          let day = Int(components[2]) else { return isoDate }
    return "\(day) \(months[month - 1]) \(components[0])"
}
