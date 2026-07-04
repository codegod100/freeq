import Foundation

/// Classification for a run of source text. The view maps each kind to a
/// color; `.plain` gets the default foreground.
enum SyntaxTokenKind: Equatable {
    case plain
    case keyword
    case string
    case comment
    case number
}

/// A contiguous run of code with a single classification. Concatenating every
/// token's `text` in order reproduces the original source exactly — the
/// highlighter never drops or reorders characters, so the view can rebuild the
/// code losslessly (and the copy button copies the original).
struct SyntaxToken: Equatable {
    let text: String
    let kind: SyntaxTokenKind
}

/// A minimal, dependency-free, heuristic tokenizer for the ~8 languages agents
/// most commonly post. This is intentionally NOT a real parser: it recognizes
/// line/block comments, quoted strings, numeric literals, and a per-language
/// keyword set. Everything else is `.plain`. Unknown languages fall back to a
/// single `.plain` token (fences stay legible, just unhighlighted).
enum SyntaxHighlighter {
    // MARK: - Public API

    static func highlight(_ code: String, language: String?) -> [SyntaxToken] {
        guard let cfg = Config.forLanguage(language) else {
            // Unknown language: don't guess, ship it plain but whole.
            return code.isEmpty ? [] : [SyntaxToken(text: code, kind: .plain)]
        }
        guard !code.isEmpty else { return [] }

        let chars = Array(code)
        let n = chars.count
        var out: [SyntaxToken] = []
        var plain = ""

        func flushPlain() {
            if !plain.isEmpty {
                out.append(SyntaxToken(text: plain, kind: .plain))
                plain = ""
            }
        }
        func emit(_ range: Range<Int>, _ kind: SyntaxTokenKind) {
            flushPlain()
            out.append(SyntaxToken(text: String(chars[range]), kind: kind))
        }
        func matches(_ pat: [Character], at i: Int) -> Bool {
            guard i + pat.count <= n else { return false }
            for k in 0..<pat.count where chars[i + k] != pat[k] { return false }
            return true
        }

        var i = 0
        while i < n {
            let c = chars[i]

            // Block comment (/* ... */)
            if let block = cfg.blockComment, matches(block.open, at: i) {
                let start = i
                i += block.open.count
                while i < n, !matches(block.close, at: i) { i += 1 }
                if i < n { i += block.close.count }
                emit(start..<i, .comment)
                continue
            }

            // Line comment (// or #)
            if let lc = cfg.lineComments.first(where: { matches($0, at: i) }) {
                let start = i
                i += lc.count
                while i < n, chars[i] != "\n" { i += 1 }
                emit(start..<i, .comment)
                continue
            }

            // String literal
            if cfg.stringDelimiters.contains(c) {
                let quote = c
                let start = i
                i += 1
                while i < n {
                    if chars[i] == "\\", i + 1 < n { i += 2; continue }
                    if chars[i] == quote { i += 1; break }
                    // A newline ends a normal string (guards against an
                    // unterminated quote swallowing the rest of the file);
                    // backtick template literals may span lines.
                    if chars[i] == "\n", quote != "`" { break }
                    i += 1
                }
                emit(start..<i, .string)
                continue
            }

            // Numeric literal (must not start mid-identifier)
            if c.isNumber, i == 0 || !isIdentifierChar(chars[i - 1]) {
                let start = i
                if c == "0", i + 1 < n, "xXbBoO".contains(chars[i + 1]) {
                    i += 2
                    while i < n, chars[i].isHexDigit || chars[i] == "_" { i += 1 }
                } else {
                    while i < n, chars[i].isNumber || chars[i] == "." || chars[i] == "_" { i += 1 }
                    if i < n, chars[i] == "e" || chars[i] == "E",
                       i + 1 < n, chars[i + 1].isNumber || chars[i + 1] == "+" || chars[i + 1] == "-" {
                        i += 1
                        if chars[i] == "+" || chars[i] == "-" { i += 1 }
                        while i < n, chars[i].isNumber { i += 1 }
                    }
                }
                emit(start..<i, .number)
                continue
            }

            // Identifier / keyword
            if isIdentifierStart(c) {
                let start = i
                i += 1
                while i < n, isIdentifierChar(chars[i]) { i += 1 }
                let word = String(chars[start..<i])
                if cfg.keywords.contains(word) {
                    emit(start..<i, .keyword)
                } else {
                    plain += word
                }
                continue
            }

            // Anything else
            plain.append(c)
            i += 1
        }
        flushPlain()
        return out
    }

    // MARK: - Character classes

    private static func isIdentifierStart(_ c: Character) -> Bool {
        c == "_" || c == "$" || c.isLetter
    }

    private static func isIdentifierChar(_ c: Character) -> Bool {
        c == "_" || c == "$" || c.isLetter || c.isNumber
    }

    // MARK: - Per-language config

    struct Config {
        let keywords: Set<String>
        let lineComments: [[Character]]
        let blockComment: (open: [Character], close: [Character])?
        let stringDelimiters: Set<Character>

        static func forLanguage(_ raw: String?) -> Config? {
            guard let raw, !raw.isEmpty else { return nil }
            let lang = raw.lowercased().trimmingCharacters(in: .whitespaces)

            let cSlash: [[Character]] = [Array("//")]
            let hash: [[Character]] = [Array("#")]
            let cBlock = (open: Array("/*"), close: Array("*/"))

            switch lang {
            case "swift":
                return Config(
                    keywords: swiftKeywords,
                    lineComments: cSlash, blockComment: cBlock,
                    stringDelimiters: ["\""])
            case "js", "javascript", "jsx", "mjs", "cjs",
                 "ts", "typescript", "tsx":
                return Config(
                    keywords: jsKeywords,
                    lineComments: cSlash, blockComment: cBlock,
                    stringDelimiters: ["\"", "'", "`"])
            case "py", "python":
                return Config(
                    keywords: pythonKeywords,
                    lineComments: hash, blockComment: nil,
                    stringDelimiters: ["\"", "'"])
            case "rs", "rust":
                return Config(
                    keywords: rustKeywords,
                    lineComments: cSlash, blockComment: cBlock,
                    stringDelimiters: ["\""])
            case "go", "golang":
                return Config(
                    keywords: goKeywords,
                    lineComments: cSlash, blockComment: cBlock,
                    stringDelimiters: ["\"", "`"])
            case "json", "jsonc":
                return Config(
                    keywords: ["true", "false", "null"],
                    lineComments: [], blockComment: nil,
                    stringDelimiters: ["\""])
            case "sh", "bash", "shell", "zsh", "shellscript":
                return Config(
                    keywords: bashKeywords,
                    lineComments: hash, blockComment: nil,
                    stringDelimiters: ["\"", "'"])
            case "c", "h", "cpp", "c++", "cc", "cxx", "hpp", "objc", "objective-c":
                return Config(
                    keywords: cKeywords,
                    lineComments: cSlash, blockComment: cBlock,
                    stringDelimiters: ["\"", "'"])
            default:
                return nil
            }
        }
    }

    // MARK: - Keyword sets

    static let swiftKeywords: Set<String> = [
        "associatedtype", "class", "deinit", "enum", "extension", "fileprivate",
        "func", "import", "init", "inout", "internal", "let", "open", "operator",
        "private", "precedencegroup", "protocol", "public", "rethrows", "static",
        "struct", "subscript", "typealias", "var", "break", "case", "continue",
        "default", "defer", "do", "else", "fallthrough", "for", "guard", "if",
        "in", "repeat", "return", "switch", "where", "while", "as", "catch",
        "false", "is", "nil", "throw", "throws", "true", "try", "self", "Self",
        "super", "async", "await", "actor", "some", "any", "lazy", "weak",
        "unowned", "final", "mutating", "nonmutating", "override", "convenience",
        "required", "indirect",
    ]

    static let jsKeywords: Set<String> = [
        "abstract", "as", "async", "await", "break", "case", "catch", "class",
        "const", "continue", "debugger", "default", "delete", "do", "else",
        "enum", "export", "extends", "false", "finally", "for", "from",
        "function", "get", "if", "implements", "import", "in", "instanceof",
        "interface", "let", "new", "null", "of", "private", "protected",
        "public", "readonly", "return", "set", "static", "super", "switch",
        "this", "throw", "true", "try", "type", "typeof", "undefined", "var",
        "void", "while", "yield", "namespace", "declare", "keyof", "infer",
    ]

    static let pythonKeywords: Set<String> = [
        "and", "as", "assert", "async", "await", "break", "class", "continue",
        "def", "del", "elif", "else", "except", "False", "finally", "for",
        "from", "global", "if", "import", "in", "is", "lambda", "None",
        "nonlocal", "not", "or", "pass", "raise", "return", "True", "try",
        "while", "with", "yield", "match", "case", "self",
    ]

    static let rustKeywords: Set<String> = [
        "as", "async", "await", "break", "const", "continue", "crate", "dyn",
        "else", "enum", "extern", "false", "fn", "for", "if", "impl", "in",
        "let", "loop", "match", "mod", "move", "mut", "pub", "ref", "return",
        "self", "Self", "static", "struct", "super", "trait", "true", "type",
        "unsafe", "use", "where", "while", "union",
    ]

    static let goKeywords: Set<String> = [
        "break", "case", "chan", "const", "continue", "default", "defer",
        "else", "fallthrough", "for", "func", "go", "goto", "if", "import",
        "interface", "map", "package", "range", "return", "select", "struct",
        "switch", "type", "var", "nil", "true", "false", "iota",
    ]

    static let bashKeywords: Set<String> = [
        "if", "then", "else", "elif", "fi", "case", "esac", "for", "select",
        "while", "until", "do", "done", "in", "function", "time", "coproc",
        "echo", "return", "exit", "export", "local", "readonly", "declare",
        "source", "set", "unset", "true", "false",
    ]

    static let cKeywords: Set<String> = [
        "auto", "break", "case", "char", "const", "continue", "default", "do",
        "double", "else", "enum", "extern", "float", "for", "goto", "if", "int",
        "long", "register", "return", "short", "signed", "sizeof", "static",
        "struct", "switch", "typedef", "union", "unsigned", "void", "volatile",
        "while", "bool", "class", "namespace", "template", "public", "private",
        "protected", "virtual", "new", "delete", "nullptr", "true", "false",
        "using", "this", "constexpr", "override", "final",
    ]
}
