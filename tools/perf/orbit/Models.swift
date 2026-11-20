import AppKit
import SwiftUI
extension Bundle { static var module: Bundle { .main } }
enum NookTheme { static let canvas = Color(red:0.10,green:0.085,blue:0.06);static let card=Color(red:0.15,green:0.13,blue:0.10);static let accent=Color(red:0.83,green:0.64,blue:0.39) }
func recommendationTopicColor(_ topic:String)->Color { NookTheme.accent }
struct Article { var id:String;var title:String;var isRead=false }
struct RecommendationMapNode {var article:Article;var rank:Int;var topic="AI";var position:CGPoint;var clusterID="";var clusterLabel="";var id:String {article.id}}
struct RecommendationMapEdge {var a:String;var b:String}
struct RecommendationGraph {var nodes:[RecommendationMapNode]=[];var edges:[RecommendationMapEdge]=[]}
enum SmartSource {case all}
struct RecommendationMapFormation {var active=false;var layoutRevision=0;var positions:[String:CGPoint]=[:];var analyzed=Set<String>();var edges:[RecommendationMapEdge]=[]}
@MainActor @Observable final class RecommendationMapController {
 var isInteractive=true;var collection=SmartSource.all;var graphRevision=0;var layoutRevision=0;var graph=RecommendationGraph();var formation=RecommendationMapFormation();var formationRevision=0;var selectedID:String?;var topic:String?;var focus=false
 func select(_ id:String) {selectedID=id};func openSelected() {}
}
