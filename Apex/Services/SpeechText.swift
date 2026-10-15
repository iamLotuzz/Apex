import Foundation

/// Makes German navigation text sound right when spoken.
///
/// MapKit instructions and street names are written for reading: "Hauptstr.",
/// "B258", "500 m", "Ri. Köln". Read out as they are, the synthesizer spells
/// letters, says "Punkt" or swallows units. This expands abbreviations and
/// units and builds grammatically correct German distances and durations.
enum SpeechText {
    /// Ordered: longer patterns before shorter ones.
    private static let replacements: [(pattern: String, template: String)] = [
        ("([A-Za-zÄÖÜäöüß])str\\.", "$1straße"),
        ("\\bStr\\.", "Straße"),
        ("\\bPl\\.", "Platz"),
        ("\\bRi\\.", "Richtung"),
        ("\\bNr\\.", "Nummer"),
        ("\\bSt\\.", "Sankt"),
        ("\\bBhf\\.", "Bahnhof"),
        ("\\bHbf\\.?", "Hauptbahnhof"),
        ("\\bAS\\b", "Anschlussstelle"),
        ("\\bAK\\b", "Autobahnkreuz"),
        ("\\bAD\\b", "Autobahndreieck"),
        ("\\bkm/h\\b", "Kilometer pro Stunde"),
        // Road numbers: "B258" → "B 258", read as letter + number.
        ("\\b([ABLK])(\\d)", "$1 $2"),
        ("(\\d)\\s?km\\b", "$1 Kilometer"),
        ("(\\d)\\s?m\\b", "$1 Meter"),
        ("\\s*&\\s*", " und "),
        ("\\s*/\\s*", ", "),
        ("[()\\[\\]]", " "),
        ("\\s{2,}", " ")
    ]

    static func normalize(_ text: String) -> String {
        var result = text
        for (pattern, template) in replacements {
            result = result.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// Dative after "in": "in 300 Metern", "in einem Kilometer",
    /// "in anderthalb Kilometern".
    static func inDistance(_ meters: Double) -> String {
        if meters >= 950 {
            let halves = (meters / 500).rounded() / 2
            if halves == 1 { return "einem Kilometer" }
            return "\(kilometers(halves)) Kilometern"
        }
        return "\(roundedMeters(meters)) Metern"
    }

    /// Nominative: "300 Meter", "ein Kilometer", "18 Kilometer".
    static func distance(_ meters: Double) -> String {
        if meters >= 950 {
            let km = meters >= 10_000 ? (meters / 1000).rounded() : (meters / 500).rounded() / 2
            if km == 1 { return "ein Kilometer" }
            return "\(kilometers(km)) Kilometer"
        }
        return "\(roundedMeters(meters)) Meter"
    }

    /// "eine Stunde zehn Minuten", "eine Minute", "23 Minuten".
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int((seconds / 60).rounded()))
        let hours = minutes / 60
        let rest = minutes % 60
        func minuteText(_ m: Int) -> String { m == 1 ? "eine Minute" : "\(m) Minuten" }
        guard hours > 0 else { return minuteText(minutes) }
        let hourText = hours == 1 ? "eine Stunde" : "\(hours) Stunden"
        return rest == 0 ? hourText : "\(hourText) \(minuteText(rest))"
    }

    private static func roundedMeters(_ meters: Double) -> Int {
        Int(meters >= 300 ? (meters / 100).rounded() * 100 : max(50, (meters / 50).rounded() * 50))
    }

    /// Half kilometres as words people say: anderthalb, zweieinhalb.
    private static func kilometers(_ value: Double) -> String {
        let whole = Int(value)
        guard value - Double(whole) > 0.25 else { return "\(whole)" }
        switch whole {
        case 1: return "anderthalb"
        case 0: return "einen halben"
        default: return "\(whole)einhalb"
        }
    }

    /// Lowercases the first letter so an instruction fits after
    /// "In 300 Metern …", without touching nouns later in the sentence.
    static func continuing(_ instruction: String) -> String {
        guard let first = instruction.first else { return instruction }
        let firstWord = instruction.prefix { $0 != " " }
        // Keep nouns such as "Ausfahrt" or "Kreisverkehr" capitalised.
        let verbs: Set<String> = ["Rechts", "Links", "Geradeaus", "Halbrechts", "Halblinks", "Leicht", "Wenden", "Weiter", "Bei", "Im", "Am", "Auf", "Nach", "Der", "Die", "Dem", "Den", "Scharf", "Bleiben", "Biegen", "Fahren", "Nehmen", "Folgen"]
        guard verbs.contains(String(firstWord)) else { return instruction }
        return first.lowercased() + instruction.dropFirst()
    }
}
