import Foundation

/// Простая формула LaTeX одной строкой Unicode — для списков, где KaTeX не рисуется:
/// `M_n(P)` → «Mₙ(P)», `A^T` → «Aᵀ», `x \to +\infty` → «x → +∞». Если в формуле есть то,
/// что одной строкой не записать (матрицы, неизвестные команды), — `nil`.
enum PlainMath {
    static func text(_ tex: String) -> String? {
        if tex.contains("\\begin") { return nil }
        var s = tex
        // Экранированные скобки и пробелы: до разбора команд и групп.
        for (from, to) in [("\\{", "\u{E000}"), ("\\}", "\u{E001}"), ("\\|", "‖"),
                           ("\\,", " "), ("\\;", " "), ("\\:", " "), ("\\!", ""), ("\\ ", " ")] {
            s = s.replacingOccurrences(of: from, with: to)
        }
        s = s.replacing(/\\(?:left|right|big|Big|bigg|Bigg)\b\s*/) { _ in "" }
        s = s.replacing(/\\[dt]?frac\{([^{}]*)\}\{([^{}]*)\}/) { m in
            "\(wrap(String(m.output.1)))/\(wrap(String(m.output.2)))"
        }
        s = s.replacing(/\\sqrt\{([^{}]*)\}/) { m in "√" + wrap(String(m.output.1)) }
        s = s.replacing(/\\mathbb\{([A-Za-z])\}/) { m in blackboard[String(m.output.1)] ?? String(m.output.1) }
        s = s.replacing(/\\(?:mathrm|mathbf|mathit|mathcal|text|operatorname)\{([^{}]*)\}/) { m in String(m.output.1) }
        var unknown = false
        s = s.replacing(/\\([A-Za-z]+)\s*/) { m in
            let name = String(m.output.1)
            if let symbol = symbols[name] { return symbol }
            if words.contains(name) { return name + " " }
            unknown = true
            return ""
        }
        if unknown || s.contains("\\") { return nil }
        s = s.replacing(/\s*([_^])(?:\{([^{}]*)\}|(\S))/) { m in
            let body = String(m.output.2 ?? m.output.3 ?? "")
            return script(body, sub: m.output.1 == "_")
        }
        s.removeAll { $0 == "{" || $0 == "}" }
        s = s.replacingOccurrences(of: "\u{E000}", with: "{").replacingOccurrences(of: "\u{E001}", with: "}")
        s = s.replacing(/\s+/) { _ in " " }.trimmingCharacters(in: .whitespaces)
        for word in words where s.contains(word + " (") {
            s = s.replacingOccurrences(of: word + " (", with: word + "(")
        }
        s = s.replacing(/\ ([)\],]|[ₐ-ₜ₀-₉⁰-⁹ᵀⁿⁱ])/) { m in String(m.output.1) }
        return s
    }

    private static func wrap(_ part: String) -> String {
        part.count <= 1 || part.allSatisfy({ $0.isLetter || $0.isNumber }) ? part : "(\(part))"
    }

    /// Индекс или степень: знаками Unicode, если все символы есть; иначе — «lim(x→a)» и «^(n+1)».
    private static func script(_ body: String, sub: Bool) -> String {
        let table = sub ? subscripts : superscripts
        let trimmed = body.replacingOccurrences(of: " ", with: "")
        if !trimmed.isEmpty, trimmed.allSatisfy({ table[$0] != nil }) {
            return String(trimmed.compactMap { table[$0] })
        }
        if sub { return trimmed.allSatisfy({ $0.isLetter || $0.isNumber }) ? trimmed : "(\(trimmed))" }
        return "^" + wrap(trimmed)
    }

    private static let symbols: [String: String] = [
        "to": " → ", "rightarrow": " → ", "Rightarrow": " ⇒ ", "Leftrightarrow": " ⇔ ", "iff": " ⇔ ",
        "mapsto": " ↦ ", "leftarrow": " ← ", "implies": " ⇒ ",
        "le": " ≤ ", "leq": " ≤ ", "ge": " ≥ ", "geq": " ≥ ", "ne": " ≠ ", "neq": " ≠ ",
        "approx": " ≈ ", "equiv": " ≡ ", "sim": " ~ ", "cdot": "·", "times": "×", "pm": "±", "mp": "∓",
        "in": " ∈ ", "notin": " ∉ ", "subset": " ⊂ ", "subseteq": " ⊆ ", "supset": " ⊃ ", "cup": " ∪ ",
        "cap": " ∩ ", "setminus": " ∖ ", "emptyset": "∅", "varnothing": "∅",
        "forall": "∀", "exists": "∃", "neg": "¬", "land": " ∧ ", "lor": " ∨ ", "wedge": " ∧ ", "vee": " ∨ ",
        "infty": "∞", "partial": "∂", "nabla": "∇", "sum": "∑", "prod": "∏", "int": "∫",
        "langle": "⟨", "rangle": "⟩", "lfloor": "⌊", "rfloor": "⌋", "lceil": "⌈", "rceil": "⌉",
        "ldots": "…", "cdots": "⋯", "dots": "…", "circ": "∘", "perp": "⊥", "parallel": "∥",
        "quad": " ", "qquad": " ",
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ε", "varepsilon": "ε",
        "zeta": "ζ", "eta": "η", "theta": "θ", "vartheta": "θ", "iota": "ι", "kappa": "κ", "lambda": "λ",
        "mu": "μ", "nu": "ν", "xi": "ξ", "pi": "π", "rho": "ρ", "sigma": "σ", "tau": "τ", "phi": "φ",
        "varphi": "φ", "chi": "χ", "psi": "ψ", "omega": "ω",
        "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ", "Xi": "Ξ", "Pi": "Π", "Sigma": "Σ",
        "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω",
    ]

    /// Имена функций пишутся словом с пробелом после: `\det A` → «det A».
    private static let words: Set<String> = [
        "det", "lim", "sin", "cos", "tan", "tg", "ctg", "cot", "ln", "log", "exp", "max", "min", "sup", "inf",
        "rank", "rk", "dim", "ker", "deg", "gcd", "sgn", "arcsin", "arccos", "arctan", "arctg", "sh", "ch",
    ]

    private static let blackboard: [String: String] = [
        "R": "ℝ", "N": "ℕ", "Z": "ℤ", "Q": "ℚ", "C": "ℂ", "P": "ℙ",
    ]

    /// Без «ⱼ»: в системном шрифте его нет, и «cᵢⱼ» рассыпается; такие индексы пишутся буквами («cij»).
    private static let subscripts: [Character: Character] = Dictionary(uniqueKeysWithValues: zip(
        "0123456789+-=()aehiklmnoprstuvx", "₀₁₂₃₄₅₆₇₈₉₊₋₌₍₎ₐₑₕᵢₖₗₘₙₒₚᵣₛₜᵤᵥₓ"))

    private static let superscripts: [Character: Character] = Dictionary(uniqueKeysWithValues: zip(
        "0123456789+-=()abcdefghijklmnoprstuvwxyzABDEGHIJKLMNOPRTUVW",
        "⁰¹²³⁴⁵⁶⁷⁸⁹⁺⁻⁼⁽⁾ᵃᵇᶜᵈᵉᶠᵍʰⁱʲᵏˡᵐⁿᵒᵖʳˢᵗᵘᵛʷˣʸᶻᴬᴮᴰᴱᴳᴴᴵᴶᴷᴸᴹᴺᴼᴾᴿᵀᵁⱽᵂ"))
}
