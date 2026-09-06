import Foundation

/// Detected from sniffing a vertical file (see `CorpusImporter.sniffSchema`) -
/// a starting point for `importCorpus`'s attributes/structures, meant to be
/// user-editable before compiling, not authoritative.
public struct DetectedSchema: Sendable {
    /// Positional attribute names beyond the mandatory first column ("word"
    /// itself is never included here - see the registry format
    /// `CorpusImporter.importCorpus` writes). Placeholder names ("attr2",
    /// "attr3", ...) when the vertical file gives no hint what a column
    /// actually means - the caller is expected to let the user rename them.
    public var attributes: [String]
    public var structures: [(name: String, attributes: [String])]
}

public enum CorpusImportError: Error, CustomStringConvertible {
    case emptyVerticalFile
    case encodevertNotFound(String)
    case encodevertFailed(status: Int32, output: String)
    /// `Process.terminationStatus` doubles as a signal number when
    /// `terminationReason == .uncaughtSignal` - this is a crash (e.g. an
    /// unhandled C++ exception, an assertion, memory corruption), not a
    /// deliberate nonzero exit, and worth reporting distinctly since the
    /// two need very different follow-up.
    case encodevertCrashed(signal: Int32, output: String)

    public var description: String {
        switch self {
        case .emptyVerticalFile:
            return "The vertical file has no token lines to sniff a schema from."
        case .encodevertNotFound(let path):
            return "encodevert not found at \(path) - build manatee-open first (see scripts/setup-dev-machine.sh)."
        case .encodevertFailed(let status, let output):
            return "encodevert exited \(status): \(output)"
        case .encodevertCrashed(let signal, let output):
            let name = signalName(signal)
            return "encodevert crashed (signal \(signal)\(name.map { " \($0)" } ?? "")): \(output)"
        }
    }

    private func signalName(_ signal: Int32) -> String? {
        switch signal {
        case SIGABRT: return "SIGABRT"
        case SIGSEGV: return "SIGSEGV"
        case SIGBUS: return "SIGBUS"
        case SIGILL: return "SIGILL"
        case SIGFPE: return "SIGFPE"
        default: return nil
        }
    }
}

/// Compiles a vertical-format corpus file into a real, queryable Manatee
/// corpus under `CompiledCorpusStore`, driving the same `encodevert` tool
/// `TestCorpusFixture`/`Corpora/scripts/build-dev-corpus.sh` already shell
/// out to by hand - the point of this type is to make that a real app
/// feature (pick a file, edit a pre-filled schema, compile) instead of a
/// script someone has to run themselves.
/// Caches `CorpusImporter.countLines`'s result per file, keyed by size +
/// modification date - cheap to check, and correctly invalidates if the
/// file is ever replaced/edited. A vertical file's line count can't change
/// without the file itself changing, so re-counting on every single Compile
/// attempt on the *same* file (e.g. after cancelling and retrying) is pure
/// waste - this makes a second attempt on an unchanged file instant instead
/// of re-scanning a potentially multi-GB file again.
private final class LineCountCache: @unchecked Sendable {
    static let shared = LineCountCache()
    private struct Key: Equatable { let size: Int; let modified: Date }
    private let lock = NSLock()
    private var entries: [URL: (key: Key, count: Int)] = [:]

    private func key(for url: URL) -> Key? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? Int, let modified = attributes[.modificationDate] as? Date
        else { return nil }
        return Key(size: size, modified: modified)
    }

    func cachedCount(for url: URL) -> Int? {
        guard let key = key(for: url) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[url], entry.key == key else { return nil }
        return entry.count
    }

    func store(_ count: Int, for url: URL) {
        guard let key = key(for: url) else { return }
        lock.lock()
        entries[url] = (key, count)
        lock.unlock()
    }
}

public enum CorpusImporter {
    /// A fast line count for `verticalFile`, so a caller can show a
    /// determinate "N / total (X%) processed" progress UI against
    /// `encodevert`'s own "Processed N lines" output instead of an
    /// indeterminate spinner. Counts raw `\n` bytes directly rather than
    /// decoding UTF-8 line-by-line (`sniffSchema`'s approach, fine for a
    /// bounded scan but too slow to run over an entire
    /// many-hundred-million-line file) - I/O-bound, not CPU-bound, so this
    /// stays fast even on a multi-GB file. Cooperatively cancellable.
    /// Cached per unchanged file (see `LineCountCache`) - repeating this on
    /// the same file (e.g. cancel then retry) is instant after the first
    /// call.
    public static func countLines(verticalFile: URL) async throws -> Int {
        if let cached = LineCountCache.shared.cachedCount(for: verticalFile) {
            return cached
        }
        let handle = try FileHandle(forReadingFrom: verticalFile)
        defer { try? handle.close() }
        var count = 0
        let newline: UInt8 = 0x0A
        while true {
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty else { break }
            count += chunk.reduce(0) { $1 == newline ? $0 + 1 : $0 }
        }
        LineCountCache.shared.store(count, for: verticalFile)
        return count
    }

    /// Reads just enough of `verticalFile` to guess its schema - capped at
    /// `maxLinesScanned` lines (a real vertical file can be many billions of
    /// lines, so scanning the whole file isn't desirable). A **heuristic**
    /// starting point, not a guarantee: real corpora can nest structures
    /// unevenly (e.g. a `<p>`/`<text>` pair that only wraps some documents,
    /// or simply doesn't appear until deep into the file) such that even a
    /// fairly generous scan window misses some - confirmed against a real
    /// 162M-line corpus, where two structures genuinely didn't appear in the
    /// first 500,000 lines. There's no bounded scan size that can
    /// *guarantee* finding every structure in an arbitrarily large,
    /// heterogeneous file without reading all of it - the schema form is
    /// fully editable specifically so the caller can add whatever this
    /// missed by hand.
    public static func sniffSchema(verticalFile: URL, maxLinesScanned: Int = 500_000) async throws -> DetectedSchema {
        var attributeCount: Int?
        var structureOrder: [String] = []
        var structureAttributes: [String: Set<String>] = [:]

        var linesScanned = 0
        for try await line in verticalFile.lines {
            if linesScanned >= maxLinesScanned { break }
            linesScanned += 1
            guard !line.isEmpty else { continue }
            if line.hasPrefix("<") {
                guard let (name, attrs) = parseStructureTag(line) else { continue }
                if structureAttributes[name] == nil {
                    structureOrder.append(name)
                    structureAttributes[name] = []
                }
                structureAttributes[name]?.formUnion(attrs)
            } else if attributeCount == nil {
                attributeCount = line.split(separator: "\t", omittingEmptySubsequences: false).count
            }
        }

        guard let attributeCount else { throw CorpusImportError.emptyVerticalFile }
        let attributes = attributeCount > 1 ? (2...attributeCount).map { "attr\($0)" } : []
        let structures = structureOrder.map { name in
            (name: name, attributes: (structureAttributes[name] ?? []).sorted())
        }
        return DetectedSchema(attributes: attributes, structures: structures)
    }

    private static let structureTagPattern = try! Regex(#"<(\w+)((?:\s+[^>]*)?)/?>"#)
    private static let attributePattern = try! Regex(#"(\w+)="[^"]*""#)

    /// `<name attr="val" ...>` -> (name, [attr, ...]); nil for closing tags
    /// or anything else that doesn't look like an opening structure tag.
    /// Uses the generic `Regex(pattern:)` initializer (untyped captures,
    /// accessed via `match.output[n].substring`) rather than regex literal
    /// syntax (`/pattern/`), which the compiler couldn't parse unambiguously
    /// in this position.
    private static func parseStructureTag(_ line: String) -> (String, [String])? {
        guard !line.hasPrefix("</"), let match = line.wholeMatch(of: structureTagPattern) else {
            return nil
        }
        let name = String(match.output[1].substring ?? "")
        let attributesBlob = String(match.output[2].substring ?? "")
        let attributes = attributesBlob.matches(of: attributePattern)
            .compactMap { $0.output[1].substring.map(String.init) }
        return (name, attributes)
    }

    /// A handle to the running `encodevert` subprocess, handed to
    /// `importCorpus`'s `onStart` callback once it's actually running - lets
    /// a caller offer real pause/resume/cancel controls (the macOS "gold
    /// standard" for a long-running operation) rather than just cancel.
    /// `suspend`/`resume` map directly to `Process`'s own (SIGSTOP/SIGCONT
    /// under the hood) - `encodevert` itself has no cooperative pause
    /// protocol, but suspending the whole process works for any subprocess.
    public final class ImportHandle: @unchecked Sendable {
        private let process: Process
        fileprivate init(process: Process) { self.process = process }
        @discardableResult public func pause() -> Bool { process.suspend() }
        @discardableResult public func resume() -> Bool { process.resume() }
    }

    /// Writes a registry file under `CompiledCorpusStore` and compiles
    /// `verticalFile` into it via `encodevert`, forwarding its output line
    /// by line to `onProgress` (its own output isn't a documented, parseable
    /// percentage, so this is the honest granularity available - an
    /// indeterminate progress UI plus visible log is the expected
    /// caller-side presentation). `onStart` is called once with an
    /// `ImportHandle` as soon as the subprocess is actually running.
    /// Cooperatively cancellable - cancelling the calling task terminates
    /// the `encodevert` subprocess (SIGTERM, immediately - not a graceful
    /// "finish the current line" wait, since there's no way to ask
    /// `encodevert` to do that). Blocks its calling thread for the whole
    /// compile (same as every other Process-based call in this codebase,
    /// e.g. `TestCorpusFixture.build()`) - callers should launch this from a
    /// background task, not on the main actor.
    public static func importCorpus(
        name: String, verticalFile: URL, attributes: [String],
        structures: [(name: String, attributes: [String])],
        onProgress: @escaping @Sendable (String) -> Void,
        onStart: (@Sendable (ImportHandle) -> Void)? = nil
    ) async throws {
        let registryPath = CompiledCorpusStore.registryPath(for: name)
        let dataDirectory = CompiledCorpusStore.dataDirectory(for: name)
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)

        let registryText = makeRegistryText(
            name: name, dataDirectory: dataDirectory, verticalFile: verticalFile,
            attributes: attributes, structures: structures)
        try registryText.write(to: registryPath, atomically: true, encoding: .utf8)

        let encodevert = manateeOpenRoot().appendingPathComponent("src/encodevert")
        guard FileManager.default.isExecutableFile(atPath: encodevert.path) else {
            throw CorpusImportError.encodevertNotFound(encodevert.path)
        }

        let process = Process()
        process.executableURL = encodevert
        process.arguments = ["-v", "-c", name]
        // encodevert calls out to a few of its own sibling tools via
        // system("toolname ...") rather than an absolute path (e.g.
        // mkregexattr, for the optional regex-query optimization pass on
        // each attribute) - those rely on being found via PATH, which
        // otherwise only has whatever this app's own process inherited and
        // not manatee-open's build directory. Without this, encodevert logs
        // "ERROR: failed to create regular expression attribute ..." for
        // every attribute and silently skips that optimization - harmless
        // (found by reading encodevert.cc's compile_regexopt(): it's an
        // optional speedup for regex-heavy CQL queries against that
        // attribute, not needed for correctness), but easy to just fix.
        let toolsDirectory = manateeOpenRoot().appendingPathComponent("src").path
        let inheritedPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        process.environment = ProcessInfo.processInfo.environment.merging(
            [
                "MANATEE_REGISTRY": CompiledCorpusStore.baseDirectory.path,
                "PATH": "\(toolsDirectory):\(inheritedPath)",
            ], uniquingKeysWith: { _, new in new })

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let output = OutputCollector()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            output.append(text)
            onProgress(text)
        }

        try await withTaskCancellationHandler {
            try process.run()
            onStart?(ImportHandle(process: process))
            process.waitUntilExit()
        } onCancel: {
            process.terminate()
        }

        // The readabilityHandler above runs asynchronously on a GCD-managed
        // queue and races with waitUntilExit() returning - without an
        // explicit final drain here, the last chunk of output (often the
        // most important part of a crash, e.g. the line right before it
        // died) could be silently missing from `output` below.
        pipe.fileHandleForReading.readabilityHandler = nil
        if let remaining = try? pipe.fileHandleForReading.readToEnd(),
           let text = String(data: remaining, encoding: .utf8), !text.isEmpty {
            output.append(text)
            onProgress(text)
        }

        if process.terminationReason == .uncaughtSignal {
            throw CorpusImportError.encodevertCrashed(signal: process.terminationStatus, output: output.text)
        }
        guard process.terminationStatus == 0 else {
            throw CorpusImportError.encodevertFailed(status: process.terminationStatus, output: output.text)
        }
    }

    /// `Pipe`'s `readabilityHandler` runs on a GCD-managed background queue
    /// independent of the calling thread (which blocks in
    /// `waitUntilExit()`) - this just serializes access to the accumulated
    /// output text across that handler and the throw site above. Caps
    /// retained text (keeping the tail, i.e. the most recent/most
    /// diagnostically relevant part) rather than growing unbounded - a real
    /// ~162M-line corpus import found `encodevert` can spew output far
    /// faster than anyone would want to store in full when something goes
    /// wrong partway through.
    private final class OutputCollector: @unchecked Sendable {
        private static let maxRetained = 200_000
        private let lock = NSLock()
        private var _text = ""
        var text: String {
            lock.lock()
            defer { lock.unlock() }
            return _text
        }
        func append(_ text: String) {
            lock.lock()
            _text += text
            if _text.count > Self.maxRetained {
                _text = String(_text.suffix(Self.maxRetained))
            }
            lock.unlock()
        }
    }

    private static func makeRegistryText(
        name: String, dataDirectory: URL, verticalFile: URL,
        attributes: [String], structures: [(name: String, attributes: [String])]
    ) -> String {
        var lines = [
            "NAME \"\(name)\"",
            "INFO \"Imported corpus\"",
            "PATH \"\(dataDirectory.path)\"",
            "VERTICAL \"\(verticalFile.path)\"",
            "LANGUAGE \"en\"",
            "ENCODING \"utf-8\"",
            "",
            "ATTRIBUTE word",
        ]
        for attribute in attributes {
            lines.append("ATTRIBUTE \(attribute) {")
            lines.append("}")
        }
        for structure in structures {
            lines.append("STRUCTURE \(structure.name) {")
            for attribute in structure.attributes {
                lines.append("    ATTRIBUTE \(attribute)")
            }
            lines.append("}")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // Package.swift resolves manatee-open the same way, relative to this
    // package's own root rather than any hardcoded machine path - fine for
    // this project's current dev-only state (see docs/project-plan.md's
    // "Packaging" note); a real shipped build would need encodevert bundled
    // into the app instead.
    private static func manateeOpenRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ManateeKit (Sources/ManateeKit)
            .deletingLastPathComponent() // Sources
            .deletingLastPathComponent() // ManateeKit (package root)
            .deletingLastPathComponent() // mac-corpora
            .appendingPathComponent("manatee-open")
    }
}
