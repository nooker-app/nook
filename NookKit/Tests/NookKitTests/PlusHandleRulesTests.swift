import Testing

@testable import NookKit

/// These mirror `nook-plus/internal/handle`. A name this accepts and the service
/// rejects is the failure that matters: the screen previews a handle and a site
/// address, which reads as confirmation that the name works.
@Suite("Nook Plus handle rules")
struct PlusHandleRulesTests {
    @Test(
        "usable names",
        arguments: [
            "alice", "bob123", "a-b-c", "abc", "x1y", "eighteen-chars-abc",
        ])
    func accepts(_ label: String) {
        #expect(PlusHandleRules.problem(with: label) == nil, "\(label) should be usable")
    }

    /// The case the user hit: typing a Korean name previewed a handle and a site
    /// address, so nothing suggested it could not be submitted.
    @Test(
        "names in other scripts are refused, not previewed",
        arguments: ["대충", "테스트이름", "テスト", "测试名", "café", "Ámbar", "мойник"])
    func refusesOtherScripts(_ label: String) {
        #expect(PlusHandleRules.problem(with: label) == .unsupportedCharacters)
        #expect(PlusHandleRules.isUsable(label) == false)
    }

    @Test("the reason is specific enough to act on")
    func reasons() {
        #expect(PlusHandleRules.problem(with: "") == .empty)
        #expect(PlusHandleRules.problem(with: "ab") == .tooShort)
        #expect(PlusHandleRules.problem(with: "nineteen-chars-abcd") == .tooLong)
        #expect(PlusHandleRules.problem(with: "-abc") == .hyphenAtEdge)
        #expect(PlusHandleRules.problem(with: "abc-") == .hyphenAtEdge)
        #expect(PlusHandleRules.problem(with: "ab--cd") == .doubleHyphen)
        #expect(PlusHandleRules.problem(with: "123") == .digitsOnly)
        #expect(PlusHandleRules.problem(with: "admin") == .reserved)
    }

    /// Length is counted in UTF-8 bytes, as the service does, so a name cannot
    /// pass here and fail there on length alone.
    @Test("length is measured the way the service measures it")
    func lengthInBytes() {
        // Three characters, nine bytes: refused for its script, and its byte
        // length also exceeds nothing — the point is that it never reads as a
        // three-character name that happens to be fine.
        #expect(PlusHandleRules.problem(with: "가나다") == .unsupportedCharacters)
        #expect(PlusHandleRules.problem(with: String(repeating: "a", count: 18)) == nil)
        #expect(PlusHandleRules.problem(with: String(repeating: "a", count: 19)) == .tooLong)
    }

    @Test("case and surrounding space are normalised, as the service does")
    func normalisation() {
        #expect(PlusHandleRules.normalize("  Alice  ") == "alice")
        #expect(PlusHandleRules.problem(with: "  Alice  ") == nil)
        // Reserved names are compared after normalising, so capitals do not
        // slip one through.
        #expect(PlusHandleRules.problem(with: "Admin") == .reserved)
    }

    /// Every reason must have something to show. An empty message would leave
    /// the field with no explanation, which is the state this whole type exists
    /// to remove.
    @Test("every reason has a message")
    func messages() {
        let all: [PlusHandleRules.Problem] = [
            .empty, .tooShort, .tooLong, .unsupportedCharacters,
            .hyphenAtEdge, .doubleHyphen, .digitsOnly, .reserved,
        ]
        for problem in all {
            #expect(problem.message.isEmpty == false)
        }
    }
}
