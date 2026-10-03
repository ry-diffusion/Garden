import Foundation
import SwiftData

/// Turns a Pluggy snapshot into ledger rows (DESIGN §4). Per transaction: update the row we already
/// know, else reconcile it with a provisional capture (Apple Pay / bank notification), else insert.
/// Rows of these accounts that vanished from the window become tombstones.
@MainActor
struct PluggyIngestor {
    let context: ModelContext
    private var ledger: Ledger { Ledger(context: context) }

    struct Report: Sendable {
        var inserted = 0, updated = 0, reconciled = 0, tombstoned = 0, skipped = 0, accounts = 0
        var warnings: [String] = []
        static func + (lhs: Report, rhs: Report) -> Report {
            Report(inserted: lhs.inserted + rhs.inserted, updated: lhs.updated + rhs.updated,
                   reconciled: lhs.reconciled + rhs.reconciled, tombstoned: lhs.tombstoned + rhs.tombstoned,
                   skipped: lhs.skipped + rhs.skipped, accounts: lhs.accounts + rhs.accounts,
                   warnings: lhs.warnings + rhs.warnings)
        }
    }

    func ingest(_ snapshot: PluggySnapshot) -> Report {
        var report = Report()
        let from = PluggyDate.parse(snapshot.from + "T00:00:00Z") ?? snapshot.fetchedAt.addingTimeInterval(-35 * 86_400)
        let institution = institutionName(snapshot)

        var accounts: [String: Account] = [:]
        for raw in snapshot.accounts { accounts[raw.id] = upsertAccount(raw, institution: institution) }
        if let identity = snapshot.identity { registerMe(identity) }
        let me = (try? context.fetch(FetchDescriptor<Person>(predicate: #Predicate { $0.isMe })))?.first

        // Everything we might match against: this window plus a few days of slack for captures.
        let windowStart = from.addingTimeInterval(-3 * 86_400)
        let existing = (try? context.fetch(FetchDescriptor<Movement>(predicate: #Predicate { $0.date >= windowStart }))) ?? []
        var byKey: [String: Movement] = [:]
        for movement in existing { for key in movement.provenanceKeys { byKey[key] = movement } }
        var openCaptures = existing.filter(\.isUnmatchedCapture)
        var seenKeys = Set<String>()

        for (pluggyAccountId, transactions) in snapshot.transactions {
            guard let account = accounts[pluggyAccountId] else { continue }
            for transaction in transactions {
                let parsed = ParsedTransaction(transaction, account: account)
                seenKeys.formUnion(parsed.keys)

                if let known = parsed.keys.lazy.compactMap({ byKey[$0] }).first {
                    update(known, with: parsed, me: me)
                    report.updated += 1
                    continue
                }
                switch reconcile(parsed, account: account, candidates: openCaptures) {
                case .merge(let capture):
                    merge(parsed, into: capture, account: account, me: me)
                    openCaptures.removeAll { $0 === capture }
                    parsed.keys.forEach { byKey[$0] = capture }
                    report.reconciled += 1
                case .installmentHeader(let capture):
                    let parcel = insert(parsed, account: account, me: me)
                    capture.linkKindRaw = "installmentHeader"
                    capture.installmentPlan = parcel.installmentPlan
                    capture.provenanceKeys.append("header:" + parsed.contentKey)
                    capture.status = .posted
                    openCaptures.removeAll { $0 === capture }
                    parsed.keys.forEach { byKey[$0] = parcel }
                    report.reconciled += 1
                case .none:
                    let movement = insert(parsed, account: account, me: me)
                    parsed.keys.forEach { byKey[$0] = movement }
                    report.inserted += 1
                }
            }
        }

        report.tombstoned = tombstone(existing, accounts: Set(accounts.values.map(\.id)), from: from, seen: seenKeys)
        for merchant in (try? context.fetch(FetchDescriptor<Merchant>())) ?? []
        where merchant.displayName.contains("|") && (merchant.movements ?? []).isEmpty {
            context.delete(merchant)
        }
        // Meu Pluggy items name the bank only on their accounts.
        upsertHoldings(snapshot.investments, institution: institution ?? accounts.values.first?.institution)
        ledger.save()
        return report
    }

    // MARK: Accounts, identity, holdings

    /// Meu Pluggy proxy items report connector "MeuPluggy"; the real bank is in the account name.
    private func institutionName(_ snapshot: PluggySnapshot) -> String? {
        guard let name = snapshot.item.connector?.name, !name.normalizedForMatching.contains("MEUPLUGGY") else { return nil }
        return name
    }

    private func upsertAccount(_ raw: PluggySnapshot.Account, institution fallback: String?) -> Account {
        let institution = Institutions.shortName(fallback ?? raw.name ?? raw.marketingName ?? "Banco")
        let kind: AccountKind = raw.type == "CREDIT" ? .credit : (raw.subtype == "SAVINGS_ACCOUNT" ? .savings : .checking)
        let number = raw.number?.filter(\.isNumber)
        let stable = StableID.sha256("\(institution.normalizedForMatching)|\(number ?? "")|\(raw.subtype)")
        let all = ((try? context.fetch(FetchDescriptor<Account>())) ?? []).filter { !$0.isArchived }

        let account = all.first { $0.pluggyAccountId == raw.id || $0.stableAcct == stable }
            // Adopt an account the user created by hand for the same bank, so history stays in one place.
            ?? all.first { candidate in
                candidate.pluggyAccountId == nil && candidate.kind == kind
                    && sameInstitution(candidate.institution, institution)
                    && (candidate.number == nil || candidate.number == number)
            }
            ?? {
                let created = Account(name: raw.marketingName ?? raw.name ?? institution, institution: institution, kind: kind)
                created.sortOrder = all.count
                context.insert(created)
                return created
            }()

        account.pluggyAccountId = raw.id
        account.stableAcct = stable
        account.number = number
        account.kind = kind
        account.institution = institution
        if let balance = raw.balance {
            // Pluggy reports a card's open bill as a positive balance; Garden stores debts as negative.
            account.balanceCents = kind == .credit ? -balance.cents : balance.cents
        }
        return account
    }

    private func registerMe(_ identity: PluggySnapshot.Identity) {
        guard identity.documentType == "CPF", let digits = identity.document?.cpfVisibleDigits else { return }
        let hmac = Keychain.cpfHMAC(visibleDigits: digits)
        let people = (try? context.fetch(FetchDescriptor<Person>())) ?? []
        let me = people.first(where: \.isMe) ?? {
            let person = Person(displayName: identity.fullName.map { MerchantRules.displayName(from: $0.normalizedForMatching) } ?? "Eu", isMe: true)
            context.insert(person)
            return person
        }()
        me.cpfHmac = hmac
        me.cpfMask = "***.***.***-**"
    }

    private func upsertHoldings(_ investments: [PluggySnapshot.Investment], institution: String?) {
        guard !investments.isEmpty else { return }
        let bank = institution ?? "Investimentos"
        let accounts = (try? context.fetch(FetchDescriptor<Account>())) ?? []
        let account = accounts.first { $0.kind == .investment && sameInstitution($0.institution, bank) } ?? {
            let created = Account(name: "\(bank) investimentos", institution: bank, kind: .investment)
            created.sortOrder = accounts.count
            context.insert(created)
            return created
        }()
        let holdings = (try? context.fetch(FetchDescriptor<Holding>())) ?? []
        let seen = Set(investments.map(\.id))

        for raw in investments where raw.status != "TOTAL_WITHDRAWAL" {
            let name = raw.name ?? raw.subtype ?? "Investimento"
            let holding = holdings.first { $0.pluggyId == raw.id }
                ?? holdings.first { $0.pluggyId == nil && $0.name.normalizedForMatching == name.normalizedForMatching }
                ?? {
                    let created = Holding(name: name, type: raw.type ?? "FIXED_INCOME", net: .zero, dailyLiquidity: false)
                    context.insert(created)
                    return created
                }()
            holding.pluggyId = raw.id
            holding.name = name
            holding.typeRaw = raw.type ?? holding.typeRaw
            holding.netCents = (raw.balance ?? raw.amount ?? 0).cents  // `balance` is net of taxes
            holding.account = account
            let normalized = name.normalizedForMatching
            holding.dailyLiquidity = normalized.contains("LIQUIDEZ DIARIA") || normalized.contains("SELIC") || raw.subtype == "SAVINGS"
            holding.liquidityDate = holding.dailyLiquidity ? nil : raw.dueDate
        }
        for holding in holdings where holding.account === account && holding.pluggyId != nil && !seen.contains(holding.pluggyId ?? "") {
            context.delete(holding)
        }
    }

    // MARK: Transactions

    /// A Pluggy transaction in Garden terms: signed centavos, identity keys, counterpart.
    struct ParsedTransaction {
        let raw: PluggySnapshot.Transaction
        let cents: Int64  // signed: negative = money out
        let idKey: String
        let contentKey: String
        var keys: [String] { [idKey, contentKey] }
        let description: String
        let counterparty: PluggySnapshot.Transaction.Party?
        var isIncoming: Bool { cents > 0 }

        init(_ raw: PluggySnapshot.Transaction, account: Account) {
            self.raw = raw
            let magnitude = Swift.abs(raw.amount.cents)
            if account.kind == .credit {
                // On cards Pluggy sends purchases positive and payments/refunds negative.
                cents = raw.amount.cents > 0 ? -magnitude : magnitude
            } else if raw.type == "DEBIT" {
                cents = -magnitude
            } else if raw.type == "CREDIT" {
                cents = magnitude
            } else {
                cents = raw.amount.cents
            }
            description = raw.description ?? raw.descriptionRaw ?? ""
            idKey = "pluggy:\(raw.id)"
            let direction = cents < 0 ? "out" : "in"
            if let providerId = raw.providerId, !providerId.isEmpty {
                contentKey = "pid:\(account.stableAcct):\(direction):\(providerId)"
            } else {
                let day = raw.date.formatted(.iso8601.year().month().day())
                let installment = raw.creditCardMetadata?.installmentNumber ?? 0
                contentKey = "plg:\(account.stableAcct):\(day):\(cents):\(description.normalizedForMatching):\(installment)"
            }
            counterparty = cents < 0 ? raw.paymentData?.receiver : raw.paymentData?.payer
        }
    }

    private enum Reconciliation { case merge(Movement), installmentHeader(Movement), none }

    /// Capture ↔ bank posting, 1:1 (DESIGN §4.3): same bank, capture within −3…+1 days of the posting,
    /// then exact amount, the full price of an installment plan, or a tip/fuel-sized difference
    /// on the same merchant.
    private func reconcile(_ parsed: ParsedTransaction, account: Account, candidates: [Movement]) -> Reconciliation {
        let postingDate = parsed.raw.date
        let name = (parsed.raw.merchant?.name ?? parsed.counterparty?.name ?? parsed.description).normalizedForMatching
        let metadata = parsed.raw.creditCardMetadata

        var best: (movement: Movement, score: Double, header: Bool)?
        for capture in candidates {
            guard (capture.amountCents < 0) == (parsed.cents < 0) else { continue }
            let gap = capture.date.timeIntervalSince(postingDate)
            guard gap > -3 * 86_400, gap < 86_400 else { continue }
            if let label = capture.institutionLabel, !sameInstitution(label, account.institution) { continue }

            let similarity = Similarity.dice(capture.displayTitle.normalizedForMatching, name)
            let captured = Swift.abs(capture.amountCents), posted = Swift.abs(parsed.cents)
            var score: Double
            var header = false
            if captured == posted {
                score = 3 + similarity
            } else if let count = metadata?.totalInstallments, count > 1, metadata?.installmentNumber == 1,
                      captured == metadata?.totalAmount?.cents || Swift.abs(Double(captured) - Double(posted * Int64(count))) <= Double(captured) * 0.01 {
                score = 2.5 + similarity
                header = true
            } else if similarity >= 0.8, Swift.abs(Double(captured - posted)) <= Double(captured) * 0.25 {
                score = 1 + similarity
            } else {
                continue
            }
            score -= Swift.abs(gap) / (30 * 86_400)  // nearer in time wins ties
            if score > (best?.score ?? -1) { best = (capture, score, header) }
        }
        guard let best else { return .none }
        return best.header ? .installmentHeader(best.movement) : .merge(best.movement)
    }

    private func merge(_ parsed: ParsedTransaction, into capture: Movement, account: Account, me: Person?) {
        capture.provenanceKeys.append(contentsOf: parsed.keys.filter { !capture.provenanceKeys.contains($0) })
        capture.status = parsed.raw.status == "PENDING" ? .pending : .posted
        capture.account = account
        if !capture.userEdited, capture.amountCents != parsed.cents {
            capture.amountCents = parsed.cents  // the bank's amount wins (tips, fuel pre-auth)
            capture.note = capture.note.isEmpty ? String(localized: "Valor alterado pelo banco") : capture.note
        }
        // The capture keeps its place and time; the bank adds identifiers and the merchant's CNPJ.
        fill(capture, from: parsed, me: me, overwriteCounterparty: capture.merchant == nil && capture.person == nil)
        if capture.category == nil, !capture.userEdited { ledger.categorize(capture) }
    }

    private func insert(_ parsed: ParsedTransaction, account: Account, me: Person?) -> Movement {
        let kind: MovementKind = parsed.isIncoming ? .income : .expense
        let movement = Movement(primaryKey: parsed.contentKey, amount: Money(cents: parsed.cents), date: parsed.raw.date,
                                kind: kind, source: .pluggy, status: parsed.raw.status == "PENDING" ? .pending : .posted,
                                rawDescription: parsed.description)
        movement.provenanceKeys.append(parsed.idKey)
        movement.account = account
        context.insert(movement)
        fill(movement, from: parsed, me: me, overwriteCounterparty: true)
        attachInstallmentPlan(movement, parsed: parsed, account: account)
        ledger.categorize(movement)
        // Recent, uncertain rows go to "pra conferir"; a 12-month backfill must not flood it.
        let recent = parsed.raw.date > Date.now.addingTimeInterval(-7 * 86_400)
        movement.reviewed = !recent || movement.categoryConfidence >= 0.8 || movement.kind == .transfer
        return movement
    }

    private func update(_ movement: Movement, with parsed: ParsedTransaction, me: Person?) {
        parsed.keys.forEach { if !movement.provenanceKeys.contains($0) { movement.provenanceKeys.append($0) } }
        movement.status = parsed.raw.status == "PENDING" ? .pending : .posted
        guard !movement.userEdited else { return }
        if movement.source == .pluggy {
            movement.amountCents = parsed.cents
            movement.date = parsed.raw.date
            movement.rawDescription = parsed.description
        }
        // Repair rows from older builds: merchants named "Compra no débito|X", and Pix to other people
        // labelled "Entre minhas contas" from Pluggy's generic "Transfers" category.
        let badMerchant = movement.merchant?.displayName.contains("|") == true
        if badMerchant || (movement.merchant == nil && movement.person == nil) {
            movement.merchant = nil
            fill(movement, from: parsed, me: me, overwriteCounterparty: true)
            movement.category = nil
            ledger.categorize(movement)
        } else {
            fill(movement, from: parsed, me: me, overwriteCounterparty: false)
        }
        if movement.kind != .transfer, movement.category?.key == "transferencias" {
            movement.category = nil
            ledger.categorize(movement)
        }
    }

    private func fill(_ movement: Movement, from parsed: ParsedTransaction, me: Person?, overwriteCounterparty: Bool) {
        let raw = parsed.raw
        movement.providerId = raw.providerId ?? movement.providerId
        movement.operationType = raw.operationType ?? movement.operationType
        movement.providerCategory = raw.merchant?.category ?? raw.category ?? movement.providerCategory
        if let mcc = raw.creditCardMetadata?.payeeMCC { movement.mcc = String(format: "%04d", mcc) }
        movement.counterpartyAccount = parsed.counterparty?.accountNumber?.filter(\.isNumber) ?? movement.counterpartyAccount
        if let reason = raw.paymentData?.reason, movement.note.isEmpty { movement.note = reason }
        guard overwriteCounterparty else { return }

        if let merchant = raw.merchant, let name = merchant.name ?? merchant.businessName {
            let resolved = ledger.resolveMerchant(named: name)
            if resolved.cnpj == nil { resolved.cnpj = merchant.cnpj }
            if resolved.cnae == nil, let cnae = merchant.cnae { resolved.cnae = cnae.filter(\.isNumber) }
            if resolved.legalName == nil { resolved.legalName = merchant.businessName }
            movement.merchant = resolved
        } else if let party = parsed.counterparty, let name = party.name {
            let document = party.documentNumber
            if document?.type == "CNPJ" {
                let resolved = ledger.resolveMerchant(named: name)
                if resolved.cnpj == nil { resolved.cnpj = document?.value }
                movement.merchant = resolved
            } else if let me, let digits = document?.value?.cpfVisibleDigits,
                      Keychain.cpfHMAC(visibleDigits: digits) == me.cpfHmac,
                      Similarity.dice(name.normalizedForMatching, me.displayName.normalizedForMatching) >= 0.8 {
                movement.person = me  // TransferDetector turns this into "Entre minhas contas"
            } else {
                let person = ledger.resolvePerson(named: name)
                if let digits = document?.value?.cpfVisibleDigits, person.cpfHmac == nil {
                    person.cpfHmac = Keychain.cpfHMAC(visibleDigits: digits)
                    person.cpfMask = document?.value
                }
                movement.person = person
            }
        } else {
            // "Compra no débito|MINIMERCADOEXEMPL…", "Transferência enviada pelo Pix|MARIA SOUZA"
            let (operation, name) = MerchantRules.splitOperation(parsed.description)
            guard !Self.isGeneric(name) else { return }
            let isPix = (operation ?? "").normalizedForMatching.contains("PIX") || (operation ?? "").normalizedForMatching.contains("TRANSFERENCIA")
            if isPix, !MerchantRules.looksLikeBusiness(name) {
                if let me, Similarity.dice(name.normalizedForMatching, me.displayName.normalizedForMatching) >= 0.9 {
                    movement.person = me
                } else {
                    movement.person = ledger.resolvePerson(named: name)
                }
            } else {
                movement.merchant = ledger.resolveMerchant(named: name)
            }
        }
    }

    /// Bank boilerplate that names no merchant.
    static func isGeneric(_ description: String) -> Bool {
        let text = description.normalizedForMatching
        let generic = ["PIX ENVIADO", "PIX RECEBIDO", "TRANSFERENCIA ENVIADA", "TRANSFERENCIA RECEBIDA", "SAQUE",
                       "PAGAMENTO DE FATURA", "PAGAMENTO RECEBIDO", "PAGAMENTO FATURA", "TED", "DOC", "DEPOSITO", "RENDIMENTO"]
        return text.isEmpty || generic.contains { text.hasPrefix($0) }
    }

    private func attachInstallmentPlan(_ movement: Movement, parsed: ParsedTransaction, account: Account) {
        guard let metadata = parsed.raw.creditCardMetadata, let count = metadata.totalInstallments, count > 1 else { return }
        movement.installmentNumber = metadata.installmentNumber
        let purchase = metadata.purchaseDate ?? parsed.raw.date
        let merchantName = movement.merchant?.displayName ?? parsed.description
        let total = metadata.totalAmount?.cents ?? Swift.abs(parsed.cents) * Int64(count)
        let planID = StableID.uuid(for: "plan:\(account.stableAcct):\(merchantName.normalizedForMatching):\(purchase.formatted(.iso8601.year().month().day())):\(count)")
        let plan = (try? context.fetch(FetchDescriptor<InstallmentPlan>(predicate: #Predicate { $0.id == planID })))?.first ?? {
            let created = InstallmentPlan(title: merchantName, origin: "card", total: Money(cents: total), count: count, firstDue: purchase)
            created.id = planID
            created.merchant = movement.merchant
            context.insert(created)
            return created
        }()
        movement.installmentPlan = plan
    }

    // MARK: Tombstones

    private func tombstone(_ existing: [Movement], accounts: Set<UUID>, from: Date, seen: Set<String>) -> Int {
        var count = 0
        for movement in existing where movement.date >= from && movement.status != .tombstoned {
            guard let account = movement.account, accounts.contains(account.id) else { continue }
            let bankKeys = movement.provenanceKeys.filter { $0.hasPrefix("pluggy:") || $0.hasPrefix("pid:") || $0.hasPrefix("plg:") }
            guard !bankKeys.isEmpty, bankKeys.allSatisfy({ !seen.contains($0) }) else { continue }
            if movement.userEdited { continue }  // keep what the user touched; it reappears on the next match
            movement.status = .tombstoned
            count += 1
        }
        return count
    }

    private func sameInstitution(_ lhs: String, _ rhs: String) -> Bool {
        let a = lhs.normalizedForMatching, b = rhs.normalizedForMatching
        guard !a.isEmpty, !b.isEmpty else { return false }
        return a == b || a.contains(b) || b.contains(a)
            || a.split(separator: " ").first == b.split(separator: " ").first
    }
}

extension Movement {
    /// An Apple Pay / notification capture still waiting for its bank posting.
    var isUnmatchedCapture: Bool {
        (source == .applePay || source == .notification) && status == .provisional
            && !provenanceKeys.contains { $0.hasPrefix("pluggy:") || $0.hasPrefix("header:") }
    }
}

/// Bigram Dice similarity on normalized names (0…1).
enum Similarity {
    static func dice(_ a: String, _ b: String) -> Double {
        let lhs = bigrams(a), rhs = bigrams(b)
        guard !lhs.isEmpty, !rhs.isEmpty else { return a == b ? 1 : 0 }
        let shared = lhs.intersection(rhs).count
        return 2 * Double(shared) / Double(lhs.count + rhs.count)
    }

    private static func bigrams(_ text: String) -> Set<String> {
        let characters = Array(text.replacingOccurrences(of: " ", with: ""))
        guard characters.count > 1 else { return [] }
        return Set((0..<(characters.count - 1)).map { String(characters[$0...($0 + 1)]) })
    }
}
