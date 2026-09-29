import Foundation
import KorporaAssistant
import ManateeKit

// Dev tool: shows what the query assistant would give its model for a
// corpus in MANATEE_REGISTRY, so prompts can be read and benchmarked
// (scripts/nl-spike/run.py --prompts) without building the app.
//
//   korpora-assistant profile CORPUS            attribute roles, tagset family
//   korpora-assistant schema CORPUS             the generation JSON Schema
//   korpora-assistant prompt CORPUS REQUEST...  system + user prompt
//   korpora-assistant prompts CORPUS FILE.tsv   one JSON object per line:
//                                               {"request", "system", "user"}
//                                               for each request (column 1)
//   korpora-assistant plans CORPUS              reads QueryPlan JSON, one per
//                                               line on stdin; writes
//                                               {"cql", "repairs"} per line
//                                               (QueryRepair + CQLSerializer)
//
// prompt/prompts take --level N (start at a less detailed prompt level)
// --no-retrieval (the bank's first examples for every request),
// --curated (UD values in gloss-table order, glossed ones only),
// --basic-rules (phase 0 v1 rules) and --no-feature-glosses.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let args = CommandLine.arguments.dropFirst()
guard let command = args.first, let corpusName = args.dropFirst().first else {
    fail("usage: korpora-assistant profile|schema|prompt|prompts CORPUS [...]")
}
var rest = Array(args.dropFirst(2))
var options = QueryContextBuilder.Options()
if let i = rest.firstIndex(of: "--level"), i + 1 < rest.count, let n = Int(rest[i + 1]) {
    options.firstLevel = n
    rest.removeSubrange(i...(i + 1))
}
for (flag, apply) in [("--no-retrieval", { options.retrieveExamples = false }),
                      ("--curated", { options.curatedUD = true }),
                      ("--basic-rules", { options.extraRules = false }),
                      ("--no-feature-glosses", { options.glossFeatures = false })] as [(String, () -> Void)] {
    if let i = rest.firstIndex(of: flag) {
        apply()
        rest.remove(at: i)
    }
}

do {
    let corpus = try await Corpus(name: corpusName)
    switch command {
    case "schema":
        print(QuerySchema.json(for: try await corpus.info()))
    case "profile":
        let profile = try await CorpusProfile.gather(from: corpus)
        print("tagset family: \(profile.tagsetFamily)")
        for a in profile.attributes {
            let sample = a.topValues.prefix(6).map(\.value).joined(separator: " ")
            print("\(a.name)\t\(a.role.rawValue)\t\(sample)")
        }
        for s in profile.structureAttributes {
            print("\(s.name)\t\(s.isCategorical ? "categorical" : "free")\t\(s.topValues.count) values")
        }
    case "prompt":
        let profile = try await CorpusProfile.gather(from: corpus)
        let prompt = QueryContextBuilder.build(
            profile: profile, request: rest.joined(separator: " "), options: options)
        print(prompt.system)
        print("\n---\n" + prompt.user)
    case "prompts":
        guard let file = rest.first else { fail("prompts needs a TSV file") }
        let profile = try await CorpusProfile.gather(from: corpus)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        for line in try String(contentsOfFile: file, encoding: .utf8).split(separator: "\n") {
            let request = String(line.split(separator: "\t", maxSplits: 1)[0])
            let prompt = QueryContextBuilder.build(profile: profile, request: request, options: options)
            let record = ["request": request, "system": prompt.system, "user": prompt.user]
            print(String(decoding: try encoder.encode(record), as: UTF8.self))
        }
    case "plans":
        let profile = try await CorpusProfile.gather(from: corpus)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        while let line = readLine() {
            var record: [String: String] = [:]
            do {
                let plan = try JSONDecoder().decode(QueryPlan.self, from: Data(line.utf8))
                let (repaired, changes) = QueryRepair.repair(plan, profile: profile)
                record["cql"] = CQLSerializer.cql(for: repaired)
                record["repairs"] = changes.map { "\($0.attribute): \($0.from) -> \($0.to)" }
                    .joined(separator: "; ")
            } catch {
                record["error"] = "\(error)"
            }
            print(String(decoding: try encoder.encode(record), as: UTF8.self))
            fflush(stdout)
        }
    default:
        fail("unknown command \(command)")
    }
} catch {
    fail("error: \(error)")
}
