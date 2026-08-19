import Foundation

/// The JavaScript both reader surfaces inject, in one place so they cannot drift.
///
/// The offscreen extractor (``ReaderModeExtractor``) and the in-app browser's
/// reader mode (``ArticleWebView``) have to agree exactly about what "the article"
/// is, because the native reader and the web reader show the same article and a
/// difference between them reads as a bug. They used to hold two copies of this
/// logic and it drifted twice.
///
/// Everything here hangs off one namespace, `window.__nook`, and defines functions
/// only — nothing runs until a driver script calls in.
enum ReaderParserScripts {
    /// `window.__nook.source()` — the page as a string, for legibility.
    ///
    /// legibility is handed HTML rather than a live DOM, and resolves nothing
    /// relative because it has no base URL to resolve against. So the page is
    /// cloned, every URL on the clone is made absolute, and the clone is
    /// serialized. Cloning rather than editing in place matters on the browser's
    /// reader path, where the live document is what the reader is looking at.
    ///
    /// `window.__nook.readability()` — Readability's article, or null.
    ///
    /// Kept available even when legibility is the chosen engine: if the engine
    /// cannot run at all — a missing resource, a trapped module — falling back to
    /// this beats telling the reader the page has no article in it, and the page is
    /// already loaded.
    static let shared = """
    (function () {
      if (window.__nook) return;

      var originalURL = document.baseURI;

      function absolutize(root) {
        root.querySelectorAll('img').forEach(function (img) {
          if (!img.getAttribute('src')) {
            var lazy = img.getAttribute('data-src') || img.getAttribute('data-lazy-src');
            if (lazy) img.setAttribute('src', lazy);
          }
        });
        root.querySelectorAll('img, iframe, video, source, audio, embed').forEach(function (media) {
          var src = media.getAttribute('src') || media.getAttribute('data-src');
          if (src) {
            try { media.setAttribute('src', new URL(src, originalURL).href); } catch (_) {}
          }
        });
        // Links too, on the legibility path only: it keeps `href` on `<a>` and
        // cannot resolve `/about` into anything a reader can tap.
        root.querySelectorAll('a[href]').forEach(function (link) {
          var href = link.getAttribute('href');
          if (href && href.charAt(0) !== '#') {
            try { link.setAttribute('href', new URL(href, originalURL).href); } catch (_) {}
          }
        });
      }

      /* Media normalization for a subtree that is about to be rendered as-is
         (the Readability path, which returns markup lifted out of the page).

         Images are absolutized too. In the browser's reader the rewritten page keeps
         a `<base href>` so a relative `src` would still resolve, but the offscreen
         extractor hands this markup to the native renderer, where there is no
         document and no base — and a relative `src` there is simply a missing
         image. */
      function normalizeMedia(root) {
        root.querySelectorAll('img').forEach(function (img) {
          if (!img.getAttribute('src')) {
            var lazy = img.getAttribute('data-src') || img.getAttribute('data-lazy-src');
            if (lazy) img.setAttribute('src', lazy);
          }
          img.setAttribute('loading', 'lazy');
        });
        root.querySelectorAll('img, iframe, video, source').forEach(function (media) {
          var src = media.getAttribute('src') || media.getAttribute('data-src');
          if (src) {
            try { media.setAttribute('src', new URL(src, originalURL).href); } catch (_) {}
          }
        });
      }

      /* The length floor exists to reject a page that is all navigation, where
         picking the biggest block of text would show junk. It does not apply when
         the markup says outright where the body is: an <article> or an
         [itemprop="articleBody"] is the page declaring it, not us guessing, and a
         short post is still a post. Without this a twenty-word note read as
         "can't show the original", which sent people to delete a perfectly good
         article. */
      var MINIMUM_GUESSED_TEXT = 80;

      /* Readability intentionally removes most iframes. Interactive CodePen
         examples are article content for developer sites, so retain them alongside
         its standard video-provider allowlist. */
      var ALLOWED_EMBEDS = /\\/\\/(www\\.)?((dailymotion|youtube|youtube-nocookie|player\\.vimeo|v\\.qq|codepen)\\.(com|io)|(archive|upload\\.wikimedia)\\.org|player\\.twitch\\.tv)/i;

      /* A detached copy of the page as it arrived, taken before anything rewrites
         it.

         The browser's reader mode replaces the live DOM with the extracted
         article, so after one render the page is no longer the page — and
         switching parsers in place would ask the second engine to read the first
         engine's output. Keeping one clone is what lets the switch happen without
         re-downloading the article, and it is only taken on the surface that
         actually rewrites: the offscreen extractor re-reads the live document
         instead, because a page whose body arrives by script may still be filling
         in. */
      var stashed = null;

      function baseDocument() {
        return stashed || document;
      }

      /* Tried in order of how specific each one is. A comma-separated
         querySelector would not do: it returns the first match in *document*
         order, not the first selector that matches, so an <article> wrapping a
         marked-up body won every time and brought the heading and byline with
         it. */
      function declaredBody(doc) {
        var selectors = [
          'article [itemprop="articleBody"]',
          '[itemprop="articleBody"]',
          'article .article-content',
          '.article-content',
          'article'
        ];
        for (var i = 0; i < selectors.length; i += 1) {
          var found = doc.querySelector(selectors[i]);
          if (found) return found;
        }
        return null;
      }

      function packaged(element, doc) {
        var content = element.cloneNode(true);
        normalizeMedia(content);
        var heading = doc.querySelector('h1');
        return {
          title: heading ? heading.textContent.trim() : doc.title,
          byline: '',
          content: content.innerHTML
        };
      }

      window.__nook = {
        /* Take the copy. Called once, by whichever surface is about to rewrite the
           live document; every later `source()` and `readability()` reads the copy
           instead of the rewritten page. */
        stash: function () {
          if (!stashed) {
            try { stashed = document.cloneNode(true); } catch (_) {}
          }
          return !!stashed;
        },

        /* The page, absolute-URL'd and serialized, for an engine that takes a
           string. */
        source: function () {
          try {
            var clone = baseDocument().cloneNode(true);
            absolutize(clone);
            return clone.documentElement.outerHTML;
          } catch (_) {
            return '';
          }
        },

        /* Readability's article, or null. Mirrors what the reader shipped before a
           second engine existed, down to the embed allowlist. */
        readability: function () {
          var doc = baseDocument();
          /* A declared body wins over Readability, and is checked first.
             Readability reads the whole document and picks the biggest candidate,
             which on a well-marked-up page sweeps the heading and byline back in —
             so the reader drew the title twice and left the date as a stray line,
             having already shown both in its own chrome. When the markup says where
             the article is, there is nothing to guess at. */
          var declared = declaredBody(doc);
          if (declared && (declared.innerText || '').trim().length > 0) {
            return packaged(declared, doc);
          }

          /* Nothing declared: Readability is the best available guess, and the
             floor applies because a guess can pick navigation. */
          if (typeof Readability !== 'undefined') {
            var clone = doc.cloneNode(true);
            normalizeMedia(clone);
            var parsed = new Readability(clone, { allowedVideoRegex: ALLOWED_EMBEDS }).parse();
            if (parsed && parsed.content && parsed.textContent
                && parsed.textContent.trim().length > MINIMUM_GUESSED_TEXT) {
              return { title: parsed.title || '', byline: parsed.byline || '', content: parsed.content };
            }
          }

          var guessed = doc.querySelector('main');
          if (!guessed || (guessed.innerText || '').trim().length < MINIMUM_GUESSED_TEXT) return null;
          return packaged(guessed, doc);
        },

        /* How many embeds the page carries that Readability would keep and
           legibility discards — its sanitizer drops the whole `<iframe>`,
           `<video>` and `<audio>` subtree.

           Counted here, on the page, because it costs one `querySelectorAll` over a
           document that is already in hand. The alternative a reader would
           otherwise get is a post that *is* a video rendering as a caption over a
           blank space, with nothing on screen saying anything was removed. */
        embedCount: function () {
          try {
            var doc = baseDocument();
            /* Scoped to the page's own article container, not the whole document.
               Counting everywhere reported the site's promo reel in the footer and the
               autoplaying clip in the sidebar, so the reader was told an embed had
               been removed from an article that never had one — and offered a switch
               that would change nothing. Not exact (only the extractor knows the final
               region) but wrong in the direction that costs nothing. */
            var scope = declaredBody(doc) || doc.querySelector('main') || doc.body;
            if (!scope) return 0;
            var n = 0;
            scope.querySelectorAll('iframe, video, audio').forEach(function (media) {
              var src = media.getAttribute('src') || media.getAttribute('data-src') || '';
              if (media.tagName.toLowerCase() !== 'iframe') {
                /* A <video> with neither a src nor a <source> is a placeholder a
                   script was going to fill; nothing was taken away. */
                if (src || media.querySelector('source[src]')) n += 1;
                return;
              }
              if (ALLOWED_EMBEDS.test(src)) n += 1;
            });
            return n;
          } catch (_) {
            return 0;
          }
        },

        /* Absolute-URL and lazy-load fixups for markup about to be inserted into
           the live page. Exposed so the browser's reader renderer shares it. */
        normalizeMedia: normalizeMedia
      };
    })();
    """
}
