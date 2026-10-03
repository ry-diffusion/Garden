import CoreLocation
import Foundation
import SwiftData

/// The write path for every source (DESIGN §4). Phase 0 covers manual entry and on-device captures;
/// the Pluggy and OFX sources plug into the same steps later.
@MainActor
struct Ledger {
    let context: ModelContext

    struct Capture {
        var amount: Money
        var direction: NotificationParser.Direction = .outgoing
        var method: NotificationParser.Method = .unknown
        /// Merchant (purchase), recipient (Pix out) or payer (money in).
        var merchantName: String?
        var counterpartyDocument: String?
        /// Bank or card label from the automation ("Nubank", "final 1234").
        var cardName: String?
        var source: MovementSource
        var date: Date = .now
        var location: CLLocationCoordinate2D?
        var placeName: String?
        var rawText: String?
        var memo: String?
        var installments: Int?

        var isPersonToPerson: Bool { method == .pix || method == .transfer }
    }

    enum CaptureOutcome {
        case inserted(Movement)
        /// The Wallet and bank-notification automations both fired for one purchase.
        case mergedIntoExisting(Movement)
    }

    // MARK: Manual entry (F1)

    @discardableResult
    func addManual(amount: Money, kind: MovementKind, merchantName: String?, account: Account?,
                   date: Date = .now) -> Movement {
        let signed = kind == .expense ? -amount.magnitude : amount.magnitude
        let movement = Movement(primaryKey: "man:\(UUID().uuidString)", amount: signed, date: date,
                                kind: kind, source: .manual, rawDescription: merchantName ?? "")
        movement.account = account
        movement.reviewed = true  // the user just typed it
        context.insert(movement)
        if let merchantName, !merchantName.isEmpty {
            movement.merchant = resolveMerchant(named: merchantName)
        }
        categorize(movement)
        save()
        return movement
    }

    // MARK: Automation captures (F2)

    func record(_ capture: Capture) -> CaptureOutcome {
        if let twin = captureTwin(of: capture) {
            // Enrich, never duplicate: keep whichever fields the first capture lacked.
            if twin.merchant == nil, twin.person == nil, let name = capture.merchantName { attachCounterparty(name, document: capture.counterpartyDocument, to: twin, capture: capture) }
            if twin.latitude == nil, let location = capture.location {
                twin.latitude = location.latitude
                twin.longitude = location.longitude
                twin.placeName = capture.placeName
            }
            if twin.cardName == nil { twin.cardName = capture.cardName }
            twin.provenanceKeys.append(provenanceKey(for: capture))
            if twin.category == nil { categorize(twin) }
            save()
            return .mergedIntoExisting(twin)
        }

        let incoming = capture.direction == .incoming
        let movement = Movement(primaryKey: provenanceKey(for: capture),
                                amount: incoming ? capture.amount.magnitude : -capture.amount.magnitude,
                                date: capture.date, kind: incoming ? .income : .expense,
                                source: capture.source, status: .provisional,
                                rawDescription: capture.rawText ?? capture.merchantName ?? "")
        movement.cardName = capture.cardName
        movement.note = capture.memo ?? ""
        movement.latitude = capture.location?.latitude
        movement.longitude = capture.location?.longitude
        movement.placeName = capture.placeName
        movement.account = account(institution: capture.cardName, method: capture.method)
        context.insert(movement)
        if let name = capture.merchantName {
            attachCounterparty(name, document: capture.counterpartyDocument, to: movement, capture: capture)
        }
        categorize(movement)
        pairOwnTransfer(movement)
        save()
        return .inserted(movement)
    }

    private func attachCounterparty(_ name: String, document: String?, to movement: Movement, capture: Capture) {
        let isCompany = document.map { $0.contains("/") } ?? false
        if capture.isPersonToPerson && !isCompany {
            movement.person = resolvePerson(named: name)
        } else {
            let merchant = resolveMerchant(named: name)
            if let document, isCompany, merchant.cnpj == nil { merchant.cnpj = document }
            movement.merchant = merchant
        }
    }

    /// Same signed amount within ±10 minutes from another capture source — the Wallet and the
    /// bank-notification automations firing for one purchase (DESIGN §4.3, capture-vs-capture).
    private func captureTwin(of capture: Capture) -> Movement? {
        let cents = capture.direction == .incoming ? capture.amount.magnitude.cents : -capture.amount.magnitude.cents
        let from = capture.date.addingTimeInterval(-600)
        let to = capture.date.addingTimeInterval(600)
        let manual = MovementSource.manual.rawValue
        let descriptor = FetchDescriptor<Movement>(predicate: #Predicate {
            $0.amountCents == cents && $0.date >= from && $0.date <= to && $0.sourceRaw != manual
        })
        let candidates = (try? context.fetch(descriptor)) ?? []
        return candidates.first { $0.source != capture.source }
    }

    /// Money leaving one of my banks and arriving at another, same amount, minutes apart, with no
    /// third party named on at least one side → "Entre minhas contas" (DESIGN §8, real-time).
    /// Seen in practice: BTG "A transferência Pix de R$ 6.000,00 foi confirmada" + Nubank
    /// "Recebemos sua transferência de R$ 6.000,00", both at 17:14.
    private func pairOwnTransfer(_ movement: Movement) {
        guard movement.status == .provisional, movement.kind != .transfer else { return }
        let opposite = -movement.amountCents
        let from = movement.date.addingTimeInterval(-900)
        let to = movement.date.addingTimeInterval(900)
        let provisional = MovementStatus.provisional.rawValue
        let descriptor = FetchDescriptor<Movement>(predicate: #Predicate {
            $0.amountCents == opposite && $0.date >= from && $0.date <= to && $0.statusRaw == provisional
        })
        let candidates = ((try? context.fetch(descriptor)) ?? []).filter { other in
            other.kind != .transfer
                && !sameInstitution(movement, other)
                && (isAnonymous(movement) || isAnonymous(other))
        }
        guard let match = candidates.min(by: {
            abs($0.date.timeIntervalSince(movement.date)) < abs($1.date.timeIntervalSince(movement.date))
        }) else { return }

        let transfers = category(forKey: "transferencias")
        for side in [movement, match] {
            side.kind = .transfer
            side.category = transfers
            side.categoryConfidence = 0.9
            side.linkKindRaw = "transferPair"
            side.reviewed = true
        }
        let incoming = movement.amountCents > 0 ? movement : match
        let outgoing = incoming === movement ? match : movement
        incoming.linkedTo = outgoing
    }

    /// A side with no third party named — or one that names me.
    private func isAnonymous(_ movement: Movement) -> Bool {
        if let person = movement.person { return person.isMe }
        return movement.merchant == nil
    }

    private func sameInstitution(_ a: Movement, _ b: Movement) -> Bool {
        let lhs = (a.account?.institution ?? a.cardName ?? "").normalizedForMatching
        let rhs = (b.account?.institution ?? b.cardName ?? "").normalizedForMatching
        return !lhs.isEmpty && lhs == rhs
    }

    private func provenanceKey(for capture: Capture) -> String {
        let minute = Int(capture.date.timeIntervalSince1970 / 60)
        let body = (capture.rawText ?? capture.merchantName ?? "").normalizedForMatching
        return "cap:\(capture.source.rawValue):" + StableID.sha256("\(body)|\(capture.amount.cents)|\(minute)")
    }

    /// Debit, Pix and transfers land on the bank account; credit on the card.
    private func account(institution label: String?, method: NotificationParser.Method) -> Account? {
        guard let label = label?.normalizedForMatching, !label.isEmpty else { return nil }
        let accounts = ((try? context.fetch(FetchDescriptor<Account>())) ?? []).filter { !$0.isArchived }
        let matching = accounts.filter {
            let name = $0.name.normalizedForMatching, institution = $0.institution.normalizedForMatching
            return (!name.isEmpty && label.contains(name)) || (!institution.isEmpty && (label.contains(institution) || institution.contains(label)))
        }
        if method == .credit {
            return matching.first { $0.kind == .credit } ?? matching.first
        }
        let preference: [AccountKind] = [.checking, .savings, .manual, .investment]
        return preference.lazy.compactMap { kind in matching.first { $0.kind == kind } }.first ?? matching.first
    }

    // MARK: Merchant & person resolution (DESIGN §5)

    func resolveMerchant(named rawName: String) -> Merchant {
        let unwrapped = MerchantRules.unwrap(rawName)
        let brand = BrandCatalog.match(unwrapped)
        let display = brand?.name ?? MerchantRules.displayName(from: unwrapped)
        let id = StableID.uuid(for: "merchant:" + display.normalizedForMatching)

        if let existing = try? context.fetch(FetchDescriptor<Merchant>(predicate: #Predicate { $0.id == id })).first {
            if !existing.aliases.contains(unwrapped) { existing.aliases.append(unwrapped) }
            if existing.domain == nil { existing.domain = brand?.domain }
            return existing
        }
        let merchant = Merchant(displayName: display, kind: brand?.merchantKind ?? .local)
        merchant.domain = brand?.domain
        if !merchant.aliases.contains(unwrapped) { merchant.aliases.append(unwrapped) }
        context.insert(merchant)
        return merchant
    }

    func resolvePerson(named name: String) -> Person {
        let normalized = name.normalizedForMatching
        let people = (try? context.fetch(FetchDescriptor<Person>())) ?? []
        if let match = people.first(where: { $0.displayName.normalizedForMatching == normalized }) { return match }
        let person = Person(displayName: MerchantRules.displayName(from: normalized))
        context.insert(person)
        return person
    }

    // MARK: Categorization (DESIGN §6, phase-0 subset: override → memory → bundled rules)

    func categorize(_ movement: Movement) {
        guard !movement.userEdited else { return }
        if movement.amountCents > 0, movement.kind == .income, isSalaryLike(movement) {
            movement.category = category(forKey: "salario")
            movement.categoryConfidence = 1
            return
        }
        // Merchant memory only carries across the same direction: an employer's "Salário" must not
        // categorize a purchase from that company, and vice versa.
        if let remembered = movement.merchant?.category,
           (remembered.key == "salario" || remembered.key == "renda") == (movement.amountCents > 0) {
            movement.category = remembered
            movement.categoryConfidence = 0.95
            return
        }
        if movement.kind == .income || movement.kind == .extraIncome {
            movement.category = category(forKey: "renda")
            movement.categoryConfidence = 0.8
            return
        }
        if movement.person != nil, movement.kind == .expense {
            movement.categoryConfidence = 0.3  // Pix to a person: ask, don't guess
            return
        }
        let name = movement.merchant.map { $0.aliases.first ?? $0.displayName.normalizedForMatching }
            ?? MerchantRules.unwrap(movement.rawDescription)
        // Catalog brand / channel ("IFD*" → Delivery) first, then the company's registered activity, then keywords.
        let brandKey = BrandCatalog.match(name)?.category
            ?? BrandCatalog.match(movement.rawDescription.normalizedForMatching)?.category
        let cnaeKey = movement.merchant?.cnae.flatMap(CNAECategories.category(for:))
        let keywordKey = MerchantRules.categoryKey(for: name)
        let mccKey = movement.mcc.flatMap(MerchantRules.categoryKey(mcc:))
        let providerKey = movement.providerCategory.flatMap(MerchantRules.categoryKey(providerCategory:))
        let key = brandKey ?? cnaeKey ?? keywordKey ?? mccKey ?? providerKey
        if let key, let category = category(forKey: key) {
            movement.category = category
            movement.categoryConfidence = brandKey != nil ? 0.9 : cnaeKey != nil ? 0.85 : keywordKey != nil ? 0.75
                : mccKey != nil ? 0.8 : 0.7
        } else {
            movement.categoryConfidence = 0
        }
    }

    // MARK: Company registry enrichment (DESIGN §5)

    /// Fills a merchant from the Receita registry when we have its CNPJ: trade name, activity (CNAE)
    /// and address. Re-categorizes its movements the user hasn't touched. Safe to call repeatedly.
    func enrichFromRegistry(_ merchant: Merchant) async {
        guard let cnpj = merchant.cnpj, merchant.cnae == nil else { return }
        guard let company = try? await CompanyRegistry.lookup(cnpj: cnpj) else { return }
        merchant.legalName = company.razaoSocial
        merchant.cnae = company.cnaeFiscal.map { String(format: "%07d", $0) }
        merchant.address = company.address
        if let fantasia = company.nomeFantasia?.trimmingCharacters(in: .whitespaces), !fantasia.isEmpty,
           BrandCatalog.match(merchant.displayName.normalizedForMatching) == nil {
            merchant.displayName = MerchantRules.displayName(from: fantasia.normalizedForMatching)
        }
        for movement in merchant.movements ?? [] where !movement.userEdited && movement.kind == .expense {
            categorize(movement)
        }
        save()
    }

    /// Enriches merchants that have a CNPJ but no registry data yet, a few at a time.
    func enrichPendingMerchants(limit: Int = 10) async {
        let merchants = ((try? context.fetch(FetchDescriptor<Merchant>())) ?? [])
            .filter { $0.cnpj != nil && $0.cnae == nil }
            .prefix(limit)
        for merchant in merchants { await enrichFromRegistry(merchant) }
    }

    // MARK: Salary (DESIGN §7: income model)

    /// A marked salary source, the bank's payroll operation, or "SALARIO"/"FOLHA" in the description.
    private func isSalaryLike(_ movement: Movement) -> Bool {
        if movement.isFromSalarySource { return true }
        if movement.operationType == "FOLHA_PAGAMENTO" || movement.operationType == "PORTABILIDADE_SALARIO" { return true }
        let text = movement.rawDescription.normalizedForMatching
        return ["SALARIO", "FOLHA DE PAGAMENTO", "PROVENTOS", "VENCIMENTOS"].contains { text.contains($0) }
    }

    /// "Marcar como salário": remembers the payer and recategorizes every payment from it.
    /// Returns the day of the month the salary usually lands on, to offer as the cycle start.
    @discardableResult
    func setSalary(_ isSalary: Bool, for movement: Movement) -> Int? {
        let target = category(forKey: isSalary ? "salario" : "renda")
        var payments: [Movement] = [movement]
        if let merchant = movement.merchant {
            merchant.isSalarySource = isSalary
            if merchant.category?.key == "salario" || merchant.category?.key == "renda" || merchant.category == nil {
                merchant.category = target
            }
            payments = merchant.movements ?? [movement]
        } else if let person = movement.person {
            person.isSalarySource = isSalary
            payments = person.movements ?? [movement]
        }
        for payment in payments where payment.amountCents > 0 && payment.kind != .transfer && payment.status != .tombstoned {
            payment.kind = .income
            payment.category = target
            payment.categoryConfidence = 1
            payment.reviewed = true
        }
        save()
        return isSalary ? Self.typicalPayday(payments.filter { $0.amountCents > 0 }.map(\.date)) : nil
    }

    /// Median day-of-month of recent salary payments, clamped to 1…28 like the cycle setting.
    static func typicalPayday(_ dates: [Date]) -> Int? {
        let recent = dates.filter { $0 > Date.now.addingTimeInterval(-200 * 86_400) }.sorted()
        guard !recent.isEmpty else { return nil }
        let days = recent.map { Calendar.brazil.component(.day, from: $0) }.sorted()
        return min(max(days[days.count / 2], 1), 28)
    }

    /// Salary paid in the cycle before `cycle` — the expectation until this cycle's salary lands.
    func salary(in cycle: PayCycle) -> Money {
        let start = cycle.start, end = cycle.end
        let movements = (try? context.fetch(FetchDescriptor<Movement>(predicate: #Predicate { $0.date >= start && $0.date < end }))) ?? []
        return Money(cents: movements.filter { $0.isSalary && $0.status != .tombstoned }.reduce(0) { $0 + $1.amountCents })
    }

    func category(forKey key: String) -> SpendCategory? {
        try? context.fetch(FetchDescriptor<SpendCategory>(predicate: #Predicate { $0.key == key })).first
    }

    // MARK: Corrections (F5, F6)

    /// Changes this movement's category (F5). The merchant remembers it for its next purchases.
    func setCategory(_ category: SpendCategory?, for movement: Movement) {
        movement.category = category
        movement.categoryConfidence = 1
        movement.userEdited = true
        movement.reviewed = true
        if movement.amountCents < 0 { movement.merchant?.category = category }  // merchant memory
        save()
    }

    /// "Sempre Mercado para Atacadão" (F6): the merchant and all its purchases move to the category,
    /// except the ones the user changed by hand. Returns how many moved.
    @discardableResult
    func alwaysCategory(_ category: SpendCategory, for merchant: Merchant) -> Int {
        merchant.category = category
        var moved = 0
        for movement in merchant.movements ?? [] where movement.amountCents < 0 && movement.kind == .expense && !movement.userEdited {
            if movement.category !== category { moved += 1 }
            movement.category = category
            movement.categoryConfidence = 0.95
            movement.reviewed = true
        }
        save()
        return moved
    }

    func setLimit(_ limit: Money?, for category: SpendCategory) {
        category.limitCents = max(limit?.cents ?? 0, 0)
        save()
    }

    /// Average spending per cycle over the last three, rounded up to R$ 50 — the suggested limit.
    func suggestedLimit(for category: SpendCategory, before cycle: PayCycle) -> Money? {
        let first = cycle.previous().previous().previous()
        let start = first.start, end = cycle.start, key = category.key
        let movements = (try? context.fetch(FetchDescriptor<Movement>(predicate: #Predicate { $0.date >= start && $0.date < end }))) ?? []
        let total = movements.filter { $0.countsAsSpending && $0.category?.key == key }.reduce(Int64(0)) { $0 + $1.netCost.magnitude.cents }
        guard total > 0 else { return nil }
        let step: Int64 = 5_000
        return Money(cents: ((total / 3 + step - 1) / step) * step)
    }

    func markReviewed(_ movements: [Movement]) {
        movements.forEach { $0.reviewed = true }
        save()
    }

    func delete(_ movement: Movement) {
        context.delete(movement)
        save()
    }

    func save() {
        do { try context.save() } catch { assertionFailure("Ledger save failed: \(error)") }
    }
}
