import Testing

@testable import NookKit

/// The reported bug, and the rules that keep it fixed.
///
/// The address field auto-filled exactly one character and then froze. Setting "the
/// writer has edited this" from the field's own change handler meant the title's
/// handler tripped it: writing the derived value looked like a person typing, so one
/// character into the title the field decided it had been taken over.
@Suite("Nook Plus address field")
struct PlusSlugFieldTests {
    /// Types a title one character at a time, as a person does. The original bug is
    /// invisible to a test that assigns the whole title at once.
    private func typing(_ title: String, into field: inout PlusSlugField) {
        var sofar = ""
        for character in title {
            sofar.append(character)
            field.titleChanged(to: sofar)
            // The view mirrors every write back through the field's own handler,
            // which is exactly how the loop arose.
            field.changed(to: field.value)
        }
    }

    @Test("the address follows a title typed one character at a time")
    func followsTyping() {
        var field = PlusSlugField()
        typing("My First Post", into: &field)

        #expect(field.value == "my-first-post")
        #expect(field.isPinned == false)
    }

    @Test("the address keeps following after many keystrokes")
    func keepsFollowing() {
        var field = PlusSlugField()
        typing("Hello", into: &field)
        #expect(field.value == "hello")

        typing(" there", into: &field)
        #expect(field.value.hasPrefix("hello") || field.value == "there")
    }

    /// The other half: once the writer changes the address, the title must stop
    /// overwriting it. Their edit is not something to discard on the next keystroke.
    @Test("an edit pins the address, and the title stops driving it")
    func editPins() {
        var field = PlusSlugField()
        field.titleChanged(to: "My First Post")
        #expect(field.value == "my-first-post")

        field.changed(to: "custom-address")
        #expect(field.isPinned)

        field.titleChanged(to: "A Completely Different Title")
        #expect(field.value == "custom-address")
    }

    /// Clearing the address by hand is an edit too. It must not spring back to the
    /// derived value on the next character of the title.
    @Test("clearing the address by hand pins it empty")
    func clearingPins() {
        var field = PlusSlugField()
        field.titleChanged(to: "My Post")
        field.changed(to: "")

        #expect(field.isPinned)
        field.titleChanged(to: "My Post Again")
        #expect(field.value == "")
    }

    /// An edit that happens to equal the derived value is indistinguishable from
    /// this type's own write, and is treated as one. The cost is that retyping the
    /// suggestion by hand leaves the field following; nothing about the address is
    /// wrong, and no other rule can tell the two apart.
    @Test("an edit equal to the derived value leaves the field following")
    func editMatchingDerivedIsNotAnEdit() {
        var field = PlusSlugField()
        field.titleChanged(to: "My Post")
        field.changed(to: "my-post")

        #expect(field.isPinned == false)
        field.titleChanged(to: "Another Title")
        #expect(field.value == "another-title")
    }

    /// The reported case: a Korean title derives nothing, and without a fallback the
    /// field sat empty while publishing stayed blocked on a value the writer had no
    /// way to guess.
    @Test("a title in another script falls back to a usable address")
    func otherScriptsUseTheFallback() {
        var field = PlusSlugField(fallback: "2026-07-30")
        typing("반가워요", into: &field)

        #expect(field.value == "2026-07-30")
        #expect(field.problem == nil)
        #expect(field.isPinned == false)
    }

    /// Adding ASCII to the title takes over from the fallback, and removing it again
    /// goes back.
    @Test("the fallback yields to a title that can be derived from")
    func fallbackYields() {
        var field = PlusSlugField(fallback: "2026-07-30")
        field.titleChanged(to: "반가워요")
        #expect(field.value == "2026-07-30")

        field.titleChanged(to: "반가워요 Hello")
        #expect(field.value == "hello")

        field.titleChanged(to: "반가워요")
        #expect(field.value == "2026-07-30")
    }

    /// An edited address is validated, and the reason is available to show. Silently
    /// accepting it meant publishing failed afterwards with nothing to point at.
    @Test("an edited address reports what is wrong with it")
    func editedAddressIsValidated() {
        var field = PlusSlugField(fallback: "2026-07-30")
        field.titleChanged(to: "My Post")
        #expect(field.problem == nil)

        field.changed(to: "반가워요")
        #expect(field.problem == .unsupportedCharacters)

        field.changed(to: "fine-again")
        #expect(field.problem == nil)
    }

    /// A way back after an edit, so a writer who changed their mind does not have to
    /// retype what the title already suggests.
    @Test("the suggestion can be taken back up")
    func suggestionCanBeRestored() {
        var field = PlusSlugField(fallback: "2026-07-30")
        field.titleChanged(to: "My Post")
        field.changed(to: "something-else")
        #expect(field.isPinned)
        #expect(field.suggestion == "my-post")

        field.useSuggestion()
        #expect(field.value == "my-post")
        #expect(field.isPinned == false)

        field.titleChanged(to: "A New Title")
        #expect(field.value == "a-new-title")
    }

    @Test("resetting returns to following the title and keeps the fallback")
    func reset() {
        var field = PlusSlugField(fallback: "2026-07-30")
        field.titleChanged(to: "My Post")
        field.changed(to: "pinned")
        #expect(field.isPinned)

        field.reset()
        #expect(field.value == "")
        #expect(field.isPinned == false)
        // The fallback belongs to the account, not to one draft.
        #expect(field.fallback == "2026-07-30")

        field.titleChanged(to: "New Post")
        #expect(field.value == "new-post")
    }
}
