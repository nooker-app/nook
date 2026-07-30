import Foundation

/// The web address as the writer types, following the title until they take it
/// over.
///
/// A separate type because the rule is easy to get subtly wrong and impossible to
/// test inside a view. The first attempt set "the writer has edited this" from the
/// address field's change handler, which the title's own handler triggers by
/// writing the derived value: one character into the title, the field decided it had
/// been edited by hand and stopped following. The address stayed one letter long
/// forever.
///
/// The fix is to know which writes are ours. A change equal to what was last
/// derived is this type's own; anything else came from the writer.
struct PlusSlugField: Equatable, Sendable {
    /// Used when a title yields no address at all, which is every title written in
    /// a script with no ASCII in it. Without it a Korean title left the field empty
    /// and publishing was blocked on a value the writer had no way to guess.
    var fallback = ""

    /// What the address field shows.
    private(set) var value = ""
    /// True once the writer has changed it themselves, after which the title stops
    /// driving it. Their edit is not something to overwrite on the next keystroke.
    private(set) var isPinned = false

    /// The last value derived from a title, so a change matching it is recognised
    /// as this type's own rather than as an edit.
    private var lastDerived = ""

    init(fallback: String = "") {
        self.fallback = fallback
        value = ""
    }

    /// Follows a new title, unless the writer has taken the address over.
    mutating func titleChanged(to title: String) {
        let derived = PlusSlug.derive(from: title)
        // An empty derivation means the title had nothing usable in it, not that the
        // writer wants an empty address.
        let next = derived.isEmpty ? fallback : derived
        lastDerived = next
        guard !isPinned else { return }
        value = next
    }

    /// What the title would produce, whether or not the field is following it.
    /// Offered as a way back after an edit.
    var suggestion: String { lastDerived }

    /// Follows the title again, discarding an edit.
    mutating func useSuggestion() {
        isPinned = false
        value = lastDerived
    }

    /// Whether the current address is one the service will accept.
    var problem: PlusSlug.Problem? { PlusSlug.problem(with: value) }

    /// Records a change to the address field.
    ///
    /// Pins the address only when the new value is not the one just derived. This is
    /// what keeps `titleChanged` from being mistaken for a person typing.
    mutating func changed(to newValue: String) {
        let wasOurs = newValue == lastDerived
        value = newValue
        if !wasOurs {
            isPinned = true
        }
    }

    /// Back to following the title, for a fresh post. Keeps the fallback, which
    /// belongs to the account rather than to one draft.
    mutating func reset() {
        self = PlusSlugField(fallback: fallback)
    }
}
