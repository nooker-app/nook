import React from 'react';
import {AbsoluteFill, Img, interpolate, staticFile, useCurrentFrame} from 'remotion';
import {CANVAS} from '../theme';

/// STORY B — "one session".
///
/// Not six shots of six features. One person, one library, one article, filmed in four moves:
/// they are looking at everything they subscribe to → they pick a single source and the list
/// answers → the same article is open on the iPad → they read down it → the list is there again.
///
/// The whole cut rests on a fact I verified in the pixels rather than assumed:
///
///   ko__mac__01-overview.png and ko__mac__03-library.png are the SAME WINDOW at the SAME
///   GEOMETRY. Sidebar, toolbar, column widths, unread counts — identical to the pixel. The
///   only differences are the selected row (모든 글 → 우아한형제들 기술블로그) and the article
///   list beside it. Held at one fixed crop and swept from the sidebar rightward, they are not
///   two slides: they are a click, filmed.
///
///   ko__ipad-13__02-articles.png and ko__ipad-13__03-reader.png are the same again — same
///   sidebar, same middle column, same selected row — with only the reader column scrolled. So
///   the change is masked to the reader column and let rise into place: that is a person
///   reading, not a cut.
///
///   And the article open on the iPad, 「멀티 어카운트 NACL 차단 자동화 도구 운영 및 개선 경험」,
///   is the third row of the Mac list two beats earlier, in the same feed, in a library with the
///   same three feeds. The Mac→iPad join is a device change, but it is the same session.
///
/// Where the captures do NOT continue each other I have not pretended they do. There is no
/// translation beat here: nothing in the 46 captures shows translation happening, the only
/// visible affordance is a stuck "번역 중…" badge, and a Japanese screenshot under a Korean
/// caption claiming it arrived in your language would be the exact fake this pass exists to
/// escape. The slot is designed (see NOTE ON THE TRANSLATION SLOT at the bottom) and empty.
///
/// LOOP: this is one hand-rolled 180-frame timeline, not a TransitionSeries, so every value is
/// computed from the global frame and there is no shot-local clock to pop. Frame 179 is the
/// opening frame — same image, same camera, no caption — so 179 → 0 is not a cut at all.

const {width: W, height: H} = CANVAS.search;
const SAFE = {
  x0: (W - CANVAS.search.safe.width) / 2,
  y0: (H - CANVAS.search.safe.height) / 2,
  w: CANVAS.search.safe.width,
  h: CANVAS.search.safe.height,
};
const SAFE_X1 = SAFE.x0 + SAFE.w;
const SAFE_Y1 = SAFE.y0 + SAFE.h;

const UI =
  "-apple-system, 'SF Pro Text', 'Apple SD Gothic Neo', 'Helvetica Neue', Helvetica, Arial, sans-serif";
const INK = '#33200F';

const clamp01 = (v: number) => (v < 0 ? 0 : v > 1 ? 1 : v);
const easeOut = (t: number) => 1 - Math.pow(1 - clamp01(t), 3);
const easeInOut = (t: number) => {
  const x = clamp01(t);
  return x < 0.5 ? 4 * x * x * x : 1 - Math.pow(-2 * x + 2, 3) / 2;
};
/// A dissolve that starts and ends on a still: linear cross-fades read as a smear on dense
/// screenshot text, where an eased one reads as one image settling into the other.
const mix = (f: number, a: number, b: number) => easeInOut((f - a) / (b - a));

/* ------------------------------------------------------------------ timing */

/// Two different joins, because two different things are happening at them.
///
///  - selA/selB and scrollA/scrollB join REGISTERED plates, where all but one region is
///    identical. I cross-faded them first and it was still wrong: the one region that does
///    change is six headlines, and six headlines at 50% over six other headlines is grey soup.
///    They are now a sweep and a masked rise respectively, so at every frame the changing
///    region is a moving edge rather than a whole pane of double-exposed text.
///  - padOut/padIn and backOut/backIn are the device change, where nothing is registered at
///    all. Those dip through paper: one dismounts, a beat of the surface both of them are
///    lying on, then the other. It also gives the eye somewhere to rest in a six-second loop
///    that is otherwise wall-to-wall text.
const T = {
  /// the selection moves: 모든 글 → one feed
  selA: 42,
  selB: 58,
  /// Mac gives way to iPad, through paper. Short and overlapped: a full frame of bare paper
  /// in a six-second loop reads as a dropped frame, not as a breath.
  padOut: 89,
  padMid: 97,
  padIn: 105,
  /// the reader column scrolls. Ten frames, not sixteen: a cross-fade between two pages of
  /// body copy is a double exposure however you ease it, so the fix is to spend as little time
  /// as possible in the middle of it and to give the incoming plate enough travel that the
  /// blur reads as movement rather than as two articles printed on top of each other.
  scrollA: 128,
  scrollB: 138,
  /// back to the list we started on — this is the loop. It lands twelve frames early and
  /// holds, so the loop point is a still frame rather than the tail of a move.
  backOut: 152,
  backMid: 160,
  backIn: 168,
};

/// Where the reader column begins, in source pixels, on the iPad captures. Measured off
/// ko__ipad-13__02-articles rather than guessed: the middle column's right rule falls at
/// x = 1135, and everything left of it is identical between the two plates.
const IPAD_READER_X = 1135;

/* ------------------------------------------------------------------ copy */

/// The captions are the rewritten set, verbatim. Three, not six: this cut is one argument
/// (a finite list, that you assembled, that then leaves you alone), and a fourth line would
/// have to be read in under half a second at this length. Shot 5's English is the alternate
/// the writer supplied for exactly this case — "Then" only works after a translation shot, and
/// there is no translation shot here.
const COPY = {
  en: {
    c1: 'A list that ends',
    c2: 'No one else put these here',
    c3: 'It gets out of the way',
  },
  ko: {
    c1: '끝이 있는 목록입니다',
    c2: '내가 하나씩 넣었습니다',
    c3: '읽는 동안엔 비켜섭니다',
  },
} as const;

type Locale = keyof typeof COPY;

/* ------------------------------------------------------------------ captures */

/// Per-locale plates. The ko cut is the reference: it is the only locale whose Mac, iPad and
/// iPhone captures share one library (우아한형제들 기술블로그 / GeekNews / tech.kakao.com), so it
/// is the only one where "same session, second device" is true rather than staged.
///
/// The en cut is deliberately NOT a straight translation of it, and the two divergences are
/// content defects in the English captures, not design choices:
///
///   - en__mac__01-overview carries "ICE Collected Nearly 1M People's DNA Last Year—Including
///     Young Children" as list row four. It sits at source y 648-700, so the Mac crop is
///     shortened to 630 rows to keep it out of frame entirely. That also trims the 6-feed
///     English sidebar mid-row, which reads as a list continuing below — fine.
///   - en__ipad-13__03-reader is unusable: the article body leaks "(opens a new tab)" out of
///     its accessibility markup six times in one screen, and the sticky title bar is drawn on
///     top of a line of italic body text. I looked for a clean band and there isn't one — the
///     litter runs the whole length of the article. So the English reading beat is a slow push
///     into a single clean capture instead of a scroll dissolve. It is the one place where the
///     English cut is weaker than the Korean, and it is a capture problem.
const PLATES = {
  ko: {
    macA: 'shots/ko__mac__01-overview.png',
    macB: 'shots/ko__mac__03-library.png',
    macSize: {w: 2560, h: 1640},
    /// crop origin is negative so the window's own rounded corner and traffic lights sit a
    /// little inside the safe box rather than flush on the crop line.
    macWide: {x: -30, y: -26, w: 1618},
    macNear: {x: -12, y: 18, w: 1478},
    padA: 'shots/ko__ipad-13__02-articles.png',
    padB: 'shots/ko__ipad-13__03-reader.png',
    padSize: {w: 2064, h: 2752},
    padFrom: {x: 22, y: 146, w: 2030},
    padTo: {x: 44, y: 182, w: 1878},
    /// true in this locale: the iPad reader is open on the article that is row three of the
    /// Mac list, in the feed that was just selected.
    scrollDissolve: true,
  },
  en: {
    macA: 'shots/en__mac__01-overview.png',
    macB: 'shots/en__mac__03-library.png',
    macSize: {w: 2560, h: 1640},
    macWide: {x: -34, y: -46, w: 1440},
    macNear: {x: -14, y: -6, w: 1330},
    padA: 'shots/en__ipad-13__02-articles.png',
    padB: 'shots/en__ipad-13__02-articles.png',
    padSize: {w: 2064, h: 2752},
    padFrom: {x: 22, y: 146, w: 2030},
    padTo: {x: 48, y: 198, w: 1856},
    scrollDissolve: false,
  },
} as const;

/* ------------------------------------------------------------------ camera */

type Crop = {x: number; y: number; w: number};

/// A camera on one image: the given source rect is mapped exactly onto the safe box, and the
/// rest of the capture is allowed to run off the canvas as bleed. Two plates given the same
/// crop are registered to the pixel, which is the whole trick this cut is built on — the
/// sidebar does not move while the selection and the list change underneath it.
const Plate: React.FC<{
  src: string;
  size: {w: number; h: number};
  crop: Crop;
  opacity: number;
  settle?: number;
  shadow?: boolean;
  /// Reveal this plate only left of a moving boundary, given in SOURCE pixels. Used for the
  /// selection change: a soft-edged sweep from the sidebar rightward, so the highlight moves
  /// first and the list answers a beat later. A cross-fade there put two different article
  /// lists at 50% each and turned six headlines into grey soup.
  wipeToSrcX?: number;
  /// Reveal this plate only right of a fixed boundary, given in SOURCE pixels. Used to confine
  /// the reader-column change to the reader column, so the sidebar and the article list are
  /// provably untouched while the article scrolls.
  clipFromSrcX?: number;
  /// Hard-clip everything left of this CANVAS x. Only the iPad captures need it, and they need
  /// it for a real defect: 13 of the 20 iPad files carry a clipped brown focus ring bleeding off
  /// the left screen edge at source x 0..19. Cropping past it is not enough, because the whole
  /// image is still drawn — the artefact simply lands in the bleed, where it is still visible at
  /// a wide breakpoint. So it gets cut off at the edge of the guaranteed box.
  clipLeft?: number;
  dy?: number;
}> = ({
  src,
  size,
  crop,
  opacity,
  settle = 1,
  shadow = true,
  wipeToSrcX,
  clipFromSrcX,
  clipLeft,
  dy = 0,
}) => {
  if (opacity <= 0.001) return null;
  const s = SAFE.w / crop.w;
  const left = SAFE.x0 - crop.x * s;
  const top = SAFE.y0 - crop.y * s;
  let mask: string | undefined;
  if (wipeToSrcX !== undefined) {
    const b = wipeToSrcX * s;
    mask = `linear-gradient(90deg, #000 ${Math.round(b - 46)}px, rgba(0,0,0,0) ${Math.round(
      b + 46
    )}px)`;
  } else if (clipFromSrcX !== undefined) {
    const b = clipFromSrcX * s;
    mask = `linear-gradient(90deg, rgba(0,0,0,0) ${Math.round(b - 2)}px, #000 ${Math.round(
      b + 16
    )}px)`;
  }
  const img = (
    <Img
      src={staticFile(src)}
      style={{
        position: 'absolute',
        left: clipLeft === undefined ? left : left - clipLeft,
        top,
        width: size.w * s,
        height: size.h * s,
        opacity,
        // scaled about the centre of the safe box, so a settle never drags the guaranteed
        // region off its own edges
        transform: `translateY(${dy}px) scale(${settle})`,
        transformOrigin: `${SAFE.x0 + SAFE.w / 2 - left}px ${SAFE.y0 + SAFE.h / 2 - top}px`,
        // NB: transformOrigin is expressed against the untranslated `left`, which is why the
        // clip shifts the element rather than the origin.
        WebkitMaskImage: mask,
        maskImage: mask,
        filter: shadow ? 'drop-shadow(0 26px 70px rgba(58,36,18,0.30))' : undefined,
      }}
    />
  );
  if (clipLeft === undefined) return img;
  return (
    <div
      style={{
        position: 'absolute',
        left: clipLeft,
        top: 0,
        width: W - clipLeft,
        height: H,
        overflow: 'hidden',
      }}
    >
      {img}
    </div>
  );
};

const lerpCrop = (a: Crop, b: Crop, t: number): Crop => ({
  x: a.x + (b.x - a.x) * t,
  y: a.y + (b.y - a.y) * t,
  w: a.w + (b.w - a.w) * t,
});

/* ------------------------------------------------------------------ caption */

/// One line, on a paper card, pinned to the BOTTOM-RIGHT corner of the safe box and inset from
/// it, so nothing important ever sits on the crop line.
///
/// It has to sit ON the capture — the safe box is 2167x1029 and a screenshot legible at store
/// scale already needs all of it, so there is no margin outside to put type in. Bottom-right
/// is the only corner that is cheap in every frame this cut uses. I built it bottom-LEFT first
/// and it was wrong in the most expensive way possible: on the beat whose entire point is the
/// blue selected feed row, the card was sitting on the blue selected feed row. Bottom-right
/// costs the third and fourth article rows on the Mac, and the lower third of the reader's
/// body copy on the iPad — in both cases a repeat of what the frame has already said above it.
const Caption: React.FC<{text: string; f: number; from: number; to: number}> = ({
  text,
  f,
  from,
  to,
}) => {
  const appear = easeOut((f - from) / 12);
  const leave = 1 - easeOut((f - (to - 9)) / 9);
  const o = clamp01(Math.min(appear, leave));
  if (o <= 0.002) return null;
  const rise = (1 - appear) * 26;
  return (
    <div
      style={{
        position: 'absolute',
        right: W - SAFE_X1 + 86,
        bottom: H - SAFE_Y1 + 80 - rise,
        opacity: o,
        display: 'flex',
        alignItems: 'stretch',
        borderRadius: 22,
        overflow: 'hidden',
        background: '#FFFAEF',
        boxShadow:
          '0 30px 80px rgba(48,30,14,0.30), 0 4px 16px rgba(48,30,14,0.16), 0 2px 0 rgba(255,255,255,0.8) inset',
      }}
    >
      <div style={{width: 13, background: '#A8763C'}} />
      <div
        style={{
          padding: '32px 62px 40px 48px',
          fontFamily: UI,
          fontSize: 98,
          fontWeight: 600,
          letterSpacing: '-0.02em',
          color: INK,
          whiteSpace: 'nowrap',
          lineHeight: 1.1,
        }}
      >
        {text}
      </div>
    </div>
  );
};

/* ------------------------------------------------------------------ story */

export const StoryB: React.FC<{locale: Locale; guides?: boolean}> = ({
  locale = 'ko',
  guides = false,
}) => {
  const f = useCurrentFrame();
  const P = PLATES[locale];
  const C = COPY[locale];

  /* ---- layer opacities. Everything is a function of the global frame, so nothing has a
          private clock that could restart at a cut, and the last frame can be made to equal
          the first on purpose. */

  // The Mac is on screen twice: the opening two beats, and the return that closes the loop.
  // It leaves to paper and comes back from paper; it never cross-fades with the iPad.
  const macOn =
    f < T.padOut
      ? 1
      : f < T.padMid
      ? 1 - mix(f, T.padOut, T.padMid)
      : f < T.backMid
      ? 0
      : mix(f, T.backMid, T.backIn);
  // Within it, plate B (a feed selected) rises over plate A (모든 글). It is snapped back to 0
  // while the Mac is off screen, so the return lands on plate A — the frame the video opened
  // on — and frame 179 is frame 0.
  const macBOn = f > T.selA && f < T.padMid ? 1 : 0;
  // …and it arrives as a sweep rather than a fade. -60 keeps the boundary off the window's own
  // left edge at the start; 2000 carries it past the right edge of the safe box.
  const wipe = interpolate(easeInOut((f - T.selA) / (T.selB - T.selA)), [0, 1], [-60, 2000]);

  const padOn =
    f < T.padMid
      ? 0
      : f < T.padIn
      ? mix(f, T.padMid, T.padIn)
      : f < T.backOut
      ? 1
      : 1 - mix(f, T.backOut, T.backMid);
  const padBOn = P.scrollDissolve ? mix(f, T.scrollA, T.scrollB) : 0;

  /* ---- cameras. The Mac camera pushes in across its two beats and is returned to its exact
          opening value while it is invisible, so the last frames and the first are the same
          framing to within a fraction of a percent. */
  const macT =
    f <= T.padMid
      ? easeInOut(f / T.padMid) // 0 -> 1 push in
      : f <= T.backMid
      ? 1 - clamp01((f - T.padMid) / (T.backMid - T.padMid)) // reset, unseen
      : 0;
  const macCrop = lerpCrop(P.macWide, P.macNear, macT);

  const padT = easeInOut(clamp01((f - T.padMid) / (T.backOut - T.padMid)));
  const padCrop = lerpCrop(P.padFrom, P.padTo, padT);

  // Each plate settles into place rather than simply appearing, and drifts away rather than
  // simply vanishing: about 2% of scale spent over each handover. It is what stops the paper
  // dip reading as a dropped frame.
  const macSettle =
    f < T.padOut
      ? 1
      : f < T.padMid
      ? 1 + 0.022 * mix(f, T.padOut, T.padMid)
      : 0.982 + 0.018 * clamp01((f - T.backMid) / 14);
  const padSettle =
    f < T.backOut
      ? 0.982 + 0.018 * clamp01((f - T.padMid) / 14)
      : 1 + 0.022 * mix(f, T.backOut, T.backMid);

  // The scroll: the reader column, and only the reader column, rises into place.
  const scrollT = P.scrollDissolve ? mix(f, T.scrollA, T.scrollB) : 0;
  const scrollDy = (1 - scrollT) * 132;

  return (
    <AbsoluteFill style={{backgroundColor: '#F6E9CE'}}>
      {/* Paper. Only the bleed outside the capture ever shows it, but the Mac plates are
          window-only PNGs with transparent rounded corners, so the top-left of the frame is a
          real window lying on a real surface rather than a screenshot pasted on a colour. */}
      <AbsoluteFill
        style={{
          background:
            'radial-gradient(120% 90% at 22% 8%, #FFFCF3 0%, #FBEFD4 46%, #EAD3A4 100%)',
        }}
      />

      <Plate src={P.macA} size={P.macSize} crop={macCrop} opacity={macOn} settle={macSettle} />
      <Plate
        src={P.macB}
        size={P.macSize}
        crop={macCrop}
        opacity={macOn * macBOn}
        settle={macSettle}
        wipeToSrcX={f < T.selB ? wipe : undefined}
      />

      <Plate
        src={P.padA}
        size={P.padSize}
        crop={padCrop}
        opacity={padOn}
        settle={padSettle}
        clipLeft={SAFE.x0 - 4}
      />
      {P.scrollDissolve ? (
        <Plate
          src={P.padB}
          size={P.padSize}
          crop={padCrop}
          opacity={padOn * padBOn}
          settle={padSettle}
          clipFromSrcX={IPAD_READER_X}
          clipLeft={SAFE.x0 - 4}
          dy={scrollDy}
        />
      ) : null}

      {/* THE FALLOFF, and it is not decoration — it is a content fix I only found by looking at
          the full canvas instead of the safe box.
          ko__mac__03-library devotes its right-hand two thirds to the empty state 글 선택 /
          "목록에서 읽을 글을 골라 보세요." At the scale this cut runs the Mac at, that lands in the
          bleed at canvas x ≈ 3100 — outside the guaranteed box, but plainly visible at any wide
          breakpoint, and "no article selected" is the last thing this asset should be saying
          out of the corner of its mouth. There is no crop that removes it, because the sidebar
          has to stay pinned at the left of the safe box.
          So the capture is lit inside the box and falls away into the paper it is lying on. The
          gradient starts at exactly SAFE_X1 and touches nothing that is guaranteed to be shown. */}
      <div
        style={{
          position: 'absolute',
          left: SAFE_X1,
          top: 0,
          width: W - SAFE_X1,
          height: H,
          background:
            'linear-gradient(90deg, rgba(250,238,213,0) 0%, rgba(249,236,209,0.72) 42%, rgba(247,233,203,0.99) 78%, #F6E8C9 100%)',
          pointerEvents: 'none',
        }}
      />
      <div
        style={{
          position: 'absolute',
          left: 0,
          top: SAFE_Y1,
          width: W,
          height: H - SAFE_Y1,
          background:
            'linear-gradient(180deg, rgba(250,238,213,0) 0%, rgba(249,236,209,0.62) 48%, rgba(247,233,203,0.97) 86%, #F6E8C9 100%)',
          pointerEvents: 'none',
        }}
      />
      <div
        style={{
          position: 'absolute',
          left: 0,
          top: 0,
          width: SAFE.x0,
          height: H,
          background:
            'linear-gradient(270deg, rgba(250,238,213,0) 0%, rgba(249,236,209,0.80) 40%, #F6E8C9 82%)',
          pointerEvents: 'none',
        }}
      />
      <div
        style={{
          position: 'absolute',
          left: 0,
          top: 0,
          width: W,
          height: SAFE.y0,
          background:
            'linear-gradient(0deg, rgba(250,238,213,0) 0%, rgba(249,236,209,0.80) 44%, #F6E8C9 84%)',
          pointerEvents: 'none',
        }}
      />

      <div
        style={{
          position: 'absolute',
          left: SAFE_X1,
          top: 0,
          width: W - SAFE_X1,
          height: H,
          opacity: macOn * macBOn,
          background:
            'linear-gradient(90deg, rgba(250,238,213,0) 0%, rgba(248,235,207,0.90) 24%, #F6E8C9 52%)',
          pointerEvents: 'none',
        }}
      />

      {/* Paper tooth. Three percent of noise over a 3840px gradient is the difference between
          "warm paper" and "a CSS gradient", and it costs nothing at this size. */}
      <svg width={W} height={H} style={{position: 'absolute', left: 0, top: 0, opacity: 0.05}}>
        <filter id="storyb-grain">
          <feTurbulence type="fractalNoise" baseFrequency="0.9" numOctaves={3} seed={7} />
          <feColorMatrix type="saturate" values="0" />
        </filter>
        <rect width={W} height={H} filter="url(#storyb-grain)" />
      </svg>

      {/* A warm shade in the caption's corner only. The captures are near-white down there and
          98px of ink on a paper card needs the frame to darken slightly under it — but a bar
          across the whole width would read as a subtitle track, which is the one thing this
          asset must not look like. */}
      <div
        style={{
          position: 'absolute',
          right: 0,
          bottom: 0,
          width: 1900,
          height: 900,
          background:
            'radial-gradient(120% 120% at 100% 100%, rgba(70,44,20,0.20) 0%, rgba(70,44,20,0.09) 45%, rgba(70,44,20,0) 72%)',
          pointerEvents: 'none',
        }}
      />

      <Caption text={C.c1} f={f} from={6} to={50} />
      <Caption text={C.c2} f={f} from={56} to={94} />
      <Caption text={C.c3} f={f} from={108} to={156} />

      {guides ? (
        <svg width={W} height={H} style={{position: 'absolute', left: 0, top: 0}}>
          <rect
            x={SAFE.x0}
            y={SAFE.y0}
            width={SAFE.w}
            height={SAFE.h}
            fill="none"
            stroke="#D2453B"
            strokeWidth={6}
          />
          <rect
            x={SAFE.x0 + 60}
            y={SAFE.y0 + 60}
            width={SAFE.w - 120}
            height={SAFE.h - 120}
            fill="none"
            stroke="#D2453B"
            strokeWidth={3}
            strokeDasharray="24 18"
            opacity={0.6}
          />
        </svg>
      ) : null}
    </AbsoluteFill>
  );
};

/* ------------------------------------------------------------------------------------------
   NOTE ON THE TRANSLATION SLOT — the shot this cut is missing, and where it goes.

   The action this cut films is "pick a source, open the piece, read it". The action the brief
   describes has one more move in it: the piece is in another language, and it becomes readable.
   That move is not in the 46 captures, and the two ways of faking it both fail:

     - the cross-locale pair (ja reader → ko reader) is two different articles by two different
       authors with two different layouts. At the 1.06x this cut runs the iPad at, the eye
       catches it on the second loop, and a looping asset gets a second loop for free.
     - the only translation affordances that exist are the Settings > 실험실 row (a row label)
       and the "번역 중…" badge at the bottom of ko__iphone-6.9__02-articles, which the repo
       README itself documents as the STUCK state shown when there is nothing to translate.

   The slot is frames 128-148, where the reader column currently dissolves from
   ko__ipad-13__02-articles to ko__ipad-13__03-reader. That dissolve is already exactly the
   right shape for it: one crop, two plates, everything but the reader column held still. To
   drop translation in, set padA/padB to a matched pair and nothing else changes:

     make app-store-capture LOCALE=ko NAME=06-translate-off      (the article, English, unread)
     make app-store-capture LOCALE=ko NAME=07-translate-reader   (the SAME article, same scroll
                                                                  offset, translated)

   Both must come from one uninterrupted simulator run so the clock, the status bar, the feed
   counts and the scroll position are pixel-identical; anything else and the dissolve flickers
   in exactly the way this cut is built to avoid. With that pair in hand the caption for the
   beat is already written: "무슨 말로 쓰였든 읽힙니다" / "It arrives in your language".
------------------------------------------------------------------------------------------- */
