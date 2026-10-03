import Foundation

/// The bundled brand catalog (Resources/Brands.json): the merchants that show up most on Brazilian
/// statements, with the descriptor fragments banks print, a category and the brand's own domain for its logo.
struct Brand: Decodable, Sendable {
    let name: String
    let patterns: [String]
    let domain: String?
    let category: String
    let kind: String

    var merchantKind: MerchantKind { MerchantKind(rawValue: kind) ?? .chain }
}

enum BrandCatalog {
    private struct File: Decodable { let brands: [Brand] }

    static let brands: [Brand] = {
        guard let url = Bundle.main.url(forResource: "Brands", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data)
        else { return [] }
        return file.brands
    }()

    /// Patterns sorted longest-first so "AMAZON PRIME" beats "AMAZON" and "YOUTUBE" beats "GOOGLE".
    private static let index: [(pattern: String, brand: Brand)] = brands
        .flatMap { brand in brand.patterns.map { ($0, brand) } }
        .sorted { $0.0.count > $1.0.count }

    /// Matches a normalized descriptor ("UBER *TRIP", "IFD*RESTAURANTE SABOR", "GOOGLE *YOUTUBE").
    static func match(_ normalized: String) -> Brand? {
        index.first { contains(normalized, wholeWord: $0.pattern) }?.brand
    }

    /// Fragment match that respects word edges, so "TIM SA" doesn't fire inside "OTIMISTA" and
    /// "VIVO" doesn't fire inside "VIVOS". Patterns ending in punctuation ("IFD*") only need a left edge.
    static func contains(_ text: String, wholeWord pattern: String) -> Bool {
        var searchStart = text.startIndex
        while let range = text.range(of: pattern, range: searchStart..<text.endIndex) {
            let leftOK = range.lowerBound == text.startIndex || !text[text.index(before: range.lowerBound)].isLetter
            let lastIsLetter = pattern.last?.isLetter ?? false
            let rightOK = !lastIsLetter || range.upperBound == text.endIndex || !text[range.upperBound].isLetter
            if leftOK && rightOK { return true }
            searchStart = text.index(after: range.lowerBound)
        }
        return false
    }
}
