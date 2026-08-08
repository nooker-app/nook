import React from 'react';
import {AbsoluteFill, Img, OffthreadVideo, staticFile, useCurrentFrame} from 'remotion';
import {CANVAS} from './theme';

/// THE SEARCH-RESULT VIDEO, built as the moving version of the asset system this repository already
/// has, rather than as a fifth invention.
///
/// Six cuts were rejected before this one, and the note that ended the search was a picture of
/// Apple's own screenshot cards: headline at the top of a card, device below it, device cropped by the
/// card's bottom edge. That format solves BY STRUCTURE the thing four cuts tried to solve by
/// placement — type and screen never compete for the same pixels, because each gets a floor of its
/// own. Everything before this either put type on top of UI (unreadable), reserved a strip for it
/// (rejected as a fixed region), or shrank the screen to open a gutter (rejected as too small).
///
/// The repository was already doing this. `marketing/app-store/Sources/AppStoreRenderer.swift` renders
/// the localized screenshots in that form and holds the tokens, and its `drawSearchResult` is a
/// landscape composition for THIS canvas: type at the top, two panels taking whatever height the type
/// leaves. Every number below is read off that file rather than chosen again — the gradient
/// #17130E -> #2C2116 at 72 degrees, the #D9974B glow at 8%, gold #E5AA61, ink #FFF8EA, muted
/// #D6C6AA, the 2.8% inset, the 11.5%/5.0% type scale, the 3.5% corner radius. A listing whose video
/// does not match its own screenshots looks like two products.
///
/// The copy is the config's for the same reason: `config.json` already carries a four-language set in
/// the app's voice ("피드는 내가 고릅니다", "읽는 데만 집중하세요"). Three attempts at a parallel voice
/// for the video were rejected before I found the config had solved it.

const {width: W, height: H} = CANVAS.search;
const SAFE = {
  x0: (W - CANVAS.search.safe.width) / 2, // 836
  y0: (H - CANVAS.search.safe.height) / 2, // 765
  w: CANVAS.search.safe.width, // 2167
  h: CANVAS.search.safe.height, // 1029
};
/// `drawSearchResult` insets the safe area by 2.8% of its width before laying anything out.
const INSET = SAFE.w * 0.028;
const C = {
  x0: SAFE.x0 + INSET,
  y0: SAFE.y0 + INSET,
  w: SAFE.w - INSET * 2,
  h: SAFE.h - INSET * 2,
};

const INK = '#FFF8EA';
const MUTED = '#D6C6AA';
const GOLD = '#E5AA61';
const UI =
  "-apple-system, 'SF Pro Text', 'Apple SD Gothic Neo', 'Helvetica Neue', Helvetica, sans-serif";

const clamp01 = (v: number) => (v < 0 ? 0 : v > 1 ? 1 : v);
const ease = (t: number) => {
  const x = clamp01(t);
  return x * x * (3 - 2 * x);
};

/* ------------------------------------------------------------------ chrome */

const Background: React.FC = () => (
  <AbsoluteFill>
    <AbsoluteFill style={{background: 'linear-gradient(72deg, #17130E 0%, #2C2116 100%)'}} />
    <div
      style={{
        position: 'absolute',
        left: W * 0.28,
        top: H * 0.06,
        width: W * 0.6,
        height: W * 0.6,
        borderRadius: '50%',
        background: 'radial-gradient(circle, rgba(217,151,75,0.08) 0%, rgba(217,151,75,0) 70%)',
      }}
    />
  </AbsoluteFill>
);

/// The dot and the word, sized `content.height * 0.052` as the renderer does it. The one element that
/// never moves across the whole 30 seconds.
const Brand: React.FC = () => {
  const size = C.h * 0.052;
  return (
    <div
      style={{
        position: 'absolute',
        left: C.x0,
        top: C.y0,
        display: 'flex',
        alignItems: 'center',
        gap: size * 0.42,
        fontFamily: UI,
        fontWeight: 600,
        fontSize: size,
        letterSpacing: '0.02em',
        color: INK,
      }}
    >
      <span style={{width: size * 0.42, height: size * 0.42, borderRadius: '50%', background: GOLD}} />
      NOOK
    </div>
  );
};

/// Title and subtitle at the renderer's sizes — 11.5% and 5.0% of the content height, bold over
/// medium, ink over muted ink.
const Heading: React.FC<{title: string; sub: string; t: number}> = ({title, sub, t}) => {
  const a = ease(t / 0.14);
  return (
    <div style={{position: 'absolute', left: C.x0, top: C.y0 + C.h * 0.115, width: C.w * 0.86}}>
      <div
        style={{
          opacity: a,
          transform: `translateY(${(1 - a) * 22}px)`,
          fontFamily: UI,
          fontWeight: 700,
          fontSize: C.h * 0.115,
          lineHeight: 1.04,
          letterSpacing: '-0.015em',
          color: INK,
        }}
      >
        {title}
      </div>
      <div
        style={{
          marginTop: C.h * 0.035,
          opacity: ease((t - 0.06) / 0.16),
          fontFamily: UI,
          fontWeight: 500,
          fontSize: C.h * 0.05,
          lineHeight: 1.16,
          color: MUTED,
        }}
      >
        {sub}
      </div>
    </div>
  );
};

/// A panel: the real screen, rounded and shadowed, CROPPED BY ITS OWN BOTTOM EDGE exactly as the
/// screenshot cards crop their devices.
///
/// The source is scaled to the panel's WIDTH and allowed to run off the bottom. That is the whole
/// trick and it is why this layout works where four others did not: fitting a 1:2.17 screen inside a
/// short landscape panel is what drove the app's own type down to 4px at store scale. Scaled to width,
/// a half-panel here is 1049px for a 1320px source — 0.79x — and the app's 17pt body lands at 40
/// canvas px, ~13px at the size the store draws this. Legible, and the panel shows the top third of
/// the screen, which is the third that carries the claim.
const Panel: React.FC<{
  src: string;
  video?: boolean;
  startFrom?: number;
  srcW: number;
  x: number;
  y: number;
  w: number;
  h: number;
  /// Where in the source to start, in source px — how a panel aims at the rows that matter.
  from?: number;
  t: number;
  /// Slow scroll across the beat, in source px.
  drift?: number;
  delay?: number;
}> = ({src, video = false, startFrom = 0, srcW, x, y, w, h, from = 0, t, drift = 0, delay = 0}) => {
  const a = ease((t - delay) / 0.2);
  const k = w / srcW;
  return (
    <div
      style={{
        position: 'absolute',
        left: x,
        top: y,
        width: w,
        height: h,
        borderRadius: `${C.h * 0.035}px ${C.h * 0.035}px 0 0`,
        overflow: 'hidden',
        background: '#0E0B07',
        boxShadow: '0 -8px 90px rgba(0,0,0,0.5)',
        border: '2px solid rgba(229,170,97,0.34)',
        opacity: a,
        transform: `translateY(${(1 - a) * 40}px)`,
      }}
    >
      <div style={{position: 'absolute', left: 0, top: -(from + drift * t) * k, width: srcW * k}}>
        {video ? (
          <OffthreadVideo src={staticFile(src)} startFrom={startFrom} muted style={{width: srcW * k, display: 'block'}} />
        ) : (
          <Img src={staticFile(src)} style={{width: srcW * k, display: 'block'}} />
        )}
      </div>
    </div>
  );
};

/* ------------------------------------------------------------------ the beats */

const CAPW = 1320;
const CLIPW = 1180;

/// THE PANEL BLEEDS. This is the change that finally makes the product big.
///
/// Keeping everything politely inside the safe box is what kept it small: 2167px of guaranteed width
/// had to hold the type AND two panels, so each panel got 1049px for a 1320px source — 0.79x, and the
/// app's own 17pt body landed at ~13px on the store's rendering. Meanwhile 3840x2560 of canvas sat
/// unused around it.
///
/// So: ONE panel per beat, 2300px wide, running from under the type off the BOTTOM of the canvas —
/// the same crop Apple's screenshot cards use on their devices. 2300/1320 = 1.74x, which puts the
/// app's body type at 89 canvas px and ~28px as the store draws it.
///
/// One panel and not two, for a reason beyond size: the before/after the two-panel version existed to
/// show is inside the recordings already. The translation clip IS the before and the after.
const PANEL_W = 2300;
const PANEL_X = (W - PANEL_W) / 2;
/// Under the type, and 644px of it are still inside the guaranteed box — enough that a crop to the
/// safe area shows the type plus a real piece of screen rather than type over a sliver.
const PANEL_TOP = 1150;
/// Past the canvas floor: the panel has no bottom edge, it just leaves.
const PANEL_H = H - PANEL_TOP + 40;

type Beat = {from: number; to: number; render: (t: number) => React.ReactNode};

const BEATS: Beat[] = [
  // 1. Paste a site address — a bare SITE address, because a feed URL in that field would say the
  //    opposite of the claim.
  {
    from: 0,
    to: 225,
    render: (t) => (
      <>
        <Heading title="주소만 붙여넣으면 됩니다" sub="사이트 주소 하나로 피드를 찾아냅니다." t={t} />
        <Panel src="shots/ko__iphone-6.9__06-add-feed.png" srcW={CAPW} x={PANEL_X} y={PANEL_TOP} w={PANEL_W} h={PANEL_H} from={120} t={t} />
      </>
    ),
  },
  // 2. What the app is, in the config's own words, over the library it describes.
  {
    from: 225,
    to: 450,
    render: (t) => (
      <>
        <Heading title="피드는 내가 고릅니다" sub="알고리즘 없이, 관심 있는 글만 한곳에." t={t} />
        <Panel src="shots/ko__iphone-6.9__07-feeds.png" srcW={CAPW} x={PANEL_X} y={PANEL_TOP} w={PANEL_W} h={PANEL_H} from={120} t={t} />
      </>
    ),
  },
  // 3. Reading. The dark capture, so the appearance change lands before the recordings do — the app
  //    has a dark mode, said by showing it rather than by claiming it.
  {
    from: 450,
    to: 660,
    render: (t) => (
      <>
        <Heading title="읽는 데만 집중하세요" sub="웹의 소음을 걷어낸 네이티브 리더." t={t} />
        <Panel src="shots/ko__iphone-6.9__09-reader-dark.png" srcW={CAPW} x={PANEL_X} y={PANEL_TOP} w={PANEL_W} h={PANEL_H} from={170} drift={420} t={t} />
      </>
    ),
  },
  // 4. TRANSLATION, and the only beat that moves by itself. The pill lands at 0.65s and the title swaps
  //    in a single frame at 5.6s, so entering at 0.5s puts the swap inside this beat.
  {
    from: 660,
    to: 900,
    render: (t) => (
      <>
        <Heading title="어느 나라 말이든 읽힙니다" sub="Apple Intelligence가 제목부터 본문까지 옮깁니다." t={t} />
        <Panel src="video/03-translate-body.mp4" video startFrom={15} srcW={CLIPW} x={PANEL_X} y={PANEL_TOP} w={PANEL_W} h={PANEL_H} from={120} t={t} />
      </>
    ),
  },
];

export const SearchStory: React.FC<{locale: 'en' | 'ko'; guides?: boolean}> = ({guides = false}) => {
  const frame = useCurrentFrame();
  const beat = BEATS.find((b) => frame >= b.from && frame < b.to) ?? BEATS[BEATS.length - 1];
  const t = (frame - beat.from) / (beat.to - beat.from);

  return (
    <AbsoluteFill>
      <Background />
      <Brand />
      {beat.render(t)}
      {guides ? (
        <svg width={W} height={H} style={{position: 'absolute', inset: 0}}>
          <rect x={SAFE.x0} y={SAFE.y0} width={SAFE.w} height={SAFE.h} fill="none" stroke="#FF00FF" strokeWidth={6} />
        </svg>
      ) : null}
    </AbsoluteFill>
  );
};
