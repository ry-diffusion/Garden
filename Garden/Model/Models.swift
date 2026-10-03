import Foundation
import SwiftData

// CloudKit-safe SwiftData models (DESIGN §12):
// every stored property has a default, every relationship is optional,
// no #Unique (identity is enforced via deterministic ids + provenance keys),
// money is Int64 centavos, enums are stored as raw strings.

// MARK: - Account

@Model
final class Account {
    var id: UUID = UUID()
    var name: String = ""
    var institution: String = ""
    var kindRaw: String = AccountKind.checking.rawValue
    var spaceRaw: String = "pessoal"
    /// sha256(ISPB | branch | number | subtype) — survives Pluggy reconnects.
    var stableAcct: String = ""
    var pluggyAccountId: String?
    /// Account or card number digits, to match Pix/TED counterparts against my own accounts.
    var number: String?
    var balanceCents: Int64 = 0
    var currency: String = "BRL"
    var isArchived: Bool = false
    var sortOrder: Int = 0
    var createdAt: Date = Date.now

    @Relationship(deleteRule: .nullify, inverse: \Movement.account) var movements: [Movement]? = []
    @Relationship(deleteRule: .cascade, inverse: \Holding.account) var holdings: [Holding]? = []

    init(name: String, institution: String, kind: AccountKind, balance: Money = .zero) {
        self.id = UUID()
        self.name = name
        self.institution = institution
        self.kindRaw = kind.rawValue
        self.balanceCents = balance.cents
    }

    var kind: AccountKind {
        get { AccountKind(rawValue: kindRaw) ?? .manual }
        set { kindRaw = newValue.rawValue }
    }

    var balance: Money { Money(cents: balanceCents, currency: currency) }
}

enum AccountKind: String, CaseIterable, Codable, Sendable {
    case checking, savings, credit, investment, cash, manual

    var label: String {
        switch self {
        case .checking: "Conta corrente"
        case .savings: "Poupança"
        case .credit: "Cartão de crédito"
        case .investment: "Investimentos"
        case .cash: "Carteira"
        case .manual: "Outra"
        }
    }

    var symbol: String {
        switch self {
        case .checking: "building.columns"
        case .savings: "banknote"
        case .credit: "creditcard"
        case .investment: "chart.line.uptrend.xyaxis"
        case .cash: "wallet.bifold"
        case .manual: "tray"
        }
    }

    var isLiability: Bool { self == .credit }
}

// MARK: - Movement (a transaction; named after "Movimentação" to avoid SwiftUI.Transaction)

@Model
final class Movement {
    /// UUIDv5 of the first provenance key, so the same record created on two devices collapses.
    var id: UUID = UUID()
    var provenanceKeys: [String] = []
    /// Signed: negative = money out, positive = money in.
    var amountCents: Int64 = 0
    var currency: String = "BRL"
    var originalAmountCents: Int64?
    var originalCurrency: String?
    var date: Date = Date.now
    var createdAt: Date = Date.now
    var kindRaw: String = MovementKind.expense.rawValue
    var statusRaw: String = MovementStatus.posted.rawValue
    var sourceRaw: String = MovementSource.manual.rawValue
    var rawDescription: String = ""
    var note: String = ""
    var latitude: Double?
    var longitude: Double?
    var placeName: String?
    var categoryConfidence: Double = 0
    var reviewed: Bool = false
    var userEdited: Bool = false
    var installmentNumber: Int?
    var linkKindRaw: String?
    var cardName: String?
    /// Open Finance end-to-end id (Pix E2E). The same id on two of my accounts = a transfer between them.
    var providerId: String?
    /// Pluggy operationType: PIX, TED, BOLETO, SAQUE, PAGAMENTO_FATURA, APLICACAO…
    var operationType: String?
    /// Card merchant category code, when the bank sends it.
    var mcc: String?
    /// The aggregator's own category label — the weakest categorization hint.
    var providerCategory: String?
    /// Digits of the other side's account, to recognize transfers to my own accounts.
    var counterpartyAccount: String?

    var account: Account?
    var merchant: Merchant?
    var person: Person?
    var category: SpendCategory?
    var budgetOverride: Budget?
    var installmentPlan: InstallmentPlan?
    var linkedTo: Movement?
    @Relationship(deleteRule: .nullify, inverse: \Movement.linkedTo) var linkedFrom: [Movement]? = []
    @Relationship(deleteRule: .nullify, inverse: \Bill.paidBy) var paidBills: [Bill]? = []

    init(primaryKey: String, amount: Money, date: Date, kind: MovementKind, source: MovementSource,
         status: MovementStatus = .posted, rawDescription: String = "") {
        self.id = StableID.uuid(for: primaryKey)
        self.provenanceKeys = [primaryKey]
        self.amountCents = amount.cents
        self.currency = amount.currency
        self.date = date
        self.kindRaw = kind.rawValue
        self.sourceRaw = source.rawValue
        self.statusRaw = status.rawValue
        self.rawDescription = rawDescription
    }

    var amount: Money {
        get { Money(cents: amountCents, currency: currency) }
        set { amountCents = newValue.cents; currency = newValue.currency }
    }

    var kind: MovementKind {
        get { MovementKind(rawValue: kindRaw) ?? .expense }
        set { kindRaw = newValue.rawValue }
    }

    var status: MovementStatus {
        get { MovementStatus(rawValue: statusRaw) ?? .posted }
        set { statusRaw = newValue.rawValue }
    }

    var source: MovementSource { MovementSource(rawValue: sourceRaw) ?? .manual }


    /// Amount minus linked credits (refunds, racha reimbursements, cashback) — DESIGN §6.
    var netCost: Money {
        let credits = (linkedFrom ?? [])
            .filter { $0.status != .tombstoned && $0.amountCents > 0 }
            .reduce(Int64(0)) { $0 + $1.amountCents }
        return Money(cents: min(amountCents + credits, 0), currency: currency)
    }

    var countsAsSpending: Bool {
        // An installment header (the full price captured at the register) is represented by its parcels.
        kind == .expense && status != .tombstoned && linkedTo == nil && linkKindRaw != "installmentHeader"
    }

    var displayTitle: String {
        // A transfer between my accounts reads as the route, even when the bank names me as the other side.
        if kind == .transfer, linkKindRaw == "transferPair" {
            let incoming = amountCents > 0 ? self : linkedFrom?.first
            let outgoing = amountCents > 0 ? linkedTo : self
            if let card = incoming?.account, card.kind == .credit { return String(localized: "Fatura \(card.name)") }
            if let from = outgoing?.institutionLabel, let to = incoming?.institutionLabel { return "\(from) → \(to)" }
            return String(localized: "Entre minhas contas")
        }
        if let merchant { return merchant.displayName }
        if let person { return person.isMe ? String(localized: "Entre minhas contas") : person.displayName }
        if source == .notification || source == .applePay {
            // Anonymous captures read as what happened, not as the raw notification title.
            switch kind {
            case .income, .extraIncome: return String(localized: "Dinheiro recebido")
            case .transfer: return String(localized: "Entre minhas contas")
            default: return rawDescription.normalizedForMatching.contains("PIX")
                ? String(localized: "Pix enviado") : String(localized: "Pagamento")
            }
        }
        if rawDescription.isEmpty { return String(localized: "Sem descrição") }
        if source == .manual { return rawDescription }
        // Pluggy descriptions are "Operação|Contraparte"; the counterpart reads better.
        let label = MerchantRules.splitOperation(rawDescription).name
        return MerchantRules.displayName(from: label.normalizedForMatching)
    }

    /// "Nubank", "BTG" — the bank behind this movement.
    var institutionLabel: String? {
        if let account, account.kind == .cash { return account.name }
        if let institution = account?.institution, !institution.isEmpty { return Institutions.shortName(institution) }
        return cardName
    }

    var hasLocation: Bool { latitude != nil && longitude != nil }

    /// Who paid this (incoming) or was paid (outgoing).
    var isFromSalarySource: Bool { merchant?.isSalarySource == true || person?.isSalarySource == true }
    var isSalary: Bool { amountCents > 0 && kind == .income && category?.key == "salario" }

    /// The incoming half of a transfer between my accounts. Lists show the pair once, as its outgoing
    /// side ("BTG → Nubank"), so this half is hidden from them.
    var isMirrorSide: Bool { linkKindRaw == "transferPair" && amountCents > 0 && linkedTo != nil }

    /// Rows lists skip: the mirror half of a transfer, and rows the bank removed (kept 30 days as tombstones).
    var isHiddenFromLists: Bool { isMirrorSide || status == .tombstoned }
}

enum MovementKind: String, CaseIterable, Codable, Sendable {
    case expense, income, transfer, refund, extraIncome

    var label: String {
        switch self {
        case .expense: "Gasto"
        case .income: "Entrada"
        case .transfer: "Entre minhas contas"
        case .refund: "Estorno"
        case .extraIncome: "Renda extra"
        }
    }
}

enum MovementStatus: String, Codable, Sendable {
    case provisional, pending, posted, tombstoned
}

enum MovementSource: String, Codable, Sendable {
    case applePay, notification, pluggy, ofx, csv, manual

    var label: String {
        switch self {
        case .applePay: "Apple Pay"
        case .notification: "Notificação do banco"
        case .pluggy: "Open Finance"
        case .ofx: "OFX"
        case .csv: "CSV"
        case .manual: "Manual"
        }
    }
}

// MARK: - Merchant

@Model
final class Merchant {
    var id: UUID = UUID()
    var displayName: String = ""
    var legalName: String?
    var cnpj: String?
    var cnae: String?
    var kindRaw: String = MerchantKind.local.rawValue
    /// The brand's own website, used to fetch its logo ("uber.com").
    var domain: String?
    /// Registered address from the CNPJ registry, for the map.
    var address: String?
    /// Normalized names this merchant has been seen under (alias table).
    var aliases: [String] = []
    var latitude: Double?
    var longitude: Double?
    var createdAt: Date = Date.now
    /// Money from this payer is salary (an employer, or the client a freelancer bills monthly).
    var isSalarySource: Bool = false

    var budget: Budget?
    /// Merchant memory: last confirmed category.
    var category: SpendCategory?
    @Relationship(deleteRule: .nullify, inverse: \Movement.merchant) var movements: [Movement]? = []
    @Relationship(deleteRule: .nullify, inverse: \InstallmentPlan.merchant) var installmentPlans: [InstallmentPlan]? = []

    init(displayName: String, kind: MerchantKind = .local) {
        // Deterministic so two devices resolving the same name converge.
        self.id = StableID.uuid(for: "merchant:" + displayName.normalizedForMatching)
        self.displayName = displayName
        self.kindRaw = kind.rawValue
        self.aliases = [displayName.normalizedForMatching]
    }

    var kind: MerchantKind {
        get { MerchantKind(rawValue: kindRaw) ?? .local }
        set { kindRaw = newValue.rawValue }
    }
}

enum MerchantKind: String, CaseIterable, Codable, Sendable {
    case chain, local, online, government

    var label: String {
        switch self {
        case .chain: "Rede"
        case .local: "Local"
        case .online: "Online"
        case .government: "Governo"
        }
    }
}

// MARK: - Person

@Model
final class Person {
    var id: UUID = UUID()
    var displayName: String = ""
    /// HMAC(deviceKey, visible CPF digits) — never the plain or bare-hashed CPF (DESIGN §8).
    var cpfHmac: String?
    var cpfMask: String?
    var isMe: Bool = false
    var household: Bool = false
    var isSalarySource: Bool = false

    @Relationship(deleteRule: .nullify, inverse: \Movement.person) var movements: [Movement]? = []
    @Relationship(deleteRule: .nullify, inverse: \InstallmentPlan.person) var installmentPlans: [InstallmentPlan]? = []

    init(displayName: String, isMe: Bool = false) {
        self.displayName = displayName
        self.isMe = isMe
    }
}

// MARK: - Category

@Model
final class SpendCategory {
    var id: UUID = UUID()
    /// Stable machine key, e.g. "mercado".
    var key: String = ""
    var name: String = ""
    var symbol: String = "circle"
    var tintRaw: String = CategoryTint.gray.rawValue
    var isSystem: Bool = false
    var sortOrder: Int = 0
    /// Spending limit per pay cycle; 0 = no limit. Categories are the budgets (one limit each).
    var limitCents: Int64 = 0
    /// Unspent limit carries into the next cycle.
    var rollover: Bool = false

    /// Legacy (v0.2 grouped "Limites"): kept so existing stores and CloudKit schemas stay compatible.
    var budget: Budget?
    @Relationship(deleteRule: .nullify, inverse: \Movement.category) var movements: [Movement]? = []
    @Relationship(deleteRule: .nullify, inverse: \Merchant.category) var merchants: [Merchant]? = []

    init(key: String, name: String, symbol: String, tint: CategoryTint, sortOrder: Int, isSystem: Bool = true) {
        self.id = StableID.uuid(for: "category:" + key)
        self.key = key
        self.name = name
        self.symbol = symbol
        self.tintRaw = tint.rawValue
        self.sortOrder = sortOrder
        self.isSystem = isSystem
    }

    var tint: CategoryTint { CategoryTint(rawValue: tintRaw) ?? .gray }

    var limit: Money? { limitCents > 0 ? Money(cents: limitCents) : nil }

    /// Categories that describe money moving in or between accounts — never a spending limit.
    var isIncomeOrTransfer: Bool { ["renda", "salario", "transferencias"].contains(key) }
}

// MARK: - Budget (legacy)

/// Legacy grouped limits from v0.2. Garden now puts one limit on each category (`SpendCategory.limitCents`);
/// this model stays in the schema only so existing stores open.

@Model
final class Budget {
    var id: UUID = UUID()
    var name: String = ""
    var symbol: String = "circle"
    var tintRaw: String = CategoryTint.gray.rawValue
    var limitCents: Int64 = 0
    var rollover: Bool = false
    var plannedBigPurchaseCents: Int64 = 0
    var sortOrder: Int = 0
    var createdAt: Date = Date.now

    @Relationship(deleteRule: .nullify, inverse: \SpendCategory.budget) var categories: [SpendCategory]? = []
    @Relationship(deleteRule: .nullify, inverse: \Merchant.budget) var merchants: [Merchant]? = []
    @Relationship(deleteRule: .nullify, inverse: \Movement.budgetOverride) var overrides: [Movement]? = []

    init(name: String, symbol: String, tint: CategoryTint, limit: Money, sortOrder: Int = 0) {
        self.name = name
        self.symbol = symbol
        self.tintRaw = tint.rawValue
        self.limitCents = limit.cents
        self.sortOrder = sortOrder
    }

    var limit: Money {
        get { Money(cents: limitCents) }
        set { limitCents = newValue.cents }
    }

    var tint: CategoryTint { CategoryTint(rawValue: tintRaw) ?? .gray }
}

// MARK: - Installment plan ("Parcelamento")

@Model
final class InstallmentPlan {
    var id: UUID = UUID()
    var title: String = ""
    var originRaw: String = "card"
    var accountingRaw: String = "perParcel"
    var totalCents: Int64 = 0
    var count: Int = 1
    var firstDue: Date = Date.now
    var createdAt: Date = Date.now

    var merchant: Merchant?
    var person: Person?
    @Relationship(deleteRule: .nullify, inverse: \Movement.installmentPlan) var parcels: [Movement]? = []

    init(title: String, origin: String, total: Money, count: Int, firstDue: Date) {
        self.title = title
        self.originRaw = origin
        self.totalCents = total.cents
        self.count = count
        self.firstDue = firstDue
    }
}

// MARK: - Bill ("Contas a pagar")

@Model
final class Bill {
    var id: UUID = UUID()
    var title: String = ""
    var kindRaw: String = "boleto"
    var due: Date = Date.now
    var amountCents: Int64 = 0
    var isPaid: Bool = false
    var createdAt: Date = Date.now
    var paidBy: Movement?

    init(title: String, kind: String, due: Date, amount: Money) {
        self.title = title
        self.kindRaw = kind
        self.due = due
        self.amountCents = amount.cents
    }
}

// MARK: - Holding

@Model
final class Holding {
    var id: UUID = UUID()
    var pluggyId: String?
    var name: String = ""
    var typeRaw: String = "FIXED_INCOME"
    var netCents: Int64 = 0
    var liquidityDate: Date?
    var dailyLiquidity: Bool = false
    var account: Account?

    init(name: String, type: String, net: Money, dailyLiquidity: Bool, liquidityDate: Date? = nil) {
        self.name = name
        self.typeRaw = type
        self.netCents = net.cents
        self.dailyLiquidity = dailyLiquidity
        self.liquidityDate = liquidityDate
    }
}

// MARK: - Net worth snapshot

@Model
final class NetWorthSnapshot {
    /// UUIDv5("nw:" + yyyy-MM-dd) so concurrent writers collapse into one row per day.
    var id: UUID = UUID()
    var day: Date = Date.now
    var assetsCents: Int64 = 0
    var liabilitiesCents: Int64 = 0

    init(day: Date, assets: Money, liabilities: Money) {
        let key = day.formatted(.iso8601.year().month().day())
        self.id = StableID.uuid(for: "nw:" + key)
        self.day = day
        self.assetsCents = assets.cents
        self.liabilitiesCents = liabilities.cents
    }
}

// MARK: - Tints (data colors for categories/budgets — the app accent stays Garden green)

enum CategoryTint: String, CaseIterable, Codable, Sendable {
    case green, teal, blue, indigo, purple, pink, red, orange, yellow, brown, gray
}
