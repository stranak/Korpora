import Darwin
import Foundation

/// Best-effort "keep this compiled corpus warm in the OS page cache" support.
/// Deliberately has **no** dependency on CManatee/manatee-open - warming
/// works by touching whatever files sit under a compiled corpus's data
/// directory (see `CompiledCorpusStore.dataDirectory`), independent of
/// Manatee's own separate `mmap` of those same files at query time (both are
/// `MAP_SHARED`, so they end up sharing the same underlying page-cache pages
/// - no engine change needed).
///
/// This is explicitly *not* true `mlock` - no special entitlements, always
/// safe/reversible, no risk of starving the system if a free-memory estimate
/// is ever off. It's a hint, not a guarantee: under real memory pressure the
/// OS can still evict these pages. A stricter `mlock`-based mode is a
/// possible future addition (see docs/project-plan.md) but isn't built here.
public enum CorpusMemoryResidency {
    public static var totalMemory: UInt64 {
        ProcessInfo.processInfo.physicalMemory
    }

    /// "Reclaimable" memory - free, inactive, and purgeable pages - the same
    /// notion Activity Monitor's memory gauge uses for "available", not just
    /// strictly-unused pages.
    public static func availableMemory() -> UInt64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let pageSize = UInt64(vm_kernel_page_size)
        let reclaimablePages = UInt64(stats.free_count) + UInt64(stats.inactive_count) + UInt64(stats.purgeable_count)
        return reclaimablePages * pageSize
    }

    /// Total size of every file under `url`, recursively.
    public static func directorySize(_ url: URL) -> UInt64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey], options: []) else { return 0 }
        var total: UInt64 = 0
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += UInt64(size)
            }
        }
        return total
    }

    /// Pure arithmetic, factored out from `availableMemory()` so it's
    /// testable without mocking `host_statistics64` - true when warming a
    /// corpus of `sizeBytes` would still leave at least `minimumFreeAfter`
    /// bytes free, given `currentlyAvailable` bytes right now.
    public static func canKeepResident(sizeBytes: UInt64, currentlyAvailable: UInt64, minimumFreeAfter: UInt64) -> Bool {
        currentlyAvailable >= sizeBytes + minimumFreeAfter
    }

    /// Walks every file under `directory`, `mmap`s it, and hints the kernel
    /// to pull it into the page cache (`MADV_WILLNEED`) - cooperatively
    /// cancellable between files. Blocks the calling thread while resident
    /// I/O happens for a given file's `madvise` call to take effect; callers
    /// should run this from a background task, not on the main actor.
    public static func warm(directory: URL) async throws {
        for file in try filesUnder(directory) {
            try Task.checkCancellation()
            adviseFile(at: file, advice: MADV_WILLNEED)
        }
    }

    /// The considerate counterpart to `warm(directory:)` - hints the kernel
    /// it can drop these pages, so turning "Keep in Memory" off actually
    /// does something rather than waiting on unrelated eviction pressure.
    public static func unwarm(directory: URL) {
        guard let files = try? filesUnder(directory) else { return }
        for file in files {
            adviseFile(at: file, advice: MADV_DONTNEED)
        }
    }

    private static func filesUnder(_ directory: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: []) else { return [] }
        var files: [URL] = []
        for case let url as URL in enumerator {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                files.append(url)
            }
        }
        return files
    }

    private static func adviseFile(at url: URL, advice: Int32) {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return }
        defer { close(fd) }
        let size = lseek(fd, 0, SEEK_END)
        guard size > 0 else { return }
        guard let mapped = mmap(nil, Int(size), PROT_READ, MAP_SHARED, fd, 0), mapped != MAP_FAILED else { return }
        madvise(mapped, Int(size), advice)
        munmap(mapped, Int(size))
    }
}
