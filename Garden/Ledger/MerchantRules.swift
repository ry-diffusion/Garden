import Foundation

/// Bundled knowledge for resolving merchants before any network enrichment (DESIGN §5–§6).
enum MerchantRules {
    /// Payment-processor prefixes that hide the real shop in Brazilian card descriptors.
    static let processorPrefixes = [
        "PAG*", "PAGSEGURO*", "MP*", "MERCPAGO*", "MERCADOPAGO*", "SUMUP*", "SUMUP *", "IFD*", "IFOOD*",
        "PG *", "PG*", "EC *", "STONE*", "STONE ", "CIELO*", "CIELO ", "PAYPAL *", "PAYPAL*", "EBANX*",
        "PICPAY*", "REDE*", "GETNET*", "MOOZ*", "ZP*", "PIX ",
    ]

    /// "PAG*PADARIABOMPAO" → "PADARIABOMPAO"; "MP*LOJA X" → "LOJA X".
    static func unwrap(_ descriptor: String) -> String {
        var name = descriptor.normalizedForMatching
        for prefix in processorPrefixes where name.hasPrefix(prefix) {
            name = String(name.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        // Card descriptors often end with the city: "PADARIA BOM PAO SAO PAULO BR".
        for suffix in [" BR", " BRA"] where name.hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count))
        }
        return name
    }

    private static let acronyms: Set<String> = [
        "IOF", "PIX", "TED", "DOC", "CPF", "CNPJ", "IPVA", "IPTU", "INSS", "FGTS", "DAS", "MEI", "LTDA", "EIRELI", "ME", "EPP", "SA",
    ]

    /// Readable display name: "PADARIA BOM PAO" → "Padaria Bom Pao".
    static func displayName(from normalized: String) -> String {
        if let brand = BrandCatalog.match(normalized) { return brand.name }
        let lowercaseWords: Set<String> = ["de", "da", "do", "das", "dos", "e", "no", "na", "nos", "nas", "em", "o", "a", "os", "as",
                                           "ao", "aos", "pelo", "pela", "por", "com", "para", "pra"]
        let vowels = Set("AEIOU")
        return normalized.split(separator: " ").enumerated().map { index, word in
            let upper = String(word)
            let w = upper.lowercased()
            if acronyms.contains(upper) { return upper }
            // Initialisms stay uppercase: "AB", "AI", "SP", "MC".
            if upper.count == 2, !lowercaseWords.contains(w) { return upper }
            if upper.count == 3, !upper.contains(where: vowels.contains) { return upper }
            return index > 0 && lowercaseWords.contains(w) ? w : w.prefix(1).uppercased() + w.dropFirst()
        }.joined(separator: " ")
    }

    /// Keyword → category for local shops (phase-0 stand-in for the CNAE map).
    static let keywordCategories: [(String, String)] = [
        ("SUPERMERC", "mercado"), ("MINIMERC", "mercado"), ("MERCADO", "mercado"), ("MERCEARIA", "mercado"), ("HORTIFRUTI", "mercado"), ("ACOUGUE", "mercado"),
        ("ATACAD", "mercado"), ("FEIRA", "mercado"), ("SACOLAO", "mercado"),
        ("PADARIA", "comer-fora"), ("PANIFICADORA", "comer-fora"), ("RESTAURANTE", "comer-fora"),
        ("LANCHONETE", "comer-fora"), ("PIZZARIA", "comer-fora"), ("BAR ", "comer-fora"), ("CAFE", "comer-fora"),
        ("HAMBURG", "comer-fora"), ("SORVET", "comer-fora"), ("CHURRASC", "comer-fora"),
        ("POSTO", "combustivel"), ("AUTO POSTO", "combustivel"), ("COMBUSTIV", "combustivel"),
        ("FARMACIA", "saude"), ("DROGARIA", "saude"), ("CLINICA", "saude"), ("LABORATORIO", "saude"),
        ("ESTACIONAMENTO", "transporte"), ("METRO", "transporte"), ("BILHETE UNICO", "transporte"),
        ("PET", "pets"), ("VETERINAR", "pets"),
        ("CINEMA", "lazer"), ("INGRESSO", "lazer"), ("TEATRO", "lazer"),
        ("SALAO", "cuidados"), ("BARBEARIA", "cuidados"), ("ACADEMIA", "cuidados"),
        ("ESCOLA", "educacao"), ("LIVRARIA", "educacao"), ("CURSO", "educacao"),
        ("ALUGUEL", "moradia"), ("CONDOMINIO", "moradia"),
        // Utilities and phone carriers live in Brands.json, which matches on word edges ("VIVO" ≠ "VIVOS").
        ("IOF", "juros"), ("JUROS", "juros"), ("TARIFA", "juros"), ("ANUIDADE", "juros"),
        ("HOTEL", "viagem"), ("POUSADA", "viagem"),
    ]

    /// Open Finance descriptions arrive as "Compra no débito|MINIMERCADOEXEMPL" or
    /// "Transferência enviada pelo Pix|MARIA SOUZA": the operation, then the counterpart.
    static func splitOperation(_ description: String) -> (operation: String?, name: String) {
        guard let bar = description.firstIndex(of: "|") else { return (nil, description) }
        let operation = description[..<bar].trimmingCharacters(in: .whitespaces)
        let name = description[description.index(after: bar)...].trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? (nil, operation) : (operation, name)
    }

    /// "MARIA SOUZA" is a person; "PADARIA BOM PAO LTDA" is a business.
    static func looksLikeBusiness(_ name: String) -> Bool {
        let text = " " + name.normalizedForMatching + " "
        let markers = [" LTDA ", " LTDA.", " S.A", " S/A", " SA ", " ME ", " EPP ", " EIRELI", " MEI ", "COMERCIO", "SERVICOS", "BANCO",
                       "PAGAMENTOS", "INSTITUICAO", "RESTAURANTE", "MERCADO", "FARMACIA", "LOJA", "ACADEMIA"]
        return markers.contains { text.contains($0) } || BrandCatalog.match(name.normalizedForMatching) != nil
    }

    /// Card MCC → category (ISO 18245), for when the bank sends one.
    static func categoryKey(mcc: String) -> String? {
        guard let code = Int(mcc) else { return nil }
        switch code {
        case 5411, 5422, 5441, 5451, 5462, 5499: return "mercado"
        case 5812, 5813: return "comer-fora"
        case 5814: return "comer-fora"
        case 5541, 5542, 5983: return "combustivel"
        case 4111, 4112, 4121, 4131, 4784, 7523: return "transporte"
        case 3000...3350, 4511, 4722, 7011, 3501...3999: return "viagem"
        case 5912, 8011...8099: return "saude"
        case 4812, 4814, 4899, 4900: return "contas-casa"
        case 5815...5818, 5734, 5735: return "assinaturas"
        case 7832, 7922, 7991, 7996, 7999: return "lazer"
        case 7997: return "cuidados"
        case 8211...8299: return "educacao"
        case 5995, 742: return "pets"
        case 9311, 9222, 9399: return "impostos"
        case 5300...5399, 5600...5699, 5700...5733, 5940...5999, 5200...5299: return "compras"
        default: return nil
        }
    }

    /// The aggregator's English category labels → Garden categories (weakest hint).
    static func categoryKey(providerCategory label: String) -> String? {
        let text = label.lowercased()
        let table: [(String, String)] = [
            // Only "Same person transfer" is between my accounts; Pluggy's plain "Transfers" are payments to others.
            ("same person", "transferencias"),
            ("salary", "renda"), ("income", "renda"),
            ("groceries", "mercado"), ("supermarket", "mercado"),
            ("food delivery", "delivery"), ("delivery", "delivery"),
            ("eating out", "comer-fora"), ("restaurant", "comer-fora"), ("food and drinks", "comer-fora"),
            ("gas station", "combustivel"), ("fuel", "combustivel"),
            ("taxi", "transporte"), ("ride", "transporte"), ("transport", "transporte"), ("parking", "transporte"), ("toll", "transporte"),
            ("rent", "moradia"), ("housing", "moradia"),
            ("electricity", "contas-casa"), ("water", "contas-casa"), ("telecom", "contas-casa"), ("internet", "contas-casa"), ("utilities", "contas-casa"),
            ("pharmac", "saude"), ("health", "saude"),
            ("education", "educacao"),
            ("streaming", "assinaturas"), ("digital services", "assinaturas"), ("subscription", "assinaturas"),
            ("travel", "viagem"), ("airline", "viagem"), ("accommodation", "viagem"),
            ("leisure", "lazer"), ("entertainment", "lazer"),
            ("pet", "pets"),
            ("tax", "impostos"),
            ("bank fee", "juros"), ("interest", "juros"),
            ("shopping", "compras"), ("clothing", "compras"), ("electronics", "compras"),
        ]
        return table.first { text.contains($0.0) }?.1
    }

    /// Category for a descriptor: catalog brand first, then local-shop keywords.
    /// The raw descriptor is checked too, so "IFD*RESTAURANTE SABOR" (an iFood order) lands in Delivery
    /// even though the merchant itself is the restaurant.
    static func categoryKey(for normalized: String, raw: String? = nil) -> String? {
        if let brand = BrandCatalog.match(normalized) { return brand.category }
        if let raw, let channel = BrandCatalog.match(raw.normalizedForMatching) { return channel.category }
        let padded = normalized + " "
        return keywordCategories.first { padded.contains($0.0) }?.1
    }
}
