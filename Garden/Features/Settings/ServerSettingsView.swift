import SwiftUI

/// Ajustes ▸ Bancos: pair with the user's Worker, register Meu Pluggy items, sync.
struct ServerSettingsView: View {
    @State private var engine = SyncEngine.shared
    @State private var isPaired = SyncEngine.shared.isPaired

    var body: some View {
        Form {
            if isPaired {
                PairedSections(engine: engine, isPaired: $isPaired)
            } else {
                PairingSection(isPaired: $isPaired)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Bancos")
        .task { if isPaired { await engine.refreshItems() } }
    }
}

// MARK: - Pairing

private struct PairingSection: View {
    @Binding var isPaired: Bool
    @AppStorage(GardenServer.urlKey) private var savedURL = ""
    @State private var url = ""
    @State private var code = ""
    @State private var isWorking = false
    @State private var error: String?

    var body: some View {
        Section {
            TextField("Servidor", text: $url, prompt: Text("garden-api.voce.workers.dev"))
                .textContentType(.URL)
                .autocorrectionDisabled()
                #if os(iOS)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                #endif
            TextField("Código", text: $code, prompt: Text("8 letras"))
                .autocorrectionDisabled()
                .monospaced()
                #if os(iOS)
                .textInputAutocapitalization(.characters)
                #endif
            Button {
                Task { await pair() }
            } label: {
                if isWorking { ProgressView() } else { Text("Conectar") }
            }
            .disabled(url.isEmpty || code.count < 6 || isWorking)
        } header: {
            Text("Conectar ao seu servidor")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if let error { Text(error).foregroundStyle(.red) }
                Text("O Garden busca seus bancos pelo Meu Pluggy através de um servidor seu na Cloudflare. No computador, rode `npm run pair` na pasta worker e cole o endereço e o código aqui.")
            }
        }
        .onAppear { if url.isEmpty { url = savedURL } }
    }

    private func pair() async {
        isWorking = true
        defer { isWorking = false }
        do {
            #if os(iOS)
            let name = UIDevice.current.name
            #else
            let name = Host.current().localizedName ?? "Mac"
            #endif
            _ = try await GardenServer.pair(url: url, code: code, deviceName: name)
            error = nil
            isPaired = true
            await SyncEngine.shared.refreshItems()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Paired

private struct PairedSections: View {
    let engine: SyncEngine
    @Binding var isPaired: Bool
    @State private var newItemId = ""
    @State private var itemError: String?
    @State private var isConfirmingUnpair = false

    var body: some View {
        Section {
            if engine.items.isEmpty {
                Text("Nenhum banco ainda. Adicione o itemId de cada conexão do Meu Pluggy.")
                    .foregroundStyle(.secondary)
            }
            ForEach(engine.items) { item in
                ItemRow(item: item, bank: engine.institutions[item.id])
            }
            .onDelete { offsets in
                let remaining = engine.items.enumerated().filter { !offsets.contains($0.offset) }.map(\.element.id)
                Task { try? await engine.setItems(remaining) }
            }
            HStack {
                TextField("itemId do Meu Pluggy", text: $newItemId)
                    .autocorrectionDisabled()
                    .font(.footnote.monospaced())
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                Button("Adicionar") {
                    Task { await addItem() }
                }
                .disabled(newItemId.trimmingCharacters(in: .whitespaces).count < 36)
            }
        } header: {
            Text("Conexões")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if let itemError { Text(itemError).foregroundStyle(.red) }
                Text("No painel do Pluggy: Applications ▸ seu app ▸ Demo ▸ conecte o MeuPluggy e copie o id de cada banco. O Meu Pluggy atualiza uma vez por dia; até 5 conexões.")
            }
        }

        Section {
            Button {
                Task { await engine.sync() }
            } label: {
                HStack {
                    Label("Sincronizar agora", systemImage: "arrow.triangle.2.circlepath")
                    Spacer()
                    if engine.isSyncing { ProgressView() }
                }
            }
            .disabled(engine.isSyncing || engine.items.isEmpty)
        } footer: {
            SyncFooter(engine: engine)
        }

        Section {
            Button("Desconectar este aparelho", role: .destructive) { isConfirmingUnpair = true }
                .confirmationDialog("Desconectar do servidor?", isPresented: $isConfirmingUnpair, titleVisibility: .visible) {
                    Button("Desconectar", role: .destructive) {
                        Task {
                            await engine.unpair()
                            isPaired = false
                        }
                    }
                } message: {
                    Text("Suas movimentações continuam no aparelho. Para voltar a sincronizar, gere um novo código.")
                }
        }
    }

    private func addItem() async {
        let id = newItemId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        do {
            try await engine.setItems(engine.items.map(\.id) + [id])
            newItemId = ""
            itemError = nil
        } catch {
            itemError = error.localizedDescription
        }
    }
}

private struct ItemRow: View {
    let item: GardenServer.ItemStatus
    let bank: String?

    var body: some View {
        HStack(spacing: 12) {
            SymbolBadge(symbol: healthy ? "building.columns" : "exclamationmark.triangle", tint: healthy ? .accentColor : .orange, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.institution.flatMap { $0 == "MeuPluggy" ? nil : $0 } ?? bank ?? "Meu Pluggy · \(item.id.prefix(8))")
                    .font(.body.weight(.medium))
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(healthy ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var healthy: Bool { item.status == "UPDATED" || item.status == "UPDATING" }

    private var subtitle: String {
        if let error = item.error { return error }
        if item.status == "UPDATING" { return String(localized: "Atualizando…") }
        guard let updated = item.lastUpdatedAt else { return item.status }
        return String(localized: "Atualizado \(updated.formatted(.relative(presentation: .named).locale(Money.brazil)))")
    }
}

struct SyncFooter: View {
    let engine: SyncEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let error = engine.lastError {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
            }
            if engine.isFollower {
                Text("Outro aparelho está sincronizando agora; os dados chegam por aqui pelo iCloud.")
            } else if engine.isSyncing {
                Text("Sincronizando… a primeira vez traz até 12 meses e pode levar um minuto.")
            } else if let last = engine.lastSyncAt {
                Text("Sincronizado \(last.formatted(.relative(presentation: .named).locale(Money.brazil))).")
                if let report = engine.lastReport {
                    Text("\(report.accounts) contas · \(report.inserted) novas · \(report.reconciled) confirmadas pelo banco · \(report.updated) atualizadas · \(report.tombstoned) removidas")
                    if report.skipped > 0 {
                        Text("\(report.skipped) itens ignorados por formato inesperado.").foregroundStyle(.orange)
                    }
                    ForEach(report.warnings, id: \.self) { warning in
                        Text("Indisponível: \(warning)").foregroundStyle(.orange).textSelection(.enabled)
                    }
                }
            }
        }
    }
}
