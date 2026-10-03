import Foundation

/// What `GET /v1/items/:id/snapshot` returns: Pluggy objects passed through by the Worker.
/// Decoding is lenient — Pluggy adds fields and enum values without versioning, so unknown keys are
/// ignored and enums are plain strings.
struct PluggySnapshot: Decodable, Sendable {
    let itemId: String
    let from: String
    let fetchedAt: Date
    let item: Item
    let accounts: [Account]
    let transactions: [String: [Transaction]]
    let investments: [Investment]
    let identity: Identity?
    /// Rows that failed to decode and were skipped instead of failing the whole sync.
    let skipped: Int
    /// Optional products Pluggy refused for this item (identity, loans, …), reported by the Worker.
    let warnings: [String]

    enum CodingKeys: String, CodingKey {
        case itemId, from, fetchedAt, item, accounts, transactions, investments, identity, warnings
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        itemId = try container.decode(String.self, forKey: .itemId)
        from = try container.decode(String.self, forKey: .from)
        fetchedAt = try container.decode(Date.self, forKey: .fetchedAt)
        item = try container.decode(Item.self, forKey: .item)
        let accountList = try container.decode(Lossy<Account>.self, forKey: .accounts)
        let investmentList = (try? container.decode(Lossy<Investment>.self, forKey: .investments)) ?? Lossy(elements: [], skipped: 0)
        let byAccount = (try? container.decode([String: Lossy<Transaction>].self, forKey: .transactions)) ?? [:]
        accounts = accountList.elements
        investments = investmentList.elements
        transactions = byAccount.mapValues(\.elements)
        identity = try? container.decodeIfPresent(Identity.self, forKey: .identity)
        warnings = (try? container.decodeIfPresent([String].self, forKey: .warnings)) ?? []
        skipped = accountList.skipped + investmentList.skipped + byAccount.values.reduce(0) { $0 + $1.skipped }
    }

    struct Item: Decodable, Sendable {
        let id: String
        let status: String
        let lastUpdatedAt: Date?
        let connector: Connector?
        struct Connector: Decodable, Sendable { let name: String }
    }

    struct Account: Decodable, Sendable {
        let id: String
        let type: String  // BANK | CREDIT
        let subtype: String
        let number: String?
        let name: String?
        let marketingName: String?
        let balance: Decimal?
        let currencyCode: String?
    }

    struct Transaction: Decodable, Sendable {
        let id: String
        let date: Date
        let description: String?
        let descriptionRaw: String?
        let amount: Decimal
        let type: String?  // DEBIT | CREDIT
        let status: String?  // POSTED | PENDING
        let operationType: String?
        let providerId: String?
        let category: String?
        let currencyCode: String?
        let merchant: Merchant?
        let paymentData: PaymentData?
        let creditCardMetadata: CardMetadata?

        enum CodingKeys: String, CodingKey {
            case id, date, description, descriptionRaw, amount, type, status, operationType, providerId, category, currencyCode
            case merchant, paymentData, creditCardMetadata
        }

        /// Only id, date and amount are required; any other field that doesn't decode is dropped, not fatal.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            date = try c.decode(Date.self, forKey: .date)
            amount = try c.decode(Decimal.self, forKey: .amount)
            description = try? c.decodeIfPresent(String.self, forKey: .description)
            descriptionRaw = try? c.decodeIfPresent(String.self, forKey: .descriptionRaw)
            type = try? c.decodeIfPresent(String.self, forKey: .type)
            status = try? c.decodeIfPresent(String.self, forKey: .status)
            operationType = try? c.decodeIfPresent(String.self, forKey: .operationType)
            providerId = try? c.decodeIfPresent(String.self, forKey: .providerId)
            category = try? c.decodeIfPresent(String.self, forKey: .category)
            currencyCode = try? c.decodeIfPresent(String.self, forKey: .currencyCode)
            merchant = try? c.decodeIfPresent(Merchant.self, forKey: .merchant)
            paymentData = try? c.decodeIfPresent(PaymentData.self, forKey: .paymentData)
            creditCardMetadata = try? c.decodeIfPresent(CardMetadata.self, forKey: .creditCardMetadata)
        }

        struct Merchant: Decodable, Sendable {
            let name: String?
            let businessName: String?
            let cnpj: String?
            let cnae: String?
            let category: String?
        }

        struct PaymentData: Decodable, Sendable {
            let payer: Party?
            let receiver: Party?
            let paymentMethod: String?
            let reason: String?
        }

        struct Party: Decodable, Sendable {
            let name: String?
            let accountNumber: String?
            let routingNumberISPB: String?
            let documentNumber: Document?
        }

        struct Document: Decodable, Sendable {
            let type: String?  // CPF | CNPJ
            let value: String?
        }

        struct CardMetadata: Decodable, Sendable {
            let installmentNumber: Int?
            let totalInstallments: Int?
            let totalAmount: Decimal?
            let purchaseDate: Date?
            let payeeMCC: Int?
            let cardNumber: String?

            enum CodingKeys: String, CodingKey {
                case installmentNumber, totalInstallments, totalAmount, purchaseDate, payeeMCC, cardNumber
            }

            // Numbers sometimes arrive as strings ("5734"); accept both, and ignore what can't be read.
            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                installmentNumber = container.flexibleInt(.installmentNumber)
                totalInstallments = container.flexibleInt(.totalInstallments)
                totalAmount = try? container.decodeIfPresent(Decimal.self, forKey: .totalAmount)
                purchaseDate = try? container.decodeIfPresent(Date.self, forKey: .purchaseDate)
                payeeMCC = container.flexibleInt(.payeeMCC)
                cardNumber = (try? container.decodeIfPresent(String.self, forKey: .cardNumber)) ?? container.flexibleInt(.cardNumber).map(String.init)
            }
        }
    }

    struct Investment: Decodable, Sendable {
        let id: String
        let name: String?
        let type: String?
        let subtype: String?
        let balance: Decimal?
        let amount: Decimal?
        let status: String?
        let dueDate: Date?
    }

    struct Identity: Decodable, Sendable {
        let fullName: String?
        let document: String?
        let documentType: String?
    }
}

/// Decodes an array element by element, keeping what decodes and counting what doesn't.
struct Lossy<Element: Decodable>: Decodable {
    var elements: [Element]
    var skipped: Int

    init(elements: [Element], skipped: Int) {
        self.elements = elements
        self.skipped = skipped
    }

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var elements: [Element] = []
        var skipped = 0
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                elements.append(element)
            } else {
                _ = try? container.decode(Skip.self)
                skipped += 1
            }
        }
        self.elements = elements
        self.skipped = skipped
    }

    private struct Skip: Decodable {}
}

extension KeyedDecodingContainer {
    func flexibleInt(_ key: Key) -> Int? {
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return value }
        if let text = try? decodeIfPresent(String.self, forKey: key) { return Int(text.filter(\.isNumber)) }
        if let value = try? decodeIfPresent(Double.self, forKey: key) { return Int(value) }
        return nil
    }
}

extension Decimal {
    /// Rounds to centavos — Pluggy sends amounts as JSON numbers.
    var cents: Int64 {
        var value = self * 100
        var rounded = Decimal()
        NSDecimalRound(&rounded, &value, 0, .plain)
        return NSDecimalNumber(decimal: rounded).int64Value
    }
}
