import ManateeKit

@main
struct CLI {
    static func main() async {
        let args = CommandLine.arguments
        guard args.count >= 3 else {
            print("usage: manateekit-cli <corpus_name> <cql_query>")
            return
        }
        do {
            let corpus = try await Corpus(name: args[1])
            print("opened corpus, size=\(try await corpus.size) tokens")
            let lines = try await corpus.query(args[2])
            print("query matched \(lines.count) hits")
            for line in lines {
                print("\(line.left) [[ \(line.kwic) ]] \(line.right)")
            }
        } catch {
            print("error: \(error)")
        }
    }
}
