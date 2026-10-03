import SwiftData
import SwiftUI

/// Ajustes — a modal on iPhone/iPad, the Settings scene (⌘,) on Mac.
struct SettingsView: View {
    @AppStorage(Preferences.paydayKey) private var payday = PayCycle.defaultPayday
    @AppStorage(Preferences.sobraModeKey) private var sobraMode: SobraMode = .plan
    @Environment(\.dismiss) private var dismiss
    @Query(filter: #Predicate<Movement> { $0.amountCents > 0 }) private var incoming: [Movement]

    private var salaryDay: Int? { Ledger.typicalPayday(incoming.filter(\.isSalary).map(\.date)) }

    var body: some View {
        Form {
            Section {
                Picker("Dia do pagamento", selection: $payday) {
                    ForEach(1...28, id: \.self) { Text("Dia \($0)").tag($0) }
                }
                if let salaryDay, salaryDay != payday {
                    Button("Seu salário costuma cair no dia \(salaryDay) — usar") { payday = salaryDay }
                }
                Picker("Sobra do mês", selection: $sobraMode) {
                    ForEach(SobraMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
            } header: {
                Text("Ciclo")
            } footer: {
                Text("Seu mês vai do dia \(payday) até o dia \(payday == 1 ? 28 : payday - 1) do mês seguinte. " + sobraMode.explanation)
            }

            Section {
                MonthlyCapField()
            } header: {
                Text("Teto do mês")
            } footer: {
                Text("O máximo que você quer gastar por ciclo, somando tudo. Ao definir um teto, a Sobra do mês passa a ser calculada por ele.")
            }

            Section {
                NavigationLink {
                    ServerSettingsView()
                } label: {
                    Label("Bancos (Meu Pluggy)", systemImage: "building.columns")
                }
            } header: {
                Text("Open Finance")
            } footer: {
                Text("Nubank, Inter e BTG pelo seu servidor. Chega com 1–2 dias de atraso e confirma o que a captura automática registrou na hora.")
            }

            Section {
                NavigationLink {
                    AutomationGuideView()
                } label: {
                    Label("Apple Pay e notificações do banco", systemImage: "wand.and.rays")
                }
            } header: {
                Text("Captura automática")
            } footer: {
                Text("Registra cada pagamento na hora, com o local, para o mapa de gastos.")
            }

            Section("Sobre") {
                LabeledContent("Versão", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Ajustes")
        #if os(iOS)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } }
        }
        #endif
        #if os(macOS)
        .frame(width: 460, height: 420)
        #endif
    }
}

/// "Quero gastar no máximo R$ 5.000 no mês." Setting a value switches Sobra to the cap.
struct MonthlyCapField: View {
    @AppStorage(Preferences.monthlyCapKey) private var capCents = 0
    @AppStorage(Preferences.sobraModeKey) private var sobraMode: SobraMode = .plan
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        LabeledContent("Gastar no máximo") {
            TextField("Sem teto", text: $text)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .focused($focused)
                #if os(iOS)
                .keyboardType(.decimalPad)
                #endif
                .onSubmit(save)
                .onChange(of: focused) { _, isFocused in if !isFocused { save() } }
        }
        .onAppear { text = capCents > 0 ? Money(cents: Int64(capCents)).formattedWhole : "" }
        #if os(iOS)
        .toolbar {
            if focused {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("OK") { focused = false }
                }
            }
        }
        #endif
        if capCents > 0 {
            Button("Remover teto", role: .destructive) {
                capCents = 0
                text = ""
                if sobraMode == .cap { sobraMode = .plan }
            }
        }
    }

    private func save() {
        let cents = Int(Money(parsing: text)?.magnitude.cents ?? 0)
        capCents = cents
        if cents > 0 {
            sobraMode = .cap
            text = Money(cents: Int64(cents)).formattedWhole
        } else if sobraMode == .cap {
            sobraMode = .plan
        }
    }
}

/// Step-by-step setup for the two Shortcuts automations (DESIGN §14).
struct AutomationGuideView: View {
    var body: some View {
        Form {
            Section {
                step(1, "Abra Atalhos ▸ Automação ▸ Nova automação ▸ **Carteira**.")
                step(2, "Escolha seus cartões (Nubank, Inter, BTG) e marque **Executar imediatamente**.")
                step(3, "Adicione **Obter localização atual**.")
                step(4, "Adicione **Registrar pagamento** (Garden): Estabelecimento = *Estabelecimento*, Valor = *Valor*, Cartão = *Cartão*, Local = *Localização atual*, Origem = *Apple Pay*.")
                step(5, "Desative **Notificar ao executar**.")
            } header: {
                Text("Apple Pay (Carteira)")
            } footer: {
                Text("Alguns cartões não enviam detalhes para a Carteira. Por isso, ative também a automação de notificação abaixo; o Garden junta as duas capturas da mesma compra.")
            }

            Section {
                step(1, "Abra Atalhos ▸ Automação ▸ Nova automação ▸ **Notificação**.")
                step(2, "Escolha o app do banco (Nubank, Inter ou BTG) e marque **Executar imediatamente**.")
                step(3, "Adicione **Obter localização atual**.")
                step(4, "Adicione **Registrar pagamento** (Garden): Origem = *Notificação do banco*, Título = *Título*, Texto = *Corpo*, Cartão ou banco = nome do banco, Local = *Localização atual*.")
                step(5, "Repita para cada banco.")
            } header: {
                Text("Notificações do banco")
            } footer: {
                Text("Cobre débito, crédito e Pix — enviados e recebidos. Quando um banco avisa que o dinheiro saiu e outro avisa que chegou, o Garden marca como Entre minhas contas. Compras negadas e avisos sem valor são ignorados.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Captura automática")
    }

    private func step(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)")
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.tint)
                .frame(width: 20)
            Text(text)
        }
    }
}
