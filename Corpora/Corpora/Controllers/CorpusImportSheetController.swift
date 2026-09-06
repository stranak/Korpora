import Cocoa
import ManateeKit

/// The sheet behind Corpora settings' "Import Corpus…" button - takes a
/// vertical file the caller already picked (see
/// `CorporaSettingsViewController.importCorpusTapped`), sniffs a starting
/// schema from it (`CorpusImporter.sniffSchema`), and lets the user review/
/// edit it before compiling (`CorpusImporter.importCorpus`) - this is the
/// whole point of the feature: no hand-written registry file, no terminal.
/// A plain, thread-safe accumulator `onProgress` callbacks append to -
/// decoupled from actually updating the log view (see `flushLog()`) so a
/// flood of very fast/frequent output can't force one expensive
/// `NSTextView` relayout per chunk. Also tracks the most recent "Processed
/// N lines" count parsed out of that output, for the determinate progress
/// bar - parsing happens here (off the main actor, wherever `onProgress` is
/// actually called from) rather than in the UI-updating timer, so a flood
/// of output doesn't turn into a flood of regex work on the main thread.
private final class LogBuffer: @unchecked Sendable {
    private static let processedLinePattern = try! Regex(#"Processed (\d+) lines"#)

    private let lock = NSLock()
    private var pending = ""
    private var _linesProcessed: Int?

    func append(_ text: String) {
        lock.lock()
        pending += text
        if let match = text.matches(of: Self.processedLinePattern).last,
           let count = match.output[1].substring.flatMap({ Int($0) }) {
            _linesProcessed = count
        }
        lock.unlock()
    }

    func drain() -> (text: String, linesProcessed: Int?) {
        lock.lock()
        defer { pending = "" }
        let result = (pending, _linesProcessed)
        lock.unlock()
        return result
    }
}

final class CorpusImportSheetController: NSViewController {
    private let verticalFile: URL
    var onImported: (() -> Void)?

    private let nameField = NSTextField(string: "")
    private let attributesField = NSTextField(string: "Detecting…")
    private let structuresView = NSTextView()
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let compileButton = NSButton(title: "Compile", target: nil, action: nil)

    private let formStack = NSView()
    private let progressStack = NSView()
    private let progressIndicator = NSProgressIndicator()
    private let statusLabel = NSTextField(labelWithString: "Preparing\u{2026}")
    private let disclosureButton = NSButton(title: "Show Log", target: nil, action: nil)
    private let progressLog = NSTextView()
    private let logScroll = NSScrollView()
    private var logHeightConstraint: NSLayoutConstraint!
    private var isLogExpanded = false
    private var importTask: Task<Void, Never>?
    private var totalLines: Int?
    private var importHandle: CorpusImporter.ImportHandle?
    private var isPaused = false
    private let pauseButton = NSButton(title: "Pause", target: nil, action: nil)

    // `encodevert`'s output rate is unbounded - on a real corpus, something
    // going wrong partway through can make it spew output far faster than
    // once-per-chunk UI updates can keep up with, which visibly corrupts
    // the text view's rendering rather than just lagging (found via a real
    // ~162M-line corpus import). `logBuffer` absorbs progress at whatever
    // rate it arrives; `logFlushTimer` drains it into the view on a fixed,
    // gentle cadence instead, and `maxDisplayedLogLength` keeps the view
    // itself from becoming enormous - independent of `CorpusImporter`'s own
    // full-output capture used for the eventual error message. The raw log
    // is collapsed behind a disclosure toggle by default - a determinate
    // progress bar plus a "N / total (X%)" status line is what most people
    // want to see; the full log is there for anyone who needs it.
    private let logBuffer = LogBuffer()
    private var logFlushTimer: Timer?
    private static let maxDisplayedLogLength = 200_000
    // Fixed for the sheet's entire lifetime, covering both the form and the
    // progress view (expanded log included) - never changed programmatically
    // after loadView(). A previous version resized the window dynamically
    // when the log was toggled, which turned out to interact badly with an
    // improperly-configured NSTextView (see progressLog's setup below) and
    // let the window balloon far off-screen on a real, long-running import -
    // fixed size is a hard backstop against that whole class of bug, not
    // just a fix for the one specific cause.
    private static let fixedContentSize = NSSize(width: 480, height: 440)
    private static let expandedLogHeight: CGFloat = 180

    init(verticalFile: URL) {
        self.verticalFile = verticalFile
        super.init(nibName: nil, bundle: nil)
        // Quitting the app must not leave an orphaned encodevert subprocess
        // running (found the hard way: it couldn't even be quit normally
        // after a crash and had to be force-killed from Xcode). This runs
        // before the app actually exits, giving the subprocess a chance to
        // receive SIGTERM instead of surviving its parent.
        NotificationCenter.default.addObserver(
            self, selector: #selector(applicationWillTerminate),
            name: NSApplication.willTerminateNotification, object: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func applicationWillTerminate() {
        importTask?.cancel()
    }

    override func loadView() {
        let root = NSView(frame: NSRect(origin: .zero, size: Self.fixedContentSize))
        view = root
        preferredContentSize = Self.fixedContentSize

        buildFormStack()
        buildProgressStack()
        for stack in [formStack, progressStack] {
            stack.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.topAnchor.constraint(equalTo: root.topAnchor),
                stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            ])
        }
        showForm()
    }

    /// `formStack`/`progressStack` must never both be visible at once (found
    /// the hard way: a real import's log content and the schema form ended
    /// up overlapping on screen) - routing every visibility change through
    /// these two methods, rather than setting each flag inline at each call
    /// site, is what actually guarantees that instead of just being
    /// disciplined about remembering to set both every time.
    private func showForm() {
        progressStack.isHidden = true
        formStack.isHidden = false
    }

    private func showProgress() {
        formStack.isHidden = true
        progressStack.isHidden = false
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        nameField.stringValue = verticalFile.deletingPathExtension().lastPathComponent
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let schema = try await CorpusImporter.sniffSchema(verticalFile: verticalFile)
                attributesField.stringValue = schema.attributes.joined(separator: ", ")
                structuresView.string = schema.structures.map { structure in
                    structure.attributes.isEmpty
                        ? structure.name
                        : "\(structure.name): \(structure.attributes.joined(separator: ", "))"
                }.joined(separator: "\n")
            } catch {
                attributesField.stringValue = ""
                errorLabel.stringValue = "Couldn’t detect a schema: \(error)"
                errorLabel.isHidden = false
            }
        }
    }

    private func buildFormStack() {
        let title = NSTextField(labelWithString: "Import Corpus")
        title.font = .boldSystemFont(ofSize: 13)
        let fileLabel = NSTextField(labelWithString: "Vertical file:")
        let filePathLabel = NSTextField(labelWithString: verticalFile.path)
        filePathLabel.lineBreakMode = .byTruncatingMiddle
        filePathLabel.font = .systemFont(ofSize: 11)
        filePathLabel.textColor = .secondaryLabelColor

        let nameLabel = NSTextField(labelWithString: "Corpus name:")
        let attributesLabel = NSTextField(labelWithString: "Positional attributes (after \u{201c}word\u{201d}), comma-separated:")
        let structuresLabel = NSTextField(labelWithString: "Structures - one per line, \u{201c}name: attr1, attr2\u{201d} or just \u{201c}name\u{201d}:")

        structuresView.isRichText = false
        structuresView.font = .systemFont(ofSize: 12)
        Self.configureForScrolling(structuresView)
        let structuresScroll = NSScrollView()
        structuresScroll.documentView = structuresView
        structuresScroll.hasVerticalScroller = true
        structuresScroll.borderType = .bezelBorder

        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.textColor = .systemRed
        errorLabel.isHidden = true

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped))
        cancelButton.keyEquivalent = "\u{1b}"
        compileButton.target = self
        compileButton.action = #selector(compileTapped)
        compileButton.keyEquivalent = "\r"
        compileButton.bezelStyle = .rounded

        let views: [NSView] = [
            title, fileLabel, filePathLabel, nameLabel, nameField,
            attributesLabel, attributesField, structuresLabel, structuresScroll,
            errorLabel, cancelButton, compileButton,
        ]
        for v in views {
            v.translatesAutoresizingMaskIntoConstraints = false
            formStack.addSubview(v)
        }

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: formStack.topAnchor, constant: 16),
            title.leadingAnchor.constraint(equalTo: formStack.leadingAnchor, constant: 16),

            fileLabel.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 16),
            fileLabel.leadingAnchor.constraint(equalTo: formStack.leadingAnchor, constant: 16),
            filePathLabel.topAnchor.constraint(equalTo: fileLabel.bottomAnchor, constant: 4),
            filePathLabel.leadingAnchor.constraint(equalTo: formStack.leadingAnchor, constant: 16),
            filePathLabel.trailingAnchor.constraint(equalTo: formStack.trailingAnchor, constant: -16),

            nameLabel.topAnchor.constraint(equalTo: filePathLabel.bottomAnchor, constant: 16),
            nameLabel.leadingAnchor.constraint(equalTo: formStack.leadingAnchor, constant: 16),
            nameField.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 4),
            nameField.leadingAnchor.constraint(equalTo: formStack.leadingAnchor, constant: 16),
            nameField.trailingAnchor.constraint(equalTo: formStack.trailingAnchor, constant: -16),

            attributesLabel.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 16),
            attributesLabel.leadingAnchor.constraint(equalTo: formStack.leadingAnchor, constant: 16),
            attributesLabel.trailingAnchor.constraint(equalTo: formStack.trailingAnchor, constant: -16),
            attributesField.topAnchor.constraint(equalTo: attributesLabel.bottomAnchor, constant: 4),
            attributesField.leadingAnchor.constraint(equalTo: formStack.leadingAnchor, constant: 16),
            attributesField.trailingAnchor.constraint(equalTo: formStack.trailingAnchor, constant: -16),

            structuresLabel.topAnchor.constraint(equalTo: attributesField.bottomAnchor, constant: 16),
            structuresLabel.leadingAnchor.constraint(equalTo: formStack.leadingAnchor, constant: 16),
            structuresLabel.trailingAnchor.constraint(equalTo: formStack.trailingAnchor, constant: -16),
            structuresScroll.topAnchor.constraint(equalTo: structuresLabel.bottomAnchor, constant: 4),
            structuresScroll.leadingAnchor.constraint(equalTo: formStack.leadingAnchor, constant: 16),
            structuresScroll.trailingAnchor.constraint(equalTo: formStack.trailingAnchor, constant: -16),
            structuresScroll.heightAnchor.constraint(equalToConstant: 100),

            errorLabel.topAnchor.constraint(equalTo: structuresScroll.bottomAnchor, constant: 12),
            errorLabel.leadingAnchor.constraint(equalTo: formStack.leadingAnchor, constant: 16),
            errorLabel.trailingAnchor.constraint(equalTo: formStack.trailingAnchor, constant: -16),

            compileButton.topAnchor.constraint(greaterThanOrEqualTo: errorLabel.bottomAnchor, constant: 16),
            compileButton.trailingAnchor.constraint(equalTo: formStack.trailingAnchor, constant: -16),
            compileButton.bottomAnchor.constraint(equalTo: formStack.bottomAnchor, constant: -16),
            cancelButton.centerYAnchor.constraint(equalTo: compileButton.centerYAnchor),
            cancelButton.trailingAnchor.constraint(equalTo: compileButton.leadingAnchor, constant: -8),
        ])
    }

    private func buildProgressStack() {
        let title = NSTextField(labelWithString: "Compiling\u{2026}")
        title.font = .boldSystemFont(ofSize: 13)

        progressIndicator.style = .bar
        progressIndicator.isIndeterminate = true
        progressIndicator.startAnimation(nil)

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor

        disclosureButton.bezelStyle = .inline
        disclosureButton.target = self
        disclosureButton.action = #selector(toggleLogVisibility)

        progressLog.isEditable = false
        progressLog.isRichText = false
        progressLog.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        Self.configureForScrolling(progressLog)
        logScroll.documentView = progressLog
        logScroll.hasVerticalScroller = true
        logScroll.borderType = .bezelBorder
        logScroll.clipsToBounds = true

        // Cmd-. is the standard macOS "stop this operation" key equivalent
        // (distinct from Escape, which the form's own Cancel uses) - the
        // import must be trivially killable, found the hard way when a
        // stuck run couldn't be quit normally and had to be force-killed
        // from Xcode.
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelImportTapped))
        cancelButton.keyEquivalent = "."
        cancelButton.keyEquivalentModifierMask = [.command]

        pauseButton.target = self
        pauseButton.action = #selector(pauseResumeTapped)

        let views: [NSView] = [
            title, progressIndicator, statusLabel, disclosureButton, logScroll, pauseButton, cancelButton,
        ]
        for v in views {
            v.translatesAutoresizingMaskIntoConstraints = false
            progressStack.addSubview(v)
        }
        logHeightConstraint = logScroll.heightAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: progressStack.topAnchor, constant: 16),
            title.leadingAnchor.constraint(equalTo: progressStack.leadingAnchor, constant: 16),

            progressIndicator.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 16),
            progressIndicator.leadingAnchor.constraint(equalTo: progressStack.leadingAnchor, constant: 16),
            progressIndicator.trailingAnchor.constraint(equalTo: progressStack.trailingAnchor, constant: -16),

            statusLabel.topAnchor.constraint(equalTo: progressIndicator.bottomAnchor, constant: 6),
            statusLabel.leadingAnchor.constraint(equalTo: progressStack.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(equalTo: progressStack.trailingAnchor, constant: -16),

            disclosureButton.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 10),
            disclosureButton.leadingAnchor.constraint(equalTo: progressStack.leadingAnchor, constant: 16),

            logScroll.topAnchor.constraint(equalTo: disclosureButton.bottomAnchor, constant: 6),
            logScroll.leadingAnchor.constraint(equalTo: progressStack.leadingAnchor, constant: 16),
            logScroll.trailingAnchor.constraint(equalTo: progressStack.trailingAnchor, constant: -16),
            logHeightConstraint,

            // Pinned relative to logScroll's own bottom (not progressStack's
            // fixed bottom edge) so the buttons sit right below the content
            // in both the collapsed and expanded states - any leftover
            // space in the sheet's fixed size falls below the buttons, not
            // in a dead gap between them and the log.
            pauseButton.topAnchor.constraint(equalTo: logScroll.bottomAnchor, constant: 16),
            pauseButton.trailingAnchor.constraint(equalTo: cancelButton.leadingAnchor, constant: -8),

            cancelButton.centerYAnchor.constraint(equalTo: pauseButton.centerYAnchor),
            cancelButton.trailingAnchor.constraint(equalTo: progressStack.trailingAnchor, constant: -16),
        ])
    }

    @objc private func toggleLogVisibility() {
        isLogExpanded.toggle()
        disclosureButton.title = isLogExpanded ? "Hide Log" : "Show Log"
        logHeightConstraint.constant = isLogExpanded ? Self.expandedLogHeight : 0
        // Animates the log area growing/shrinking within the sheet's fixed
        // size (see fixedContentSize's doc comment) - never the window
        // itself, on purpose.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.allowsImplicitAnimation = true
            view.layoutSubtreeIfNeeded()
        }
    }

    @objc private func pauseResumeTapped() {
        guard let importHandle else { return }
        isPaused.toggle()
        // flushProgress() (on the same timer as everything else) folds
        // isPaused into the status text itself on its next tick - not done
        // here, so it can't be immediately clobbered by that same timer.
        if isPaused {
            importHandle.pause()
            pauseButton.title = "Resume"
        } else {
            importHandle.resume()
            pauseButton.title = "Pause"
        }
    }

    /// Standard Apple-documented setup for an `NSTextView` hosted in an
    /// `NSScrollView` when created programmatically rather than via a
    /// convenience initializer - without `widthTracksTextView`, long
    /// unwrapped lines (e.g. real absolute file paths in `encodevert`'s
    /// output) make the text view grow arbitrarily wide/tall instead of
    /// wrapping, which doesn't stay properly clipped to its scroll view and
    /// was found to drag the whole sheet's layout along with it on a real,
    /// long-running import - this is the likely actual root cause of that,
    /// not just defensive hardening.
    private static func configureForScrolling(_ textView: NSTextView) {
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
    }

    private func parseStructures() -> [(name: String, attributes: [String])] {
        structuresView.string
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { rawLine -> (String, [String])? in
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty else { return nil }
                guard let colon = line.firstIndex(of: ":") else { return (line, []) }
                let name = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
                let attributes = line[line.index(after: colon)...]
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                return name.isEmpty ? nil : (name, attributes)
            }
    }

    @objc private func compileTapped() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else {
            errorLabel.stringValue = "Give the corpus a name."
            errorLabel.isHidden = false
            return
        }
        let attributes = attributesField.stringValue
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let structures = parseStructures()

        showProgress()
        ActiveImportTracker.shared.setImporting(true)
        progressLog.string = ""
        statusLabel.stringValue = "Counting lines\u{2026}"
        progressIndicator.isIndeterminate = true
        progressIndicator.startAnimation(nil)
        totalLines = nil
        importHandle = nil
        isPaused = false
        pauseButton.title = "Pause"
        pauseButton.isEnabled = false
        logFlushTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.flushProgress()
        }

        // CorpusImporter.importCorpus blocks its calling thread for the
        // whole compile (it calls Process.waitUntilExit() synchronously -
        // see its own doc comment) - Task.detached, not a plain/@MainActor
        // Task, keeps that off the UI thread.
        importTask = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            do {
                let total = try await CorpusImporter.countLines(verticalFile: verticalFile)
                await MainActor.run {
                    self.totalLines = total
                    self.progressIndicator.isIndeterminate = false
                    self.progressIndicator.maxValue = Double(total)
                    self.statusLabel.stringValue = "Starting\u{2026}"
                }
                try await CorpusImporter.importCorpus(
                    name: name, verticalFile: verticalFile, attributes: attributes, structures: structures,
                    // Only buffers - see LogBuffer/flushProgress. encodevert's
                    // output rate is unbounded (found via a real ~162M-line
                    // corpus import, where something going wrong partway
                    // through made it spew output far faster than
                    // once-per-chunk UI updates could keep up with, visibly
                    // corrupting the text view's rendering rather than just
                    // lagging) - hopping to the main actor per chunk here,
                    // like this used to, doesn't degrade gracefully under
                    // that kind of flood.
                    onProgress: { [weak self] text in self?.logBuffer.append(text) },
                    onStart: { [weak self] handle in
                        Task { @MainActor in
                            self?.importHandle = handle
                            self?.pauseButton.isEnabled = true
                        }
                    })
                await MainActor.run {
                    self.finishImport()
                    self.onImported?()
                    self.dismiss(self)
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.finishImport()
                    self.dismiss(self)
                }
            } catch {
                await MainActor.run {
                    self.finishImport()
                    self.showForm()
                    let message = "\(error)"
                    self.errorLabel.stringValue = message.count > 4000
                        ? "…" + message.suffix(4000) : message
                    self.errorLabel.isHidden = false
                }
            }
        }
    }

    /// Stops the flush timer and drains anything still buffered - every
    /// completion path (success, cancel, error) needs this so the log
    /// doesn't silently drop whatever arrived in the last < 0.2s.
    private func finishImport() {
        ActiveImportTracker.shared.setImporting(false)
        logFlushTimer?.invalidate()
        logFlushTimer = nil
        pauseButton.isEnabled = false
        flushProgress()
    }

    private func flushProgress() {
        let (pending, linesProcessed) = logBuffer.drain()
        if !pending.isEmpty {
            progressLog.string += pending
            // Bounds what's actually rendered, independent of how much
            // output arrived - CorpusImporter's own OutputCollector still
            // captures the full text for the eventual error message; this
            // is only about keeping the live view itself from becoming
            // enormous and slow (or worse - see LogBuffer's doc comment) to
            // lay out.
            if progressLog.string.count > Self.maxDisplayedLogLength {
                progressLog.string = String(progressLog.string.suffix(Self.maxDisplayedLogLength))
            }
            progressLog.scrollToEndOfDocument(nil)
        }
        guard let linesProcessed, let totalLines, totalLines > 0 else { return }
        progressIndicator.doubleValue = Double(min(linesProcessed, totalLines))
        let percent = min(100, Int((Double(linesProcessed) / Double(totalLines)) * 100))
        let format = NumberFormatter()
        format.numberStyle = .decimal
        let processedText = format.string(from: NSNumber(value: linesProcessed)) ?? "\(linesProcessed)"
        let totalText = format.string(from: NSNumber(value: totalLines)) ?? "\(totalLines)"
        statusLabel.stringValue = "\(processedText) / \(totalText) lines (\(percent)%)"
            + (isPaused ? " \u{2014} paused" : "")
    }

    @objc private func cancelImportTapped() {
        importTask?.cancel()
    }

    @objc private func cancelTapped() {
        dismiss(self)
    }
}
