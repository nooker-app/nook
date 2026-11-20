#if os(macOS)
/// Presentation follows completed batches, never an estimated timer. The final
/// graph layout has no measurable fraction and stays indeterminate.
struct RecommendationMapPreparation: Equatable, Sendable {
    enum Phase: Equatable, Sendable { case idle, preparing, analyzing, connecting, ready }
    private(set) var phase: Phase = .idle
    private(set) var completed = 0
    private(set) var total = 0

    var isWorking: Bool { phase == .preparing || phase == .analyzing || phase == .connecting }
    var fraction: Double { total > 0 ? Double(completed) / Double(total) : 0 }

    mutating func begin() { self = Self(); phase = .preparing }

    mutating func update(completed: Int, total: Int) {
        guard isWorking, total >= 0 else { return }
        self.total = total
        self.completed = min(total, max(self.completed, completed))
        phase = self.completed == total ? .connecting : .analyzing
    }

    mutating func finish() { phase = .ready }
    mutating func reset() { self = Self() }
}
#endif
