import SwiftUI

/// After "Marcar como salário": offer to start the month on the day the salary usually lands.
struct PaydaySuggestion: ViewModifier {
    @Binding var suggestedDay: Int?
    @AppStorage(Preferences.paydayKey) private var payday = PayCycle.defaultPayday

    func body(content: Content) -> some View {
        content.alert(
            "Seu salário costuma cair no dia \(suggestedDay ?? payday)",
            isPresented: Binding(get: { suggestedDay != nil && suggestedDay != payday }, set: { if !$0 { suggestedDay = nil } })
        ) {
            Button("Começar o mês no dia \(suggestedDay ?? payday)") {
                if let day = suggestedDay { payday = day }
                suggestedDay = nil
            }
            Button("Manter dia \(payday)", role: .cancel) { suggestedDay = nil }
        } message: {
            Text("Limites e a Sobra do mês seguem o ciclo do pagamento. Hoje o ciclo começa no dia \(payday).")
        }
    }
}

extension View {
    func paydaySuggestion(_ day: Binding<Int?>) -> some View { modifier(PaydaySuggestion(suggestedDay: day)) }
}
