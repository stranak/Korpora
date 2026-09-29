import Foundation
import KorporaAssistant
import ManateeKit

/// Natural language in, a reviewed-ready CQL query out, for one corpus and
/// one loaded model (docs/nl-query-assistant.md, "Validation loop"):
///
///   prompt → guided generation → QueryPlan → repair → CQL → engine check
///   → (if the engine objects, a value doesn't exist, or nothing matches)
///   one retry with that feedback.
///
/// The result is a suggestion for the query field, never run by itself;
/// its hit count is capped, so it says "at least N" for a big query
/// without evaluating it fully.
public final class QueryAssistant: @unchecked Sendable {
    public let corpus: Corpus
    public let profile: CorpusProfile
    public let model: LocalModel
    /// `QueryGrammar` for this corpus: set `spacedJSON` to rebuild it.
    public private(set) var grammar: String
    /// `", "`/`": "` between JSON items instead of none (a benchmark knob;
    /// see `QueryGrammar.ebnf(spaced:)`).
    public var spacedJSON = false {
        didSet { grammar = Self.grammar(for: profile, spaced: spacedJSON) }
    }

    public var hitCap = 10_000
    /// Prompt budget in the model's tokens. Qwen3's context is 32k; the
    /// prompt is ~2k, so this only matters for small-context models.
    public var promptBudget = 6_000
    public var options = QueryContextBuilder.Options()

    public init(corpus: Corpus, profile: CorpusProfile, model: LocalModel) {
        self.corpus = corpus
        self.profile = profile
        self.model = model
        self.grammar = Self.grammar(for: profile, spaced: false)
    }

    static func grammar(for profile: CorpusProfile, spaced: Bool) -> String {
        QueryGrammar.ebnf(attributes: profile.info.attributes,
                          structureAttributes: QuerySchema.structureAttributeNames(profile.info),
                          spaced: spaced)
    }

    public struct Suggestion: Sendable {
        public var cql: String
        public var plan: QueryPlan
        public var explanation: String { plan.explanation }
        /// Hits up to `hitCap`; nil when the engine rejected the query.
        public var hits: Int?
        public var hitsCapped: Bool
        /// The engine's error for the final query, if it still has one.
        public var engineError: String?
        public var repairs: [QueryRepair.Change]
        /// Set when the first attempt was sent back: what the model was
        /// told, and the query it had produced.
        public var retryFeedback: String?
        public var firstCQL: String?
        public var seconds: Double
    }

    public enum Failure: Error, CustomStringConvertible {
        case undecodable(String)

        public var description: String {
            switch self {
            case .undecodable(let text): return "the model's output isn't a QueryPlan: \(text.prefix(200))"
            }
        }
    }

    public func suggest(_ request: String, retry: Bool = true) async throws -> Suggestion {
        let start = Date()
        let prompt = await buildPrompt(request)
        var messages: [LocalModel.Message] = [.init(.system, prompt.system), .init(.user, prompt.user)]
        var attempt = try await self.attempt(messages)
        var feedback: String?
        var firstCQL: String?
        if retry, let message = try await problems(attempt) {
            feedback = message
            firstCQL = attempt.cql
            messages += [.init(.assistant, attempt.text), .init(.user, "\(message) Fix the QueryPlan.")]
            attempt = try await self.attempt(messages)
        }
        return Suggestion(
            cql: attempt.cql, plan: attempt.plan, hits: attempt.hits,
            hitsCapped: (attempt.hits ?? 0) >= hitCap, engineError: attempt.engineError,
            repairs: attempt.repairs, retryFeedback: feedback, firstCQL: firstCQL,
            seconds: Date().timeIntervalSince(start))
    }

    private func buildPrompt(_ request: String) async -> QueryPrompt {
        // The model's tokenizer is async (it lives in the model container),
        // the builder's counter is sync: measure the full-detail prompt once
        // and scale, rather than tokenizing every candidate level.
        let full = QueryContextBuilder.build(profile: profile, request: request, options: options)
        let tokens = await model.tokenCount(full.system + full.user)
        guard tokens > promptBudget else { return full }
        let ratio = Double(tokens) / Double(max(full.system.utf8.count + full.user.utf8.count, 1))
        return QueryContextBuilder.build(
            profile: profile, request: request, budget: promptBudget,
            countTokens: { Int(Double($0.utf8.count) * ratio) + 1 }, options: options)
    }

    struct Attempt {
        var text: String
        var plan: QueryPlan
        var cql: String
        var repairs: [QueryRepair.Change]
        var hits: Int?
        var engineError: String?
    }

    private func attempt(_ messages: [LocalModel.Message]) async throws -> Attempt {
        let text = try await model.generate(grammar: grammar, messages: messages)
        guard let plan = try? JSONDecoder().decode(QueryPlan.self, from: Data(text.utf8)) else {
            throw Failure.undecodable(text)
        }
        let (repaired, repairs) = QueryRepair.repair(plan, profile: profile)
        let cql = CQLSerializer.cql(for: repaired)
        var hits: Int?
        var engineError: String?
        do {
            hits = try await corpus.probeQuery(cql, limit: hitCap)
        } catch {
            engineError = "\(error)"
        }
        return Attempt(text: text, plan: repaired, cql: cql, repairs: repairs, hits: hits,
                       engineError: engineError)
    }

    /// The retry feedback for an attempt, or nil if it looks right.
    private func problems(_ attempt: Attempt) async throws -> String? {
        var missing: [QueryFeedback.MissingValue] = []
        if attempt.engineError == nil {
            let samples = Dictionary(uniqueKeysWithValues: profile.attributes.map { ($0.name, $0) })
            for condition in QueryFeedback.literalConditions(attempt.plan) {
                guard let sample = samples[condition.attribute] else { continue }
                let known = sample.topValues.map(\.value)
                if known.contains(condition.value) { continue }
                // A value outside a partial sample (a rare word) may still
                // exist: ask the engine. A complete sample is the answer.
                let complete = known.count < CorpusProfile.valueSampleSize
                if !complete {
                    let probe = "[\(condition.attribute)=\(CQLSerializer.quoted(condition.value))]"
                    if (try? await corpus.probeQuery(probe, limit: 1)) ?? 0 > 0 { continue }
                }
                let foundIn = profile.attributes
                    .filter { $0.name != condition.attribute && $0.topValues.contains { $0.value == condition.value } }
                    .map(\.name)
                missing.append(.init(attribute: condition.attribute, value: condition.value,
                                     similar: QueryFeedback.similar(to: condition.value, in: known),
                                     foundIn: foundIn))
            }
        }
        return QueryFeedback.message(engineError: attempt.engineError, missing: missing, hits: attempt.hits)
    }
}
