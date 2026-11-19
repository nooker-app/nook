import Foundation

enum RecommendationContentText {
    static func title(_ text:String) -> String {
        var value=text
        for pattern in ["(?i)^(?:show (?:hn|gn)|ask (?:hn|gn)|tell hn|beta|tool|sponsor)\\s*:\\s*","(?i)^(?:introducing|announcing)\\s+","(?i)^(?:i|we) (?:built|made|created|developed|launched)\\s+(?:a |an )?"] {
            value=value.replacingOccurrences(of:pattern,with:"",options:.regularExpression)
        }
        return value.trimmingCharacters(in:.whitespacesAndNewlines)
    }
    static func clean(_ text:String) -> String {
        var value=text
        for pattern in ["(?is)originally handwritten and published.*$","(?is)submitted by /u/.*$","(?is)\\[link\\]\\s*\\[(?:comments|댓글)\\].*$","(?i)^(?:hi|hey|hello) (?:everyone|folks|r/rss)[!, .—–-]*"] {
            value=value.replacingOccurrences(of:pattern,with:"",options:.regularExpression)
        }
        return value.trimmingCharacters(in:.whitespacesAndNewlines)
    }
    static func duplicateKey(_ article:Article) -> String {
        title(article.title).lowercased()+"\n"+clean(article.summary).lowercased()
    }
    static func embeddingInput(_ article:Article) -> String {
        article.title+"\n"+String(article.summary.prefix(500))+"\n"+String(article.bodyParagraphs.joined(separator:" ").prefix(900))
    }
    static func rerankingInput(_ article:Article) -> String {
        let body=article.bodyParagraphs.joined(separator:" ")
        let extra = !body.isEmpty && !body.hasPrefix(String(article.summary.prefix(60))) ? String(body.prefix(500)) : ""
        return article.title+"\n"+String(article.summary.prefix(500))+"\n"+extra
    }
}
