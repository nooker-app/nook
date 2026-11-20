#if os(macOS)
import SwiftUI

struct RecommendationMapIntroduction: View {
    let onDetails: () -> Void
    let onLater: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(String(localized: "Your map can go a little deeper", bundle: .module), systemImage: "point.3.connected.trianglepath.dotted")
                .font(.headline).foregroundStyle(NookTheme.accent)
            Text("These connections use the words in your articles. Add local models to discover related ideas across different expressions and languages.", bundle: .module)
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            Text("Optional download · \(RecommendationModelManifest.totalBytes, format: .byteCount(style: .decimal)) · runs on this Mac", bundle: .module)
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(String(localized: "Review models", bundle: .module), action: onDetails)
                    .buttonStyle(MagazineGlassButtonStyle())
                Button(String(localized: "Later", bundle: .module), action: onLater)
                    .buttonStyle(MagazinePlainButtonStyle(capsule: true))
            }
        }
        .padding(18).glassEffect(.regular, in: .rect(cornerRadius: 20))
    }
}
#endif
