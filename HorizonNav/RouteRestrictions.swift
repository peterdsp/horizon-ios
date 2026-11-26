import Foundation

/// Vignette motorways and low-emission zones on a route, from TomTom's `tollVignette` and `lowEmissionZone` route sections.
/// The other routing services do not report them, so nothing is shown for their routes rather than a guess.
enum RouteRestrictions {
    /// The countries whose vignette the route needs, in the order they are reached, as ISO 3166-1 alpha-2 codes.
    static func vignetteCountries(_ route: RouteOption) -> [String] {
        var out: [String] = []
        for section in route.vignetteSections.sorted(by: { $0.start < $1.start }) {
            let code = alpha2(section.country)
            if !code.isEmpty, !out.contains(code) { out.append(code) }
        }
        // A vignette stretch with no country still has to be flagged.
        if out.isEmpty, !route.vignetteSections.isEmpty { out.append("") }
        return out
    }

    static func entersLowEmissionZone(_ route: RouteOption) -> Bool { !route.lowEmissionSections.isEmpty }

    /// TomTom gives ISO 3166-1 alpha-3 codes; the countries that sell vignettes are mapped to alpha-2 for names and links.
    static func alpha2(_ code: String) -> String {
        let upper = code.uppercased()
        if upper.count == 2 { return upper }
        let map = ["AUT": "AT", "CHE": "CH", "CZE": "CZ", "SVK": "SK", "SVN": "SI", "HUN": "HU", "BGR": "BG", "ROU": "RO",
                   "MDA": "MD", "LIE": "LI", "BLR": "BY", "KGZ": "KG"]
        return map[upper] ?? ""
    }

    /// "Vignette needed: Austria, Switzerland".
    static func vignetteText(_ countries: [String]) -> String {
        let names = countries.filter { !$0.isEmpty }.map { Locale.current.localizedString(forRegionCode: $0) ?? $0 }
        return names.isEmpty ? String(localized: "Vignette needed on part of this route")
                             : String(localized: "Vignette needed: \(names.formatted(.list(type: .and)))")
    }

    /// The official vignette shop or road authority of each country, where one is well established.
    static func officialVignetteLink(_ country: String) -> URL? {
        let links = [
            "AT": "https://www.asfinag.at",
            "CH": "https://via.admin.ch",
            "CZ": "https://edalnice.cz",
            "SK": "https://eznamka.sk",
            "SI": "https://evinjeta.dars.si",
            "HU": "https://nemzetiutdij.hu",
            "BG": "https://www.bgtoll.bg",
            "RO": "https://www.erovinieta.ro",
        ]
        return links[country].flatMap(URL.init(string:))
    }

    /// The EU-supported directory of urban access rules, which links each zone's own rules.
    static let lowEmissionZoneRules = URL(string: "https://urbanaccessregulations.eu")!
}
