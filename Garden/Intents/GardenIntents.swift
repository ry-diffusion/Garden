import AppIntents
import CoreLocation
import SwiftData

/// Which Shortcuts automation fired (DESIGN §14). Both run for every card; the ledger merges twins.
enum CaptureOrigin: String, AppEnum {
    case wallet, notification

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Origem"
    static let caseDisplayRepresentations: [CaptureOrigin: DisplayRepresentation] = [
        .wallet: "Apple Pay",
        .notification: "Notificação do banco",
    ]
}

/// Called by the Wallet-transaction and bank-notification automations.
struct LogPaymentIntent: AppIntent {
    static let title: LocalizedStringResource = "Registrar pagamento"
    static let description = IntentDescription(
        "Registra no Garden um pagamento capturado pelo Apple Pay ou pela notificação do banco.",
        categoryName: "Captura"
    )

    @Parameter(title: "Origem", default: .wallet)
    var origin: CaptureOrigin

    @Parameter(title: "Estabelecimento")
    var merchant: String?

    /// Text keeps this tolerant of how Shortcuts renders the Wallet amount ("R$45,90", "45.90").
    @Parameter(title: "Valor")
    var amount: String?

    @Parameter(title: "Cartão ou banco", description: "Nome do cartão (Carteira) ou do app do banco (notificação).")
    var card: String?

    @Parameter(title: "Título da notificação")
    var notificationTitle: String?

    @Parameter(title: "Texto da notificação", inputOptions: String.IntentInputOptions(multiline: true))
    var notificationText: String?

    @Parameter(title: "Local")
    var place: CLPlacemark?

    static var parameterSummary: some ParameterSummary {
        Summary("Registrar pagamento de \(\.$origin)") {
            \.$merchant
            \.$amount
            \.$card
            \.$notificationTitle
            \.$notificationText
            \.$place
        }
    }

    enum CaptureError: Error, CustomLocalizedStringResourceConvertible {
        case missingAmount

        var localizedStringResource: LocalizedStringResource {
            "Não encontrei o valor do pagamento."
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let context = GardenStore.shared.mainContext
        let ledger = Ledger(context: context)

        var capture: Ledger.Capture
        if let text = notificationText, !text.isEmpty, origin == .notification || amount == nil {
            switch NotificationParser().parse(title: notificationTitle, body: text) {
            case .success(let parsed):
                let cardLabel = card ?? parsed.cardLast4.map { "final \($0)" }
                capture = Ledger.Capture(amount: parsed.amount, direction: parsed.direction, method: parsed.method,
                                         merchantName: parsed.counterparty, counterpartyDocument: parsed.counterpartyDocument,
                                         cardName: cardLabel, source: .notification,
                                         rawText: [notificationTitle, text].compactMap { $0 }.joined(separator: " · "),
                                         memo: parsed.memo, installments: parsed.installments)
            case .failure:
                // Declined purchases, refunds, product news… are not money movements. Ignore quietly.
                return .result(dialog: "Notificação ignorada.")
            }
        } else {
            guard let amount, let money = Money(parsing: amount) else { throw CaptureError.missingAmount }
            capture = Ledger.Capture(amount: money, merchantName: merchant, cardName: card, source: .applePay)
        }

        if let location = place?.location {
            capture.location = location.coordinate
            capture.placeName = place?.name
        }

        let movement: Movement
        switch ledger.record(capture) {
        case .inserted(let inserted): movement = inserted
        case .mergedIntoExisting(let existing): movement = existing
        }
        if let merchant = movement.merchant { await ledger.enrichFromRegistry(merchant) }
        return .result(dialog: IntentDialog(stringLiteral: Self.summary(for: movement, context: context)))
    }

    /// "R$ 45,90 · Padaria Bom Pão → Comer fora (R$ 210 restantes)" — remaining only when the category has a limit.
    @MainActor
    static func summary(for movement: Movement, context: ModelContext) -> String {
        var text = "\(movement.amount.magnitude.formatted) · \(movement.displayTitle)"
        if movement.kind == .transfer { return text + " → Entre minhas contas" }
        if movement.kind == .income { return "+" + text }
        guard let category = movement.category else { return text }
        text += " → \(category.name)"
        if category.limit != nil {
            let cycle = Preferences.currentCycle
            let start = cycle.start, end = cycle.end
            let movements = (try? context.fetch(FetchDescriptor<Movement>(predicate: #Predicate { $0.date >= start && $0.date < end }))) ?? []
            if let remaining = CategoryMath(cycle: cycle, categories: [category], movements: movements).remaining(in: category) {
                text += " (\(remaining.formattedWhole) restantes)"
            }
        }
        return text
    }
}

/// Opens the Lançar sheet — used by Siri, Spotlight, the Action button and (later) the Control.
struct AddMovementIntent: AppIntent {
    static let title: LocalizedStringResource = "Lançar"
    static let description = IntentDescription("Abre o Garden pronto para lançar um gasto.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppRouter.shared.presentAdd()
        return .result()
    }
}

struct GardenShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AddMovementIntent(),
            phrases: ["Lançar no \(.applicationName)", "Novo gasto no \(.applicationName)"],
            shortTitle: "Lançar",
            systemImageName: "plus.circle"
        )
        AppShortcut(
            intent: LogPaymentIntent(),
            phrases: ["Registrar pagamento no \(.applicationName)"],
            shortTitle: "Registrar pagamento",
            systemImageName: "creditcard"
        )
    }
}
