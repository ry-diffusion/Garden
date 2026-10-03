import Foundation

/// Strict parser for Brazilian bank notifications (DESIGN §4.1, §14).
///
/// Formats verified against real Nubank and BTG notifications (2026-10-03):
///   Nubank  "Compra no débito aprovada" / "Compra de R$ 38,00 em AB RESTAURANTE"
///   Nubank  "Compra no crédito aprovada" / "Compra de R$ 28,20 APROVADA em EXEMPLO SOFTWARE, INC. para o cartão com final 1234."
///   Nubank  "Transferência recebida" / "Recebemos sua transferência de R$ 6.000,00."
///   BTG     "Transação Pix Confirmada" / "A transferência Pix de R$ 6.000,00 foi confirmada."
///   BTG     "Pix Recebido" / "Você recebeu um Pix de Cliente Exemplo Tecnologia Ltda 12.345.678/0001-90
///            no valor de R$ 6.000,00 - Prestação de serviço."
/// Inter formats are still unverified. Text that can't be parsed confidently is rejected, never guessed.
struct NotificationParser: Sendable {
    enum Direction: Equatable, Sendable { case outgoing, incoming }
    enum Method: Equatable, Sendable { case debit, credit, pix, transfer, unknown }

    struct Parsed: Equatable, Sendable {
        var amount: Money
        var direction: Direction
        var method: Method
        /// Merchant for purchases; recipient (outgoing) or payer (incoming) for Pix.
        var counterparty: String?
        /// CNPJ/CPF when the bank prints it ("12.345.678/0001-90").
        var counterpartyDocument: String?
        var cardLast4: String?
        var installments: Int?
        /// Free-text description some banks append ("Prestação de serviço").
        var memo: String?
    }

    enum Rejection: Error, Equatable, Sendable {
        case notAMovement(String)
        case noAmount
    }

    /// Notifications with money in them that are not a movement of money.
    private static let rejectKeywords = [
        "NEGADA", "RECUSADA", "NAO APROVADA", "NAO AUTORIZADA", "CANCELADA", "LIMITE DISPONIVEL",
        "ESTORNO", "ESTORNADA", "CASHBACK", "FATURA FECHOU", "FATURA FECHADA", "FATURA DISPONIVEL",
        "VENCE", "VENCIMENTO", "RENDEU", "RENDIMENTO", "AGENDAD", "LEMBRETE",
    ]
    private static let incomingKeywords = ["RECEBIDO", "RECEBIDA", "RECEBEU", "RECEBEMOS", "CAIU NA SUA CONTA", "DEPOSITO"]

    private static let amountPattern = #/R\$\s*(\d{1,3}(?:\.\d{3})*,\d{2}|\d+,\d{2}|\d+\.\d{2})/#
    private static let cardPattern = #/(?i)final\s*(\d{4})/#
    private static let installmentsPattern = #/(?i)\bem\s+(\d{1,2})\s?x\b/#
    private static let documentPattern = #/(\d{2}\.\d{3}\.\d{3}/\d{4}-\d{2}|\d{3}\.\d{3}\.\d{3}-\d{2}|\*{3}\.\d{3}\.\d{3}-\*{2})/#
    /// "em AB RESTAURANTE" — stops at card phrases, installments, or the end of a sentence (not at commas: "EXEMPLO SOFTWARE, INC.").
    private static let merchantAfterEm = #/(?i)\bem\s+(?!\d{1,2}\s?x\b)(.+?)(?=\s+(?:no|com o|para o|pelo)\s+cart[aã]o|\s+cart[aã]o\s+final|\s+final\s+\d{4}|\s+em\s+\d{1,2}\s?x\b|\s+às\s+\d|\.\s|\.$|;|!|\n|$)/#
    /// "para Maria Silva" (outgoing Pix).
    private static let recipientAfterPara = #/(?i)\bpara\s+(?!o\s+cart|a\s+sua)(.+?)(?=\s+(?:via|com|às)\s|\s+\d{2}\.\d{3}|\s+\d{3}\.\d{3}|\.\s|\.$|;|!|\n|$)/#
    /// "recebeu um Pix de Cliente Exemplo … Ltda 12.345.678/0001-90 no valor" (incoming Pix).
    private static let payerAfterDe = #/(?i)(?:recebeu|recebido)\s+(?:um\s+)?(?:pix|transfer[eê]ncia)\s+de\s+(?!R\$)(.+?)(?=\s+\d{2}\.\d{3}\.\d{3}/|\s+\d{3}\.\d{3}\.\d{3}-|\s+\*{3}\.|\s+no\s+valor|\s+de\s+R\$|\.\s|\.$|\n|$)/#
    private static let memoAfterDash = #/\d,\d{2}\s+-\s+(.+?)\.?$/#

    func parse(title: String? = nil, body: String) -> Result<Parsed, Rejection> {
        let text = [title, body].compactMap { $0 }.joined(separator: "\n")
        let normalized = text.normalizedForMatching
        if let keyword = Self.rejectKeywords.first(where: { normalized.contains($0) }) {
            return .failure(.notAMovement(keyword))
        }
        guard let amountMatch = body.firstMatch(of: Self.amountPattern) ?? text.firstMatch(of: Self.amountPattern),
              let amount = Money(parsing: String(amountMatch.1))
        else { return .failure(.noAmount) }

        let direction: Direction = Self.incomingKeywords.contains { normalized.contains($0) } ? .incoming : .outgoing
        let method: Method
        if normalized.contains("DEBITO") { method = .debit }
        else if normalized.contains("CREDITO") || normalized.contains("CARTAO") { method = .credit }
        else if normalized.contains("PIX") { method = .pix }
        else if normalized.contains("TRANSFERENCIA") || normalized.contains("TED") { method = .transfer }
        else if normalized.contains("COMPRA") { method = .unknown }
        else { return .failure(.notAMovement("sem tipo")) }

        var counterparty: String?
        switch (direction, method) {
        case (.incoming, _):
            counterparty = body.firstMatch(of: Self.payerAfterDe).map { String($0.1) }
        case (.outgoing, .pix), (.outgoing, .transfer):
            counterparty = body.firstMatch(of: Self.recipientAfterPara).map { String($0.1) }
        case (.outgoing, _):
            counterparty = body.firstMatch(of: Self.merchantAfterEm).map { String($0.1) }
        }
        counterparty = counterparty?
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        if counterparty?.isEmpty == true { counterparty = nil }

        return .success(Parsed(
            amount: amount,
            direction: direction,
            method: method,
            counterparty: counterparty,
            counterpartyDocument: body.firstMatch(of: Self.documentPattern).map { String($0.1) },
            cardLast4: text.firstMatch(of: Self.cardPattern).map { String($0.1) },
            installments: text.firstMatch(of: Self.installmentsPattern).flatMap { Int($0.1) },
            memo: body.firstMatch(of: Self.memoAfterDash).map { String($0.1).trimmingCharacters(in: .whitespaces) }
        ))
    }
}
