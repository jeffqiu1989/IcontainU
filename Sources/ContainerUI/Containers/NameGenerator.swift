import Foundation

/// Generates Docker-style `adjective_noun` names (e.g. `brave_turing`) so a
/// container left unnamed gets a short, memorable id instead of a raw UUID.
enum NameGenerator {
    private static let adjectives = [
        "admiring", "agitated", "amazing", "awesome", "blissful", "bold", "brave",
        "busy", "charming", "clever", "cool", "compassionate", "competent", "crazy",
        "dazzling", "determined", "eager", "ecstatic", "elastic", "elegant", "epic",
        "fervent", "festive", "flamboyant", "focused", "friendly", "frosty", "gallant",
        "gifted", "goofy", "gracious", "happy", "hardcore", "heuristic", "hopeful",
        "hungry", "infallible", "inspiring", "jolly", "jovial", "keen", "kind",
        "laughing", "loving", "lucid", "magical", "modest", "musing", "mystifying",
        "naughty", "nervous", "nifty", "nostalgic", "objective", "optimistic",
        "peaceful", "pedantic", "pensive", "practical", "quirky", "quizzical",
        "relaxed", "reverent", "romantic", "serene", "sharp", "silly", "sleepy",
        "stoic", "sweet", "tender", "trusting", "upbeat", "vibrant", "vigilant",
        "vigorous", "wizardly", "wonderful", "youthful", "zealous", "zen",
    ]

    private static let nouns = [
        "albattani", "allen", "almeida", "archimedes", "ardinghelli", "babbage",
        "banach", "bardeen", "bartik", "bell", "benz", "blackwell", "bohr", "booth",
        "borg", "bose", "boyd", "brahmagupta", "brattain", "carson", "cartwright",
        "chandrasekhar", "clarke", "colden", "cori", "cray", "curie", "darwin",
        "davinci", "dijkstra", "dubinsky", "easley", "edison", "einstein", "elion",
        "engelbart", "euclid", "euler", "fermat", "fermi", "feynman", "franklin",
        "galileo", "gauss", "goldberg", "goldstine", "goodall", "haibt", "hamilton",
        "hawking", "heisenberg", "hermann", "hodgkin", "hoover", "hopper", "hugle",
        "hypatia", "jang", "jennings", "jepsen", "johnson", "joliot", "jones",
        "kalam", "kepler", "khorana", "kilby", "kirch", "knuth", "kowalevski",
        "lalande", "lamarr", "lamport", "leakey", "leavitt", "lewin", "lovelace",
        "lumiere", "mahavira", "margulis", "matsumoto", "maxwell", "mayer",
        "mccarthy", "mcclintock", "mclean", "meitner", "mendel", "mestorf",
        "morse", "newton", "nightingale", "nobel", "noether", "northcutt", "noyce",
        "panini", "pare", "pascal", "pasteur", "payne", "perlman", "pike",
        "poincare", "poitras", "ptolemy", "raman", "ramanujan", "ride", "ritchie",
        "roentgen", "rosalind", "saha", "sammet", "shannon", "shaw", "shockley",
        "sinoussi", "snyder", "spence", "stallman", "swanson", "swartz", "tesla",
        "thompson", "torvalds", "turing", "varahamihira", "visvesvaraya", "volhard",
        "wescoff", "williams", "wilson", "wozniak", "wright", "yalow", "yonath",
    ]

    /// A random `adjective_noun` name, avoiding any name in `taken`. Falls back to
    /// a numeric suffix if the (large) namespace somehow keeps colliding.
    static func random(avoiding taken: Set<String> = []) -> String {
        for _ in 0..<32 {
            guard let adjective = adjectives.randomElement(),
                let noun = nouns.randomElement()
            else { break }
            let name = "\(adjective)_\(noun)"
            if !taken.contains(name) { return name }
        }
        let base = "\(adjectives.randomElement() ?? "brave")_\(nouns.randomElement() ?? "turing")"
        var suffixed = base
        var counter = 2
        while taken.contains(suffixed) {
            suffixed = "\(base)\(counter)"
            counter += 1
        }
        return suffixed
    }
}
