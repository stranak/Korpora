// swift-tools-version:5.9
import PackageDescription
import Foundation

// Resolve the sibling `manatee-open` checkout relative to this package, so
// nothing here is tied to this specific machine's absolute paths.
let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let manateeRoot = packageRoot.deletingLastPathComponent()
    .appendingPathComponent("manatee-open").path

// The manifest evaluator's PATH doesn't reliably include Homebrew's bin dir,
// so search the common prefixes (Apple Silicon and Intel) before falling
// back to plain PATH lookup via /usr/bin/env.
func findPkgConfig() -> String {
    for candidate in ["/opt/homebrew/bin/pkg-config", "/usr/local/bin/pkg-config"] {
        if FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
    }
    return "pkg-config"
}

func pkgConfig(_ args: String...) -> [String] {
    let exe = findPkgConfig()
    let p = Process()
    if exe == "pkg-config" {
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["pkg-config"] + args
    } else {
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
    }
    let pipe = Pipe()
    p.standardOutput = pipe
    do {
        try p.run()
    } catch {
        FileHandle.standardError.write("warning: pkg-config invocation failed: \(error)\n".data(using: .utf8)!)
        return []
    }
    p.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let out = String(data: data, encoding: .utf8) ?? ""
    if p.terminationStatus != 0 {
        FileHandle.standardError.write("warning: pkg-config \(args) exited \(p.terminationStatus)\n".data(using: .utf8)!)
    }
    return out.split(whereSeparator: { $0 == " " || $0.isNewline })
        .map(String.init).filter { !$0.isEmpty }
}

let pcre2CFlags = pkgConfig("--cflags", "libpcre2-8")
let pcre2LibFlags = pkgConfig("--libs", "libpcre2-8")

let manateeIncludeDirs: [String] = [
    manateeRoot,
    "\(manateeRoot)/corp",
    "\(manateeRoot)/finlib",
    "\(manateeRoot)/fsa3",
    "\(manateeRoot)/hat-trie",
    "\(manateeRoot)/concord",
    "\(manateeRoot)/query",
]

// Built up statement by statement, with explicit types and no chained `+`
// on array literals, rather than inline in the `.unsafeFlags(...)` calls
// below.
//
// That isn't style: as one expression each (`["-DHAVE_CONFIG_H"] +
// manateeIncludeDirs.flatMap { ["-I", $0] } + pcre2CFlags`) nested inside
// the big `Package(...)` literal, they gave the type checker enough
// overload combinations to blow its budget - "the compiler is unable to
// type-check this expression in reasonable time", reported against
// `Package(` itself, which points nowhere near the actual cause. It
// happened to stay under the limit on some toolchains and not others, so
// the manifest built for some people and not others (reported 2026-09-09).
// Keep these as separate statements.

var cManateeCxxFlags: [String] = ["-DHAVE_CONFIG_H"]
for includeDir in manateeIncludeDirs {
    cManateeCxxFlags.append("-I")
    cManateeCxxFlags.append(includeDir)
}
cManateeCxxFlags.append(contentsOf: pcre2CFlags)

var cManateeLinkerFlags: [String] = ["-L\(manateeRoot)/src/.libs", "-lbuiltinmanatee"]
cManateeLinkerFlags.append(contentsOf: pcre2LibFlags)
cManateeLinkerFlags.append(contentsOf: ["-liconv", "-ldl"])

let package = Package(
    name: "ManateeKit",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ManateeKit", targets: ["ManateeKit"]),
        .executable(name: "manateekit-cli", targets: ["manateekit-cli"]),
    ],
    targets: [
        .target(
            name: "CManatee",
            cxxSettings: [.unsafeFlags(cManateeCxxFlags)],
            linkerSettings: [.unsafeFlags(cManateeLinkerFlags)]
        ),
        .target(
            name: "ManateeKit",
            dependencies: ["CManatee"]
        ),
        .executableTarget(
            name: "manateekit-cli",
            dependencies: ["ManateeKit"]
        ),
        .testTarget(
            name: "ManateeKitTests",
            dependencies: ["ManateeKit"]
        ),
    ],
    cxxLanguageStandard: .cxx14
)
