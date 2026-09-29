import Foundation
import MLX
import MLXGuidedGeneration
import MLXLLM
import MLXLMCommon
import Tokenizers

/// One MLX language model loaded from a local directory (weights,
/// config.json, tokenizer files - a Hugging Face snapshot), generating JSON
/// constrained to a schema.
///
/// Everything touching the model runs inside `ModelContainer.perform`,
/// off the main actor: the first grammar compile blocks for a noticeable
/// moment, and generation takes a second or two.
///
/// Dev switches (environment): `KORPORA_DEBUG_PROMPT` prints the decoded
/// prompt, its first and last token ids, and the raw output to stderr;
/// `KORPORA_FF` turns XGrammar's jump-forward on (see `generate`).
public final class LocalModel: @unchecked Sendable {
    public let directory: URL
    private let container: ModelContainer

    private init(directory: URL, container: ModelContainer) {
        self.directory = directory
        self.container = container
    }

    public static func load(from directory: URL) async throws -> LocalModel {
        let container = try await LLMModelFactory.shared.loadContainer(
            from: directory, using: TransformersTokenizerLoader())
        return LocalModel(directory: directory, container: container)
    }

    public struct Message: Sendable {
        public enum Role: Sendable { case system, user, assistant }
        public var role: Role
        public var content: String

        public init(_ role: Role, _ content: String) {
            self.role = role
            self.content = content
        }
    }

    /// Greedy generation constrained to an EBNF `grammar` (XGrammar
    /// syntax, root rule `root`) - see `QueryGrammar` for why not a JSON
    /// Schema. The output always matches the grammar, or this throws.
    ///
    /// Thinking is switched off in the chat template (Qwen3 defaults it
    /// on), since the grammar allows no `<think>` block anyway. The closing
    /// bias wraps the object up if the token budget runs low.
    public func generate(grammar: String, messages: [Message], maxTokens: Int = 512) async throws -> String {
        try await container.perform { context in
            let tokenizer = context.tokenizer
            let vocab = TokenizerVocabExtractor.extractForGrammar(from: tokenizer)
            let grammarTokenizer = try GrammarTokenizer(
                vocab: vocab.vocab, vocabType: vocab.vocabType,
                eosTokenId: Int32(tokenizer.eosTokenId ?? 0))
            let constraint = try GrammarConstraint(
                tokenizer: grammarTokenizer, grammar: grammar, rootRule: "root",
                // No jump-forward: with it, XGrammar inserts the grammar's
                // forced text (`{"positions":[{"conditions":[...`) as tokens
                // of its own choosing, not the ones the model would have
                // produced, and Qwen3-4B went off the rails right after -
                // 15/60 on the dev split instead of Python's 34 with the
                // same prompt (docs/nl-query-assistant.md, "Phase 3").
                // KORPORA_FF=1 turns it back on for experiments.
                fastForward: ProcessInfo.processInfo.environment["KORPORA_FF"] != nil,
                hostTokenizer: tokenizer)
            let chat: [Chat.Message] = messages.map {
                switch $0.role {
                case .system: return .system($0.content)
                case .user: return .user($0.content)
                case .assistant: return .assistant($0.content)
                }
            }
            let input = try await context.processor.prepare(
                input: UserInput(chat: chat, additionalContext: ["enable_thinking": false]))
            if ProcessInfo.processInfo.environment["KORPORA_DEBUG_PROMPT"] != nil {
                let tokens = input.text.tokens.asArray(Int.self)
                FileHandle.standardError.write(Data(
                    "--- prompt (\(tokens.count) tokens) \(tokens.prefix(5)) \(tokens.suffix(8)) ---\n\(tokenizer.decode(tokenIds: tokens))\n---\n".utf8))
            }
            let closing = ClosingTokenBias.compute(tokenizer: tokenizer, eosTokenId: tokenizer.eosTokenId)
            var text = ""
            try GuidedGenerationLoop.run(
                input: input, context: context, constraint: constraint,
                maxTokens: maxTokens, vocabSize: grammarTokenizer.vocabSize, closingBias: closing
            ) { delta in
                text += delta
                return true
            }
            if ProcessInfo.processInfo.environment["KORPORA_DEBUG_PROMPT"] != nil {
                FileHandle.standardError.write(Data("--- output ---\n\(text)\n---\n".utf8))
            }
            return text
        }
    }

    /// Tokens in `text` by this model's tokenizer, for the prompt budget.
    public func tokenCount(_ text: String) async -> Int {
        await container.perform { context in
            context.tokenizer.encode(text: text, addSpecialTokens: false).count
        }
    }
}

/// swift-transformers' tokenizer behind MLXLMCommon's protocol - by hand,
/// the same as MLXHuggingFace's `#adaptHuggingFaceTokenizer` macro expands
/// to, so the package needs no macro plugin.
struct TransformersTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        TokenizerBridge(upstream: try await AutoTokenizer.from(modelFolder: directory))
    }
}

struct TokenizerBridge: MLXLMCommon.Tokenizer {
    let upstream: any Tokenizers.Tokenizer

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(
                messages: messages, tools: tools, additionalContext: additionalContext)
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}
