import AppKit
import SwiftUI

extension Bundle { static var module: Bundle { .main } }
func recommendationTopicColor(_ topic: String) -> Color { Color(red: 0.43, green: 0.65, blue: 0.54) }
struct Article { var id: String; var title: String; var isRead = false }
struct RecommendationMapNode {
    var article: Article; var rank: Int; var topic = ""; var position: CGPoint
    var clusterID = ""; var clusterLabel = ""; var id: String { article.id }
}
struct RecommendationMapEdge: Codable { var a: String; var b: String }
struct RecommendationGraph { var nodes: [RecommendationMapNode] = []; var edges: [RecommendationMapEdge] = [] }
enum SmartSource { case all }
struct RecommendationMapFormation {
    var active = false; var layoutRevision = 0; var positions: [String: CGPoint] = [:]
    var analyzed = Set<String>(); var edges: [RecommendationMapEdge] = []
}
@MainActor @Observable final class RecommendationMapController {
    var isInteractive = true; var collection = SmartSource.all; var graphRevision = 0; var layoutRevision = 0
    var graph = RecommendationGraph(); var formation = RecommendationMapFormation(); var formationRevision = 0
    var selectedID: String?; var topic: String?; var focus = false
    func select(_ id: String) { selectedID = id }
    func openSelected() {}
}
struct DemoStory: Codable, Identifiable {
    var id: String; var title: String; var summary: String; var source: String; var url: String
    var x: Double; var y: Double; var cluster: String
}
struct DemoSnapshot: Codable { var nodes: [DemoStory]; var edges: [RecommendationMapEdge] }
enum DemoMaterial: Int, CaseIterable, Identifiable {
    case adaptive, lens, halo, original
    var id: Int { rawValue }
    var title: String { switch self { case .adaptive: "연결 기준"; case .lens: "앰버 렌즈"; case .halo: "라이트 헤일로"; case .original: "기존 도트" } }
    var caption: String {
        switch self {
        case .adaptive: "연결 없는 글은 앰버 렌즈,\n연결 있는 글은 라이트 헤일로로 보입니다."
        case .lens: "투명한 중심, 얇은 유리 가장자리.\nNook의 앰버가 아래쪽에 은은히 맺힙니다."
        case .halo: "작은 빛을 감싸는 가벼운 테두리.\n연결과 공간을 더 넓게 드러냅니다."
        case .original: "현재 앱의 불투명한 구체.\n같은 위치에서 차이를 비교해 보세요."
        }
    }
    var symbol: String { switch self { case .adaptive: "point.3.connected.trianglepath.dotted"; case .lens: "circle.lefthalf.filled"; case .halo: "circle.dotted.circle"; case .original: "circle.fill" } }
}

struct DemoOverviewSnapshot {
    var points: [CGPoint] = []
    var viewport = CGRect(x: 0, y: 0, width: 1, height: 1)
    var selected: CGPoint?
    var canGoBack = false
    var percent = 100
}
