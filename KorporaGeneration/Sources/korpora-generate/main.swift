import Foundation
import KorporaAssistant
import KorporaGeneration
import ManateeKit

// Dev tool: the app's whole generation path (QueryAssistant) from the
// command line, for a corpus in MANATEE_REGISTRY and a local MLX model
// directory (a Hugging Face snapshot: config.json, *.safetensors,
// tokenizer files).
//
//   korpora-generate ask CORPUS MODEL_DIR REQUEST...
//   korpora-generate bench CORPUS MODEL_DIR REQUESTS.tsv [--no-retry] > results.tsv
//
// --spaced generates JSON with ", "/": " separators (QueryGrammar).
//
// `bench` writes run.py's results format (request, gold, cql, -, error,
// note, explanation, seconds), so scripts/nl-spike/run.py --rescore scores
// it: scripts/nl-spike/bench-swift.sh does both.
//
// MLX's Metal shaders need Xcode's build system, so build with
//   xcodebuild -scheme korpora-generate -destination platform=macOS \
//       -derivedDataPath .build/xcode build
// in KorporaGeneration/ (plain `swift build` links, then fails at runtime
// for want of default.metallib).

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func tsv(_ s: String) -> String {
    s.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
}

var args = Array(CommandLine.arguments.dropFirst())
let retry = !args.contains("--no-retry")
let spaced = args.contains("--spaced")
args.removeAll { $0 == "--no-retry" || $0 == "--spaced" }
guard args.count >= 4 else {
    fail("usage: korpora-generate ask|bench CORPUS MODEL_DIR REQUEST...|REQUESTS.tsv [--no-retry]")
}
let (command, corpusName, modelDir) = (args[0], args[1], args[2])

do {
    let corpus = try await Corpus(name: corpusName)
    let profile = try await CorpusProfile.gather(from: corpus)
    let model = try await LocalModel.load(from: URL(fileURLWithPath: modelDir))
    let assistant = QueryAssistant(corpus: corpus, profile: profile, model: model)
    assistant.spacedJSON = spaced
    switch command {
    case "ask":
        let s = try await assistant.suggest(args[3...].joined(separator: " "), retry: retry)
        print(s.cql)
        print(s.explanation)
        print("hits: \(s.hits.map { s.hitsCapped ? "≥\($0)" : "\($0)" } ?? "-")"
              + (s.engineError.map { "  error: \($0)" } ?? ""))
        if let feedback = s.retryFeedback { print("retried: \(feedback) (first: \(s.firstCQL ?? ""))") }
        if !s.repairs.isEmpty { print("repaired: \(s.repairs)") }
        print(String(format: "%.1f s", s.seconds))
    case "bench":
        let lines = try String(contentsOfFile: args[3], encoding: .utf8).split(separator: "\n")
        for line in lines {
            let cols = line.split(separator: "\t", maxSplits: 1).map(String.init)
            let (request, gold) = (cols[0], cols.count > 1 ? cols[1] : "")
            var row: [String]
            do {
                let s = try await assistant.suggest(request, retry: retry)
                var notes: [String] = []
                if !s.repairs.isEmpty {
                    notes.append("repaired (" + s.repairs.map { "\($0.attribute): \($0.from) -> \($0.to)" }
                        .joined(separator: "; ") + ")")
                }
                if let feedback = s.retryFeedback {
                    notes.append("retried (\(feedback); first: \(s.firstCQL ?? ""))")
                }
                row = [request, gold, s.cql, "", s.engineError ?? "", notes.joined(separator: " "),
                       s.explanation, String(format: "%.1f", s.seconds)]
            } catch {
                row = [request, gold, "", "", "generation failed: \(error)", "", "", ""]
            }
            print(row.map(tsv).joined(separator: "\t"))
            fflush(stdout)
            FileHandle.standardError.write(Data("\(row[2].isEmpty ? "FAIL" : "ok  ") \(request)\n".utf8))
        }
    default:
        fail("unknown command \(command)")
    }
} catch {
    fail("error: \(error)")
}
