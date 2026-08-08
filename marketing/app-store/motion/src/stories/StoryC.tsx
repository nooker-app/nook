import React from 'react';
import {AbsoluteFill, Img, interpolate, staticFile, useCurrentFrame} from 'remotion';
import {CANVAS} from '../theme';

/// Story C — "the argument, with the screenshots as evidence."
///
/// Nook's claim is not "an RSS reader". It is two sentences: NOBODY IS CHOOSING FOR YOU, and
/// LANGUAGE IS NOT A WALL. This cut spends its 180 frames making those two claims and handing the
/// viewer a real screenshot as the receipt for each one.
///
/// Rules this file holds itself to:
///   - Every pixel of app UI is a real capture from public/shots. Nothing is drawn and passed off
///     as a screenshot. The one non-capture frame is the closing type card, and it contains no UI.
///   - The first half stays on ONE screenshot for 100 frames — full window, then the feed list,
///     then the add-feed/sync-folder footer. Three claims, three magnifications, one unedited
///     window: whatever else a viewer doubts, they cannot doubt that it is all the same app.
///   - Shot order is the argument, not a feature list. 1-3 are "you chose this", 4 is "and the
///     language does not stop you", 5 is "and the result is yours to keep".
///   - Nothing periodic uses shot-local time: there is no TransitionSeries here at all. Every
///     layer reads the composition frame, so frame 179 dissolves back into frame 0's exact rect.

const {width: W, height: H} = CANVAS.search;
const SAFE = {
  x0: (W - CANVAS.search.safe.width) / 2, // 836.5
  y0: (H - CANVAS.search.safe.height) / 2, // 765.5
  w: CANVAS.search.safe.width,
  h: CANVAS.search.safe.height,
};

/// The safe box is 2167x1029 — aspect 2.106 — which is exactly the aspect every crop in the
/// capture inventory is cut to, so a crop fills it precisely and leaves NO room for type beside it.
///
/// So the geometry is: each crop is mapped onto the SAFE BOX, and the capture is then allowed to
/// run past it to whatever size it naturally reaches on the 3840x2560 canvas. The guaranteed
/// region always holds exactly the framing I designed; the bleed fills with more of the same real
/// screenshot, or with paper. My first pass instead drew a 2340x1112 plate and left 700px of empty
/// paper above and below it, and at full canvas that looked marooned — the whole reason for this
/// version.

const IMG = {
  mac: {w: 2560, h: 1640},
  ipad: {w: 2064, h: 2752},
  iphone: {w: 1320, h: 2868},
} as const;

const INK = '#33200F';
const PAPER = '#FBF3E4';
const UI = "-apple-system, 'SF Pro Text', 'Helvetica Neue', Helvetica, Arial, sans-serif";

/// The ground. Declared once and reused by the four edge veils below, so they can hide the bleed
/// by painting the ground back over it and still line up seamlessly.
const GROUND =
  'radial-gradient(78% 70% at 50% 46%, #FFFCF2 0%, #F7ECD6 50%, #EBDCBB 80%, #DDC8A0 100%)';

/// Paint the ground back over the bleed, fading to nothing at the safe box edge.
///
/// This is not decoration, it is a content gate. Two things live outside the safe box that must
/// never be delivered: the top of a person's head in a kakao lead image at source (1600..1760,
/// 1595..1640) of ko__mac__01-overview — the repo has a `make app-store-check-faces` gate that
/// exists to fail exactly that — and, at the magnifications this cut uses, whatever else happens to
/// sit beyond the framing I chose. I walked the head's canvas position frame by frame across all
/// 180: while the camera is wide it lands at y~2100, under the bottom veil, which is opaque from
/// y=2024; while the camera is moving in it leaves the canvas entirely; at the footer framing it is
/// at x~4340, off the right edge; and everywhere else an opaque layer is on top of it. If you
/// change MAC_PATH or MAC_FOOT, redo that walk — the veils are the only thing between this asset
/// and a face in it.
const Veil: React.FC<{
  box: {left: number; top: number; width: number; height: number};
  mask: string;
}> = ({box, mask}) => (
  <div
    style={{
      position: 'absolute',
      ...box,
      background: GROUND,
      backgroundSize: `${W}px ${H}px`,
      backgroundPosition: `${-box.left}px ${-box.top}px`,
      WebkitMaskImage: mask,
      maskImage: mask,
    }}
  />
);

const clamp01 = (v: number) => (v < 0 ? 0 : v > 1 ? 1 : v);
const easeInOut = (t: number) => {
  const x = clamp01(t);
  return x < 0.5 ? 4 * x * x * x : 1 - Math.pow(-2 * x + 2, 3) / 2;
};
const easeOut = (t: number) => 1 - Math.pow(1 - clamp01(t), 3);

/* ------------------------------------------------------------------ evidence */

type Rect = readonly [number, number, number, number]; // sx, sy, sw, sh in source pixels

const lerpRect = (a: Rect, b: Rect, t: number): Rect => {
  const e = easeInOut(t);
  return [
    a[0] + (b[0] - a[0]) * e,
    a[1] + (b[1] - a[1]) * e,
    a[2] + (b[2] - a[2]) * e,
    a[3] + (b[3] - a[3]) * e,
  ];
};

/// Walk a keyframed camera path. Frames outside the path clamp to its ends, which is what lets the
/// mac layer fly back to its opening rect while it is hidden behind the iPad and the phone.
const walk = (path: readonly (readonly [number, Rect])[], f: number): Rect => {
  if (f <= path[0][0]) return path[0][1];
  for (let i = 1; i < path.length; i++) {
    if (f <= path[i][0]) {
      const [t0, r0] = path[i - 1];
      const [t1, r1] = path[i];
      return lerpRect(r0, r1, (f - t0) / (t1 - t0));
    }
  }
  return path[path.length - 1][1];
};

/// One capture, placed so that its source rect lands exactly on the safe box.
///
/// `radius` is for the iPad and iPhone files, which are fully opaque with square corners: left
/// bare they end in a hard vertical seam against the paper and read as a screenshot someone
/// pasted. The mac files are window-only PNGs with their own transparent rounded corners, so they
/// only want the shadow.
const Evidence: React.FC<{
  src: string;
  nat: {w: number; h: number};
  rect: Rect;
  opacity: number;
  radius?: number;
}> = ({src, nat, rect, opacity, radius = 0}) => {
  const [sx, sy, sw] = rect;
  const scale = SAFE.w / sw;
  return (
    <Img
      src={staticFile(src)}
      style={{
        position: 'absolute',
        left: SAFE.x0 - sx * scale,
        top: SAFE.y0 - sy * scale,
        width: nat.w * scale,
        height: nat.h * scale,
        opacity,
        borderRadius: radius,
        filter: 'drop-shadow(0 22px 56px rgba(74,52,25,0.24))',
      }}
    />
  );
};

/* ------------------------------------------------------------------ copy */

/// The captions are the argument; the screenshots are the evidence. Each line is the sentence the
/// frame under it is answering, which is why none of them names the feature in the frame.
/// Every line is hand-broken into two, and the breaks are not free-text wrapping.
///
/// English sets about 40% wider than Korean at the same point size, and I rendered the single-line
/// version: "No one else put these here" made a slip 1452px wide whose left edge landed on the feed
/// rows — on Hacker News's unread count, in the one shot whose whole argument is those rows. Two
/// short lines keep every slip under ~970px, which clears the sidebar in all five framings, and
/// they let me choose the break myself instead of letting the layout choose it ("No need to learn /
/// the language" rather than "No need to learn the / language").
const COPY = {
  en: {
    lines: [
      ['A list', 'that ends'],
      ['No one else', 'put these here'],
      ['The address', 'is enough'],
      ['No need to learn', 'the language'],
      ['Your library is', 'a folder you own'],
    ],
    end: 'The reading you chose',
  },
  ko: {
    lines: [
      ['끝이 있는', '목록입니다'],
      ['내가 하나씩', '넣었습니다'],
      ['주소 하나면', '됩니다'],
      ['그 나라 말을', '몰라도 됩니다'],
      ['읽는 동안엔', '비켜섭니다'],
    ],
    end: '고른 글만 남습니다',
  },
} as const;

type Locale = keyof typeof COPY;

/* ------------------------------------------------------------------ shots */

const MAC_SRC: Record<Locale, string> = {
  ko: 'shots/ko__mac__01-overview.png',
  en: 'shots/en__mac__03-library.png',
};

/// The mac camera. ko opens on the full four-pane window; en's 03-library devotes its right two
/// thirds to an empty "Select an Article" state, so en opens tighter — and en__mac__01-overview,
/// which would have opened wide, is out on content grounds (a US immigration-enforcement headline
/// sits in every usable band, and its lead image is visibly AI-generated).
///
/// This layer also carries the loop. It is the base of the stack, it is the only thing left when
/// the closing card fades, and its path is written to ARRIVE at the opening rect on f180 — so the
/// last frames the viewer sees are already the opening framing, still drifting into it.
const MAC_PATH: Record<Locale, readonly (readonly [number, Rect])[]> = {
  ko: [
    [0, [0, 0, 2560, 1216]],
    [26, [34, 16, 2492, 1184]],
    [44, [0, 0, 1390, 660]],
    [70, [6, 4, 1366, 649]],
    // Arrives at the opening rect ON f180, drifting rather than sitting still, so the last visible
    // frames of the loop are still moving in when f0 takes over. Parking on R1 early made the seam
    // a five-frame freeze followed by a lurch.
    [140, [0, 30, 2560, 1216]],
    [180, [0, 0, 2560, 1216]],
  ],
  en: [
    [0, [0, 0, 1720, 817]],
    [26, [22, 10, 1676, 796]],
    [44, [0, 0, 1390, 660]],
    [70, [6, 4, 1366, 649]],
    [140, [0, 20, 1720, 817]],
    [180, [0, 0, 1720, 817]],
  ],
};

/// The sidebar footer, as a MATCH DISSOLVE on a second copy of the same screenshot rather than a
/// continued camera move. I built the move first, both as a zoom and as a pure vertical pan, and
/// rendered both: between the feed list and the footer lies 760px of empty sidebar, so for a third
/// of a second the screen is a white rectangle with a caption floating on it. Dissolving between
/// two framings of one image keeps the claim (this is the same window, nobody swapped anything)
/// and throws away the dead transit.
///
/// Framed wide enough (2.19x, not the 3.6x the crop notes suggest) that the article column and the
/// "67 unread" status line stay in shot. At 3.6x the two labels are enormous, but I rendered it at
/// the size the store actually shows and 60% of the frame is empty sidebar — a white rectangle
/// with a caption on it. This framing costs some label size and buys back context.
const MAC_FOOT: readonly (readonly [number, Rect])[] = [
  [62, [0, 1170, 990, 470]],
  [100, [16, 1178, 958, 455]],
];

/// The foreign-language beat. A genuinely Japanese library — gihyo.jp with 789 unread, すべての記事
/// 836, a Japanese article open in the reader — subscribed inside the same app. See TRANSLATION_GAP
/// at the bottom of this file before changing anything here.
const JA_PATH: readonly (readonly [number, Rect])[] = [
  [94, [26, 150, 2038, 967]],
  [140, [86, 178, 1918, 910]],
];

/// The last piece of evidence, on the third platform. ko gets the reader — no defect of any kind in
/// that file, and at 1.64x the title, the byline and the first bullet are the largest legible type
/// in the cut. Every English reader capture is disqualified: the iPhone one contains two human
/// faces, the iPad one draws its sticky title on top of a line of body text and litters the page
/// with "(opens a new tab)". So the English cut lands on the sync-folder row instead and takes the
/// folder line, which is honest for the frame it is over.
const PHONE: Record<Locale, {src: string; path: readonly (readonly [number, Rect])[]}> = {
  ko: {
    src: 'shots/ko__iphone-6.9__03-reader.png',
    path: [
      [130, [0, 330, 1320, 627]],
      [170, [20, 348, 1280, 608]],
    ],
  },
  en: {
    src: 'shots/en__iphone-6.9__05-settings.png',
    path: [
      [130, [0, 2100, 1320, 627]],
      [170, [20, 2118, 1280, 608]],
    ],
  },
};

/* ------------------------------------------------------------------ type */

/// The caption is a SLIP: an opaque cream card laid over the bottom-right of the evidence.
///
/// Two problems forced it. A gradient scrim strong enough to carry 100px type also veiled the feed
/// names and unread counts — the payload of the whole argument — and I rendered that and it was
/// unusable. And unbacked ink type landed at the same weight as the app's own headlines, so on the
/// reader frame the caption read as part of the article. The slip fixes both: it is opaque, so the
/// type is at full contrast and nothing else is dimmed, and it is plainly a different object from
/// the app (square corners, cream, an accent bar) so it can never be mistaken for UI.
///
/// Bottom-RIGHT is not taste. Every crop in this cut carries its payload on the LEFT — a macOS
/// sidebar, an iPadOS sidebar, a settings label, an article title — so the bottom-right is the one
/// quadrant that is expendable in all five.
const SLIP = {
  right: SAFE.x0 + SAFE.w - 54, // 2949
  bottom: SAFE.y0 + SAFE.h - 56, // 1738
};

const Caption: React.FC<{
  text: readonly string[];
  from: number;
  to: number;
  frame: number;
  size: number;
}> = ({text, from, to, frame, size}) => {
  if (frame < from - 1 || frame > to + 1) return null;
  const inT = easeOut((frame - from) / 9);
  const outT = 1 - clamp01((frame - (to - 5)) / 5);
  const opacity = clamp01(inT) * outT;
  const slide = (1 - inT) * 54;
  return (
    <div
      style={{
        position: 'absolute',
        right: W - SLIP.right,
        bottom: H - SLIP.bottom,
        opacity,
        transform: `translateX(${slide}px)`,
        background: '#F7E9CD',
        borderLeft: '15px solid #A8763C',
        boxShadow: '0 12px 34px rgba(74,52,25,0.22)',
        padding: `${size * 0.36}px ${size * 0.56}px ${size * 0.42}px ${size * 0.52}px`,
        fontFamily: UI,
        fontSize: size,
        fontWeight: 600,
        letterSpacing: '-0.018em',
        lineHeight: 1.14,
        color: INK,
        whiteSpace: 'nowrap',
      }}
    >
      {text.map((line) => (
        <div key={line}>{line}</div>
      ))}
    </div>
  );
};

/* ------------------------------------------------------------------ the cut */

export const StoryC: React.FC<{locale: Locale; guides?: boolean}> = ({locale, guides}) => {
  const frame = useCurrentFrame();
  const copy = COPY[locale];

  // The stack, bottom to top. Every ramp is written against the composition frame, never a
  // shot-local one, so the last frame of the loop is reconcilable with the first by construction.
  const footOp = clamp01(interpolate(frame, [62, 70, 92, 100], [0, 1, 1, 0]));
  const jaOp = clamp01(interpolate(frame, [92, 100, 128, 136], [0, 1, 1, 0]));
  const phoneOp = clamp01(interpolate(frame, [128, 136, 158, 166], [0, 1, 1, 0]));
  // Lands on 0 at 179, not 180: the closing card has to be fully gone by the last rendered frame
  // or the loop pops a 20%-opaque sheet of paper over the mac window on the seam.
  const cardOp = clamp01(interpolate(frame, [158, 166, 174, 179], [0, 1, 1, 0]));

  const size = locale === 'ko' ? 112 : 106;

  return (
    <AbsoluteFill style={{background: PAPER}}>
      {/* The warm ground. It reads as a desk, not a void. */}
      <AbsoluteFill style={{background: GROUND}} />

      <Evidence
        src={MAC_SRC[locale]}
        nat={IMG.mac}
        rect={walk(MAC_PATH[locale], frame)}
        opacity={1}
      />
      {/* The footer framing needs its own opaque ground: the mac captures are window-only PNGs with
          transparent corners and transparent surround, so without a backing the wide framing
          underneath ghosts through the dissolve. */}
      <AbsoluteFill style={{opacity: footOp, background: GROUND}}>
        <Evidence src={MAC_SRC[locale]} nat={IMG.mac} rect={walk(MAC_FOOT, frame)} opacity={1} />
      </AbsoluteFill>
      <AbsoluteFill style={{opacity: jaOp, background: GROUND}}>
        <Evidence
          src="shots/ja__ipad-13__01-library.png"
          nat={IMG.ipad}
          rect={walk(JA_PATH, frame)}
          opacity={1}
          radius={34}
        />
      </AbsoluteFill>
      <AbsoluteFill style={{opacity: phoneOp, background: GROUND}}>
        <Evidence
          src={PHONE[locale].src}
          nat={IMG.iphone}
          rect={walk(PHONE[locale].path, frame)}
          opacity={1}
          radius={34}
        />
      </AbsoluteFill>

      <Veil
        box={{left: 0, top: 0, width: W, height: SAFE.y0}}
        mask="linear-gradient(to bottom, #000 0%, #000 70%, transparent 100%)"
      />
      <Veil
        box={{left: 0, top: SAFE.y0 + SAFE.h, width: W, height: H - (SAFE.y0 + SAFE.h)}}
        mask="linear-gradient(to bottom, transparent 0%, #000 30%, #000 100%)"
      />
      <Veil
        box={{left: 0, top: 0, width: SAFE.x0, height: H}}
        mask="linear-gradient(to right, #000 0%, #000 76%, transparent 100%)"
      />
      <Veil
        box={{left: SAFE.x0 + SAFE.w, top: 0, width: W - (SAFE.x0 + SAFE.w), height: H}}
        mask="linear-gradient(to left, #000 0%, #000 76%, transparent 100%)"
      />

      <Caption text={copy.lines[0]} from={6} to={30} frame={frame} size={size} />
      <Caption text={copy.lines[1]} from={40} to={62} frame={frame} size={size} />
      <Caption text={copy.lines[2]} from={68} to={90} frame={frame} size={size} />
      <Caption text={copy.lines[3]} from={98} to={126} frame={frame} size={size} />
      <Caption text={copy.lines[4]} from={134} to={156} frame={frame} size={size} />

      {/* the one non-capture frame: the close. No UI on it — a line and the name. */}
      <AbsoluteFill style={{opacity: cardOp}}>
        <AbsoluteFill
          style={{
            background: `radial-gradient(110% 80% at 50% 46%, #FFFDF6 0%, ${PAPER} 62%, #EFE0C2 100%)`,
          }}
        />
        <div
          style={{
            position: 'absolute',
            left: SAFE.x0 + 92,
            top: SAFE.y0 + 292,
            width: SAFE.w - 184,
            fontFamily: UI,
            color: INK,
          }}
        >
          <div style={{width: 190, height: 11, background: '#A8763C'}} />
          <div
            style={{
              marginTop: 74,
              fontSize: locale === 'ko' ? 182 : 168,
              fontWeight: 600,
              letterSpacing: '-0.028em',
              lineHeight: 1.06,
            }}
          >
            {copy.end}
          </div>
          <div
            style={{
              marginTop: 78,
              fontSize: 92,
              fontWeight: 500,
              letterSpacing: '0.14em',
              color: '#8A6A3F',
            }}
          >
            Nook
          </div>
        </div>
      </AbsoluteFill>

      {guides ? (
        <div
          style={{
            position: 'absolute',
            left: SAFE.x0,
            top: SAFE.y0,
            width: SAFE.w,
            height: SAFE.h,
            outline: '3px solid rgba(220,60,60,0.8)',
          }}
        />
      ) : null}
    </AbsoluteFill>
  );
};

/// TRANSLATION_GAP — read this before "fixing" shot 4.
///
/// The headline claim (an article in a language you do not read, made readable) has NO honest
/// evidence in the 46 captures. Each locale was captured from feeds in its own language, so there
/// is no matched before/after of one article. The two things that exist are a Settings > 실험실 row
/// label, and a '번역 중…' badge that the repo README says is the STUCK state shown when there is
/// nothing to translate. Both are worse than silence.
///
/// So shot 4 shows a real Japanese library inside Nook and lets the caption make the claim, and
/// nothing anywhere in this file pretends to be translated UI. To close the gap properly, capture
/// in ONE uninterrupted simulator run so the clock, feed set and scroll offset match:
///   make app-store-capture LOCALE=ko NAME=06-translate-list     (list titles translated)
///   make app-store-capture LOCALE=ko NAME=07-translate-reader   (same article, mid-stream)
///   and the one the README does not ask for: the same article, same scroll, translation OFF.
/// Then JA_PATH becomes a two-layer A/B on one article and this comment can go.
export const TRANSLATION_GAP = true;
