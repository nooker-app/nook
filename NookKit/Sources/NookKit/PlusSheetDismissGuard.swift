import SwiftUI

/// What a sheet should do when somebody swipes it down.
///
/// A value rather than two lines inside a UIKit delegate, because the UIKit part
/// only compiles for iOS and the package's tests run on the host. The rule is the
/// part worth pinning: unsaved work must turn a swipe into a question, and a sheet
/// with nothing at stake must still close on the gesture.
enum SheetDismissDecision: Equatable {
    /// Let the gesture close the sheet.
    case dismiss
    /// Refuse the gesture and ask instead.
    case ask

    /// - Parameter hasUnsavedWork: whether closing would throw something away.
    static func forSwipe(hasUnsavedWork: Bool) -> SheetDismissDecision {
        hasUnsavedWork ? .ask : .dismiss
    }

    var allowsDismissal: Bool { self == .dismiss }
}

#if os(iOS)
    import UIKit

    /// Turns a swipe-down on a sheet into the same question the Cancel button asks.
    ///
    /// `interactiveDismissDisabled` alone blocks the gesture and says nothing: the
    /// sheet moves a little and springs back, with no hint that anything is being
    /// protected. Without it the sheet simply closes, and writing that was never saved
    /// is gone — which is what happened, because a composer's Cancel button already
    /// asked what to do with unsaved work and a swipe went around it.
    ///
    /// UIKit already distinguishes these: a presentation controller can refuse a
    /// dismissal *and* be told one was attempted. SwiftUI exposes only the refusal, so
    /// this reaches for the delegate to get the other half.
    ///
    /// iOS only. A Mac sheet has no dismiss gesture, so there is nothing to intercept
    /// and the composer's Cancel button is the only way out.
    struct SheetDismissGuard: UIViewControllerRepresentable {
        /// Whether leaving needs to be confirmed. False lets the gesture work normally.
        let isGuarded: Bool
        /// Called on the attempt, to ask whatever the Cancel button asks.
        let onAttempt: () -> Void

        func makeUIViewController(context: Context) -> UIViewController {
            Controller(coordinator: context.coordinator)
        }

        func updateUIViewController(_ controller: UIViewController, context: Context) {
            context.coordinator.isGuarded = isGuarded
            context.coordinator.onAttempt = onAttempt
            context.coordinator.apply(to: controller)
        }

        func makeCoordinator() -> Coordinator {
            Coordinator(isGuarded: isGuarded, onAttempt: onAttempt)
        }

        final class Coordinator: NSObject, UIAdaptivePresentationControllerDelegate {
            var isGuarded: Bool
            var onAttempt: () -> Void

            /// Held rather than made per attempt: a generator has to be prepared
            /// before it can fire without a delay, and a delayed tap does not read as
            /// a response to the gesture that caused it.
            private let bump = UIImpactFeedbackGenerator(style: .rigid)

            init(isGuarded: Bool, onAttempt: @escaping () -> Void) {
                self.isGuarded = isGuarded
                self.onAttempt = onAttempt
            }

            /// Claims the delegate and keeps the modal flag in step.
            ///
            /// Re-applied on every update rather than once: SwiftUI owns this
            /// presentation and sets both itself, so a view that claimed them at
            /// creation would quietly lose them again.
            func apply(to controller: UIViewController) {
                guard let presentation = controller.parentPresentationController else { return }
                if presentation.delegate !== self {
                    presentation.delegate = self
                }
                presentation.presentedViewController.isModalInPresentation = isGuarded
                // Warmed while the sheet is guarded, so the tap lands with the gesture
                // rather than a moment after it.
                if isGuarded { bump.prepare() }
            }

            func presentationControllerShouldDismiss(_: UIPresentationController) -> Bool {
                SheetDismissDecision.forSwipe(hasUnsavedWork: isGuarded).allowsDismissal
            }

            func presentationControllerDidAttemptToDismiss(_: UIPresentationController) {
                // Felt before it is read. The sheet springing back says something
                // stopped it, but not that the stop was deliberate; a firm tap at the
                // moment of refusal does, and it arrives before the dialog has drawn.
                //
                // .rigid rather than a warning: nothing has gone wrong. The sheet met
                // something solid, which is what the gesture needs to convey.
                bump.impactOccurred()
                onAttempt()
            }
        }

        /// An empty controller whose only job is to be inside the sheet, so the
        /// presentation controller can be found from it.
        private final class Controller: UIViewController {
            private let coordinator: Coordinator

            init(coordinator: Coordinator) {
                self.coordinator = coordinator
                super.init(nibName: nil, bundle: nil)
                view.isUserInteractionEnabled = false
            }

            @available(*, unavailable)
            required init?(coder: NSCoder) { fatalError("not used") }

            override func didMove(toParent parent: UIViewController?) {
                super.didMove(toParent: parent)
                coordinator.apply(to: self)
            }
        }
    }

    extension UIViewController {
        /// The presentation controller of the sheet this controller is inside.
        ///
        /// Walked upwards because the representable is nested several containers deep
        /// inside whatever SwiftUI built; the presentation belongs to the outermost
        /// controller, which is the one that was presented.
        fileprivate var parentPresentationController: UIPresentationController? {
            // The controller that was actually presented, which is the one holding the
            // sheet's presentation controller. Walking `parent` gets there because the
            // representable is added as a child several containers deep inside
            // whatever SwiftUI built for the sheet's content.
            var top: UIViewController = self
            while let parent = top.parent {
                top = parent
            }
            // Not `self.presentationController`: a child answers with the same object,
            // and setting the delegate from a child is fine, but the modal flag has to
            // go on the presented controller or UIKit ignores it.
            return top.presentationController
        }
    }

    extension View {
        /// Asks before a swipe can throw away unsaved work.
        ///
        /// Applied as a background so it adds nothing to the layout: the controller it
        /// installs exists only to find the sheet it is in.
        func confirmSheetDismissal(
            when isGuarded: Bool, onAttempt: @escaping () -> Void
        ) -> some View {
            background(
                // 1×1 and invisible rather than zero-sized: SwiftUI does not build a
                // representable that has been given no area, so a 0×0 frame meant the
                // controller was never created and the guard never installed.
                SheetDismissGuard(isGuarded: isGuarded, onAttempt: onAttempt)
                    .frame(width: 1, height: 1)
                    .opacity(0.01)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            )
        }
    }
#endif
