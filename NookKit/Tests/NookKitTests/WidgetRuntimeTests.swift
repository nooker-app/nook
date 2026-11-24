import Foundation
import Testing
@testable import NookKit

@Suite("Widget update recovery")
struct WidgetRuntimeTests {
    @Test("An update reloads even unchanged content, once per build")
    func reload() {
        #expect(NookWidgetRuntime.needsTimelineReload(build: "0.1.76/80", lastReloadedBuild: "0.1.75/79"))
        #expect(NookWidgetRuntime.needsTimelineReload(build: "0.1.76/80", lastReloadedBuild: nil))
        #expect(!NookWidgetRuntime.needsTimelineReload(build: "0.1.76/80", lastReloadedBuild: "0.1.76/80"))
        #expect(!NookWidgetRuntime.needsTimelineReload(build: "", lastReloadedBuild: nil))
    }

    @Test("Native Mach-O identities reject incomplete commands and malformed binaries")
    func identity() {
        func data(_ words: [UInt32]) -> Data {
            words.reduce(into: Data()) { result, word in
                var value = word.littleEndian
                withUnsafeBytes(of: &value) { result.append(contentsOf: $0) }
            }
        }
        let uuid = Data(0..<16)
        let header: [UInt32] = [0xfeedfacf, 0x0100000c, 0, 2, 1, 24, 0, 0]
        let valid = data(header + [0x1b, 24]) + uuid
        #expect(NookWidgetRuntime.uuid(in: valid) == uuid)
        #expect(NookWidgetRuntime.uuid(in: valid.dropLast()) == nil)
        #expect(NookWidgetRuntime.uuid(in: data(header + [0x1b, 0]) + uuid) == nil)
        #expect(NookWidgetRuntime.sliceOffset(in: valid, cpu: 0x0100000c, subtype: 0) == 0)
        #expect(NookWidgetRuntime.sliceOffset(in: valid, cpu: 0x01000007, subtype: 3) == nil)
        let fat32: [UInt32] = [0xcafebabe, 2, 0x01000007, 3, 4096, 100, 0, 0x0100000c, 0, 8192, 100, 0]
        #expect(NookWidgetRuntime.sliceOffset(in: data(fat32.map(\.bigEndian)), cpu: 0x0100000c, subtype: 0) == 8192)
        let fat64: [UInt32] = [0xcafebabf, 1, 0x0100000c, 0, 0, 8192, 0, 100, 0, 0]
        #expect(NookWidgetRuntime.sliceOffset(in: data(fat64.map(\.bigEndian)), cpu: 0x0100000c, subtype: 0) == 8192)
        #expect(NookWidgetRuntime.sliceOffset(in: data([0xbebafeca, .max]), cpu: 0x0100000c, subtype: 0) == nil)
    }
}
