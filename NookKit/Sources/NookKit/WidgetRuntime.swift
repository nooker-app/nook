import Foundation
#if os(macOS)
import MachO
#endif

/// WidgetKit may keep an extension alive across replacement of its app bundle.
/// Never archive a view using old machine code with the new bundle's resources.
public enum NookWidgetRuntime {
    public static func needsTimelineReload(build: String, lastReloadedBuild: String?) -> Bool {
        !build.isEmpty && build != lastReloadedBuild
    }

    public static func executableWasReplaced() -> Bool {
        #if os(macOS)
        guard let header = _dyld_get_image_header(0), header.pointee.magic == MH_MAGIC_64,
              let url = Bundle.main.executableURL,
              let file = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? file.close() }
        let size = Int(header.pointee.sizeofcmds)
        guard size <= 1_048_576 else { return false }
        let loaded = Data(bytes: header, count: MemoryLayout<mach_header_64>.size + size)
        do {
            let prefix = try file.read(upToCount: 4096) ?? Data()
            guard let offset = sliceOffset(in: prefix, cpu: UInt32(bitPattern: header.pointee.cputype),
                                           subtype: UInt32(bitPattern: header.pointee.cpusubtype)) else { return false }
            try file.seek(toOffset: offset)
            guard let head = try file.read(upToCount: 32), head.count == 32,
                  let commands = word(head, 20), commands <= 1_048_576,
                  let body = try file.read(upToCount: Int(commands)), body.count == Int(commands),
                  let installedID = uuid(in: head + body), let loadedID = uuid(in: loaded) else { return false }
            return installedID != loadedID
        } catch { return false }
        #else
        return false
        #endif
    }

    /// Accept the native 64-bit slice only; a missing/unreadable identity never
    /// causes an exit. Reads are bounded and work inside the extension sandbox.
    static func uuid(in data: Data) -> Data? {
        guard word(data, 0) == 0xfeedfacf, let count = word(data, 16),
              let bytes = word(data, 20), bytes <= 1_048_576,
              data.count >= 32 + Int(bytes), count <= bytes / 8 else { return nil }
        var offset = 32
        let end = 32 + Int(bytes)
        for _ in 0..<count {
            guard offset + 8 <= end, let command = word(data, offset),
                  let size = word(data, offset + 4), size >= 8,
                  Int(size) <= end - offset else { return nil }
            if command == 0x1b {
                guard size == 24 else { return nil }
                return data.subdata(in: (offset + 8)..<(offset + 24))
            }
            offset += Int(size)
        }
        return nil
    }

    static func sliceOffset(in data: Data, cpu: UInt32, subtype: UInt32) -> UInt64? {
        guard let magic = word(data, 0) else { return nil }
        if magic == 0xfeedfacf {
            return word(data, 4) == cpu && word(data, 8) == subtype ? 0 : nil
        }
        // Universal Mach-O tables are big-endian, with 32- or 64-bit offsets.
        guard magic == 0xbebafeca || magic == 0xbfbafeca,
              let rawCount = word(data, 4) else { return nil }
        let count = Int(rawCount.bigEndian)
        let stride = magic == 0xbfbafeca ? 32 : 20
        guard count <= 64, data.count >= 8 + count * stride else { return nil }
        for index in 0..<count {
            let base = 8 + index * stride
            guard let type = word(data, base), let sub = word(data, base + 4),
                  type.bigEndian == cpu, sub.bigEndian == subtype else { continue }
            if stride == 32 {
                return data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: base + 8, as: UInt64.self).bigEndian }
            }
            return word(data, base + 8).map { UInt64($0.bigEndian) }
        }
        return nil
    }

    private static func word(_ data: Data, _ offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        return data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian }
    }
}
