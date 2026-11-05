import Foundation

/// Types de manœuvre Valhalla → forme de flèche + phrases françaises (port de `maneuvers.ts` du web).
/// https://valhalla.github.io/valhalla/api/turn-by-turn/api-reference/#trip-legs-and-maneuvers
enum GuidanceKind: String, Sendable {
    case depart, straight
    case slightRight = "slight-right", right, sharpRight = "sharp-right", uturnRight = "uturn-right"
    case slightLeft = "slight-left", left, sharpLeft = "sharp-left", uturnLeft = "uturn-left"
    case rampRight = "ramp-right", rampLeft = "ramp-left", exitRight = "exit-right", exitLeft = "exit-left"
    case keepRight = "keep-right", keepLeft = "keep-left", merge, mergeRight = "merge-right", mergeLeft = "merge-left"
    case roundabout, roundaboutExit = "roundabout-exit", ferry, ferryExit = "ferry-exit"
    case arrive, arriveRight = "arrive-right", arriveLeft = "arrive-left"
    /// Étape intermédiaire (routing : `typeName == "waypoint"`, instruction « Étape atteinte : X »).
    case waypoint

    var isArrive: Bool { self == .arrive || self == .arriveLeft || self == .arriveRight }

    /// Symbole SF de secours (Live Activity : champ `symbol`).
    var symbol: String {
        switch self {
        case .depart, .straight, .merge, .mergeLeft, .mergeRight: "arrow.up"
        case .slightRight, .keepRight, .rampRight, .exitRight: "arrow.up.right"
        case .slightLeft, .keepLeft, .rampLeft, .exitLeft: "arrow.up.left"
        case .right, .sharpRight: "arrow.turn.up.right"
        case .left, .sharpLeft: "arrow.turn.up.left"
        case .uturnLeft, .uturnRight: "arrow.uturn.down"
        case .roundabout, .roundaboutExit: "arrow.triangle.2.circlepath"
        case .ferry, .ferryExit: "ferry.fill"
        case .arrive, .arriveLeft, .arriveRight: "mappin.circle.fill"
        case .waypoint: "flag.fill"
        }
    }
}

enum GuidancePhrases {
    private static let byNumber: [Int: GuidanceKind] = [
        1: .depart, 2: .depart, 3: .depart,
        4: .arrive, 5: .arriveRight, 6: .arriveLeft,
        7: .straight, 8: .straight,
        9: .slightRight, 10: .right, 11: .sharpRight, 12: .uturnRight,
        13: .uturnLeft, 14: .sharpLeft, 15: .left, 16: .slightLeft,
        17: .straight, 18: .rampRight, 19: .rampLeft,
        20: .exitRight, 21: .exitLeft,
        22: .straight, 23: .keepRight, 24: .keepLeft,
        25: .merge, 26: .roundabout, 27: .roundaboutExit,
        28: .ferry, 29: .ferryExit,
        37: .mergeRight, 38: .mergeLeft,
    ]

    static func kind(_ m: Maneuver) -> GuidanceKind {
        if let name = m.typeName?.lowercased() {
            if name == "waypoint" { return .waypoint }
            if let k = GuidanceKind(rawValue: name.replacingOccurrences(of: "_", with: "-")) { return k }
        }
        return byNumber[m.type] ?? .straight
    }

    // MARK: - petits outils regex

    static func match(_ pattern: String, _ s: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        return (0..<m.numberOfRanges).map { i in Range(m.range(at: i), in: s).map { String(s[$0]) } ?? "" }
    }

    static func replace(_ pattern: String, in s: String, with t: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return s }
        return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: t)
    }

    static func capitalize(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }
    static func lowerFirst(_ s: String) -> String { s.prefix(1).lowercased() + s.dropFirst() }

    // MARK: - rond-point, étape, rue

    /// Numéro de sortie : champ `roundaboutExit`, sinon lu dans le texte (« 2e sortie »).
    static func roundaboutExit(_ m: Maneuver) -> Int? {
        if let n = m.roundaboutExit, n > 0 { return n }
        if let g = match(#"(\d+)\s*(?:e|è|ème|eme|re|ère|er)\s+sortie"#, m.instruction), let n = Int(g[1]) { return n }
        return nil
    }

    private static let ordinals = ["", "première", "deuxième", "troisième", "quatrième", "cinquième", "sixième", "septième", "huitième", "neuvième", "dixième"]
    static func ordinalWord(_ n: Int) -> String { ordinals.indices.contains(n) && n > 0 ? ordinals[n] : "\(n)e" }
    /// « 1re », « 2e ».
    static func ordinalShort(_ n: Int) -> String { n == 1 ? "1re" : "\(n)e" }

    /// Rue ou direction de sortie d'un rond-point lue dans le texte Valhalla.
    static func roundaboutExitTarget(_ m: Maneuver) -> (via: String, name: String)? {
        guard let g = match(#"sortie\s+(dans|sur|vers)\s+([^,./]+)"#, m.instruction) else { return nil }
        let name = replace(#"\s*\([^)]*\)"#, in: g[2], with: "").trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : (g[1].lowercased() == "vers" ? "vers" : "sur", name)
    }

    /// « Étape atteinte : Vichy » → « Vichy ».
    static func waypointName(_ m: Maneuver) -> String {
        if let g = match(#":\s*(.+)$"#, m.instruction) {
            let n = replace(#"\.$"#, in: g[1], with: "").trimmingCharacters(in: .whitespaces)
            if !n.isEmpty { return n }
        }
        return mainStreet(m)
    }

    /// Premier nom de rue (Valhalla donne parfois « Cours Jean Jaurès/D 528 »).
    static func mainStreet(_ m: Maneuver?) -> String {
        guard let s = m?.street else { return "" }
        let first = s.components(separatedBy: CharacterSet(charactersIn: "/,")).first ?? ""
        return first.trimmingCharacters(in: .whitespaces)
    }

    /// « la rue de Paris », « l'avenue Victor Hugo », « le boulevard… », « la D 2009 », « l'A 71 ».
    static func withArticle(_ name: String) -> String {
        let n = name.trimmingCharacters(in: .whitespaces)
        if n.isEmpty { return "" }
        if match(#"^(la|le|les|l')\s?"#, n) != nil { return lowerFirst(n) }
        let low = lowerFirst(n)
        if match(#"^(rue|route|place|voie|rocade|traverse|petite rue|grande rue|nationale|départementale)\b"#, n) != nil { return "la \(low)" }
        if match(#"^(avenue|allée|impasse|esplanade|autoroute)\b"#, n) != nil { return "l'\(low)" }
        if match(#"^(boulevard|chemin|quai|cours|faubourg|pont|rond-point|carrefour|square|passage|sentier|mail|clos|parvis|périphérique)\b"#, n) != nil { return "le \(low)" }
        if match(#"^(A|E)\s?\d"#, n) != nil, n.first?.isUppercase == true { return "l'\(n)" }
        if match(#"^(D|N|RN|RD|M|C|R)\s?\d"#, n) != nil, n.first?.isUppercase == true { return "la \(n)" }
        return n
    }

    /// Texte Valhalla utilisable en milieu de phrase (première phrase, minuscule, sans point).
    private static func cleanInstruction(_ text: String) -> String {
        let first = text.components(separatedBy: ". ").first ?? ""
        var t = replace(#"\.$"#, in: first, with: "")
        t = replace(#"\s*/\s*"#, in: t, with: ", ").trimmingCharacters(in: .whitespaces)
        return lowerFirst(t)
    }

    // MARK: - phrases

    /// Action à l'impératif, en minuscule, sans distance : « tournez à droite sur la rue de Paris ».
    static func action(_ m: Maneuver) -> String {
        let k = kind(m)
        let street = mainStreet(m)
        let on = street.isEmpty ? "" : " sur \(withArticle(street))"
        let hasText = !m.instruction.isEmpty
        switch k {
        case .depart: return street.isEmpty ? "suivez l'itinéraire" : "suivez \(withArticle(street))"
        case .straight: return "continuez tout droit\(on)"
        case .slightRight: return "tournez légèrement à droite\(on)"
        case .right: return "tournez à droite\(on)"
        case .sharpRight: return "tournez fortement à droite\(on)"
        case .slightLeft: return "tournez légèrement à gauche\(on)"
        case .left: return "tournez à gauche\(on)"
        case .sharpLeft: return "tournez fortement à gauche\(on)"
        case .uturnLeft, .uturnRight: return "faites demi-tour\(on)"
        case .keepRight: return hasText ? cleanInstruction(m.instruction) : "restez à droite\(on)"
        case .keepLeft: return hasText ? cleanInstruction(m.instruction) : "restez à gauche\(on)"
        case .rampRight, .exitRight: return hasText ? cleanInstruction(m.instruction) : "prenez la sortie à droite\(on)"
        case .rampLeft, .exitLeft: return hasText ? cleanInstruction(m.instruction) : "prenez la sortie à gauche\(on)"
        case .merge, .mergeLeft, .mergeRight: return hasText ? cleanInstruction(m.instruction) : "insérez-vous\(on)"
        case .roundabout:
            let to = roundaboutExitTarget(m).map { " \($0.via) \(withArticle($0.name))" } ?? ""
            if let n = roundaboutExit(m) { return "au rond-point, prenez la \(ordinalWord(n)) sortie\(to)" }
            return "au rond-point, suivez l'itinéraire\(to)"
        case .roundaboutExit: return "sortez du rond-point\(on)"
        case .ferry: return "prenez le ferry"
        case .ferryExit: return "débarquez du ferry\(on)"
        case .arrive: return "vous arriverez à destination"
        case .arriveRight: return "vous arriverez à destination, sur la droite"
        case .arriveLeft: return "vous arriverez à destination, sur la gauche"
        case .waypoint:
            let name = waypointName(m)
            return name.isEmpty ? "vous arriverez à l'étape" : "vous arriverez à l'étape, \(name)"
        }
    }

    /// Libellé court pour l'affichage quand il n'y a pas de nom de rue.
    static func shortLabel(_ m: Maneuver) -> String {
        switch kind(m) {
        case .roundabout: return roundaboutExit(m).map { "\(ordinalShort($0)) sortie" } ?? "Rond-point"
        case .roundaboutExit: return "Sortez du rond-point"
        case .arrive: return "Destination"
        case .arriveRight: return "Destination à droite"
        case .arriveLeft: return "Destination à gauche"
        case .waypoint: let n = waypointName(m); return n.isEmpty ? "Étape" : n
        default:
            var bare = m; bare.street = nil
            return capitalize(action(bare))
        }
    }

    /// Distance dite à voix haute : « 300 mètres », « 1,5 kilomètre », « 2 kilomètres ».
    static func spokenDistance(_ m: Double) -> String {
        if m < 95 { return "\(max(10, Int((m / 10).rounded()) * 10)) mètres" }
        if m < 975 { return "\(Int((m / 50).rounded()) * 50) mètres" }
        let km = m >= 9750 ? (m / 1000).rounded() : (m / 500).rounded() / 2
        let txt = km == km.rounded() ? String(Int(km)) : String(format: "%.1f", km).replacingOccurrences(of: ".", with: ",")
        return "\(txt) kilomètre\(km >= 2 ? "s" : "")"
    }

    /// Les émetteurs d'alertes écrivent souvent la distance dans le texte (« Police signalée dans 1,2 km ») :
    /// on la retire, puisque le HUD affiche une distance qui décompte et que la voix la dit déjà.
    static func stripDistance(_ text: String) -> String {
        replace(#"\s*(?:à|dans)\s+\d+(?:[,.]\d+)?\s*(?:km|m|mètres?|kilomètres?)\b\.?\s*$"#, in: text, with: "")
            .trimmingCharacters(in: .whitespaces)
    }
}
