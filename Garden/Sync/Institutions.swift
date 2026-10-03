import Foundation

/// Open Finance reports banks by legal name ("Nu Pagamentos S.A. - Instituição de Pagamento").
/// The app shows the name people use.
enum Institutions {
    private static let known: [(match: String, name: String)] = [
        ("NU PAGAMENTOS", "Nubank"), ("NUBANK", "Nubank"), ("NU FINANCEIRA", "Nubank"),
        ("BANCO INTER", "Inter"), ("INTER S.A", "Inter"), ("INTER SA", "Inter"),
        ("BTG PACTUAL", "BTG"), ("BTG", "BTG"),
        ("ITAU", "Itaú"), ("BRADESCO", "Bradesco"), ("SANTANDER", "Santander"),
        ("CAIXA ECONOMICA", "Caixa"), ("BANCO DO BRASIL", "Banco do Brasil"),
        ("C6 BANK", "C6 Bank"), ("BANCO C6", "C6 Bank"), ("MERCADO PAGO", "Mercado Pago"), ("MERCADOPAGO", "Mercado Pago"),
        ("PICPAY", "PicPay"), ("XP INVESTIMENTOS", "XP"), ("BANCO XP", "XP"), ("SICOOB", "Sicoob"), ("SICREDI", "Sicredi"),
        ("BANCO PAN", "Banco Pan"), ("NEON", "Neon"), ("PAGBANK", "PagBank"), ("PAGSEGURO", "PagBank"),
        ("BANCO ORIGINAL", "Original"), ("SAFRA", "Safra"), ("RICO", "Rico"), ("WILL BANK", "Will Bank"),
    ]

    static func shortName(_ name: String) -> String {
        let normalized = name.normalizedForMatching
        return known.first { normalized.contains($0.match) }?.name ?? name
    }
}
