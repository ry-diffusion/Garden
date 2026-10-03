#if DEBUG
import Foundation
import SwiftData

/// Sample ledger for previews and simulator runs launched with `-seedDemo`. Never compiled into Release.
enum DemoData {
    @MainActor static let previewContainer: ModelContainer = {
        let container = GardenStore.make(inMemory: true)
        seedIfEmpty(container.mainContext)
        return container
    }()

    @MainActor static func seedIfEmpty(_ context: ModelContext) {
        guard ((try? context.fetchCount(FetchDescriptor<Account>())) ?? 0) <= 1 else { return }  // only Carteira
        let ledger = Ledger(context: context)
        func category(_ key: String) -> SpendCategory? { ledger.category(forKey: key) }

        let nubank = Account(name: "Nubank crédito", institution: "Nubank", kind: .credit)
        let nuConta = Account(name: "Nubank conta", institution: "Nubank", kind: .checking, balance: Money(cents: 120_000))
        let inter = Account(name: "Inter", institution: "Inter", kind: .checking, balance: Money(cents: 482_350))
        let btgConta = Account(name: "BTG conta", institution: "BTG", kind: .checking, balance: Money(cents: 650_000))
        let btg = Account(name: "BTG investimentos", institution: "BTG", kind: .investment)
        for (index, account) in [nubank, nuConta, inter, btgConta, btg].enumerated() {
            account.sortOrder = index + 1
            context.insert(account)
        }

        let cdb = Holding(name: "CDB Liquidez Diária", type: "FIXED_INCOME", net: Money(cents: 3_100_000), dailyLiquidity: true)
        let tesouro = Holding(name: "Tesouro Selic 2029", type: "FIXED_INCOME", net: Money(cents: 2_430_000), dailyLiquidity: true)
        let lci = Holding(name: "LCI 95% CDI", type: "FIXED_INCOME", net: Money(cents: 2_900_000), dailyLiquidity: false,
                          liquidityDate: Calendar.brazil.date(byAdding: .month, value: 9, to: .now))
        for holding in [cdb, tesouro, lci] { holding.account = btg; context.insert(holding) }

        // Limits on a few categories; the rest are tracked without one.
        let limits: [(String, Int64)] = [("mercado", 140_000), ("comer-fora", 45_000), ("delivery", 20_000),
                                          ("transporte", 30_000), ("moradia", 320_000)]
        for (key, cents) in limits { category(key)?.limitCents = cents }

        let cycle = Preferences.currentCycle
        let calendar = Calendar.brazil
        func day(_ offset: Int, _ hour: Int) -> Date {
            let base = calendar.date(byAdding: .day, value: offset, to: cycle.start) ?? cycle.start
            return calendar.date(bySettingHour: hour, minute: 17, second: 0, of: base) ?? base
        }
        let elapsedDays = max(calendar.dateComponents([.day], from: cycle.start, to: .now).day ?? 0, 1)

        // (merchant, cents, dayOffset, hour, account, source, lat, lon)
        let rows: [(String, Int64, Int, Int, Account, MovementSource, Double?, Double?)] = [
            ("ATACADAO SAO PAULO", 38_742, 1, 10, nubank, .applePay, -23.5275, -46.6656),
            ("PAG*PADARIABOMPAO", 2_350, 3, 8, nubank, .applePay, -23.5614, -46.6559),
            ("UBER *TRIP", 2_870, 3, 23, nubank, .applePay, nil, nil),
            ("AUTO POSTO SHELL", 21_000, 5, 18, nubank, .applePay, -23.5503, -46.6900),
            ("PAG*PADARIABOMPAO", 1_890, 6, 8, nubank, .applePay, -23.5614, -46.6559),
            ("NETFLIX.COM", 5_590, 8, 3, nubank, .pluggy, nil, nil),
            ("ASSAI ATACADISTA", 52_310, 10, 11, nubank, .applePay, -23.5200, -46.6200),
            ("CINEMARK PAULISTA", 7_600, 12, 19, nubank, .applePay, -23.5646, -46.6527),
            ("PAG*PADARIABOMPAO", 2_780, 13, 8, nubank, .applePay, -23.5614, -46.6559),
            ("DROGASIL", 4_629, 14, 17, nubank, .applePay, -23.5580, -46.6610),
            ("RESTAURANTE VILA MADALENA", 14_350, 16, 13, nubank, .applePay, -23.5531, -46.6905),
            ("UBER *TRIP", 3_410, 17, 1, nubank, .applePay, nil, nil),
            ("CARREFOUR EXPRESS", 9_870, 18, 19, nubank, .applePay, -23.5660, -46.6500),
        ]
        for (index, row) in rows.enumerated() where row.2 < elapsedDays + 1 {
            let movement = Movement(primaryKey: "demo:\(index)", amount: Money(cents: -row.1), date: day(row.2, row.3),
                                    kind: .expense, source: row.5, status: .posted, rawDescription: row.0)
            movement.account = row.4
            movement.latitude = row.6
            movement.longitude = row.7
            movement.reviewed = index % 5 != 0
            context.insert(movement)
            movement.merchant = ledger.resolveMerchant(named: row.0)
            ledger.categorize(movement)
        }

        // Rent via Pix to a person — the case that always needs the user once.
        let rent = Movement(primaryKey: "demo:rent", amount: Money(cents: -230_000), date: day(0, 9),
                            kind: .expense, source: .pluggy, rawDescription: "PIX ENVIADO JOSE DA SILVA")
        rent.account = inter
        context.insert(rent)
        rent.person = ledger.resolvePerson(named: "JOSE DA SILVA")
        ledger.categorize(rent)

        let salary = Movement(primaryKey: "demo:salary", amount: Money(cents: 850_000), date: day(0, 7),
                              kind: .income, source: .pluggy, rawDescription: "SALARIO")
        salary.account = inter
        salary.reviewed = true
        salary.category = category("salario")
        context.insert(salary)

        replayYesterdaysNotifications(ledger)
        try? context.save()
    }

    /// `-pairURL http://127.0.0.1:8787 -pairCode ABCD2345 -pluggyItems id1,id2` pairs with a local
    /// `wrangler dev` (backed by worker/dev/mock-pluggy.mjs), registers the items and syncs.
    @MainActor static func pairFromLaunchArguments() {
        let defaults = UserDefaults.standard
        guard let url = defaults.string(forKey: "pairURL"), let code = defaults.string(forKey: "pairCode") else { return }
        let items = (defaults.string(forKey: "pluggyItems") ?? "").split(separator: ",").map(String.init)
        Task {
            do {
                _ = try await GardenServer.pair(url: url, code: code, deviceName: "Simulador")
                if !items.isEmpty { try await SyncEngine.shared.setItems(items) }
                await SyncEngine.shared.sync()
            } catch {
                print("Dev pairing failed: \(error)")
            }
        }
    }

    /// Yesterday's real Nubank/BTG notification formats (payer names and CNPJs anonymized), fed through
    /// the same path the Shortcuts automation uses — exercises parsing, account choice and transfer pairing.
    @MainActor static func replayYesterdaysNotifications(_ ledger: Ledger) {
        let calendar = Calendar.brazil
        let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: .now)) ?? .now
        let feed: [(String, String, String, String)] = [
            ("05:21", "BTG", "Pix Recebido", "Você recebeu um Pix de Secretaria De Estado Exemplo 00.000.000/0001-00 no valor de R$ 900,00."),
            ("11:32", "Nubank", "Compra no crédito aprovada", "Compra de R$ 28,20 APROVADA em EXEMPLO SOFTWARE, INC. para o cartão com final 1234."),
            ("12:18", "BTG", "Transação Pix Confirmada", "A transferência Pix de R$ 900,00 foi confirmada."),
            ("12:18", "Nubank", "Caixinha Turbo ativada", "Agora você pode guardar a 115% do CDI com a liberdade de tirar quando quiser."),
            ("13:48", "Nubank", "Compra no débito aprovada", "Compra de R$ 19,24 em MINIMERCADOEXEMPL"),
            ("16:01", "BTG", "Pix Recebido", "Você recebeu um Pix de Cliente Exemplo Tecnologia Ltda 12.345.678/0001-90 no valor de R$ 6.000,00 - Prestação de serviço."),
            ("16:30", "Nubank", "Compra no débito aprovada", "Compra de R$ 14,49 em MINIMERCADOEXEMPL"),
            ("16:33", "Nubank", "Compra no débito aprovada", "Compra de R$ 47,26 em MINIMERCADOEXEMPL"),
            ("17:14", "BTG", "Transação Pix Confirmada", "A transferência Pix de R$ 6.000,00 foi confirmada."),
            ("17:14", "Nubank", "Transferência recebida", "Recebemos sua transferência de R$ 6.000,00."),
            ("23:15", "Nubank", "Compra no débito aprovada", "Compra de R$ 38,00 em AB RESTAURANTE"),
        ]
        for (time, bank, title, body) in feed {
            let parts = time.split(separator: ":").compactMap { Int($0) }
            let date = calendar.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: yesterday) ?? yesterday
            guard case .success(let parsed) = NotificationParser().parse(title: title, body: body) else { continue }
            _ = ledger.record(Ledger.Capture(
                amount: parsed.amount, direction: parsed.direction, method: parsed.method,
                merchantName: parsed.counterparty, counterpartyDocument: parsed.counterpartyDocument,
                cardName: bank, source: .notification, date: date,
                rawText: "\(title) · \(body)", memo: parsed.memo, installments: parsed.installments))
        }
    }
}
#endif
