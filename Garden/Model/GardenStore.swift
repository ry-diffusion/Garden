import Foundation
import SwiftData

enum GardenStore {
    static let schema = Schema([
        Account.self, Movement.self, Merchant.self, Person.self, SpendCategory.self,
        Budget.self, InstallmentPlan.self, Bill.self, Holding.self, NetWorthSnapshot.self,
    ])

    /// One container shared by the app and its App Intents.
    /// CloudKit + App Group are switched on once the bundle id and iCloud container are provisioned
    /// (DESIGN §2.8); until then the store is local.
    static let shared: ModelContainer = make()

    static func make(inMemory: Bool = false) -> ModelContainer {
        let configuration = ModelConfiguration(
            "Garden",
            schema: schema,
            isStoredInMemoryOnly: inMemory,
            cloudKitDatabase: .none
        )
        do {
            let container = try ModelContainer(for: schema, configurations: [configuration])
            Seed.bootstrap(container.mainContext)
            return container
        } catch {
            fatalError("Garden store failed to open: \(error)")
        }
    }
}

// MARK: - Seed

enum Seed {
    struct CategorySeed {
        let key: String, name: String, symbol: String, tint: CategoryTint
    }

    static let categories: [CategorySeed] = [
        .init(key: "mercado", name: "Mercado", symbol: "cart", tint: .green),
        .init(key: "comer-fora", name: "Comer fora", symbol: "fork.knife", tint: .orange),
        .init(key: "delivery", name: "Delivery", symbol: "takeoutbag.and.cup.and.straw", tint: .red),
        .init(key: "transporte", name: "Transporte", symbol: "car", tint: .blue),
        .init(key: "combustivel", name: "Combustível", symbol: "fuelpump", tint: .indigo),
        .init(key: "moradia", name: "Moradia", symbol: "house", tint: .brown),
        .init(key: "contas-casa", name: "Contas da casa", symbol: "bolt", tint: .yellow),
        .init(key: "saude", name: "Saúde", symbol: "cross.case", tint: .teal),
        .init(key: "educacao", name: "Educação", symbol: "book", tint: .indigo),
        .init(key: "lazer", name: "Lazer", symbol: "theatermasks", tint: .purple),
        .init(key: "compras", name: "Compras", symbol: "bag", tint: .pink),
        .init(key: "assinaturas", name: "Assinaturas", symbol: "repeat", tint: .purple),
        .init(key: "viagem", name: "Viagem", symbol: "airplane", tint: .blue),
        .init(key: "pets", name: "Pets", symbol: "pawprint", tint: .brown),
        .init(key: "cuidados", name: "Cuidados pessoais", symbol: "scissors", tint: .pink),
        .init(key: "presentes", name: "Presentes", symbol: "gift", tint: .red),
        .init(key: "impostos", name: "Impostos e taxas", symbol: "building.columns", tint: .gray),
        .init(key: "juros", name: "Juros e tarifas", symbol: "percent", tint: .gray),
        .init(key: "salario", name: "Salário", symbol: "briefcase", tint: .green),
        .init(key: "renda", name: "Renda", symbol: "arrow.down.circle", tint: .green),
        .init(key: "transferencias", name: "Entre minhas contas", symbol: "arrow.left.arrow.right", tint: .gray),
        .init(key: "outros", name: "Outros", symbol: "ellipsis.circle", tint: .gray),
    ]

    /// Idempotent: inserts missing system categories and the cash account ("Carteira").
    static func bootstrap(_ context: ModelContext) {
        let existing = Set(((try? context.fetch(FetchDescriptor<SpendCategory>())) ?? []).map(\.key))
        for (index, seed) in categories.enumerated() where !existing.contains(seed.key) {
            context.insert(SpendCategory(key: seed.key, name: seed.name, symbol: seed.symbol, tint: seed.tint, sortOrder: index))
        }

        let cashKind = AccountKind.cash.rawValue
        let cash = FetchDescriptor<Account>(predicate: #Predicate { $0.kindRaw == cashKind })
        if ((try? context.fetchCount(cash)) ?? 0) == 0 {
            let wallet = Account(name: "Carteira", institution: "Dinheiro", kind: .cash)
            wallet.stableAcct = "cash:carteira"
            wallet.id = StableID.uuid(for: "account:cash:carteira")
            context.insert(wallet)
        }
        try? context.save()
    }
}
