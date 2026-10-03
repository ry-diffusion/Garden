import Foundation

/// Looks a CNPJ up in the public Receita Federal registry (via BrasilAPI) and maps the company's
/// main activity (CNAE) to a Garden category — DESIGN §5–§6. Only company data is requested and kept;
/// the partners list (`qsa`) in the response is personal data and is ignored.
/// Phase 1 moves this behind the Worker's KV cache.
enum CompanyRegistry {
    struct Company: Decodable, Sendable {
        let razaoSocial: String
        let nomeFantasia: String?
        let cnaeFiscal: Int?
        let cnaeFiscalDescricao: String?
        let logradouro: String?
        let numero: String?
        let bairro: String?
        let municipio: String?
        let uf: String?
        let cep: String?

        enum CodingKeys: String, CodingKey {
            case razaoSocial = "razao_social", nomeFantasia = "nome_fantasia", cnaeFiscal = "cnae_fiscal"
            case cnaeFiscalDescricao = "cnae_fiscal_descricao", logradouro, numero, bairro, municipio, uf, cep
        }

        /// "Voluntarios da Franca, 1465 · Centro · Franca/SP"
        var address: String? {
            let street = [logradouro, numero].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: ", ")
            let city = [municipio, uf].compactMap { $0 }.joined(separator: "/")
            let parts = [street, bairro ?? "", city].filter { !$0.isEmpty }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }
    }

    static func digits(_ document: String) -> String { document.filter(\.isNumber) }

    static func lookup(cnpj: String) async throws -> Company {
        let digits = digits(cnpj)
        guard digits.count == 14, let url = URL(string: "https://brasilapi.com.br/api/cnpj/v1/\(digits)") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(Company.self, from: data)
    }
}

/// CNAE (IBGE) → Garden category. Keys are code prefixes; the longest matching prefix wins,
/// so "4789004" (pet shops) beats "47" (retail).
enum CNAECategories {
    static let prefixes: [String: String] = [
        // Retail food
        "4711": "mercado", "4712": "mercado", "4722": "mercado", "4723": "mercado", "4724": "mercado", "4729": "mercado",
        "4721": "comer-fora",  // padarias e confeitarias
        // Fuel and vehicles
        "4731": "combustivel", "4732": "combustivel", "4520": "transporte", "4530": "transporte", "4541": "transporte",
        // Health and beauty retail
        "4771": "saude", "4773": "saude", "4774": "saude", "4772": "cuidados",
        // General retail
        "4713": "compras", "4751": "compras", "4752": "compras", "4753": "compras", "4754": "compras", "4755": "compras",
        "4756": "compras", "4757": "compras", "4759": "compras", "4781": "compras", "4782": "compras", "4783": "compras",
        "4789": "compras", "4762": "lazer", "4763": "lazer", "4761": "educacao", "4789004": "pets",
        "4741": "moradia", "4742": "moradia", "4743": "moradia", "4744": "moradia",
        // Food service
        "5611": "comer-fora", "5612": "comer-fora", "5620": "comer-fora",
        // Transport
        "4921": "transporte", "4922": "transporte", "4923": "transporte", "4929": "transporte",
        "5221": "transporte", "5222": "transporte", "5223": "transporte",
        "5111": "viagem", "5112": "viagem", "50": "viagem", "5510": "viagem", "5590": "viagem", "7911": "viagem", "7912": "viagem",
        // Leisure
        "5914": "lazer", "9001": "lazer", "9002": "lazer", "9003": "lazer", "9311": "lazer", "9312": "lazer",
        "9319": "lazer", "9321": "lazer", "9329": "lazer", "9313": "cuidados",
        // Education, health, personal care
        "85": "educacao", "86": "saude", "87": "saude", "75": "pets", "9602": "cuidados",
        // Household services, housing
        "35": "contas-casa", "36": "contas-casa", "37": "contas-casa", "61": "contas-casa",
        "68": "moradia", "8112": "moradia",
        // Digital services and subscriptions
        "62": "assinaturas", "63": "assinaturas", "5913": "assinaturas",
        // Government
        "84": "impostos",
    ]

    static func category(for cnae: String) -> String? {
        let code = cnae.filter(\.isNumber)
        var length = min(code.count, 7)
        while length >= 2 {
            if let key = prefixes[String(code.prefix(length))] { return key }
            length -= 1
        }
        return nil
    }
}
