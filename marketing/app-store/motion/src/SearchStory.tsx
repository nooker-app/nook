import React, {useMemo} from 'react';
import {AbsoluteFill, Img, staticFile, useCurrentFrame} from 'remotion';
import {TransitionSeries, linearTiming} from '@remotion/transitions';
import {fade} from '@remotion/transitions/fade';
import {CANVAS} from './theme';

/// THE SEARCH-RESULT VIDEO.
///
/// This slot is not the poster. It sits in a list of results being scrolled past, beside
/// competitors, and it has about two seconds to answer "what is this and can it do the thing I
/// came here for". Two earlier cuts were rejected: one for being atmospheric (a nest, poetry) and
/// one for hand-drawn mock UI with tooltip copy. So: every pixel of product in this file is a real
/// capture of the shipping app, and nothing is drawn.
///
/// THE FORM is a fixed APERTURE, not a display case. There are no bezels, no perspective, no
/// devices floating on a gradient — the single loudest tell of an App Store template. The frame
/// stays put and the screenshots move behind it, so a magnification reads as a lens moving over a
/// real object rather than as a slide in a deck. Beats 1, 2 and 6 are ONE PNG at three
/// magnifications, which is also the cheapest possible proof that nothing was mocked up: you
/// cannot suspect a mock of a frame that is visibly a detail of the frame before it.
///
/// LAYOUT. The guaranteed box is 2167x1029 at x 836..3003, y 765..1794 — wide and short, 2.1:1.
/// A paper band is laid ACROSS it at y 1504..1794 holding one line and one quiet platform tag,
/// in the same place for all 180 frames so the eye never hunts. Spending the box's bottom 28% on
/// words is what buys the pictures their magnification: it forces every crop to a 2.93:1 band, and
/// a 2.93:1 band of a Mac window is a 1.3x-2.2x punch-in where a full-height band would have been
/// a 0.85x REDUCTION. Rendered both: at 600px wide (nearer what the store draws) the full-height
/// version's headlines were 4-5px tall grey mush. Magnification is legibility here.
///
/// THE LOOP. `TransitionSeries` does not wrap: frame 179 cuts hard to frame 0. Beat 6 is therefore
/// a return — it pulls back to land on beat 1's exact opening rectangle of the same file, eased so
/// its velocity is zero at the seam, and it carries NO caption, so the seam has no type on it
/// either. The only free-running thing in the piece, the light on the paper, is computed from
/// `startsAt + local` over a period of exactly 180, because inside a TransitionSeries.Sequence
/// `useCurrentFrame()` restarts at 0 and anything periodic keyed to it pops at every cut.

const {width: W, height: H} = CANVAS.search;
const SAFE = {
  x0: (W - CANVAS.search.safe.width) / 2, // 836
  y0: (H - CANVAS.search.safe.height) / 2, // 765
  w: CANVAS.search.safe.width, // 2167
  h: CANVAS.search.safe.height, // 1029
};
const SAFE_X1 = SAFE.x0 + SAFE.w; // 3003

/// The caption band, laid across the picture rather than under it. Its bottom edge is the safe
/// area's bottom edge: at the guaranteed crop the band runs to the bottom of frame, and at any
/// wider crop the capture resumes below it so the frame stays full of app. An earlier version made
/// it a FLOOR running to the canvas bottom — fine inside the safe box, and at the full 3840x2560
/// it turned 41% of the frame into empty paper with one line of type in it. Only visible by
/// rendering the whole canvas.
const SHELF_Y = 1504;
const SHELF_H = 1794 - SHELF_Y;
/// The picture band in canvas coordinates. Every beat maps a source rectangle onto exactly this;
/// whatever else the capture holds spills outside it as bleed.
const BAND = {x: SAFE.x0, y: SAFE.y0, w: SAFE.w, h: SHELF_Y - SAFE.y0}; // 2167 x 739, 2.932:1

const TOTAL = 180;

/// Paper a full step deeper than Nook's own cream chrome (#FBF3E4-ish). It was matched to it
/// before, and at 600px the iPhone captures dissolved into the layout — you could not see where
/// the screen ended, which quietly undoes the "this is a photograph of software" argument the whole
/// cut rests on. Deepening the ground was cheaper and steadier than drawing a border.
const PAPER = '#E9DEC7';
const PAPER_LIT = '#F3EAD8';
const INK = '#2C1D10';
const TAG = '#9A7E56';
const RULE = '#D6C4A2';
const UI =
  "-apple-system, 'SF Pro Text', 'Apple SD Gothic Neo', 'Helvetica Neue', Helvetica, sans-serif";

const clamp01 = (v: number) => (v < 0 ? 0 : v > 1 ? 1 : v);
/// Smoothstep, not spring(): a spring is not periodic and cannot be reasoned about at a seam.
const ease = (t: number) => {
  const x = clamp01(t);
  return x * x * (3 - 2 * x);
};
const lerp = (a: number, b: number, t: number) => a + (b - a) * t;

/* ------------------------------------------------------------------ copy */

/// Four lines and a close, from the rewritten set, used as written.
///
/// WHY ONLY FOUR. Six lines in six seconds is not reading, it is flashing. Two beats here carry no
/// line at all — the tap (beat 3) and the return (beat 6) — because both are actions the picture
/// performs and a caption on either would be narrating what the eye has already got.
///
/// "주소 하나면 됩니다 / The address is enough" is unused: it belongs to a shot of the Add Feed
/// sheet with a bare site address typed into it and NO SUCH CAPTURE EXISTS. "무슨 말로 쓰였든
/// 읽힙니다 / It arrives in your language" is unused for the same reason — see TRANSLATION_GAP.
/// A line asserting a feature over a frame that does not show it is the failure this pass exists
/// to avoid; the piece makes four claims it can photograph instead of six it cannot.
const COPY = {
  en: {
    /// Beat 1, over the four-pane window with its finite counts (Unread 61 / All Articles 65).
    /// Finitude is the one thing an infinite feed structurally cannot offer, so no competitor can
    /// write this line.
    c1: 'A list that ends',
    /// Beat 2, over the named feeds. States the anti-algorithm claim without naming the enemy —
    /// the word "algorithm" would hand the viewer's last thought to the For You feed.
    c2: 'No one else put these here',
    /// The reading beat. English says "It gets out of the way", not "Then it gets out of the way":
    /// "Then" only works after a translation shot, and there is no translation shot.
    c3: 'It gets out of the way',
    /// The close, on the beat before the return. Same sentence the product-page header ends on.
    end: 'The reading you chose',
    size: 108,
  },
  ko: {
    c1: '끝이 있는 목록입니다',
    c2: '내가 하나씩 넣었습니다',
    c3: '읽는 동안엔 비켜섭니다',
    end: '고른 글만 남습니다',
    size: 126,
  },
} as const;

type Locale = keyof typeof COPY;

/// TRANSLATION_GAP — the headline feature is absent from this video, deliberately, and this block
/// is what turns that from an omission into a costed slot.
///
/// Nothing in the 46 captures shows translation happening. The three ways to fake it all fail:
///   (a) the cross-locale pair — ja__ipad-13__03-reader cut against ko__ipad-13__03-reader — is two
///       different articles by two different authors with different layouts, presented as one
///       article being translated. This asset LOOPS, so a viewer gets a second and a third look.
///   (b) the only affordances that exist are the Settings row labelled 실험실 / Experimental, which
///       proves a settings screen and nothing else, and the "번역 중…" badge at the bottom of
///       ko__iphone-6.9__02-articles, which the repo README documents as the STUCK state shown when
///       there is nothing to translate. Shipping a perpetual spinner as proof is worse than silence.
///   (c) a Japanese library under a Korean caption claiming "no need to learn the language" states
///       the payoff over a frame showing only the problem — and to a Korean viewer 1.5 seconds of a
///       Japanese screen reads first as "this app is Japanese".
///
/// So the slot is left empty and costed. Beat 5 runs 45 frames; dropping it to 27 and beat 6 to 20
/// frees 22 frames for a translation beat in 4th position with no other retiming. It needs THREE
/// captures, in one uninterrupted simulator run so the clock, status bar, feed set and scroll
/// offset are pixel-identical (anything else and the join flickers):
///   make app-store-capture LOCALE=ko NAME=06-translate-list
///   make app-store-capture LOCALE=ko NAME=07-translate-reader
///   and the one the README does not ask for and a video absolutely needs: the same article at the
///   same scroll offset with translation OFF — the "before". Without a matched before there is
///   still no honest two-frame cut.
/// The line for that slot is already written and waiting: 무슨 말로 쓰였든 읽힙니다 /
/// It arrives in your language.
const TRANSLATION_GAP = true;

/* ------------------------------------------------------------------ the aperture */

type Rect = {x: number; y: number; w: number; h: number};

/// Map a rectangle of the source image onto the picture band. The source rectangle may run negative
/// or past the file's edges — that simply means paper shows, which is what the establishing beats
/// want (a window lying on a page) and what the punch-ins never hit (they are entirely interior).
const framed = (src: {w: number; h: number}, r: Rect) => {
  const scale = BAND.w / r.w;
  return {
    width: src.w * scale,
    height: src.h * scale,
    left: BAND.x - r.x * scale,
    top: BAND.y - r.y * scale,
  };
};

/// THE ANCHOR. Every screen edge in the piece — Mac window, iPad, iPhone — lands on canvas
/// x = 990 whatever the magnification, and the caption is set to the same line. The lens goes from
/// 1.34x to 2.2x and back and across three machines while that one vertical never moves, which is
/// what makes differently-scaled crops of different devices read as one composed page.
const WINDOW_EDGE = 990;
/// Solve x so that source column `edge` lands on WINDOW_EDGE at whatever magnification `w` implies.
/// On the iPad `edge` is 24 rather than 0, which throws away a strip of empty sidebar padding and
/// with it the clipped brown focus ring that bleeds off the left of 13 of the 20 iPad captures.
const anchored = (edge: number, y: number, w: number): Rect => ({
  x: edge - ((WINDOW_EDGE - BAND.x) * w) / BAND.w,
  y,
  w,
  h: (w * BAND.h) / BAND.w,
});
/// An interior punch-in, with no screen edge in frame and therefore nothing to anchor: give the
/// source rectangle's own left edge directly.
const at = (x: number, y: number, w: number): Rect => ({x, y, w, h: (w * BAND.h) / BAND.w});
/// The Mac establishing framings additionally pin the window's TOP edge, so beat 1's push and
/// beat 6's pull-back are a zoom anchored on the window's own corner: the corner does not drift,
/// the content grows out of it. A centre-anchored zoom slid that corner across the safe-area
/// boundary and read, for four or five frames, as a cropped window.
const MAC_TOP = 859;
const macCorner = (w: number): Rect => {
  const s = BAND.w / w;
  return anchored(0, -(MAC_TOP - BAND.y) / s, w);
};

const tween = (a: Rect, b: Rect, t: number): Rect => ({
  x: lerp(a.x, b.x, t),
  y: lerp(a.y, b.y, t),
  w: lerp(a.w, b.w, t),
  h: lerp(a.h, b.h, t),
});

/* ------------------------------------------------------------------ the plates */

/// The real captures, per locale. A localized listing showing another language's screenshots is the
/// same class of mistake as a mock-up, so the two cuts share no PNG. Sizes are the files' own.
///
/// Why these files and not the obvious ones — every one of these decided by opening the capture and
/// reading it, not by the filename:
///   - en Mac is 03-library, NOT 01-overview, for the wide beats: every usable band of
///     en__mac__01-overview carries a US immigration-enforcement headline about DNA collection, and
///     its reader's lead image is a visibly AI-generated CRT with garbled text on it. All three
///     English Mac framings live in 03-library's left third, so its empty "Select an Article" pane
///     never enters frame.
///   - en macRead IS en__mac__01-overview, but only as an interior punch-in on the reader column
///     ABOVE that lead image: byline, headline, Star and Categories. The sidebar is out of frame,
///     so the fact that a different feed is selected in that file is invisible, and the list column
///     with the bad headline is out of frame too. It is the only clean English reading surface in
///     46 captures — see BEATS.en[2].
///   - en iPad is cropped to the sidebar and list ONLY. Its reader column reads "I'll just say it:
///     What the hell is going on with AI 'reasoning'?" and litters "(opens a new tab)" out of the
///     feed's accessibility markup six times in one screen. There is no clean band containing it.
///   - en phone is 04-starred. en__iphone-6.9__03-reader contains a film still with two identifiable
///     human faces and names five actors; the repo's own `make app-store-check-faces` gate exists to
///     fail exactly that. 02-articles carries a memoir about a parent's death and a named rap duo.
///   - ko phoneList and phoneRead are the SAME SESSION on the SAME DEVICE, and the row the list beat
///     lands on is the article the reader beat opens. See BEATS.ko[2].
const PLATES = {
  ko: {
    mac: {file: 'shots/ko__mac__01-overview.png', w: 2560, h: 1640},
    phoneList: {file: 'shots/ko__iphone-6.9__02-articles.png', w: 1320, h: 2868},
    phoneRead: {file: 'shots/ko__iphone-6.9__03-reader.png', w: 1320, h: 2868},
    ipad: {file: 'shots/ko__ipad-13__02-articles.png', w: 2064, h: 2752},
  },
  en: {
    mac: {file: 'shots/en__mac__03-library.png', w: 2560, h: 1640},
    macRead: {file: 'shots/en__mac__01-overview.png', w: 2560, h: 1640},
    ipad: {file: 'shots/en__ipad-13__02-articles.png', w: 2064, h: 2752},
    phone: {file: 'shots/en__iphone-6.9__04-starred.png', w: 1320, h: 2868},
  },
} as const;

type Plate = {file: string; w: number; h: number};

type Beat = {
  plate: Plate;
  /// Source rectangle at the beat's first frame and at its last.
  a: Rect;
  b: Rect;
  /// The quiet platform label in the band's opposite corner. It is the only place the piece says
  /// "Mac / iPad / iPhone" — a caption spent on a platform list is a caption wasted, but a 48px
  /// label in the corner costs nothing and is the only thing carrying "all three".
  tag: string;
  /// null means this beat is deliberately wordless.
  caption: string | null;
  /// Genuine clipping of the plate, in the capture's own pixels — not repositioning. Three distinct
  /// jobs, all of them found by rendering rather than reasoning:
  ///
  ///   left — anchoring a crop at source x = 24 positions that column on the layout line but does
  ///     NOT remove columns 0..23; they simply land 27 canvas pixels to its left, still inside the
  ///     safe area. On the iPad captures those columns are a clipped brown focus ring bleeding off
  ///     the screen edge, present on 13 of the 20 iPad files.
  ///
  ///   right and bottom — THE BLEED. Only the safe box is guaranteed, but the store may show more,
  ///     and the frame outside it is still the frame. Two beats were carefully cropped so that bad
  ///     content sat just outside the safe box — and at the full 3840x2560 that content was plainly
  ///     legible in the bleed, which I only saw by rendering the whole canvas. The English iPad
  ///     showed the reader column I had cropped away ("What the hell is going on with AI
  ///     'reasoning'?", plus "(opens a new tab)" leaking out of the feed's accessibility markup),
  ///     and the English Mac reader showed, below the band, the AI-generated CRT image the framing
  ///     exists to avoid. Clipping the plate is the only fix that holds at every breakpoint: past
  ///     the clip there is paper, which is what the rest of the canvas is anyway.
  clipSrc?: {left?: number; right?: number; bottom?: number};
  /// A shadow is drawn only where a screen edge is actually in frame. A shadow under a full-bleed
  /// interior punch-in is a shadow under nothing.
  edged?: boolean;
  /// Frames to sit still on `a` before the move starts. Only the list beat uses it, and it is the
  /// difference between a camera pan and a thumb: a person looks at the top of a list, then flicks,
  /// and the flick decelerates onto what they were reaching for. Without the hold, the filter row —
  /// the one unmistakably-iOS thing in the frame — was off screen by frame 9 of 24.
  hold?: number;
};

/* ------------------------------------------------------------------ the beats */

/// Beat lengths and transition lengths: sum(SHOTS) - sum(XITIONS) = 185 - 5 = 180.
///
/// EVERY JOIN IS A HARD CUT. TransitionSeries has no zero-length transition, and one frame of
/// crossfade at 30fps is a cut. This is the second thing this file was rebuilt for, after looking:
/// the device changes were 7-frame directional slides, and rendering their middles showed why that
/// was wrong. Every framing here hangs its screen edge on x = 990, so both the outgoing and the
/// incoming frame carry a paper margin at the left — and a slide puts those two margins on screen
/// together. At the midpoint the safe box was half a Mac window cropped at an arbitrary column and
/// half empty paper, under an empty caption band. Fourteen of 180 frames looked like a rendering
/// fault. A cut cannot be double-exposed, cannot be half-empty, and is also what the app itself
/// does: tapping a row swaps the screen on one frame.
///
/// XITIONS[2] is the tap and was always going to be a cut. An earlier cut of this material
/// dissolved its equivalent join over ten frames and the frozen midpoint was one article's title
/// printed on top of another article's diagram.
const SHOTS = [35, 31, 25, 31, 39, 24];
const XITIONS = [1, 1, 1, 1, 1];
const STARTS = SHOTS.reduce<number[]>((acc, _, i) => {
  acc.push(i === 0 ? 0 : acc[i - 1] + SHOTS[i - 1] - XITIONS[i - 1]);
  return acc;
}, []);
// → [0, 34, 64, 88, 118, 156], and 156 + 24 = 180.

/// Source rectangles, in each capture's own pixels. Each states what the GUARANTEED band must
/// contain; `framed` derives the placement and the rest of the file spills out as bleed.
const BEATS: Record<Locale, Beat[]> = {
  ko: [
    {
      /// 1. ESTABLISH, and push. Opens at 1.34x with the window's own corner in frame — traffic
      /// lights, 라이브러리 / 안 읽음 67 / 오늘 29 / 별표 / 모든 글 70, three real headlines, the
      /// reader beginning — so the first thing a scrolling eye resolves is "a real Mac app with a
      /// lot of real content in it". Then it closes to 1.75x, so by the time the line has landed
      /// the type is legible rather than merely dense. Not opened wider: rendered at 0.85x, where
      /// the whole four-pane window fits, and at 600px the deks were grey noise.
      plate: PLATES.ko.mac,
      a: macCorner(1617),
      b: macCorner(1240),
      tag: 'macOS',
      caption: COPY.ko.c1,
      edged: true,
    },
    {
      /// 2. INSERT: the feeds. Hard cut, closer lens, same window — 우아한형제들 기술블로그 9,
      /// GeekNews 49, tech.kakao.com 9. The frame that says a person built this list, cropped to
      /// nothing else. 2.2x and not more: those favicons are 32px bitmaps and past about 2.4x they
      /// visibly block up, which is exactly the tell this pass exists to avoid. The 18-source-pixel
      /// upward drift is the speed of a list being read, not of a camera being moved.
      plate: PLATES.ko.mac,
      a: anchored(0, 382, 985),
      b: anchored(0, 400, 985),
      tag: 'macOS',
      caption: COPY.ko.c2,
      edged: true,
    },
    {
      /// 3. THE TAP, first half — and this is the only beat in the piece that shows a FEATURE being
      /// used rather than a surface being looked at. ko__iphone-6.9__02-articles opens on the real
      /// filter row (안 읽음 with its 70 badge / 오늘 / 전체) and the search glass, then travels down
      /// the list at reading speed to settle with "Diátaxis - 기술 문서 작성을 위한 체계적 접근법"
      /// in the lower half. That row is the article the NEXT beat has open. Two real captures of one
      /// session on one device: a tap, filmed. Wordless on purpose — the picture is the sentence.
      ///
      /// The pan starts at source y 170 rather than 0 so the '번역 중…' badge and the BMW/Spider-Man
      /// headline at the file's foot never enter frame, and it ends at exactly 800 — measured, not
      /// guessed. The Diátaxis row occupies source y 954..1206, so at 800 its centre sits 57% down
      /// a 494-tall band: the row is the largest thing in the last frame before the cut, which is
      /// what makes the cut read as opening THAT row. The first framing ended at 670 and the row
      /// was one of three, small and low; the match did not land. 800 also keeps the following
      /// headline's first line (source y 1309) outside the band instead of sliced by its edge.
      ///
      /// 1.49x rather than the 1.41x used elsewhere for phones: at 1.41x the row titles held at
      /// 600px but the deks under them started to close up, and this beat is asking a viewer to
      /// read one specific row.
      plate: PLATES.ko.phoneList,
      a: anchored(0, 170, 1450),
      b: anchored(0, 800, 1450),
      tag: 'iPhone',
      caption: null,
      edged: true,
      hold: 10,
    },
    {
      /// 4. THE TAP, second half. One-frame cut and the row is open: the same headline, now set
      /// large, with the GeekNews byline, the rule and the first summary bullet under it. This is
      /// the cleanest capture in the whole set: no smear, no artefact, no clipping.
      ///
      /// The opening rectangle starts at source y 150 because the back chevron and the ⋯ menu sit
      /// at 187..317 and the title at 413..590 — so the first frame after the cut holds a circular
      /// iOS control AND the headline the tapped row carried. An earlier version opened at 330 and
      /// the controls were already gone: the frame was large type on cream, with no cue that it was
      /// a phone at all, indistinguishable from a title card. It then settles to 400, which trades
      /// the controls away for the byline, the rule and the whole first bullet — by then the frame
      /// has already said "phone" and can spend itself on saying "article".
      plate: PLATES.ko.phoneRead,
      a: anchored(0, 150, 1450),
      b: anchored(0, 400, 1450),
      tag: 'iPhone',
      caption: COPY.ko.c3,
      edged: true,
    },
    {
      /// 5. iPad, and the close. The single most informative frame available: a true three-pane
      /// NavigationSplitView with the sidebar's counts, a feed-titled column with its 글 검색 field,
      /// and a full reader with a heading and running body — navigation, search and reading at once.
      /// It is also the frame the end line is truest over, because everything in it is something
      /// the reader subscribed to. 1.14x; the left 24 source pixels are hard-clipped.
      plate: PLATES.ko.ipad,
      a: anchored(24, 170, 1900),
      b: anchored(24, 196, 1900),
      tag: 'iPadOS',
      caption: COPY.ko.end,
      clipSrc: {left: 24},
      edged: true,
    },
    {
      /// 6. RETURN, wordless. Back to the Mac, pulling out to land on beat 1's exact opening
      /// rectangle of the same file with velocity eased to zero, so 179 and 0 are the same picture
      /// under the same empty band and the seam is a match rather than a transition.
      plate: PLATES.ko.mac,
      a: macCorner(1290),
      b: macCorner(1617),
      tag: 'macOS',
      caption: null,
      edged: true,
    },
  ],
  en: [
    {
      /// 1.41x rather than the Korean 1.34x, and the 77 source pixels of difference are not taste.
      /// In en__mac__03-library the selected feed row is a saturated system-blue pill at source
      /// y 464..539 (measured, not eyeballed), and at 1617 the band's bottom edge falls at source
      /// y 482 — so the frame carried a 24px stripe of raw blue along its bottom left, which at
      /// 600px reads as a crop mistake. At 1540 the band bottom lands at 459 and the pill is
      /// entirely below frame. The Korean file's selected row is at 334..397, well inside the band,
      /// so it needs no such correction.
      plate: PLATES.en.mac,
      a: macCorner(1540),
      b: macCorner(1230),
      tag: 'macOS',
      caption: COPY.en.c1,
      edged: true,
    },
    {
      /// English subscribes to six feeds, not three, and they run from source y 472 to 830 rather
      /// than 477 to 660 — so the English feed beat needs a taller band and therefore a slightly
      /// wider lens than the Korean one.
      plate: PLATES.en.mac,
      a: anchored(0, 404, 1114),
      b: anchored(0, 422, 1114),
      tag: 'macOS',
      caption: COPY.en.c2,
      edged: true,
    },
    {
      /// 3. The English reading beat, and it is a SUBSTITUTION rather than an equivalent — the
      /// Korean cut gets a tap on a phone and English gets a punch-in on a Mac, because English has
      /// no clean reader capture on any other device (see PLATES). What it does have is this: an
      /// interior crop of en__mac__01-overview's reader column above its lead image, carrying the
      /// Hacker News byline, the full headline, and the Star and Categories buttons. No sidebar, no
      /// list, no chrome — which is what earns "It gets out of the way" on this frame.
      ///
      /// The rectangle stops at source y 496 because the reader's lead image starts at 498 and is a
      /// visibly AI-generated CRT with garbled text on it; at this magnification it reads as slop.
      /// It starts at x 1430 because the headline's right edge is at 2392 and the crop has to hold
      /// the whole line.
      plate: PLATES.en.macRead,
      a: at(1430, 162, 970),
      b: at(1436, 178, 946),
      tag: 'macOS',
      caption: COPY.en.c3,
      // The lead image begins at source y 498. Below the caption band the frame keeps going, so
      // without this the bleed showed it. Clipped at 496; past that the page is paper.
      clipSrc: {bottom: 496},
    },
    {
      /// 4. iPad, wordless, cropped to the sidebar and the article column only — the reader column
      /// is deliberately just out of frame at the right, and 1200 is the widest lens that keeps it
      /// there (the column's left rule is at source x 1132, and `anchored` shows source x up to
      /// 0.929w). The pan travels down the sidebar's six named feeds with their unread counts while
      /// the article column runs beside it.
      ///
      /// It starts at 520 rather than at the top: the first framing began at 240 and its left half
      /// was the Library section's four rows above a lot of empty sidebar, which is the emptiest
      /// kind of frame and the one a scrolling thumb skips.
      plate: PLATES.en.ipad,
      a: anchored(24, 520, 1200),
      b: anchored(24, 840, 1200),
      tag: 'iPadOS',
      caption: null,
      // 1138 is the article column's right rule. The reader column beyond it is unusable (see
      // PLATES) and the safe box already ends within a pixel or two of it, so the clip only ever
      // removes bleed.
      clipSrc: {left: 24, right: 1138},
      edged: true,
    },
    {
      /// 5. iPhone, and the close. A Starred list is the one English frame the end line is literally
      /// true of: SwiftUI After 7 Years, The myth of Snow Leopard, What's Up: August 2026 — the
      /// best-written list content in the entire English set, and every row is there because someone
      /// starred it, with its yellow star still on the row — which is what makes the end line land
      /// on evidence rather than on a mood.
      ///
      /// The band starts at source y 950, measured: row one is NASA's APOD and its dek is a scraped
      /// navigation strip ("APOD Archive Submissions Index Search Calendar RSS…") that reads as a
      /// parsing failure, and that row ends at 849. A first pass started at 700 and the strip was
      /// on screen for most of the beat. The pan ends at 1330 so the last frame holds the two best
      /// titles in the entire English set for this audience — "SwiftUI After 7 Years" and "The myth
      /// of Snow Leopard" — both starred.
      plate: PLATES.en.phone,
      a: anchored(0, 950, 1450),
      b: anchored(0, 1330, 1450),
      tag: 'iPhone',
      caption: COPY.en.end,
      edged: true,
    },
    {
      plate: PLATES.en.mac,
      a: macCorner(1280),
      b: macCorner(1540),
      tag: 'macOS',
      caption: null,
      edged: true,
    },
  ],
};

/* ------------------------------------------------------------------ pieces */

const Picture: React.FC<{beat: Beat; rect: Rect}> = ({beat, rect}) => {
  const box = framed(beat.plate, rect);
  const s = box.width / beat.plate.w; // source pixel → drawn pixel
  const c = beat.clipSrc;
  const inset = c
    ? `inset(0 ${c.right ? (beat.plate.w - c.right) * s : 0}px ` +
      `${c.bottom ? (beat.plate.h - c.bottom) * s : 0}px ${c.left ? c.left * s : 0}px)`
    : undefined;
  return (
    <div style={{position: 'absolute', left: 0, top: 0, width: W, height: H, overflow: 'hidden'}}>
      <Img
        src={staticFile(beat.plate.file)}
        style={{
          position: 'absolute',
          left: box.left,
          top: box.top,
          width: box.width,
          height: box.height,
          clipPath: inset,
          filter: beat.edged ? 'drop-shadow(0 22px 46px rgba(96,70,36,0.22))' : undefined,
        }}
      />
    </div>
  );
};

/// The band: one line, and a tag naming the machine. The band is drawn on every frame even when the
/// beat is wordless, because it is a page element and a page element that comes and goes is a
/// sticker. The tag never leaves, so a wordless beat still says which machine you are looking at.
const Shelf: React.FC<{
  text: string | null;
  size: number;
  tag: string;
  opacity: number;
  rise: number;
}> = ({text, size, tag, opacity, rise}) => (
  <>
    <div
      style={{
        position: 'absolute',
        left: 0,
        top: SHELF_Y,
        width: W,
        height: SHELF_H,
        background: PAPER,
        borderTop: `4px solid ${RULE}`,
        borderBottom: `4px solid ${RULE}`,
        boxSizing: 'border-box',
      }}
    />
    {text ? (
      <div
        style={{
          position: 'absolute',
          left: WINDOW_EDGE,
          top: SHELF_Y + 84,
          width: SAFE_X1 - WINDOW_EDGE - 320,
          fontFamily: UI,
          fontSize: size,
          fontWeight: 600,
          letterSpacing: -0.012 * size,
          color: INK,
          opacity,
          transform: `translateY(${rise}px)`,
          whiteSpace: 'nowrap',
        }}
      >
        {text}
      </div>
    ) : null}
    <div
      style={{
        position: 'absolute',
        left: SAFE.x0,
        top: SHELF_Y + 118,
        width: SAFE.w - 110,
        textAlign: 'right',
        fontFamily: UI,
        fontSize: 48,
        fontWeight: 500,
        letterSpacing: 5,
        color: TAG,
        opacity: 0.9,
      }}
    >
      {tag}
    </div>
  </>
);

/// The only thing that runs continuously across cuts, so the only thing keyed to
/// `startsAt + local`: one slow sweep of warm light over the paper, period exactly 180.
const Paper: React.FC<{global: number}> = ({global}) => {
  const phase = (global / TOTAL) * Math.PI * 2;
  const cx = 50 + Math.cos(phase) * 14;
  return (
    <AbsoluteFill
      style={{
        background: `radial-gradient(120% 90% at ${cx}% 8%, ${PAPER_LIT} 0%, ${PAPER} 62%, #E0D3B8 100%)`,
      }}
    />
  );
};

/* ------------------------------------------------------------------ the shot */

/// One component for all six beats. Everything that differs is data in BEATS; everything that is
/// the same — the caption ramp, the aperture tween, the paper phase — is here once, which is what
/// keeps the two locales' timing identical when their plates are not.
const Shot: React.FC<{index: number; locale: Locale}> = ({index, locale}) => {
  const local = useCurrentFrame();
  const beat = BEATS[locale][index];
  const c = COPY[locale];

  /// Geometry does not depend on the frame, so it is memoised on the things that actually change
  /// it. The tween below is the only per-frame arithmetic.
  const {span, outAt, isLast} = useMemo(() => {
    const last = index === SHOTS.length - 1;
    // Visible span: a beat is on screen from its own start until the next beat's start.
    const visible = last ? TOTAL - STARTS[index] : STARTS[index + 1] - STARTS[index];
    return {
      span: visible,
      /// The line leaves 6 frames before the outgoing transition begins, so a caption is never
      /// half-faded while two half-images are crossing the band. Rendering a transition and looking
      /// at the middle of it was the only way to catch that.
      outAt: SHOTS[index] - (XITIONS[index] ?? 0) - 6,
      isLast: last,
    };
  }, [index]);

  /// Beat 6's tween must land EXACTLY on beat 1's opening rectangle at its final frame, not
  /// asymptotically, or the seam shows a one-frame jump. Hence the divisor is SHOTS-1 there.
  /// A beat with a `hold` also lands exactly, because its move is a thumb-flick and a flick
  /// settles; every other beat overshoots its divisor so the move is still travelling when it is
  /// cut away from — a move that visibly parks before a cut reads as a slide instead of a lens.
  const hold = beat.hold ?? 0;
  const t = ease(
    isLast
      ? local / (SHOTS[index] - 1)
      : hold > 0
        ? (local - hold) / (span - hold - 1)
        : local / (span + 8)
  );
  /// In by local frame 7, so there is a fully readable line inside the first quarter-second of a
  /// beat. The previous cut ramped over 11 frames starting at 5 and at frame 8 the opening line was
  /// still washed out to near-invisibility — a meaningful slice of the two-second window with
  /// nothing to read.
  const inn = ease((local - 2) / 5);
  const out = 1 - ease((local - outAt) / 6);
  const cap = Math.min(inn, out);

  return (
    <AbsoluteFill>
      <Paper global={STARTS[index] + local} />
      <Picture beat={beat} rect={tween(beat.a, beat.b, t)} />
      <Shelf
        text={beat.caption}
        size={c.size}
        tag={beat.tag}
        opacity={cap}
        rise={(1 - inn) * 18}
      />
    </AbsoluteFill>
  );
};

/* ------------------------------------------------------------------ the series */

export const SearchStory: React.FC<{locale: Locale; guides?: boolean}> = ({
  locale,
  guides = false,
}) => {
  const timing = (n: number) => linearTiming({durationInFrames: n});
  return (
    <AbsoluteFill style={{background: PAPER}}>
      <TransitionSeries>
        {SHOTS.flatMap((dur, i) => [
          <TransitionSeries.Sequence key={`s${i}`} durationInFrames={dur}>
            <Shot index={i} locale={locale} />
          </TransitionSeries.Sequence>,
          ...(i < XITIONS.length
            ? [
                <TransitionSeries.Transition
                  key={`t${i}`}
                  presentation={fade()}
                  timing={timing(XITIONS[i])}
                />,
              ]
            : []),
        ])}
      </TransitionSeries>

      {guides ? (
        <svg width={W} height={H} style={{position: 'absolute', inset: 0}}>
          <rect
            x={SAFE.x0}
            y={SAFE.y0}
            width={SAFE.w}
            height={SAFE.h}
            fill="none"
            stroke="#FF00FF"
            strokeWidth={6}
          />
          <line x1={0} y1={SHELF_Y} x2={W} y2={SHELF_Y} stroke="#00A0FF" strokeWidth={4} />
          <line
            x1={WINDOW_EDGE}
            y1={0}
            x2={WINDOW_EDGE}
            y2={H}
            stroke="#00A0FF"
            strokeWidth={3}
          />
        </svg>
      ) : null}
    </AbsoluteFill>
  );
};

export {TRANSLATION_GAP};
