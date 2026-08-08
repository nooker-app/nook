import React from 'react';
import {AbsoluteFill, Img, staticFile, useCurrentFrame} from 'remotion';
import {TransitionSeries, linearTiming} from '@remotion/transitions';
import {fade} from '@remotion/transitions/fade';
import {slide} from '@remotion/transitions/slide';
import {CANVAS} from '../theme';

/// STORY A — "the app on its devices", done as a camera rather than a display case.
///
/// The cliché this cut is built to avoid is three floating devices at a jaunty angle on a
/// gradient. Nothing here is a device object: there are no bezels, no perspective, no shadows
/// under levitating slabs. Instead the frame is a fixed APERTURE and the real screenshots move
/// behind it. A platform is not a thing on a shelf; it is what happens to be under the lens.
///
/// Three consequences, stated so nobody "improves" them back into the cliché:
///   - Every pixel of app you see is a real capture from `public/shots`. Nothing is redrawn.
///   - Shots 1, 2, 3 and 6 are ONE PNG seen at 1.3x, 2.2x, 3.2x and back. The pushes are
///     continuous moves on that single file and the two hard cuts between them are inserts, in
///     the sense a film editor means it — same subject, closer lens. A viewer cannot suspect a
///     mock-up of a frame that is visibly a detail of the frame before it.
///   - The device changes ARE the cuts, and they are the only places anything slides.
///
/// LAYOUT. The guaranteed box is 2167x1029 at x 836..3003, y 765..1794. A paper band is laid
/// across it at y 1504..1794 carrying one caption and one quiet platform tag, in the same place
/// for all 180 frames, so the eye never hunts for the words. Spending the box's bottom 28% on
/// words is what buys the pictures their magnification: it forces every crop to a 2.93:1 band,
/// and a 2.93:1 band of a Mac window is a 1.3x-3.2x punch-in where a full-height band would have
/// been a 0.85x reduction. At the size the store actually draws this thing, magnification is
/// legibility — verified by rendering the safe box down to 600px wide and reading it, not by
/// trusting the arithmetic.
///
/// THE LOOP. There is no free-running animation to go out of phase: every move is shot-local
/// and every shot boundary is a cut, so nothing can pop mid-piece. The 179->0 seam is solved by
/// making it a match rather than a transition — shot 6 pulls back to exactly shot 1's opening
/// framing of the same PNG, and both ends hold an empty shelf, so the last frame and the first
/// frame are the same picture with the same empty caption. The one thing that must survive the
/// cuts, the light on the paper, is therefore computed from `startsAt + local` over a period of
/// exactly 180.

const {width: W, height: H} = CANVAS.search;
const SAFE = {
  x0: (W - CANVAS.search.safe.width) / 2, // 836
  y0: (H - CANVAS.search.safe.height) / 2, // 765
  w: CANVAS.search.safe.width, // 2167
  h: CANVAS.search.safe.height, // 1029
};
const SAFE_X1 = SAFE.x0 + SAFE.w; // 3003
const SAFE_Y1 = SAFE.y0 + SAFE.h; // 1794

/// The caption band: a paper stripe laid ACROSS the picture, not a floor under it. Its bottom
/// edge is the safe area's bottom edge, so at the guaranteed crop the band runs to the bottom of
/// frame and the layout is simply picture-over-words; at any wider crop the capture resumes below
/// it and the frame stays full of app instead of turning into a field of empty paper. That was
/// the difference between a composed page and an unfinished one, and it is only visible at the
/// full 3840x2560 — which is exactly why it had to be rendered and looked at rather than reasoned
/// about.
const SHELF_Y = 1504;
const SHELF_H = 1794 - SHELF_Y;
/// The picture band, in canvas coordinates. Every shot maps a source rectangle onto exactly
/// this, and whatever else the capture contains spills outside it as bleed.
const BAND = {x: SAFE.x0, y: SAFE.y0, w: SAFE.w, h: SHELF_Y - SAFE.y0}; // 2167 x 739, 2.93:1

const TOTAL = 180;

const PAPER = '#F3EBDC';
const PAPER_LIT = '#F8F2E6';
const INK = '#2C1D10';
const TAG = '#9A7E56';
const RULE = '#DFCFB2';
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

/// The lines are the rewritten set, used as written. Two notes on what is NOT here.
///
/// "The address is enough / 주소 하나면 됩니다" is unused: it belongs to a shot of the Add Feed
/// sheet with a bare site address typed into it, and no such capture exists. The nearest real
/// affordance is the sidebar footer's "+ 피드 추가" button, which is in shot 3 — but that frame
/// also contains the "동기화 폴더" row with its iCloud glyph, and between a line that would be
/// asserting an unphotographed feature and a line the pixels actually prove, the pixels win.
///
/// There is no translation shot. See the note above `SHOTS`.
const COPY = {
  en: {
    c1: 'A list that ends',
    c2: 'No one else put these here',
    c3: 'Your library is a folder you own',
    c4: 'Then it gets out of the way',
    end: 'The reading you chose',
    size: 108,
    endSize: 108,
  },
  ko: {
    c1: '끝이 있는 목록입니다',
    c2: '내가 하나씩 넣었습니다',
    c3: '서재는 내 폴더입니다',
    c4: '읽는 동안엔 비켜섭니다',
    end: '고른 글만 남습니다',
    size: 126,
    endSize: 126,
  },
} as const;

type Locale = keyof typeof COPY;

/* ------------------------------------------------------------------ the aperture */

type Rect = {x: number; y: number; w: number; h: number};

/// Map a rectangle of the source image onto the picture band. The source rectangle may run
/// negative or past the file's edges — that simply means the paper shows, which is what the
/// establishing shots want (a window sitting on a page) and what the punch-ins never hit
/// (they are entirely interior).
const framed = (src: {w: number; h: number}, r: Rect) => {
  const scale = BAND.w / r.w;
  return {
    width: src.w * scale,
    height: src.h * scale,
    left: BAND.x - r.x * scale,
    top: BAND.y - r.y * scale,
  };
};

/// Captures per locale. A localized listing showing another language's screenshots is the same
/// class of mistake as a mock-up, so the two cuts do not share a single PNG.
///
/// Why these files and not the obvious ones, all decided by looking at the frame rather than the
/// filename:
///   - en Mac is 03-library, NOT 01-overview. Every usable band of en__mac__01-overview carries a
///     US immigration-enforcement headline about DNA collection, and its reader's lead image is a
///     visibly AI-generated CRT with garbled text on it. 03-library's list is clean, and all four
///     Mac framings here live in its left third, so the empty "Select an Article" pane that makes
///     that file unusable at full width never enters frame.
///   - en iPhone is 04-starred, NOT 03-reader. The English phone reader contains a film still
///     with two identifiable human faces; the repo has a `make app-store-check-faces` gate that
///     exists to fail exactly that. 04-starred is the cleanest English phone frame in the set and
///     it holds the same shape as the Korean one — status bar, Dynamic Island, a floating circular
///     control, then a large title over body copy — so the two locales cut identically.
///     This is a substitution, not an equivalent: see the report.
const SHOT_SRC = {
  ko: {
    mac: {file: 'shots/ko__mac__01-overview.png', w: 2560, h: 1640},
    ipad: {file: 'shots/ko__ipad-13__02-articles.png', w: 2064, h: 2752},
    phone: {file: 'shots/ko__iphone-6.9__03-reader.png', w: 1320, h: 2868},
  },
  en: {
    mac: {file: 'shots/en__mac__03-library.png', w: 2560, h: 1640},
    ipad: {file: 'shots/en__ipad-13__02-articles.png', w: 2064, h: 2752},
    phone: {file: 'shots/en__iphone-6.9__04-starred.png', w: 1320, h: 2868},
  },
} as const;

type Machine = keyof (typeof SHOT_SRC)['ko'];

/// The picture. Clipped to the band, drop-shadowed only where a screen edge is actually in
/// frame, because a shadow under a full-bleed punch-in is a shadow under nothing.
const Picture: React.FC<{
  locale: Locale;
  src: Machine;
  rect: Rect;
  edged?: boolean;
  /// Source pixels to cut off the left of the file before it is drawn. Anchoring a crop at
  /// source x = 24 positions that column on the layout line but does NOT remove columns 0..23 —
  /// they simply land 27 canvas pixels to its left, inside the safe area. On the iPad captures
  /// those columns are a clipped brown focus ring bleeding off the screen edge, so they have to
  /// be genuinely clipped, not merely pushed.
  clipLeftSrc?: number;
}> = ({locale, src, rect, edged = false, clipLeftSrc = 0}) => {
  const s = SHOT_SRC[locale][src];
  const box = framed(s, rect);
  const cut = (clipLeftSrc * box.width) / s.w;
  return (
    <div
      style={{
        position: 'absolute',
        left: 0,
        top: 0,
        width: W,
        height: H,
        overflow: 'hidden',
      }}
    >
      <Img
        src={staticFile(s.file)}
        style={{
          position: 'absolute',
          left: box.left,
          top: box.top,
          width: box.width,
          height: box.height,
          clipPath: cut > 0 ? `inset(0 0 0 ${cut}px)` : undefined,
          filter: edged ? 'drop-shadow(0 22px 46px rgba(96,70,36,0.20))' : undefined,
        }}
      />
    </div>
  );
};

/// The shelf: the caption, and a tag naming the machine. The tag is the only place the piece
/// says "Mac / iPad / iPhone" — a caption spent on a platform list is a caption wasted, but a
/// 48px label in the corner costs nothing and is the only thing carrying "all three".
const Shelf: React.FC<{
  text: string;
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

/// The only thing in the piece that runs continuously across cuts, so it is the only thing
/// keyed to `startsAt + local`: one slow sweep of warm light over the paper, period exactly 180.
const Paper: React.FC<{global: number}> = ({global}) => {
  const phase = (global / TOTAL) * Math.PI * 2;
  const cx = 50 + Math.cos(phase) * 14;
  return (
    <AbsoluteFill
      style={{
        background: `radial-gradient(120% 90% at ${cx}% 8%, ${PAPER_LIT} 0%, ${PAPER} 62%, #EDE3D0 100%)`,
      }}
    />
  );
};

/* ------------------------------------------------------------------ shot geometry */

/// Source rectangles, in the capture's own pixels, chosen against a written inventory of all 46
/// captures and then rendered and looked at one by one. Each states what the GUARANTEED band
/// must contain; `framed` derives the placement, and whatever else the file holds spills out as
/// bleed. Each is picked so no screen edge lands on a safe-area edge: either the edge sits well
/// inside the box, or the capture bleeds past it.
///
/// THE ANCHOR. Across all four Mac beats the source rectangles are solved so the window's own
/// left edge lands on canvas x = 990 at every magnification — see `macAnchored`. The lens changes
/// from 1.34x to 3.1x and back while that one vertical line does not move, which is what makes
/// four differently-scaled crops read as one window rather than four pictures. The caption is set
/// to the same line, so the type and the window share an edge for the whole piece.
const WINDOW_EDGE = 990;
/// Solve V so that `edge` — the source x a screen's left edge sits at — lands on WINDOW_EDGE at
/// whatever magnification the rectangle implies. Every Mac, iPad and iPhone frame in the piece
/// is solved through this, so all three machines hang off one line, and the caption is set to the
/// same line. On the iPad `edge` is 24 rather than 0, which throws away a strip of empty sidebar
/// padding and, with it, the dimmed sliver that bleeds off the left of every iPad capture.
const anchored = (edge: number, y: number, w: number) => ({
  x: edge - ((WINDOW_EDGE - BAND.x) * w) / BAND.w,
  y,
  w,
  h: (w * BAND.h) / BAND.w,
});
/// The Mac establishing framings additionally pin the window's TOP edge, so shot 1's push and
/// shot 6's pull-back are a zoom anchored on the window's own corner: the corner does not drift,
/// the content grows out of it. A centre-anchored zoom would slide that corner across the safe
/// area boundary and read, for four or five frames, as a cropped window.
const MAC_TOP = 859;
const macCorner = (w: number) => {
  const s = BAND.w / w;
  return anchored(0, -(MAC_TOP - BAND.y) / s, w);
};

const FRAMES = {
  /// Establish: traffic lights, the sidebar with its real counts, three list rows, the reader
  /// beginning. 1.34x — above 1:1, because at the size the store draws this asset a reduction
  /// is illegible and the four-pane "whole window" shot is texture, not information.
  macWideA: macCorner(1617),
  /// ...pushed to 1.75x on the sidebar and list. Same PNG, no cut yet.
  macWideB: macCorner(1240),
  /// The feed section: 피드, then the three subscribed sites with their unread counts. The frame
  /// that says a person built this list, cropped to nothing else. 2.2x, and not more: the feeds'
  /// favicons are 32px bitmaps, and past about 2.4x they visibly pixelate, which is precisely the
  /// kind of detail that makes a real screenshot look like a cheap one.
  macFeedsA: anchored(0, 382, 985),
  macFeedsB: anchored(0, 400, 985),
  /// English subscribes to four feeds, not three, and they run from source y 472 to 760 rather
  /// than 477 to 660 — so the English feed beat needs a taller band and therefore a slightly
  /// wider lens. Every other framing in the piece is shared between the two locales.
  macFeedsEnA: anchored(0, 404, 1114),
  macFeedsEnB: anchored(0, 422, 1114),
  /// The sidebar footer — "+ 피드 추가" and "동기화 폴더" with the iCloud glyph, side by side in
  /// one real control cluster. It sits below every naive band crop of this window. 3.2x, and it
  /// keeps the window's bottom-left rounded corner in shot, which is what stops a 3x detail from
  /// floating free of the window it came out of.
  macFootA: anchored(0, 1400, 680),
  macFootB: anchored(0, 1404, 658),
  /// The pull back out, landing on macWideA exactly.
  macReturnA: macCorner(1290),
  /// iPad: three panes again, unmistakably touch — the search field, iPadOS type, the reader's
  /// own headings. Its screen edge hangs off the same line as the Mac window's.
  ipadA: anchored(24, 170, 1900),
  ipadB: anchored(24, 196, 1900),
  /// iPhone. The band opens on the status bar, the Dynamic Island and the two floating circular
  /// controls — the only unfaked "this is a phone" cue available, since the alternative is to
  /// draw a bezel — and then travels down the article at reading speed.
  phoneA: anchored(0, 60, 1535),
  phoneB: anchored(0, 600, 1535),
  /// The English phone travels further and faster, because row one of that screen (NASA's APOD)
  /// carries a dek that is really a scraped navigation strip — "APOD Science APOD APOD: 2026
  /// August 3 -... Archive Submissions Index Search Calendar RSS" — and a frame that rests on it
  /// reads as a parsing failure. The pan clears it and settles on rows two to four, which are the
  /// best-written list content in the entire English set.
  phoneEnA: anchored(0, 60, 1535),
  phoneEnB: anchored(0, 780, 1535),
} as const;

const tween = (a: Rect, b: Rect, t: number): Rect => ({
  x: lerp(a.x, b.x, t),
  y: lerp(a.y, b.y, t),
  w: lerp(a.w, b.w, t),
  h: lerp(a.h, b.h, t),
});

/* ------------------------------------------------------------------ shots */

/// Shot lengths and transition lengths. sum(shots) - sum(transitions) = 196 - 16 = 180.
///
/// The 1-frame transitions are hard cuts; TransitionSeries has no zero, and a single frame of
/// cross-fade at 30fps is a cut. They fall between the three Mac framings, where the grammar is
/// insert-cutting on one image, and on the iPad->iPhone match cut where the caption is held.
/// The 7- and 6-frame slides fall on the two device changes, where a directional move is the
/// aperture travelling to another machine.
///
/// WHAT IS NOT HERE: translation, the headline feature. There is no honest capture of it. The
/// only two affordances in the whole set are a Settings row labelled 실험실 (which proves a
/// settings screen) and a "번역 중…" badge that the repo's own README explains is the STUCK
/// state shown when there is nothing to translate. The cross-locale pair — a Japanese reader cut
/// against a Korean one — is two different articles by two different authors, and at these
/// magnifications the eye catches that in one glance. So the slot is designed and left empty:
/// dropping shot 3 to 20 frames and shot 6 to 30 frees 20 frames for a 4th-position beat the
/// moment 06-translate-list / 07-translate-reader and a matched translation-OFF "before" exist.
const SHOTS = [34, 26, 24, 34, 38, 40];
const XITIONS = [1, 1, 7, 1, 6];
const STARTS = SHOTS.reduce<number[]>((acc, _, i) => {
  acc.push(i === 0 ? 0 : acc[i - 1] + SHOTS[i - 1] - XITIONS[i - 1]);
  return acc;
}, []);

type ShotProps = {startsAt: number; locale: Locale};

const Stage: React.FC<{
  global: number;
  children: React.ReactNode;
}> = ({global, children}) => (
  <AbsoluteFill>
    <Paper global={global} />
    {children}
  </AbsoluteFill>
);

/// 1. ESTABLISH, and push. Opens at 1.34x with the window's own corner in frame — traffic
/// lights, the sidebar and its real counts, three list rows, the reader beginning — so the first
/// thing a scroller's eye resolves is "a real Mac app with a lot of real content in it". Then it
/// closes to 1.75x, so by the time the caption has landed the type is legible rather than
/// merely dense.
const Shot1: React.FC<ShotProps> = ({startsAt, locale}) => {
  const local = useCurrentFrame();
  const c = COPY[locale];
  const t = ease(local / (SHOTS[0] + 6));
  const cap = ease((local - 5) / 11);
  return (
    <Stage global={startsAt + local}>
      <Picture locale={locale} src="mac" rect={tween(FRAMES.macWideA, FRAMES.macWideB, t)} edged />
      <Shelf text={c.c1} size={c.size} tag="macOS" opacity={cap} rise={(1 - cap) * 18} />
    </Stage>
  );
};

/// 2. INSERT: the feeds. A hard cut, closer lens, same window — the list of sites a person
/// subscribed to, each with the count of what is waiting. The drift is 18 source pixels upward,
/// which at 2.2x is the speed of a list being read, not of a camera being moved.
const Shot2: React.FC<ShotProps> = ({startsAt, locale}) => {
  const local = useCurrentFrame();
  const c = COPY[locale];
  const t = ease(local / (SHOTS[1] + 10));
  const cap = ease((local - 2) / 9);
  return (
    <Stage global={startsAt + local}>
      <Picture locale={locale} src="mac" rect={tween(
          locale === 'en' ? FRAMES.macFeedsEnA : FRAMES.macFeedsA,
          locale === 'en' ? FRAMES.macFeedsEnB : FRAMES.macFeedsB,
          t
        )} edged />
      <Shelf text={c.c2} size={c.size} tag="macOS" opacity={cap} rise={(1 - cap) * 18} />
    </Stage>
  );
};

/// 3. INSERT: the sidebar footer. "+ 피드 추가" and "동기화 폴더" with the iCloud checkmark, at
/// 3x. The claim that the data is a plain folder in a folder you chose is the one no
/// server-backed competitor can make, and this is the only frame in 46 captures that shows it
/// spelled out.
const Shot3: React.FC<ShotProps> = ({startsAt, locale}) => {
  const local = useCurrentFrame();
  const c = COPY[locale];
  const t = ease(local / (SHOTS[2] + 12));
  const cap = ease((local - 2) / 9);
  return (
    <Stage global={startsAt + local}>
      <Picture locale={locale} src="mac" rect={tween(FRAMES.macFootA, FRAMES.macFootB, t)} edged />
      <Shelf text={c.c3} size={c.size} tag="macOS" opacity={cap} rise={(1 - cap) * 18} />
    </Stage>
  );
};

/// 4. iPad. The device change is the slide. Same three panes, a search field, a real article
/// open — and the caption that arrives here is held through the next cut, because the claim
/// belongs to both machines and a caption that survives a cut is the cheapest way to say so.
///
/// Its caption is up almost immediately (`local / 7`) rather than after the transition, because
/// the slide carries the whole composed frame — picture AND band — so a caption that waited for
/// the slide to finish left the band empty for seven frames while two half-images crossed it.
/// Rendering the transition and looking at it was the only way to catch that.
const Shot4: React.FC<ShotProps> = ({startsAt, locale}) => {
  const local = useCurrentFrame();
  const c = COPY[locale];
  const t = ease(local / (SHOTS[3] + 14));
  const cap = ease(local / 7);
  return (
    <Stage global={startsAt + local}>
      <Picture
        locale={locale}
        src="ipad"
        rect={tween(FRAMES.ipadA, FRAMES.ipadB, t)}
        clipLeftSrc={24}
        edged
      />
      <Shelf text={c.c4} size={c.size} tag="iPadOS" opacity={cap} rise={(1 - cap) * 18} />
    </Stage>
  );
};

/// 5. iPhone, and the only motion in the piece that is the product rather than the camera: the
/// aperture travels down the article at reading speed. Caption already up and unchanged from
/// shot 4, so the cut reads as one claim about two machines.
const Shot5: React.FC<ShotProps> = ({startsAt, locale}) => {
  const local = useCurrentFrame();
  const c = COPY[locale];
  const t = ease(local / (SHOTS[4] + 2));
  return (
    <Stage global={startsAt + local}>
      <Picture locale={locale} src="phone" rect={tween(
          locale === 'en' ? FRAMES.phoneEnA : FRAMES.phoneA,
          locale === 'en' ? FRAMES.phoneEnB : FRAMES.phoneB,
          t
        )} edged />
      <Shelf text={c.c4} size={c.size} tag="iPhone" opacity={1} rise={0} />
    </Stage>
  );
};

/// 6. RETURN. Back to the Mac, pulling out to land on shot 1's exact opening framing, with the
/// end line — the same sentence the product page header closes on — clearing the shelf before
/// the last two frames so that 179 and 0 are the same picture under the same empty shelf.
const Shot6: React.FC<ShotProps> = ({startsAt, locale}) => {
  const local = useCurrentFrame();
  const c = COPY[locale];
  const t = ease(local / (SHOTS[5] - 2));
  const inn = ease(local / 8);
  const out = 1 - ease((local - 28) / 10);
  const cap = Math.min(inn, out);
  return (
    <Stage global={startsAt + local}>
      <Picture locale={locale} src="mac" rect={tween(FRAMES.macReturnA, FRAMES.macWideA, t)} edged />
      <Shelf text={c.end} size={c.endSize} tag="macOS" opacity={cap} rise={(1 - inn) * 18} />
    </Stage>
  );
};

/* ------------------------------------------------------------------ the series */

export const StoryA: React.FC<{locale: Locale; guides?: boolean}> = ({locale, guides = false}) => {
  const timing = (n: number) => linearTiming({durationInFrames: n});
  const shot = [Shot1, Shot2, Shot3, Shot4, Shot5, Shot6];
  return (
    <AbsoluteFill style={{background: PAPER}}>
      <TransitionSeries>
        <TransitionSeries.Sequence durationInFrames={SHOTS[0]}>
          {React.createElement(shot[0], {startsAt: STARTS[0], locale})}
        </TransitionSeries.Sequence>
        <TransitionSeries.Transition presentation={fade()} timing={timing(XITIONS[0])} />

        <TransitionSeries.Sequence durationInFrames={SHOTS[1]}>
          {React.createElement(shot[1], {startsAt: STARTS[1], locale})}
        </TransitionSeries.Sequence>
        <TransitionSeries.Transition presentation={fade()} timing={timing(XITIONS[1])} />

        <TransitionSeries.Sequence durationInFrames={SHOTS[2]}>
          {React.createElement(shot[2], {startsAt: STARTS[2], locale})}
        </TransitionSeries.Sequence>
        {/* Device change: the aperture travels. */}
        <TransitionSeries.Transition
          presentation={slide({direction: 'from-right'})}
          timing={timing(XITIONS[2])}
        />

        <TransitionSeries.Sequence durationInFrames={SHOTS[3]}>
          {React.createElement(shot[3], {startsAt: STARTS[3], locale})}
        </TransitionSeries.Sequence>
        {/* Match cut: same claim, same caption, smaller machine. */}
        <TransitionSeries.Transition presentation={fade()} timing={timing(XITIONS[3])} />

        <TransitionSeries.Sequence durationInFrames={SHOTS[4]}>
          {React.createElement(shot[4], {startsAt: STARTS[4], locale})}
        </TransitionSeries.Sequence>
        {/* Travelling back the way we came, so the return reads as a return. */}
        <TransitionSeries.Transition
          presentation={slide({direction: 'from-left'})}
          timing={timing(XITIONS[4])}
        />

        <TransitionSeries.Sequence durationInFrames={SHOTS[5]}>
          {React.createElement(shot[5], {startsAt: STARTS[5], locale})}
        </TransitionSeries.Sequence>
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
          <rect
            x={SAFE.x0 + 86}
            y={SHELF_Y + 40}
            width={SAFE.w - 172}
            height={SAFE_Y1 - SHELF_Y - 60}
            fill="none"
            stroke="#00A0FF"
            strokeWidth={3}
          />
        </svg>
      ) : null}
    </AbsoluteFill>
  );
};
