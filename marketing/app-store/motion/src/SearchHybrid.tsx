import React from 'react';
import {AbsoluteFill, Img, OffthreadVideo, Sequence, interpolate, staticFile, useCurrentFrame} from 'remotion';
import {ACCENTS, Accent, CLAY, CREAM, GOLD, INK, NestBack, NestFront, SAGE} from './SearchIllustration';
import {CURVE, FLAT, periodic, SAFE_INSET, SEARCH_SAFE as S, TYPE, UI} from './motion';
import {CANVAS} from './theme';

/// SEARCH RESULTS — the hybrid: the illustration's craft carrying the app itself.
///
/// Apple asks this slot to "state the obvious — be sure your app's purpose is obvious at a glance" and
/// to "showcase the firsthand experience... the interface, content". The illustrated cut fails both:
/// its headline leads with translation, which is the differentiator and not the category, and it
/// contains no interface at all. Both were deliberate, for a reason that is not one of the two things
/// this slot is judged on.
///
/// THE STRUCTURE IS TYPE CARDS ALTERNATING WITH FULL SCREENS, and it is forced rather than chosen.
///
/// The screens have to be shown WHOLE. The system's panel rule crops a capture to its top third and
/// scales it to 2300px, which puts the app's own body type at ~28px as the store draws this — but the
/// recordings' whole point is action that crosses the screen: pasting an address and watching the feed
/// arrive, translations landing one card at a time. Cropping those loses the payoff. Whole and
/// full-height puts `APP_BODY_PX` at 15.2px (simulator sources) / 17.0px (real device) at
/// `STORE_WIDTH` — about half the legibility of a cropped panel, in exchange for the thing the footage
/// was taken for.
///
/// Side by side with the headline it would be worse still. A 2167px guaranteed box cannot hold a
/// full-height device AND type at headline scale — the type column falls to about 760px, which is 120px
/// type, an 8% cap height against a floor of 20%. So each gets its own frame.
///
/// TWO VISIBLE DEPARTURES FROM `motion.ts`, declared here because that file requires an asset that
/// ignores it to do so visibly.
///
/// 1. THE PANEL RULE IS NOT USED (`PANEL_W`, `panelTop`). See above: this asset trades the crop for the
///    action. What it does instead is fit by HEIGHT after removing the iOS status bar — not a crop of
///    the app, but of the OS and the hardware. `STATUS_FRAC` is one number for both 6.9" geometries
///    because their two valid windows overlap, not because the strip is the same height on both. It
///    exists because the three sources disagree about the time of day: the real-device clips carry a
///    red recording dot, `08:25` and `72%`, and the simulator sources carry `12:30`, `9:41` and a
///    charging bolt. Three clocks read as three different sessions. Side effect worth having: `k`
///    rises, so the app's own type gets bigger.
///
/// 2. `enterAt` IS NOT USED, ANYWHERE IN THIS FILE. It reaches 88% at t=0.03, and `beatT` divides by a
///    beat length, so the same "entrance" is 6 frames on one beat and 21 on another. Every entrance
///    here is `interpolate(fLocal, [a, b], ...)` with a and b in FRAMES. Same reason the wipe is
///    `(frame - from) / XF` and never `CURVE(t)`: `CURVE` reaches 0.72 by t=0.22, which on a 170-frame
///    beat is an 8-frame wipe.
///
/// And a third thing that is not a departure but is worth stating: THE SCREEN IS PLACED AND DOES NOT
/// MOVE. Fitting by height makes the window exactly as tall as the fitted source, so the slack is zero
/// and any travel exposes the backing colour — measured on the previous cut, `drift` 520 left a 464px
/// black band under the phone at the end of the beat. The `1.006 → 1.000` settle it also carried was
/// 15px of overscan for 0.075px/frame, which is not motion but an undeclared crop that changes over
/// time. All motion in a screen beat comes from OUTSIDE the device; that is what the flanks are for.

const {width: W, height: H} = CANVAS.search;
const TOTAL = 900;

const clamp01 = (v: number) => (v < 0 ? 0 : v > 1 ? 1 : v);
const smoothstep = (a: number, b: number, v: number) => {
  const t = clamp01((v - a) / (b - a));
  return t * t * (3 - 2 * t);
};
/// Frames in, frames out — the only ramp this file uses. `a` and `b` are absolute or beat-local frame
/// numbers, never a 0..1 beat fraction; see departure 2 in the header.
const ramp = (f: number, a: number, b: number, eased = true) =>
  interpolate(f, [a, b], [0, 1], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
    ...(eased ? {easing: CURVE} : {}),
  });

/* ------------------------------------------------------------------ fitting a capture */

/// The iOS status bar and Dynamic Island, as a fraction of source height — and it is a WINDOW, not a
/// point, which is the thing 0.0743 got wrong.
///
/// Measured off the sources, by row, rather than assumed: the island's ink ends at y 152 of 2868 in the
/// stills and y 143 of 2556 in the `.mov`, and the app's OWN first drawn pixel is y 186 and y 177. So
/// the cut may land anywhere in 0.0563..0.0648 and 0.0743 was above the top of it — it took 213px off a
/// 2868 source, which is 27px into the app, and on `08-articles` those 27px are the top of the 안 읽음
/// pill and the upper two thirds of its `67` badge. The one asset built to show the app WHOLE was the
/// one that looked cropped, and it lost the unread count on the beat whose callout reads 안 읽은 글.
/// 0.061 sits mid-window on both: 175px on 2868 (23px of clearance under the island, 11px above the
/// app) and 156px on 2556 (13px and 21px).
const STATUS_FRAC = 0.061;

/// Fit by height with that strip removed. Every pixel the APP draws is still on screen at full height.
const fit = (srcW: number, srcH: number) => {
  const cropTop = srcH * STATUS_FRAC;
  const k = H / (srcH - cropTop);
  return {k, w: srcW * k, top: -cropTop * k};
};

const CAP = fit(1320, 2868); //  k 0.95059, w 1254.8 — the stills and the real-device add-feed clip
const CLIP = fit(1180, 2556); // k 1.06663, w 1258.6 — the real-device translate clip

/// One nominal screen width rather than either fitted one, so the flank column centres and the callout
/// anchor do not move by 2px between a still beat and a video beat.
const SCREEN_W = 1257;

/// The two flanks the fitted screen leaves: 1291.5px each, a third of the canvas each. What fills them
/// is §2 of the shot list and the whole reason the ground is not empty.
const FLANK = (W - SCREEN_W) / 2;

const Screen: React.FC<{f: ReturnType<typeof fit>; children: React.ReactNode}> = ({f, children}) => (
  <div
    style={{position: 'absolute', left: (W - f.w) / 2, top: 0, width: f.w, height: H, overflow: 'hidden'}}
  >
    {/* The strip comes off by moving the media UP inside a full-height window, not by scaling it into
        one: the window's height IS the fitted app height, so there is no slack to expose. */}
    <div style={{position: 'absolute', left: 0, top: f.top, width: f.w}}>{children}</div>
  </div>
);

/* ------------------------------------------------------------------ ground */

const Ground: React.FC<{u: number; dark: boolean; children?: React.ReactNode}> = ({u, dark, children}) => (
  <AbsoluteFill style={{background: dark ? FLAT.fieldDark : FLAT.field}}>
    <svg width={W} height={H} viewBox={`0 0 ${W} ${H}`} style={{opacity: dark ? 0.5 : 1}}>
      {ACCENTS.map((a, i) => (
        <Accent key={i} a={a} u={u} i={i} />
      ))}
      {children}
    </svg>
  </AbsoluteFill>
);

/* ------------------------------------------------------------------ the flank marquee */

/// Two columns of article cards drifting up the flanks. The claim is the reason: beat 1 says 읽는
/// 사이트를 한곳에, the device shows ONE list, and the flanks show the traffic that list is made of. It
/// is the only thing the 2563px of empty ground can say that the headline is already committed to.
///
/// THE CARDS CARRY NO TYPE. Two reasons, both hard: at store scale card type is sub-6px, and illegible
/// type in a store asset reads as a rendering fault; and a typeless card cannot accidentally ship an
/// invented publication — or a real one — into App Store creative.
const DECK: {tint: string; lines: number}[] = [
  {tint: CREAM, lines: 3},
  {tint: GOLD, lines: 2},
  {tint: SAGE, lines: 3},
  {tint: CREAM, lines: 2},
  {tint: GOLD, lines: 3},
  {tint: SAGE, lines: 2},
];

const CARD = {w: 620, h: 380, pitch: 780};
const RUN = DECK.length * CARD.pitch; // 4680

const FlankCard: React.FC<{c: (typeof DECK)[number]; x: number; y: number; k: number}> = ({c, x, y, k}) => {
  const edge =
    smoothstep(-CARD.h * 0.6, CARD.h * 0.75, y) * (1 - smoothstep(H - CARD.h * 0.75, H + CARD.h * 0.6, y));
  if (edge <= 0.001) return null;
  return (
    // 0.5 is a ceiling, not a taste: louder and the flanks compete with the screen for the
    // firsthand-experience reading, which is the one thing this slot is judged on.
    <g transform={`translate(${x.toFixed(1)} ${y.toFixed(1)}) scale(${k})`} opacity={edge * 0.5}>
      <rect x={-CARD.w / 2} y={-CARD.h / 2} width={CARD.w} height={CARD.h} rx={34} fill={c.tint} />
      <rect
        x={-CARD.w / 2}
        y={-CARD.h / 2}
        width={CARD.w}
        height={CARD.h}
        rx={34}
        fill="none"
        stroke={INK}
        strokeWidth={7}
      />
      <circle cx={-CARD.w / 2 + 74} cy={-CARD.h / 2 + 74} r={14} fill={CLAY} />
      {new Array(c.lines).fill(0).map((_, i) => (
        <rect
          key={i}
          x={-CARD.w / 2 + 52}
          y={-CARD.h / 2 + 150 + i * 62}
          width={CARD.w - 104 - (i === c.lines - 1 ? 190 : 0)}
          height={26}
          rx={13}
          fill={INK}
          opacity={0.82}
        />
      ))}
    </g>
  );
};

/// `frame` is ABSOLUTE. The columns do not restart at a cut, and the outgoing and incoming panels'
/// copies agree pixel-for-pixel through a 40-frame wipe — which they have to, because both are on the
/// frame at once and any disagreement reads as a double image.
///
/// 2.6 px/frame is 78px/s: a card moves its own drawn height in about three seconds. The probe's 0.9
/// was too slow to register inside a four-second beat.
const FlankMarquee: React.FC<{frame: number; near: boolean; far: boolean}> = ({frame, near, far}) => {
  const cols = [
    {cx: FLANK / 2, v: 2.6, phase: 0, k: 0.62, on: near},
    {cx: W - FLANK / 2, v: 1.8, phase: RUN / 2, k: 0.52, on: far},
  ];
  return (
    <svg width={W} height={H} viewBox={`0 0 ${W} ${H}`} style={{position: 'absolute', inset: 0}}>
      {cols.map((col, ci) =>
        col.on
          ? DECK.map((c, i) => {
              const y = H + CARD.h - (((((frame * col.v + col.phase + i * CARD.pitch) % RUN) + RUN) % RUN));
              const jog = Math.sin((frame + i * 140 + ci * 400) * 0.011) * 26;
              return <FlankCard key={`${ci}-${i}`} c={c} x={col.cx + jog} y={y} k={col.k} />;
            })
          : null,
      )}
    </svg>
  );
};

/* ------------------------------------------------------------------ the cut */

export const XF = 40;

/// ONE MECHANISM, SIX BOUNDARIES. Not a `TransitionSeries`: a beat here has to know where it sits on
/// the absolute timeline, and inside a TransitionSeries.Sequence `useCurrentFrame()` restarts at 0 —
/// which would restart the accent field and the marquee at every cut. `motion.ts:109-112` rules it out
/// for exactly this reason and it is load-bearing here.
///
/// A clipPath inset wipe with a 14px GOLD rule riding the edge. The outgoing panel is drawn UNDERNEATH
/// at full opacity and removed only once the edge has closed — a fade would show ground through the
/// leading edge and the whole thing would read as a dissolve. Removal happens at the instant the edge
/// is closed, when it moves no pixels.
const Wipe: React.FC<{p: number; dir: 1 | -1; children: React.ReactNode}> = ({p, dir, children}) => {
  const e = clamp01(p) * 100;
  const open =
    dir === 1 ? `inset(0% ${(100 - e).toFixed(3)}% 0% 0%)` : `inset(0% 0% 0% ${(100 - e).toFixed(3)}%)`;
  const x = dir === 1 ? (e / 100) * W : W - (e / 100) * W;
  return (
    <>
      <AbsoluteFill style={{clipPath: open}}>{children}</AbsoluteFill>
      {p > 0.001 && p < 0.999 ? (
        <div
          style={{
            position: 'absolute',
            left: x - 7,
            top: 0,
            width: 14,
            height: H,
            background: GOLD,
            opacity: interpolate(p, [0, 0.1, 0.9, 1], [0, 1, 1, 0], {
              extrapolateLeft: 'clamp',
              extrapolateRight: 'clamp',
            }),
          }}
        />
      ) : null}
    </>
  );
};

type Beat = {
  from: number;
  /// Direction is a rule, not an alternation: SCREENS arrive left→right, TYPE arrives right→left.
  dir: 1 | -1;
  dark?: boolean;
  near: boolean;
  far: boolean;
  /// Drawn inside the Ground's svg, under everything. Only the close uses it, for the nest. Gets the
  /// absolute frame as well as the beat-local one, because anything that has to survive the loop seam
  /// has to be periodic on the absolute timeline.
  ground?: (f: number, frame: number) => React.ReactNode;
  render: (f: number) => React.ReactNode;
};

/// A beat is alive from its own `from` until the NEXT beat's wipe has closed. Array order is time
/// order, so the incoming panel draws last and the wipe uncovers new over old.
///
/// AND THE SEAM IS THE SEVENTH BOUNDARY, not an exception to the six. Beat 1 used to get `p = 1`
/// unconditionally, which made 899→0 the only hard cut in the piece: measured, that step moved 27.5% of
/// the frame against a whole-timeline maximum of 7.6% for any other step — the nest and the wordmark
/// vanished and the far marquee column appeared at phase 0, all in one frame. It also left frame 0
/// carrying nothing at all, because beat 1's own entrance starts there, so the poster frame of this
/// mp4 was bare ground.
///
/// The fix is to keep the LAST beat standing for the first `XF` frames of the next loop, drawn first so
/// beat 1's wipe uncovers it exactly like every other cut. `f` is carried across the wrap (`frame +
/// TOTAL - from`) so beat 7's ramps stay clamped at their settled end instead of restarting.
const live = (frame: number, beats: Beat[]) => {
  const last = beats.length - 1;
  const on = beats
    .map((b, i) => ({b, i, f: frame - b.from, p: clamp01((frame - b.from) / XF)}))
    .filter((e) => frame >= e.b.from && (e.i === last || frame < beats[e.i + 1].from + XF));
  if (frame < XF) on.unshift({b: beats[last], i: last, f: frame + TOTAL - beats[last].from, p: 1});
  return on;
};

/* ------------------------------------------------------------------ type */

/// 230, not the 210 an earlier cut used and not `TYPE.title` 168. 210 gave Hangul ink 189px = 0.184 of
/// the 1029 guaranteed height, under `CAP_FRACTION.floor` of 0.20. 230 gives ~207px = 0.201 — the floor
/// is MET, not exceeded, because width binds: at 230 the longest line here (붙여넣으면 됩니다) runs
/// ~1820px against a 2047px column. That is also why the old 어떤 언어로 쓰였든, line could not survive
/// the size bump — 2026px against 2047 would have clipped silently under `whiteSpace: 'pre'`.
const TITLE_PX = 230;
const LEAD = 253; // 230 * TYPE.titleLead
const RULE_W = 460;

/// 1.06x the line pitch with matching slack top and bottom, so a face or size change cannot clip the
/// ascenders the way an exact-fit box would.
const MASK_H = 269;

const TypeCard: React.FC<{title: string[]; sub: string; f: number}> = ({title, sub, f}) => {
  const top = S.y0 + 180;
  const ruleY = top + title.length * LEAD + 4;
  const draw = ramp(f, 34, 64);
  return (
    <>
      {title.map((line, i) => {
        // Each line rises OUT OF NOTHING inside its own overflow box rather than fading in, which is
        // the only entrance that reads at store size — a 30-frame opacity ramp on 230px type is
        // indistinguishable from a slow render.
        const p = ramp(f, i * 10, i * 10 + 28);
        return (
          <div
            key={i}
            style={{
              position: 'absolute',
              left: S.x0 + 60,
              top: top + i * LEAD - 8,
              width: S.w - 120,
              height: MASK_H,
              overflow: 'hidden',
            }}
          >
            <div
              style={{
                marginTop: 8,
                translate: `0px ${((1 - p) * MASK_H).toFixed(1)}px`,
                fontFamily: UI,
                fontWeight: TYPE.titleWeight,
                fontSize: TITLE_PX,
                lineHeight: TYPE.titleLead,
                letterSpacing: TYPE.titleTracking,
                color: CREAM,
                whiteSpace: 'pre',
              }}
            >
              {line}
            </div>
          </div>
        );
      })}
      <svg width={W} height={H} viewBox={`0 0 ${W} ${H}`} style={{position: 'absolute', inset: 0}}>
        <line
          x1={S.x0 + 66}
          y1={ruleY}
          x2={S.x0 + 66 + RULE_W}
          y2={ruleY}
          stroke={GOLD}
          strokeWidth={12}
          strokeLinecap="round"
          strokeDasharray={RULE_W}
          strokeDashoffset={((1 - draw) * RULE_W).toFixed(1)}
        />
      </svg>
      <div
        style={{
          position: 'absolute',
          left: S.x0 + 66,
          top: ruleY + 52,
          opacity: ramp(f, 48, 64),
          fontFamily: UI,
          fontWeight: TYPE.subWeight,
          // Nothing gold may shrink: GOLD #F0B865 on FIELD #8A4B2A is 3.80:1, which clears large-text
          // 3:1 and fails normal-text 4.5:1. Every gold element in this file is >= 72px.
          fontSize: 84,
          color: GOLD,
        }}
      >
        {sub}
      </div>
    </>
  );
};

/* ------------------------------------------------------------------ annotation */

/// The anchor sits 70px off the fitted screen's right edge; the label is right-aligned INSIDE the
/// guaranteed box. That is deliberate — it is the only type on a screen beat, so a crop to the
/// 2167x1029 box shows a real screen AND a Korean word instead of a bare picture of a phone.
///
/// WHICH IS ALSO WHY EVERY CALLOUT'S `y` IS BELOW 870. Being inside the box horizontally is half the
/// claim and the easy half. The guaranteed box runs y 765.5..1794.5, the label's baseline is y-34 and
/// this face's Hangul ink reaches ~52px above its baseline, so an anchor at y 700 — where the shot
/// list put the first one — draws its label with ink from 614 to 666, entirely ABOVE the box. Measured
/// on a render of frame 200: crop to S and there was a screen and no word. The floor is
/// y >= S.y0 + 20 + 52 + 34 = 872.
///
/// AND THE LABEL HAS A WIDTH BUDGET, which is the other half of the same clearance. It is right-aligned
/// at `S.x1 - SAFE_INSET` = 2948.5 and may not come within 70px of the screen's right edge at 2548.5,
/// so it gets 330px. Measured off a render, this face sets Hangul at ~0.90em and the space at ~0.28em,
/// so at 72px five syllables plus a space is ~328px and six is ~390px. 웹사이트 주소 was six: it started
/// 1.6px off the device and read as fused to the white sheet. Five is the ceiling here.
const ANCHOR_X = (W + SCREEN_W) / 2 + 70; // 2618.5
const LEADER_W = 300;

const Callout: React.FC<{y: number; text: string; f: number; grow: [number, number]; go: [number, number]}> = ({
  y,
  text,
  f,
  grow,
  go,
}) => {
  const p = ramp(f, grow[0], grow[1]);
  const out = 1 - ramp(f, go[0], go[1]);
  if (p * out <= 0.001) return null;
  return (
    <svg
      width={W}
      height={H}
      viewBox={`0 0 ${W} ${H}`}
      style={{position: 'absolute', inset: 0}}
      opacity={p * out}
    >
      <line
        x1={ANCHOR_X}
        y1={y}
        x2={ANCHOR_X + LEADER_W * p}
        y2={y}
        stroke={GOLD}
        strokeWidth={10}
        strokeLinecap="round"
      />
      <circle cx={ANCHOR_X} cy={y} r={18} fill={CLAY} />
      <text
        x={S.x1 - SAFE_INSET}
        y={y - 34}
        textAnchor="end"
        fontFamily={UI}
        fontSize={72}
        fontWeight={700}
        fill={CREAM}
      >
        {text}
      </text>
    </svg>
  );
};

/* ------------------------------------------------------------------ the beats */

const BEATS: Beat[] = [
  // 1 · 0-140. WHAT IT IS. This card exists because of Apple's first criterion and nothing else:
  //    someone who searched for a reader has to learn in one glance that this is one. From f 64 the
  //    type is still and the frame is carried by the far marquee column and the accents — which is the
  //    ground's entire justification.
  {
    from: 0,
    dir: 1,
    near: false, // the headline lives in the near column's lane and the cards crowd the title
    far: true,
    render: (f) => (
      <TypeCard title={['읽는 사이트를', '한곳에']} sub="구독한 사이트의 새 글이 자동으로 모입니다." f={f} />
    ),
  },

  // 2 · 140-250. The list itself. The screen is STATIC for 3.7s and that is accepted, not overlooked:
  //    fitting by height leaves zero slack, so no Ken Burns of any kind is available. The real fix is
  //    upstream — a scroll recording, which would make the source taller than the window.
  {
    from: 140,
    dir: 1,
    near: true,
    far: true,
    render: (f) => (
      <>
        <Screen f={CAP}>
          <Img src={staticFile('shots/ko__iphone-6.9__08-articles.png')} style={{width: CAP.w, display: 'block'}} />
        </Screen>
        {/* 920, not 700: see ANCHOR_X. 880 cleared S.y0 but only by 29px, inside `SAFE_INSET`; 920
            puts the label’s ink top at 834, which is 69px in. */}
        <Callout y={920} text="안 읽은 글" f={f} grow={[52, 70]} go={[96, 110]} />
      </>
    ),
  },

  // 3 · 250-360. HOW YOU START.
  {
    from: 250,
    dir: -1,
    near: false,
    far: true,
    render: (f) => (
      <TypeCard title={['주소만', '붙여넣으면 됩니다']} sub="사이트 주소 하나로 피드를 찾아냅니다." f={f} />
    ),
  },

  // 4 · 360-530. Filmed rather than described, and the reason the screens are shown whole: the payoff
  //    is the fourth feed arriving in the list, which a cropped panel would cut off.
  //
  //    TRIM 130 AND NOT 54, WHICH IS THE WHOLE FIX ON THIS BEAT. The clip's events sit at source 1.8s
  //    (the add menu), 4.0s (sheet up, placeholder), 5.5s (the paste chip), 7.5s (the URL pasted), 9.0s
  //    (사이트 확인 중), 10.0s (the list back with tech.kakao.com in it), 10.6s (settled). At 54/1.55 the
  //    beat opened on 1.8s and spent its first 2.4s on a sheet with one empty field and 70% of its
  //    height blank, then reached the payoff at local f 162 — eight frames of it clear before the wipe
  //    began eating the frame. Both ends were wrong: the dead part was at the front and the part the
  //    beat exists for was under the cut.
  //
  //    Source seconds are now (130 + f*1.22)/30 → 4.33s at f=0, so it opens on the sheet already up and
  //    the paste chip lands at f 29; the payoff lands at f 139 and holds clear for 31 frames before the
  //    wipe starts. Longest still stretch is the pasted URL sitting in the field, f 79..112 (1.1s).
  //
  //    Verified against `remotion/dist/cjs/video/get-current-time.js`: trimBefore is an inner Sequence
  //    from={-trimBefore} and the expected media frame is `trimBefore + f*playbackRate` — the trim is
  //    NOT scaled by the rate, which is the easy way to be 30 frames wrong.
  //
  //    The Sequence runs 170 + XF so the clip keeps playing under the OUTGOING half of the next wipe.
  //    It reaches the 11.84s EOF at f 185 and holds its last frame for the rest — which is the settled
  //    feed list, i.e. the payoff, while it is being wiped away. The device is fully covered by f 197.
  //    (54/1.55 also ran past EOF, at f 194; the old comment checked f 192 and stopped one frame short
  //    of noticing.)
  {
    from: 360,
    dir: 1,
    near: true,
    far: true,
    render: (f) => (
      <>
        <Sequence from={360} durationInFrames={170 + XF}>
          <Screen f={CAP}>
            <OffthreadVideo
              src={staticFile('video/06-add-feed.mp4')}
              trimBefore={130}
              playbackRate={1.22}
              muted
              toneMapped={false}
              style={{width: CAP.w, display: 'block'}}
            />
          </Screen>
        </Sequence>
        {/* Up while the paste chip and the URL are what the device is doing, down before the 확인 중
            spinner. NO callout on the payoff: the arriving feed is the most legible event in the piece
            and a second leader line would turn the frame into a diagram.

            사이트 주소, not 웹사이트 주소 — six syllables overran the width budget at ANCHOR_X and touched
            the sheet. Nothing is lost: beat 3's subtitle sets the phrase up two beats earlier.

            y 920 for the reason at ANCHOR_X, and it costs something here that it does not cost on the
            other two beats: the sheet's URL field is at source y 305..410, which is canvas y 124..223,
            so this anchor is level with blank sheet rather than with the field it names. Taken anyway,
            because the alternative is a beat whose guaranteed crop has no word in it at all. The
            retract runs to local 124 so the label is still up at frame 470, which is one of the three
            frames this asset is checked on. */}
        <Callout y={920} text="사이트 주소" f={f} grow={[30, 48]} go={[110, 124]} />
      </>
    ),
  },

  // 5 · 530-640. THE DIFFERENTIATOR, stated as what is actually on the next frame.
  //
  //    The earlier line promised the reverse of the footage. Both translate recordings are real-device
  //    Korean→English and there is no recapture available — Apple Intelligence translation does not run
  //    in the simulator. So the copy changed, and it is not a dodge: the headline describes exactly
  //    what happens on screen (the original headline stays, a translation card appears beneath it) and
  //    names no target language, so it cannot be read as "your Korean becomes English". The subtitle
  //    names the target once, as a setting the reader chooses. It no longer claims the body, because
  //    the body clip is no longer in the piece.
  {
    from: 530,
    dir: -1,
    near: false,
    far: true,
    render: (f) => (
      <TypeCard title={['제목은 그대로,', '번역은 그 아래에']} sub="읽을 언어는 설정에서 고릅니다." f={f} />
    ),
  },

  // 6 · 640-790. The only dark beat, and the ground goes dark WITH it — carried by the wipe over 40
  //    frames rather than flipped across the whole canvas in one, which is what the previous cut did on
  //    two content-empty frames (a 3.5x luminance jump over 100% of the frame area). Both panels draw
  //    their Ground from the same absolute `u`, so the accent field's phase is provably identical
  //    either side of the seam: it changes brightness, which is the point, and nothing else.
  //
  //    Source seconds are (18 + f*1.32)/30 → 0.60s at f=0, 7.20s at f=150, 8.17s at f=190 against an
  //    8.72s clip. Four complete translation cards land at local f ~2, 49, 99, 134; max gap 50f. The
  //    source is 60fps CFR with a measured 0 px/frame of scroll — nothing pans, the cards just appear,
  //    which is why this clip survives 1.32x. Card 1 completes at local f 36, four frames before the
  //    wipe closes: the reveal delivers an event rather than arriving on a still frame.
  {
    from: 640,
    dir: 1,
    dark: true,
    near: true,
    far: true,
    render: (f) => (
      <>
        <Sequence from={640} durationInFrames={150 + XF}>
          <Screen f={CLIP}>
            <OffthreadVideo
              src={staticFile('video/04-translate-list.mov')}
              trimBefore={18}
              playbackRate={1.32}
              muted
              toneMapped={false}
              style={{width: CLIP.w, display: 'block'}}
            />
          </Screen>
        </Sequence>
        {/* 995, not 400 — see ANCHOR_X. It costs nothing here: 400 was level with the FIRST translation
            card and 995 is level with the second, which has landed by local 49 and is still there when
            the callout finishes growing at local 60. */}
        <Callout y={995} text="번역된 제목" f={f} grow={[42, 60]} go={[140, 154]} />
      </>
    ),
  },

  // 7 · 790-900. THE CLOSE, and the only beat with neither type card nor screen. The nest is the app's
  //    icon, and a listing that ends on its own mark is remembered as one thing rather than as three
  //    recordings. Both marquee columns are off: the nest is the object in this frame and cards
  //    drifting past it is two subjects. The removal is done by the wipe, not by a fade.
  //
  //    STILLNESS IS THE CONTENT HERE, BUT IT WAS A FREEZE. Everything on this beat had settled by local
  //    f 41 — `ramp(f, 0, 46)` is at 0.9995 there — and the accents' own breathing is ~0.1px/frame on a
  //    120px shape, so frames 831..899 were pixel-identical: 2.3s of mean-abs-diff 0.003 against the
  //    shipping sibling's 0.96 in the same slot. So the nest keeps a slow float that never terminates,
  //    built from `periodic` and not from a ramp: 6 cycles over TOTAL is a 5s period, ±30px (19px as
  //    the store draws this), and sin closes the loop exactly, which an eased ramp cannot.
  {
    from: 790,
    dir: -1,
    near: false,
    far: false,
    /// `frame` is ABSOLUTE for the float, so it is identical either side of the seam and unaffected by
    /// the wrap in `live()` handing this beat an `f` of 110 and up.
    ground: (f, frame) => (
      <g
        transform={`translate(0 ${(
          (1 - ramp(f, 0, 46)) * 90 +
          Math.sin(periodic(frame, TOTAL) * 6) * 30
        ).toFixed(1)})`}
      >
        <NestBack />
        <NestFront />
      </g>
    ),
    render: (f) => (
      <>
        <div
          style={{
            position: 'absolute',
            left: S.x0 + 60,
            top: S.y0 + 60,
            opacity: ramp(f, 12, 42),
            fontFamily: UI,
            fontWeight: TYPE.titleWeight,
            // 290, not 220. This face's measured cap ratio is 0.709em, so 220 is 156px = 0.152 of the
            // guaranteed height — ten percent above the 0.138 `motion.ts:37-38` records as rejected
            // twice, on the frame the listing is meant to be remembered by. 290 gives 206px = 0.200.
            // Width by `inkRatio(3.14, 4, 0.02)` = 3.20em = 928px, right edge 1824.5; the nest's ink
            // does not reach above y 1412, so the wordmark's band is clear of it.
            fontSize: 290,
            letterSpacing: '0.02em',
            color: CREAM,
          }}
        >
          NOOK
        </div>
        <div
          style={{
            position: 'absolute',
            left: S.x0 + 66,
            top: S.y0 + 340,
            opacity: ramp(f, 26, 56),
            fontFamily: UI,
            fontWeight: TYPE.subWeight,
            fontSize: 88,
            color: GOLD,
          }}
        >
          읽을거리는 내가 고릅니다
        </div>
      </>
    ),
  },
];

/* ------------------------------------------------------------------ assembly */

/// A full-bleed panel: its own ground, its own marquee gating, its own contents. Two of these are on
/// the frame for the 40 frames of a wipe — about 60 extra SVG shapes, which is free.
const Panel: React.FC<{b: Beat; f: number; frame: number; u: number}> = ({b, f, frame, u}) => (
  <AbsoluteFill>
    <Ground u={u} dark={!!b.dark}>
      {b.ground ? b.ground(f, frame) : null}
    </Ground>
    <FlankMarquee frame={frame} near={b.near} far={b.far} />
    {b.render(f)}
  </AbsoluteFill>
);

export const SearchHybrid: React.FC<{guides?: boolean}> = ({guides = false}) => {
  const frame = useCurrentFrame();
  const u = frame / TOTAL;

  return (
    <AbsoluteFill style={{background: FLAT.field}}>
      {live(frame, BEATS).map((e) => (
        <Wipe key={e.i} p={e.p} dir={e.b.dir}>
          <Panel b={e.b} f={e.f} frame={frame} u={u} />
        </Wipe>
      ))}
      {guides ? (
        <svg width={W} height={H} style={{position: 'absolute', inset: 0}}>
          <rect x={S.x0} y={S.y0} width={S.w} height={S.h} fill="none" stroke="#FF00FF" strokeWidth={6} />
        </svg>
      ) : null}
    </AbsoluteFill>
  );
};
