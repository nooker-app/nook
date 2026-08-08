import React from 'react';
import {AbsoluteFill, Img, staticFile, useCurrentFrame} from 'remotion';
import {CANVAS} from '../theme';

/* ==========================================================================================
   STORY B2 — "the column"  ·  900 frames / 30fps / 3840x2560 / silent / loops
   ==========================================================================================

   THE CRAFT PROBLEM, NAMED
   ------------------------
   An iPhone capture is 1320x2868 — 1:2.17 portrait. The only region the store guarantees is
   2167x1029 — 2.1:1 landscape. A whole phone scaled to 1029px of height is 474px wide: 22% of
   the guaranteed box, and its body copy lands at roughly 10 canvas px. That is not a product
   video, it is a thumbnail with a lot of wallpaper.

   What this file does instead: ONE fixed rounded card, 980x1188, standing at the right of the
   guaranteed box, and the phone screen moves BEHIND it. The card is a window onto the screen
   at 0.742x — about 1400 source pixels tall at rest — so a headline is ~33 canvas px and body
   copy ~30. That is 3x the legibility of a whole-phone layout. The 984px left over on the left
   is not leftover: it is the type column, and the caption never sits on the screenshot.

   The card is 1188 tall against a 1029 guaranteed box and is deliberately NOT centred on it
   (top 646, bottom 1834, against a box of 765.5..1794.5). It hangs 119px above the guaranteed
   box and 40px below. Two reasons, both load-bearing:
     - at the guaranteed crop the card runs off the top and bottom edges, so it reads as a tall
       column of screen rather than a squarish tile;
     - the asymmetry drags the guaranteed band DOWN inside the card, which is the only way the
       Settings beat can put 동기화 폴더 변경 / Change Sync Folder — a row that lives 85% of the
       way down that screen — inside the box at all. See BEAT 4.

   WHAT I REJECTED, AND WHAT IT LOOKED LIKE — see the block at the bottom of this file.

   THE LANE
   --------
   Held frames and very slow moves. Four screens, each on for five to seven seconds, joined by
   moves slow enough that the eye does not register a cut. The pans run at 2-4 canvas px per
   frame; the pushes are 6% over five seconds. The line between calm and inert is that nothing
   is ever completely still except at the loop seam, and every beat's move is the move the
   screen itself implies: the library gets a push (there is nothing to scroll — the list ends),
   the article list gets a scroll, the reader gets a settle, Settings gets a scroll that lands
   on the one row the caption is about.

   THE BEAT SHEET
   --------------
     f0-244    LIBRARY          ko 3 feeds / en 6.  push 1.000 -> 1.020, no pan.
                                caption 1  f70-200
     f214-244  join 1           soft wipe UPWARD (crosses the library's empty cream first)
     f214-430  ARTICLES         scroll 990 -> 1500 source (ko), push -> 1.06.
                                caption 2  f262-390
     f400-430  join 2           ko: a band opening out of the shared headline
                                en: soft wipe downward (no continuity to claim)
     f400-618  READER (ko)      the push unwinds 1.064 -> 1.000; the page creeps up 58px.
                                caption 3  f452-582      · en runs STARRED here, silent
     f588-618  join 3           soft wipe downward
     f588-808  SETTINGS         scroll 1500 -> 2005 + push -> 1.06, lands f730, HELD to f808.
                                caption 4  f664-774
     f778-808  join 4           soft wipe UPWARD — the only one that runs back the way it came
     f778-899  LIBRARY again    the opening frame, unwinding 1.012 -> 1.000
                                close      f806-882
   f0-70 and f882-899 carry no type, and they are the two ends that meet.

   LOOP
   ----
   One hand-rolled timeline. No TransitionSeries, no shot-local clock, no spring(). Every value
   is a function of the global frame, so nothing can pop at a join or at the seam. Frame 899 is
   frame 0 to the pixel: the same capture, the same camera (C=985/1000, z=1.000), no caption.
   f882-899 and f0-70 are both untyped, so 899 -> 0 meets under the same conditions.
========================================================================================== */

const {width: W, height: H} = CANVAS.search;
const SAFE = {
  x0: (W - CANVAS.search.safe.width) / 2, //  836.5
  y0: (H - CANVAS.search.safe.height) / 2, //  765.5
  x1: (W + CANVAS.search.safe.width) / 2, // 3003.5
  y1: (H + CANVAS.search.safe.height) / 2, // 1794.5
};

/// The card. Fixed for the whole film — it is the one object in the frame, and moving it would
/// be the churn this lane exists to avoid.
const CARD = {x: 1950, y: 646, w: 980, h: 1188, r: 46};
const SHOT = {w: 1320, h: 2868};
/// canvas px per source px at z = 1
const S = CARD.w / SHOT.w; // 0.742424…

/// The type column: from the left edge of the guaranteed box to 70px short of the card.
const COL = {x: SAFE.x0 + 40, w: CARD.x - (SAFE.x0 + 40) - 74}; // 876.5 .. 1876
const UI =
  "-apple-system, 'SF Pro Display', 'SF Pro Text', 'Apple SD Gothic Neo', 'Helvetica Neue', Helvetica, Arial, sans-serif";
const INK = '#33200F';
const ACCENT = '#A8763C';

const clamp01 = (v: number) => (v < 0 ? 0 : v > 1 ? 1 : v);
const easeOut = (t: number) => 1 - Math.pow(1 - clamp01(t), 3);
const easeInOut = (t: number) => {
  const x = clamp01(t);
  return x < 0.5 ? 4 * x * x * x : 1 - Math.pow(-2 * x + 2, 3) / 2;
};
/// Linear ramps for the CAMERA, on purpose. An eased pan accelerates and decelerates at every
/// beat boundary, which is exactly where the joins are — the eye reads a stop as a cut. A
/// constant velocity carried straight through a dissolve is what makes the dissolve disappear.
const ramp = (f: number, a: number, b: number, va: number, vb: number) =>
  va + (vb - va) * clamp01((f - a) / (b - a));

/* ------------------------------------------------------------------ timing */

/// Every join lands in a gap between captions. The type never crosses a cut, so a join never
/// has to compete with something being read.
const T = {
  j1: [214, 244], // library  -> articles
  j2: [400, 430], // articles -> reader (ko) / starred (en)
  j3: [588, 618], // reader   -> settings
  j4: [778, 808], // settings -> library (the loop)
} as const;

/// Caption in/out points, verbatim from the writer's atFrame + holdFrames.
const CUE = {
  c1: [70, 200],
  c2: [262, 390],
  c3: [452, 582],
  c4: [664, 774],
  close: [806, 882],
} as const;

/* ------------------------------------------------------------------ copy */

/// The rewritten set, as written, including the line breaks. The ONLY thing I changed is SIZE:
/// the two long lines ("아무 일도 일어나지 않는다", "It lives in a folder you picked") are set
/// smaller so they fit the column on one line rather than being re-broken. That is the order the
/// brief gives — change the size or the layout before you change the writer's break.
const COPY = {
  ko: {
    c1: ['추천으로 들어온 건', '하나도 없다'],
    c2: ['다 읽으면 그걸로 끝'],
    c3: ['읽는 동안은', '아무 일도 일어나지 않는다'],
    c4: ['내 폴더에 그대로 있다'],
    close: ['읽을 것은 내가 고른다'],
    cap: 100,
    track: '-0.028em',
  },
  en: {
    c1: ['You went looking', 'for each of these'],
    c2: ['This one you can finish'],
    /// EN c3 is never shown — there is no clean English iPhone reader capture. See BEAT 3.
    c3: ['Nobody else is on this page'],
    c4: ['It lives in a folder you picked'],
    close: ['The reading you chose'],
    cap: 92,
    track: '-0.022em',
  },
} as const;

type Locale = keyof typeof COPY;

/* ------------------------------------------------------------------ captures & cameras

   Every plate is an iPhone 6.9" capture. No Mac anywhere in this file: this is an iOS listing.
   No iPad either — I had one honest use for it and rejected it (see the bottom of the file).

   A camera is (C, z): C is the SOURCE y that lands on the card's centre, z is the push. The
   card's own geometry then decides what is guaranteed. At z the card sees
        source y in  [C - 594/(S·z),  C + 594/(S·z)]
   and the store guarantees only
        source y in  [C - 474.5/(S·z), C + 554.5/(S·z)]
   because the card's centre (canvas y 1240) sits 40px above the guaranteed box's centre. Every
   number below was solved against those two intervals and then checked by rendering the frame
   and looking at it.                                                                        */

const plates = (locale: Locale) => {
  const ko = locale === 'ko';
  return {
    /* ---- BEAT 1 · LIBRARY · f0-244 ------------------------------------------------------
       ko__iphone-6.9__01-library: 모든 글, then 우아한형제들 기술블로그 / GeekNews /
       tech.kakao.com with 10 / 45 / 10 unread. Three feeds a person typed in, and then the
       screen simply stops — a third of the card is the app's own cream with nothing in it.
       That emptiness is the beat: "추천으로 들어온 건 하나도 없다".
       en__iphone-6.9__01-library has six (Ars Technica, Daring Fireball, Hacker News, NASA,
       Quanta, The Verge) and fills the card exactly. Both are true; neither caption counts
       feeds, which is why the same line survives the locale change.
       Camera: C fixed, z 1.000 -> 1.020. There is nothing to scroll on this screen, so the
       move is a push, and it is the slowest in the film (2% over eight seconds).
       Window at z=1: ko 185..1785, en 200..1800 — the status bar (source y 42-151) is out of
       frame in every beat of this film. It never scrolls in real iOS, so panning it would be
       the one piece of motion here that lies about the app. */
    lib: {
      src: ko ? 'shots/ko__iphone-6.9__01-library.png' : 'shots/en__iphone-6.9__01-library.png',
      C: ko ? 985 : 1000,
    },
    /* ---- BEAT 2 · ARTICLES · f214-430 ---------------------------------------------------
       A scroll, 2.5 source px a frame, plus a 6% push. It ends framed so that the third row —
       「Diátaxis - 기술 문서 작성을 위한 체계적 접근법」 — sits 60px below the top of the
       guaranteed box, because that is the article the reader capture is open on. See BEAT 3.
       Cropped OUT, deliberately, in ko: 「BMW, 구매한 차량 화면에 Spider-Man 광고 배포」 at
       source y 2368-2544 and the "번역 중…" badge at 2782 (which the repo README documents as
       the STUCK state shown when there is nothing to translate — a stalled spinner is worse
       evidence than silence). The window never reaches 2360 at any frame of this beat.
       Cropped OUT in en: "Angela Nissel faces down grief with a laugh" and its dek, which
       names a memoir called "Good Grief, Pass the Bread, Mom Is Dead". Source y 476-649; the
       en window never starts above 655. */
    art: {
      src: ko ? 'shots/ko__iphone-6.9__02-articles.png' : 'shots/en__iphone-6.9__02-articles.png',
      C0: ko ? 990 : 1480,
      C1: ko ? 1500 : 1620,
    },
    /* ---- BEAT 3 · READER (ko) / STARRED (en) · f400-618 ---------------------------------
       ko__iphone-6.9__03-reader is open on the Diátaxis piece: the SAME article that is row
       three of the list in beat 2, in the same library. So the join is not a cut and not a
       claim — it is a tap, filmed. The two plates are cross-dissolved with the headline pinned
       to one canvas position in both, so the only thing that does not move through the
       dissolve is the words you were just reading; the article grows around them.
       That match is why C_reader = C_articles - 566 exactly: source y 974 (list headline top)
       and source y 408 (reader headline top) have to land on the same pixel.

       EN HAS NO READER BEAT, and that is a capture defect, not a design choice.
       en__iphone-6.9__03-reader is a Nolan review whose body reads "The manufactured online
       trolling/culture war campaign that preceded the film's release…", names actors, and
       carries a film still with identifiable faces below the fold — the repo has a
       make app-store-check-faces gate for precisely that. en__ipad-13__03-reader leaks
       "(opens a new tab)" out of its accessibility markup six times in one screen, which would
       sit directly under a caption claiming nothing else is on the page. I looked for a clean
       band in both and there is not one.
       So en runs en__iphone-6.9__04-starred here, SILENT, exactly as the writer specified
       ("영어 컷은 이 비트를 무자막으로 돌리고 캡션 3개 + 클로즈로 간다"). It is clean —
       APOD / Fender / SwiftUI After 7 Years / The myth of Snow Leopard / NASA skywatching —
       and four yellow stars against real headlines are a sentence on their own.
       REQUIRED CAPTURE: make app-store-capture LOCALE=en NAME=06-reader-clean — a Quanta
       Magazine piece open in the iPhone reader. With it, en gets its reader and its third
       caption and this asymmetry disappears. */
    third: {
      src: ko ? 'shots/ko__iphone-6.9__03-reader.png' : 'shots/en__iphone-6.9__04-starred.png',
      C0: ko ? 0 : 990, // ko is derived from the match; en is free
      C1: ko ? 1030 : 1010,
    },
    /* ---- BEAT 4 · SETTINGS · f588-808 ---------------------------------------------------
       The only claim here that a cloud-backed competitor could not copy, and the screen proves
       it: 동기화 폴더 변경 / Change Sync Folder, a real row at source y 2417-2490.
       That row is 85% of the way down a 2868px screen and there is an untidy zone right under
       it — the floating tab pill at 2615-2745 bisects "OPML 가져오기". Every framing that keeps
       the pill out of the card also pins the sync row to the very bottom edge of the guaranteed
       box, within about ten source pixels of falling out of it; I solved it three ways and
       measured all three. The one that works is to let the pill IN, whole, with the app's own
       cream under it — it is real navigation, it gives the frame a bottom, and it puts the sync
       row 170px clear of the safe edge. The bisected OPML label is the one blemish in this cut
       and it is what the shipping app actually looks like.
       Camera: C 1500 -> 2005 with z 1.000 -> 1.060, finishing at f730 and then HELD for 78
       frames while the caption is up. The push is the "into a row" move: it lands on the row,
       it does not sail past it. */
    set: {
      src: ko ? 'shots/ko__iphone-6.9__05-settings.png' : 'shots/en__iphone-6.9__05-settings.png',
      C0: 1500,
      C1: 2005,
    },
  } as const;
};

/* ------------------------------------------------------------------ plate */

type PlateProps = {
  src: string;
  C: number;
  z: number;
  opacity?: number;
  /// Soft-edged reveal, 0 = hidden, 1 = fully revealed. A 200px-tall gradient boundary crossing
  /// the card. I built the joins as straight cross-fades first and they were wrong in the way
  /// StoryB's author found: two pages of dense Korean text at 50% each is not a dissolve, it is
  /// grey soup. Rendered at 400px of softness it was still soup — a third of the card was
  /// double-exposed at once. At 200 the mush is a 130px band on a 1188px card and it reads as an
  /// edge, which is what it is. Direction is chosen per join by where the OUTGOING plate is
  /// cheapest: the library's bottom third is the app's own empty cream, so the two joins that
  /// touch it run upward and cross that cream first.
  wipe?: {p: number; up?: boolean};
  /// The other kind of join, used once. Instead of a boundary crossing the card, a band opens
  /// outward from one canvas y — the y where the headline of the row and the headline of the
  /// article sit on the same pixel. So the first thing revealed is the only thing that is
  /// identical in both plates, and the swap there is invisible; the article then grows out of
  /// its own headline. See BEAT 3.
  band?: {yc: number; p: number};
};

const SOFT = 100;

const Plate: React.FC<PlateProps> = ({src, C, z, opacity = 1, wipe, band}) => {
  if (opacity <= 0.002) return null;
  const eff = S * z;
  let mask: string | undefined;
  if (band) {
    /// h must never go negative: with h < 0 the four gradient stops fall out of order, CSS
    /// clamps them, and the "band" silently becomes a one-sided wedge opening downward. That is
    /// what the first render of this join actually did — it revealed the article's SECOND title
    /// line over the row's dek and the match never appeared on screen. Found it by looking at
    /// frames 402 and 406, not by reading the code.
    const h = Math.max(0, band.p * 1250);
    const {yc} = band;
    mask =
      `linear-gradient(180deg, rgba(0,0,0,0) ${Math.round(yc - h - SOFT)}px, ` +
      `#000 ${Math.round(yc - h)}px, #000 ${Math.round(yc + h)}px, ` +
      `rgba(0,0,0,0) ${Math.round(yc + h + SOFT)}px)`;
  } else if (wipe) {
    const b = -SOFT + wipe.p * (CARD.h + 2 * SOFT);
    mask = `linear-gradient(${wipe.up ? 0 : 180}deg, #000 ${Math.round(
      b - SOFT
    )}px, rgba(0,0,0,0) ${Math.round(b + SOFT)}px)`;
  }
  return (
    <div
      style={{
        position: 'absolute',
        inset: 0,
        opacity,
        WebkitMaskImage: mask,
        maskImage: mask,
      }}
    >
      <Img
        src={staticFile(src)}
        style={{
          position: 'absolute',
          left: CARD.w / 2 - (SHOT.w / 2) * eff,
          top: CARD.h / 2 - C * eff,
          width: SHOT.w * eff,
          height: SHOT.h * eff,
        }}
      />
    </div>
  );
};

/* ------------------------------------------------------------------ caption */

/// Rough advance widths, in ems, so a line can be fitted to the column without a measuring
/// pass. Hangul is monospaced-ish at 1.0; Latin is not, so the common offenders are called out.
/// Checked against rendered stills at 600px and at full size.
const emOf = (ch: string) => {
  if (ch === ' ') return 0.3;
  const c = ch.codePointAt(0) ?? 0;
  if (c >= 0x1100 && c <= 0x11ff) return 1.0;
  if (c >= 0x3000 && c <= 0x9fff) return 1.0;
  if (c >= 0xac00 && c <= 0xd7a3) return 1.0;
  if ('iljItf1.,;:!|\'’'.includes(ch)) return 0.31;
  if ('mwMW'.includes(ch)) return 0.87;
  if ('ABCDEFGHJKLNOPQRSTUVXYZ'.includes(ch)) return 0.68;
  return 0.545;
};
const emWidth = (s: string) => [...s].reduce((a, ch) => a + emOf(ch), 0);

/// One caption. Bare type on the paper, never on the capture — the whole reason the layout
/// spends 984px on a column. A card behind the text (StoryB's solution) exists only because
/// there the type had to sit on a screenshot; here it would be a box drawn for no reason.
const Caption: React.FC<{
  lines: readonly string[];
  cue: readonly [number, number] | readonly number[];
  f: number;
  cap: number;
  track: string;
  weight?: number;
}> = ({lines, cue, f, cap, track, weight = 600}) => {
  const [from, to] = cue;
  const appear = easeOut((f - from) / 18);
  const leave = 1 - easeOut((f - (to - 15)) / 15);
  const o = clamp01(Math.min(appear, leave));
  if (o <= 0.003) return null;

  const widest = Math.max(...lines.map(emWidth));
  const size = Math.min(cap, (COL.w * 0.985) / widest);
  const lh = 1.2;
  const blockH = lines.length * size * lh;
  const rule = 9;
  const gap = 54;
  /// BOTTOM-anchored, not centred. Centred was the first version and it left the bottom-left
  /// quarter of every frame dead while the card's own weight sits high. Hung from a fixed
  /// baseline the type makes a diagonal with the screen — mark top-left, statement bottom-left,
  /// app right — and a one-line card and a two-line card end on the same line instead of
  /// wandering up and down between beats.
  const top = 1596 - (blockH + rule + gap);
  const rise = (1 - appear) * 30;

  return (
    <div
      style={{
        position: 'absolute',
        left: COL.x,
        top: top + rise,
        width: COL.w,
        opacity: o,
      }}
    >
      <div
        style={{
          width: 118 * appear,
          height: 9,
          borderRadius: 5,
          background: ACCENT,
          marginBottom: gap,
          opacity: 0.92,
        }}
      />
      {lines.map((line, i) => (
        <div
          key={i}
          style={{
            fontFamily: UI,
            fontSize: size,
            lineHeight: lh,
            fontWeight: weight,
            letterSpacing: track,
            color: INK,
            whiteSpace: 'nowrap',
            opacity: clamp01((f - (from + i * 5)) / 16),
          }}
        >
          {line}
        </div>
      ))}
    </div>
  );
};

/* ------------------------------------------------------------------ story */

export const StoryB2: React.FC<{locale: Locale; guides?: boolean}> = ({
  locale = 'ko',
  guides = false,
}) => {
  const f = useCurrentFrame();
  const P = plates(locale);
  const C = COPY[locale];
  const isKo = locale === 'ko';

  /* ---- cameras. All linear in f, all defined from the global frame. ---- */

  // BEAT 1 — library. Push only, 1.000 -> 1.020 across f0..244.
  const libC = P.lib.C;
  const libZ = 1 + 0.02 * clamp01(f / 244);

  // BEAT 2 — articles. One continuous scroll+push from f214, still moving when it hands over.
  const artC = ramp(f, 214, 415, P.art.C0, P.art.C1);
  const artZ = ramp(f, 214, 415, 1, 1.06);

  // BEAT 3 — the reader (ko) or starred (en).
  //   ko: through the whole j2 window the reader IS the article list — same headline, same
  //       pixel — so its camera is derived, not authored: C = C_articles - 566.
  //   After the join it releases: the push unwinds 1.064 -> 1.000 over 110 frames while the
  //   page creeps up 58 source px. That unwind is the beat's whole move, and it is what a page
  //   settling in front of you looks like.
  const j2End = T.j2[1];
  const thirdHandoff = isKo ? ramp(j2End, 214, 415, P.art.C0, P.art.C1) - 566 : P.third.C0;
  const thirdC = isKo
    ? f < j2End
      ? artC - 566
      : ramp(f, j2End, 618, thirdHandoff, P.third.C1)
    : ramp(f, T.j2[0], 618, P.third.C0, P.third.C1);
  const thirdZ = isKo
    ? f < j2End
      ? artZ
      : 1.064 - 0.064 * easeOut((f - j2End) / 110)
    : 1.06 - 0.06 * easeOut((f - T.j2[0]) / 130);

  // BEAT 4 — settings. Scroll + push f588..730, then held to f808.
  const setC = ramp(f, 588, 730, P.set.C0, P.set.C1);
  const setZ = ramp(f, 588, 730, 1, 1.06);

  // BEAT 5 — the library again, and this is the loop. It arrives at z 1.012 and unwinds to
  // exactly 1.000 at f899, which is exactly where f0 starts. Same capture, same C, same z, no
  // caption on either side. 899 -> 0 is not a cut; it is the same frame twice.
  const lib2C = P.lib.C;
  const lib2Z = ramp(f, 778, 899, 1.012, 1.0);

  /* ---- joins ---- */
  /// Where the row's headline and the article's headline meet, in card-local canvas pixels.
  /// Derived, never typed in. Source y 408-584 is the reader's title block and source y 974 is
  /// the top of the same words in the list; the cameras are solved so those tops coincide, and
  /// the band opens from the CENTRE of the title block (source 496) so that the first thing it
  /// swaps is one headline for the same headline.
  const matchY = CARD.h / 2 + (496 - thirdC) * S * thirdZ;
  const w1 = easeInOut((f - T.j1[0]) / (T.j1[1] - T.j1[0]));
  const w2 = easeInOut((f - T.j2[0]) / (T.j2[1] - T.j2[0]));
  const w3 = easeInOut((f - T.j3[0]) / (T.j3[1] - T.j3[0]));
  const w4 = easeInOut((f - T.j4[0]) / (T.j4[1] - T.j4[0]));

  return (
    <AbsoluteFill style={{backgroundColor: '#EFDCB4'}}>
      {/* Paper. Deliberately a shade deeper and warmer than the app's own cream (#FBF5E5) so
          the card reads as a lit screen lying on a surface rather than as a rectangle drawn on
          the same colour. */}
      <AbsoluteFill
        style={{
          background:
            'radial-gradient(130% 100% at 26% 6%, #FFFAEE 0%, #F8E9C9 44%, #E9D3A2 100%)',
        }}
      />

      {/* THE CARD. One object, fixed for 900 frames. Everything else moves behind it. */}
      <div
        style={{
          position: 'absolute',
          left: CARD.x,
          top: CARD.y,
          width: CARD.w,
          height: CARD.h,
          borderRadius: CARD.r,
          overflow: 'hidden',
          background: '#FBF5E5',
          boxShadow:
            '0 40px 110px rgba(58,36,18,0.30), 0 10px 34px rgba(58,36,18,0.18), 0 0 0 2px rgba(120,88,48,0.10)',
        }}
      >
        {f < 252 ? <Plate src={P.lib.src} C={libC} z={libZ} /> : null}

        {f >= T.j1[0] && f < 438 ? (
          <Plate
            src={P.art.src}
            C={artC}
            z={artZ}
            wipe={f < T.j1[1] ? {p: w1, up: true} : undefined}
          />
        ) : null}

        {f >= T.j2[0] && f < 626 ? (
          isKo ? (
            /* the band opening out of the shared headline */
            <Plate
              src={P.third.src}
              C={thirdC}
              z={thirdZ}
              band={f < T.j2[1] ? {yc: matchY, p: w2} : undefined}
            />
          ) : (
            <Plate
              src={P.third.src}
              C={thirdC}
              z={thirdZ}
              wipe={f < T.j2[1] ? {p: w2} : undefined}
            />
          )
        ) : null}

        {f >= T.j3[0] && f < 816 ? (
          <Plate src={P.set.src} C={setC} z={setZ} wipe={f < T.j3[1] ? {p: w3} : undefined} />
        ) : null}

        {f >= T.j4[0] ? (
          /* the only wipe that runs upward — it is the film coming back to where it started */
          <Plate
            src={P.lib.src}
            C={lib2C}
            z={lib2Z}
            wipe={f < T.j4[1] ? {p: w4, up: true} : undefined}
          />
        ) : null}
      </div>

      {/* Paper tooth. Three percent of noise is the difference between "warm paper" and "a CSS
          gradient", and it costs nothing at this size. */}
      <svg width={W} height={H} style={{position: 'absolute', left: 0, top: 0, opacity: 0.05}}>
        <filter id="storyb2-grain">
          <feTurbulence type="fractalNoise" baseFrequency="0.9" numOctaves={3} seed={11} />
          <feColorMatrix type="saturate" values="0" />
        </filter>
        <rect width={W} height={H} filter="url(#storyb2-grain)" />
      </svg>

      {/* A vignette that stays clear of the card (x 1950..2930) and of the type column, so the
          only thing it darkens is bare paper in the bleed. */}
      <AbsoluteFill
        style={{
          background:
            'radial-gradient(78% 74% at 50% 46%, rgba(70,44,20,0) 0%, rgba(70,44,20,0) 62%, rgba(70,44,20,0.16) 100%)',
          pointerEvents: 'none',
        }}
      />

      {/* The wordmark, always on, top-left of the guaranteed box. It is what stops the type
          column reading as empty in the 70 frames before the first caption and the 18 after the
          last — the two stretches that meet at the loop seam. */}
      <div
        style={{
          position: 'absolute',
          left: COL.x,
          top: SAFE.y0 + 34,
          fontFamily: UI,
          fontSize: 46,
          fontWeight: 600,
          letterSpacing: '0.34em',
          color: 'rgba(51,32,15,0.40)',
        }}
      >
        NOOK
      </div>

      <Caption lines={C.c1} cue={CUE.c1} f={f} cap={C.cap} track={C.track} />
      <Caption lines={C.c2} cue={CUE.c2} f={f} cap={C.cap} track={C.track} />
      {isKo ? <Caption lines={C.c3} cue={CUE.c3} f={f} cap={C.cap} track={C.track} /> : null}
      <Caption lines={C.c4} cue={CUE.c4} f={f} cap={C.cap} track={C.track} />
      <Caption lines={C.close} cue={CUE.close} f={f} cap={C.cap} track={C.track} weight={700} />

      {guides ? (
        <svg width={W} height={H} style={{position: 'absolute', left: 0, top: 0}}>
          <rect
            x={SAFE.x0}
            y={SAFE.y0}
            width={SAFE.x1 - SAFE.x0}
            height={SAFE.y1 - SAFE.y0}
            fill="none"
            stroke="#D2453B"
            strokeWidth={6}
          />
          <rect
            x={CARD.x}
            y={CARD.y}
            width={CARD.w}
            height={CARD.h}
            fill="none"
            stroke="#2C6EA8"
            strokeWidth={4}
          />
        </svg>
      ) : null}
    </AbsoluteFill>
  );
};

/* ==========================================================================================
   WHAT I TRIED AND THREW AWAY

   1. THE WHOLE PHONE, HELD TALL, BESIDE TYPE.
      The obvious reading of "portrait object in a landscape box". Rendered it: the phone is
      474px wide inside a 2167px box, a feed row is 14 canvas px tall, and at the 600px-wide
      check the article list is grey corduroy. It also leaves a 1600px hole that wants to be
      filled with something, and everything that fills it is decoration. The store slot is a
      product demo; a product you cannot read is not demonstrated.

   2. TWO AND THREE PHONES IN A ROW, SHOWING A SEQUENCE.
      Three whole phones at 474px wide, library / list / reader. It reads instantly and it says
      "three screenshots", which is the thing the six-second cut was rejected for. Worse for
      this lane specifically: with three devices on screen there is nothing left to move — the
      only available motion is the row sliding, and a sliding row of thumbnails is a carousel.
      It also triples the content-safety surface: three screens' worth of headlines on frame at
      once, in a locale set where two captures already carry rows that have to be cropped out.

   3. THE SCREEN WITHOUT A DEVICE, FULL BLEED.
      1320x2868 blown up until it fills 2560px of canvas height is 1178px wide, and then the
      guaranteed box only ever shows a 40% band of it anyway — so it is this file's card with
      the edges taken off and no room for type. The edges are worth keeping: a crisp rounded
      boundary is what tells the eye it is looking at a screen rather than at a page.

   4. THE iPAD, ONCE, FOR THE READER BEAT IN ENGLISH.
      The brief allows one iPad beat with justification, and en__ipad-13__03-reader is the only
      English reader capture that is not the Nolan piece. It leaks "(opens a new tab)" out of
      its accessibility markup six times in one screenful. Under "Nobody else is on this page"
      that is a screen arguing with its own caption. Rejected, and the beat runs silent instead.

   5. CROSS-FADING THE JOINS.
      Tried first, because this lane is supposed to be soft. Two pages of dense Korean text at
      50% over each other for 30 frames is not soft, it is illegible — StoryB's author hit the
      same wall. Every join here is a soft wipe with a 400px boundary instead, except the one
      join where a cross-fade is the right tool because one element is identical in both plates.

   6. PANNING THE STATUS BAR.
      The first Settings pass started at the top of the screen and scrolled down past 12:30 and
      the battery. Status bars do not scroll. It is the only motion in the film that would have
      described something the app cannot do, so no window in this file ever starts above source
      y 160.

   7. THE STARRED SCREEN AS A FIFTH KOREAN BEAT.
      The writer left it silent and near frame 690-800, which collides with the Settings
      caption at 664-774. There is no third place for it: the caption cues are fixed and the
      gaps between them are 62, 62, 82 and 32 frames. A screen that appears for two seconds
      between two other screens is the churn this lane exists to avoid, and starring is a
      feature every reader in the category has. It is out of the Korean cut and it is the whole
      third beat of the English one, where the reader capture cannot be used.

   THE CAPTURES THIS CUT IS STILL MISSING
     make app-store-capture LOCALE=en NAME=06-reader-clean
        A Quanta Magazine article open in the iPhone reader. No faces, no politics, no
        "(opens a new tab)". With it, en's third beat becomes the reader and gets caption c3,
        and the two locales stop diverging.
     make app-store-capture LOCALE=ko NAME=06-translate-off
     make app-store-capture LOCALE=ko NAME=07-translate-on
        The same article, same scroll offset, same clock, same unread counts, one untranslated
        and one translated, from ONE uninterrupted simulator run. There is no translation beat
        in this file because there is no capture of translation anywhere in the 46, and the two
        available fakes — a Japanese screen under Korean type, or the stuck "번역 중…" badge —
        are both worse than silence. With that pair, the beat 2 -> beat 3 join is already the
        right shape for it: one card, two plates, one thing changing.
========================================================================================== */
