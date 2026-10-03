import Foundation
import SwiftData

/// Marks movements between my own accounts (DESIGN §8). Runs after every item is ingested, because the
/// two halves of a Pix between Nubank and BTG arrive in different snapshots. Signals, strongest first:
/// same Pix E2E id on two of my accounts · the counterparty is one of my accounts or me ·
/// investment moves · credit-card bill payments · cash withdrawals (into Carteira).
@MainActor
struct TransferDetector {
    let context: ModelContext

    @discardableResult
    func run(since: Date) -> Int {
        let movements = (try? context.fetch(FetchDescriptor<Movement>(predicate: #Predicate { $0.date >= since }))) ?? []
        let accounts = ((try? context.fetch(FetchDescriptor<Account>())) ?? []).filter { !$0.isArchived }
        let ownNumbers = Set(accounts.compactMap(\.number).filter { $0.count >= 5 })
        let hasCard = accounts.contains { $0.kind == .credit && $0.pluggyAccountId != nil }
        let transfers = Ledger(context: context).category(forKey: "transferencias")
        var marked = 0

        func markTransfer(_ movement: Movement, link: String) {
            guard !movement.userEdited, movement.kind != .transfer, movement.status != .tombstoned else { return }
            movement.kind = .transfer
            movement.linkKindRaw = movement.linkKindRaw ?? link
            movement.category = transfers
            movement.categoryConfidence = 0.95
            movement.budgetOverride = nil
            movement.reviewed = true
            marked += 1
        }

        // 1 · Same E2E id on two of my accounts, opposite directions.
        let byProvider = Dictionary(grouping: movements.filter { $0.providerId != nil && $0.status != .tombstoned }) { $0.providerId ?? "" }
        for group in byProvider.values where group.count == 2 {
            guard let outgoing = group.first(where: { $0.amountCents < 0 }), let incoming = group.first(where: { $0.amountCents > 0 }),
                  outgoing.account !== incoming.account else { continue }
            markTransfer(outgoing, link: "transferPair")
            markTransfer(incoming, link: "transferPair")
            outgoing.linkKindRaw = "transferPair"
            incoming.linkKindRaw = "transferPair"
            incoming.linkedTo = outgoing
        }

        for movement in movements where movement.kind != .transfer || movement.linkKindRaw == "cardPayment" {
            let operation = movement.operationType ?? ""
            let text = movement.rawDescription.normalizedForMatching

            // 2 · The other side is one of my accounts, or me.
            if let counterpart = movement.counterpartyAccount, counterpart.count >= 5,
               ownNumbers.contains(where: { $0.hasSuffix(counterpart) || counterpart.hasSuffix($0) }) {
                markTransfer(movement, link: "ownAccount")
            } else if movement.person?.isMe == true {
                markTransfer(movement, link: "ownAccount")
            }
            // 3 · Investment moves.
            else if operation.hasPrefix("APLICACAO") || operation.hasPrefix("RESGATE") {
                markTransfer(movement, link: "investment")
            }
            // 4 · Card bill payments: the card side always; the bank side only when the card is tracked.
            else if movement.account?.kind == .credit, movement.amountCents > 0,
                    operation == "PAGAMENTO_FATURA" || operation == "PAGAMENTO" || text.hasPrefix("PAGAMENTO RECEBIDO") {
                markTransfer(movement, link: "cardPayment")
            } else if movement.amountCents < 0, operation == "PAGAMENTO_FATURA" || text.contains("PAGAMENTO DE FATURA"), hasCard {
                markTransfer(movement, link: "cardPayment")
            }
            // 5 · Cash withdrawals move money into Carteira; cash spending is counted when it happens.
            else if operation == "SAQUE" || text.hasPrefix("SAQUE"), movement.amountCents < 0 {
                markTransfer(movement, link: "cash")
                depositIntoWallet(movement)
            }
        }

        // Card bill: pair the bank-side payment with the card-side credit so it reads as one event.
        let payments = movements.filter { $0.linkKindRaw == "cardPayment" && $0.linkedTo == nil && ($0.linkedFrom ?? []).isEmpty }
        for credit in payments where credit.amountCents > 0 && credit.account?.kind == .credit {
            guard let payment = payments.first(where: { candidate in
                candidate.amountCents == -credit.amountCents && candidate.account?.kind != .credit
                    && Swift.abs(candidate.date.timeIntervalSince(credit.date)) < 4 * 86_400 && (candidate.linkedFrom ?? []).isEmpty
            }) else { continue }
            payment.linkKindRaw = "transferPair"
            credit.linkKindRaw = "transferPair"
            credit.linkedTo = payment
        }
        try? context.save()
        return marked
    }

    private func depositIntoWallet(_ withdrawal: Movement) {
        let key = "cash:\(withdrawal.id.uuidString)"
        let id = StableID.uuid(for: key)
        guard ((try? context.fetchCount(FetchDescriptor<Movement>(predicate: #Predicate { $0.id == id }))) ?? 0) == 0 else { return }
        let cashKind = AccountKind.cash.rawValue
        guard let wallet = (try? context.fetch(FetchDescriptor<Account>(predicate: #Predicate { $0.kindRaw == cashKind })))?.first else { return }
        withdrawal.linkKindRaw = "transferPair"
        let deposit = Movement(primaryKey: key, amount: withdrawal.amount.magnitude, date: withdrawal.date,
                               kind: .transfer, source: withdrawal.source, rawDescription: "Saque")
        deposit.account = wallet
        deposit.linkKindRaw = "transferPair"
        deposit.linkedTo = withdrawal
        deposit.category = withdrawal.category
        deposit.reviewed = true
        context.insert(deposit)
    }
}
