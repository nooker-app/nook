import Foundation

/// A page exactly as the service serves it, captured from a live publication.
///
/// A hand-written approximation is not the same thing: the failure this suite
/// exists for was in how the real markup and the real extractor met, and an
/// approximation had already been passing while the real page did not.
enum ReaderExtractionFixture {
    static let publishedArticle = """
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Hello nook — tim</title>
<link rel="canonical" href="https://staging.nooker.app/@tim/hellonook">
<link rel="alternate" type="application/rss+xml" title="tim" href="https://staging.nooker.app/@tim/feed.xml">
<link rel="alternate" type="application/atom+xml" title="tim" href="https://staging.nooker.app/@tim/atom.xml">

<meta name="author" content="tim.staging.nooker.app">
<meta property="article:published_time" content="2026-07-30T01:23:01Z">
<meta property="article:modified_time" content="0001-01-01T00:00:00Z">
<link rel="icon" href="https://staging.nooker.app/icon.png" type="image/png">
<link rel="apple-touch-icon" href="https://staging.nooker.app/icon.png">
<meta name="generator" content="nook-plus renderer 3">
<style>
/* The same palette and type as nooker.app, so a published page reads as part of
   Nook rather than as a generic default. Values are duplicated from the site
   rather than shared: this stylesheet is inlined into every published page and
   has to keep working with no external request, and a page rendered today must
   still render the same way years from now, which a link to a living stylesheet
   would not guarantee. */
:root {
  color-scheme: light dark;
  --fg: #241d14;
  --muted: #5c5044;
  --bg: #fbf5e5;
  --card: #fffdf6;
  --rule: #e0d6c1;
  --link: #8b5a2d;
}
@media (prefers-color-scheme: dark) {
  :root {
    --fg: #f0e9dc;
    --muted: #b3a692;
    --bg: #1b1710;
    --card: #29241b;
    --rule: #443c2e;
    --link: #d5a366;
  }
}
* { box-sizing: border-box; }
body { margin: 0 auto; padding: 2.75rem 1.25rem 5rem; max-width: 42rem; background: var(--bg); color: var(--fg);
  font: 17px/1.65 ui-serif, Georgia, "Times New Roman", serif; -webkit-text-size-adjust: 100%; }
a { color: var(--link); text-decoration-thickness: 1px; text-underline-offset: 2px; }
a:hover { text-decoration-thickness: 2px; }
header.site { padding-bottom: 1.25rem; margin-bottom: 2rem; border-bottom: 1px solid var(--rule); }
header.site a { color: var(--fg); text-decoration: none; }
h1 { font-size: 2.1rem; line-height: 1.2; letter-spacing: -0.02em; margin: 0 0 .6rem; }
h2 { font-size: 1.3rem; letter-spacing: -0.01em; margin: 2.5rem 0 .6rem; }
h3 { font-size: 1.05rem; margin: 1.75rem 0 .4rem; }
p, ul, ol, blockquote, pre, table { margin: 1.1rem 0; }
li { margin: .35rem 0; }
.muted, .summary { color: var(--muted); }
time { color: var(--muted); font-size: .9375rem; }
/* The title, byline, and summary sit in a header of their own, separated from the
   body by a rule rather than by a blank line — a bare date under a heading read
   as a stray paragraph. */
header.entry { margin-bottom: 1.75rem; padding-bottom: 1.25rem; border-bottom: 1px solid var(--rule); }
header.entry h1 { margin-bottom: .5rem; }
p.byline { margin: 0; color: var(--muted); font-size: .9375rem; }
p.byline time { font-size: inherit; }
header.entry p.summary { margin: .75rem 0 0; font-size: 1.05rem; }
.entry-body > :first-child { margin-top: 0; }
article ul.index { list-style: none; padding: 0; }
article ul.index li { padding: 1rem 0; border-top: 1px solid var(--rule); }
article ul.index li:last-child { border-bottom: 1px solid var(--rule); }
article ul.index a { font-size: 1.15rem; font-weight: 600; letter-spacing: -0.01em; text-decoration: none; }
article ul.index a:hover { text-decoration: underline; }
pre { overflow-x: auto; padding: .9rem 1rem; background: var(--card); border: 1px solid var(--rule); border-radius: 10px; }
code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: .9em;
  background: var(--card); border: 1px solid var(--rule); border-radius: 4px; padding: .05em .3em; }
pre code { font-size: .875rem; background: none; border: 0; padding: 0; }
table { width: 100%; border-collapse: collapse; display: block; overflow-x: auto; font-size: .95rem; }
th, td { text-align: left; padding: .55rem .6rem; border-bottom: 1px solid var(--rule); vertical-align: top; }
th { font-weight: 700; }
blockquote { margin-left: 0; padding-left: 1rem; border-left: 3px solid var(--rule); color: var(--muted); }
img { max-width: 100%; height: auto; border-radius: 8px; }
hr { border: 0; border-top: 1px solid var(--rule); margin: 2.5rem 0; }
footer.site { margin-top: 4rem; padding-top: 1.25rem; border-top: 1px solid var(--rule);
  color: var(--muted); font-size: .9rem; }
</style>
</head>
<body>
<header class="site"><a href="https://staging.nooker.app/@tim">tim</a></header>
<article itemscope itemtype="https://schema.org/Article">
<header class="entry">
<h1 itemprop="headline">Hello nook</h1>
<p class="byline">
<span itemprop="author" itemscope itemtype="https://schema.org/Person"><span itemprop="name">tim.staging.nooker.app</span></span> · <time itemprop="datePublished" datetime="2026-07-30T01:23:01Z">30 July 2026</time>
</p>

</header>
<div class="entry-body" itemprop="articleBody">
<h2>반가워요</h2>
<p><strong>굵기</strong> 테스트</p>
<ul>
<li>항목</li>
<li>테스트</li>
</ul>

</div>
</article>
<footer class="site"><a href="https://staging.nooker.app/@tim">← tim</a></footer>
</body>
</html>

"""
}
