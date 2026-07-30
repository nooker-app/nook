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

    /// A title with no ASCII derives nothing, and the field is left empty rather
    /// than holding a stale address from an earlier title.
    @Test("a title in another script leaves the address empty")
    func otherScripts() {
        var field = PlusSlugField()
        typing("반가워요", into: &field)
        #expect(field.value == "")
        #expect(field.isPinned == false)
    }

    @Test("resetting returns to following the title")
    func reset() {
        var field = PlusSlugField()
        field.titleChanged(to: "My Post")
        field.changed(to: "pinned")
        #expect(field.isPinned)

        field.reset()
        #expect(field.value == "")
        #expect(field.isPinned == false)

        field.titleChanged(to: "New Post")
        #expect(field.value == "new-post")
    }
}
