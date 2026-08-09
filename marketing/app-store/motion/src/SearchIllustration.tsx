import React from 'react';
import {AbsoluteFill, useCurrentFrame} from 'remotion';
import {CANVAS} from './theme';

/// SEARCH RESULTS — the illustrated draft, kept alongside the screenshot cut rather than replacing it.
///
/// The reference is Apple's own editorial art (the "Travel With Siri Shortcuts" card and its family):
/// one saturated flat field, flat-colour objects with no gradients and no perspective, hand-drawn
/// accents scattered through the negative space, and a heavy sans headline sitting straight on top of
/// the picture. It works in that slot because it reads as a POSTER at any size — there is nothing in it
/// small enough to lose — which is the exact failure mode the screenshot cut spent six revisions
/// fighting.
///
/// WHAT IT TRADES. The screenshot cut is evidence: those are real screens and a viewer can check them.
/// This is a claim, drawn. It can say "every language arrives as yours" in one image, which no
/// screenshot can, and it cannot prove the app exists. That is the actual decision between the two,
/// and it is worth taking deliberately rather than on taste.
///
/// THE SCENE. Article cards in five scripts spiral in from the edges of the frame; as each crosses the
/// middle its type turns into the reader's language; and they are gathered by a nest, which is the app
/// icon and the centre of the picture rather than decoration in it. The nest is drawn here rather than
/// generated with `twig.ts`: that generator exists to make wood look REAL — it tapers every rod, kinks
/// it at knuckles, splits it into shoots — and one realistic element inside a flat illustration reads
/// as a mistake rather than as craft. See the long note above `BARK` for what it is instead, and for
/// the two rejected nests it was chosen over.
///
/// Everything is periodic over the 900-frame loop: card positions are angles on a circle, accents
/// breathe on a divisor of the period. Nothing eases one way.

const {width: W, height: H} = CANVAS.search;
const SAFE = {
  x0: (W - CANVAS.search.safe.width) / 2, // 836
  y0: (H - CANVAS.search.safe.height) / 2, // 765
  x1: (W + CANVAS.search.safe.width) / 2, // 3003
  y1: (H + CANVAS.search.safe.height) / 2, // 1794
};

const TOTAL = 900;

/// A flat field, not the screenshot cut's gradient. Apple's cards commit to one saturated colour and
/// let the art carry the depth; a gradient here would be the illustration apologising for being flat.
/// This is Nook's darkest wood tone pushed to a printable flat, so the two assets are recognisably the
/// same brand without being the same treatment.
export const FIELD = '#8A4B2A';
export const CREAM = '#FFF3DC';
export const INK = '#2B1A0E';
export const GOLD = '#F0B865';
export const SAGE = '#9DAE86';
export const CLAY = '#D9714B';

export const UI =
  "-apple-system, 'SF Pro Display', 'Apple SD Gothic Neo', 'Helvetica Neue', Helvetica, sans-serif";

const clamp01 = (v: number) => (v < 0 ? 0 : v > 1 ? 1 : v);
const TAU = Math.PI * 2;

/* ------------------------------------------------------------------ the cards */

/// Five sources, five scripts, and the same sentence underneath. The headlines are invented: a real
/// masthead in a store asset is a trademark and an implied endorsement, and invented independent
/// titles read as the kind of writing this app is for.
///
/// `foreign` is what the card carries on its way in; `mine` is what it carries once it has crossed the
/// middle. They are the same length on purpose, so the card does not resize as it turns — a card that
/// grew would read as a different card rather than the same one, translated.
/// SIX cards, of which any one build shows five.
///
/// Each card is written in its own language and carries the same headline in every language the
/// listing ships. A build then drops the card whose SOURCE language is the reader's — a Japanese
/// reader must not be shown a Japanese card as the thing being translated, which is the one way this
/// scene can state its claim backwards. Six sources for four locales means every build still has five.
///
/// The mastheads are invented. A real one in a store asset is a trademark and an implied endorsement,
/// and invented independent titles read as the kind of writing this app is for.
type Lang = 'ko' | 'en' | 'ja' | 'zh-Hans';
type PoolCard = {
  source: string;
  /// The language the piece was written in.
  src: Lang | 'no' | 'fr';
  /// Two lines per language. Two because the card is a fixed rectangle and a headline that reflows
  /// would change the card's shape mid-translation, which is the one thing the streaming must not do.
  lines: Record<string, [string, string]>;
  tint: string;
};

const POOL: PoolCard[] = [
  {
    source: '慢水',
    src: 'ja',
    tint: CREAM,
    lines: {
      ja: ['流れの遅い川ほど', '深く削る'],
      ko: ['느린 강일수록', '깊게 깎는다'],
      en: ['Slow water', 'cuts deepest'],
      'zh-Hans': ['水流越慢', '切得越深'],
    },
  },
  {
    source: 'NORDLYS',
    src: 'no',
    tint: GOLD,
    lines: {
      no: ['Lys i den', 'lange vinteren'],
      ko: ['긴 겨울의', '빛'],
      en: ['Light in the', 'long winter'],
      ja: ['長い冬の', '光'],
      'zh-Hans': ['漫长冬日', '的光'],
    },
  },
  {
    source: 'Papier & Encre',
    src: 'fr',
    tint: CREAM,
    lines: {
      fr: ['La marge', 'comme une pièce'],
      ko: ['여백이라는', '방 하나'],
      en: ['The margin', 'as a room'],
      ja: ['余白という', '部屋'],
      'zh-Hans': ['留白', '如一间房'],
    },
  },
  {
    source: '边注',
    src: 'zh-Hans',
    tint: SAGE,
    lines: {
      'zh-Hans': ['读得慢一点', '记得久一点'],
      ko: ['천천히 읽으면', '오래 남는다'],
      en: ['Read slower,', 'remember longer'],
      ja: ['ゆっくり読めば', '長く残る'],
    },
  },
  {
    source: 'Field Notes',
    src: 'en',
    tint: CREAM,
    lines: {
      en: ['On keeping a', 'reading table'],
      ko: ['읽을 것을 두는', '탁자에 대하여'],
      ja: ['読む物を置く', '机について'],
      'zh-Hans': ['关于一张', '读书桌'],
    },
  },
  {
    source: '우물',
    src: 'ko',
    tint: GOLD,
    lines: {
      ko: ['깊은 우물은', '대답이 늦다'],
      en: ['A deep well', 'answers late'],
      ja: ['深い井戸は', '答えが遅い'],
      'zh-Hans': ['深井', '回答得慢'],
    },
  },
];

/// The five this build shows, and the two texts each one needs.
const deckFor = (locale: Lang) =>
  POOL.filter((c) => c.src !== locale)
    .slice(0, 5)
    .map((c) => ({
      source: c.source,
      tint: c.tint,
      foreign: c.lines[c.src],
      mine: c.lines[locale],
    }));

/// Cards SPIRAL IN. The first draft put each on a fixed circle, and five things going round a point
/// read as drifting rather than as gathering — which is the opposite of what this app does. Now the
/// radius falls from off-canvas to the nest's rim across one turn, the card shrinks as it comes, and
/// it is swallowed by the front of the weave; a new one enters off-frame behind it. The loop closes
/// because entry and exit both happen where they cannot be seen, not because the path is a circle.
///
/// The sweep starts in the upper RIGHT and turns clockwise through the bottom, so a card is only ever
/// high in the frame while it is far out on the right. The headline lives at the top LEFT, and this is
/// what keeps the two apart — in the first draft the orbits ran straight through the type.

/// WHERE THE NEST SITS, and why it is not at y 1560 any more.
///
/// The rejected nest was 500px tall, so a spiral centred at 1560 cleared the subtitle without anyone
/// having to think about it. A BOWL is 930px tall — that is the cost of having an inside — and at 1560
/// its back rim runs from y 1077, straight through the gold subtitle at y 1192-1254. Measured on the
/// render, not guessed: 915 pixels of wood on the subtitle's own baseline row.
///
/// So the nest is FITTED rather than moved, and then deliberately overgrown.
///
/// At 0.9 with its centre at 1740 the bowl ran 1305..2145 — clear of the subtitle, but it left 415px of
/// bare field between its underside and the canvas floor, so the object read as sitting low in a frame
/// with a dead strip beneath it. Shrinking it to close that gap is the wrong direction; the whole
/// difficulty of this asset has been things being too small.
///
/// So it is scaled UP until it leaves the canvas: 1.45 uniform (never non-uniform — that ovals every
/// round cap), centre at 1975. Top lands at 1290, clearing the subtitle by 65px; bottom at 2660, which
/// is 100px past the canvas floor, so there is no underside to leave a gap. Width 2677 — wider than the
/// 2167 safe box, which is correct: this is bleed, and only the bowl's OPENING has to be guaranteed.
/// The opening sits at roughly 1290..1760 against a safe floor of 1794.
///
/// `NEST` is the spiral's target as well as the nest's centre, so the cards follow it down and still
/// land in the bowl.
const NEST = {x: W / 2, y: 1975};
const SPIRAL = {start: -0.15, turns: 1.15, rFar: 2500, rNear: 300, squash: 0.4};

/// THE TYPE'S OWN RECTANGLE, and cards are pushed out of it.
///
/// The previous attempt kept cards off the headline by choosing where the spiral STARTS, which works
/// for exactly as long as the spiral has not come round again — and it comes round once per loop, at a
/// radius small enough to miss the headline and exactly right to cross the subtitle. Steering by angle
/// cannot solve a geometry problem; this states the geometry.
///
/// The push is vertical and it is ramped by horizontal distance, so a card slides under the type
/// instead of stepping around it. A hard clamp would read as the card hitting glass.
const TYPE = {x0: SAFE.x0 + 40, y0: SAFE.y0 + 20, x1: SAFE.x0 + 1560, y1: SAFE.y0 + 520};
const smoothstep = (edge0: number, edge1: number, v: number) => {
  const t = clamp01((v - edge0) / (edge1 - edge0));
  return t * t * (3 - 2 * t);
};

/// Where a card stops being in front of the nest and starts being inside it. 0.62 rather than the 0.66
/// the landing used to start at, so the card is settled over the opening for a moment before it sinks.
const SWAP = 0.62;

/// The parent needs each card's phase to decide which layer to draw it in, and it has to be the SAME
/// number the card computes for itself or the two would disagree by a frame.
const DECK_N = 5;
export const cardPhase = (index: number, u: number) => (u + index / DECK_N) % 1;

type DeckCard = ReturnType<typeof deckFor>[number];

const Card: React.FC<{index: number; u: number; card: DeckCard}> = ({index, u, card}) => {
  // Staggered so one is always arriving and one always leaving.
  const phase = index / DECK_N;
  const a = (u + phase) % 1;
  const theta = (SPIRAL.start + a * SPIRAL.turns) * TAU;
  // Radius falls fast at first and slows into the nest, which is how a thing being drawn in moves —
  // a linear fall reads as a machine feeding parts.
  const r = SPIRAL.rFar + (SPIRAL.rNear - SPIRAL.rFar) * (1 - Math.pow(1 - a, 2));
  const xSpiral = NEST.x + Math.cos(theta) * r + ((index * 137) % 180) - 90;
  const ySpiral = NEST.y + Math.sin(theta) * r * SPIRAL.squash - 140;

  // THE HOVER, and it exists to hide a layer change.
  //
  // Cards used to be drawn in ONE place — between NestBack and NestFront — for their whole path, so a
  // card was behind the near wall from the moment it entered the nest's silhouette. Measured on the
  // render: the green card held 7062, 6786, 6468, 6151, 5834 visible pixels on frames 300-320, losing
  // about 5% a frame, and then 0 on frame 325. A hard cut, at an opacity of 0.65 — it was not fading
  // out, it was being clipped by wood it was supposed to still be in front of.
  //
  // Splitting the cards into two layers fixes the clipping and introduces a worse problem: the swap
  // itself pops, because a card that is behind the near wall one frame and in front of it the next
  // changes shape instantly.
  //
  // So the trajectory does the work. Every card is steered to a HOVER POINT directly over the opening
  // before it descends, and the swap happens there. Over the opening the near wall is not between the
  // card and the viewer — the hollow is — so moving the card from the front layer to the middle one
  // changes not one pixel. The measured opening is centred (1965, 1804) with ry 210, so its lower arc
  // is at y 2014 on the centre column; the hover sits at 1660 with a half-height of 146, i.e. a bottom
  // edge at 1806, clear of that arc by 208px. The swap is invisible by construction rather than by
  // being fast.
  const HOVER = {x: 1965 + (((index * 211) % 320) - 160), y: 1660};

  // THE LANDING — a card LIES DOWN INTO the bowl instead of dropping behind it.
  //
  // The previous version pushed the card 300px straight down over the last quarter turn and faded it
  // out. Two things were wrong with that and they compound: straight down from a spiral that ends at
  // r=300 takes the card out through the NEAR WALL rather than into the opening, so it read as passing
  // behind the nest; and it stayed a square upright rectangle the whole way, so nothing about it said
  // "settling into something". Together they made the disappearance abrupt.
  //
  // Now the last third steers to a point inside the measured opening — world (1965, 1804), rx 870,
  // ry 210, computed from HOLE through the fit transform rather than eyeballed — and 180px below its
  // centre, which is where the near wall's top boundary starts covering things. On the way the card
  // foreshortens to 0.3 of its height, which is what a flat card does as it goes from facing you to
  // lying in a bowl, and it turns a few degrees so it does not land square to the frame.
  const land = smoothstep(SWAP, 1, a);
  const LAND = {x: HOVER.x, y: 1984};
  // Two blends that meet exactly at the hover, so position is continuous across the layer change: the
  // spiral is steered into HOVER over the approach, then HOVER is carried down into the bowl.
  const gather = smoothstep(0.4, SWAP, a);
  const x = a < SWAP ? xSpiral + (HOVER.x - xSpiral) * gather : HOVER.x + (LAND.x - HOVER.x) * land;
  const yRaw =
    a < SWAP ? ySpiral + (HOVER.y - ySpiral) * gather : HOVER.y + (LAND.y - HOVER.y) * land;
  const scale = 1.05 - a * 0.45;
  // Foreshortening, applied to Y only — the card keeps its width as it tips away from the viewer.
  const lie = 1 - land * 0.7;

  // Clear the type. `hx` is 1 while the card shares columns with the type block and falls to 0 over
  // 420px either side, so the push arrives and leaves gradually.
  const halfW = 300 * scale;
  const halfH = 190 * scale;
  const hx =
    smoothstep(TYPE.x0 - halfW - 420, TYPE.x0 - halfW, x) *
    (1 - smoothstep(TYPE.x1 + halfW, TYPE.x1 + halfW + 420, x));
  const clearY = TYPE.y1 + 90 + halfH;
  const y = yRaw + hx * Math.max(0, clearY - yRaw);
  // The fade is a safety net, not the mechanism: by the time it starts the card is already three
  // quarters behind the near wall. Fading earlier is what made the old landing look like a bug.
  const alpha = Math.min(clamp01(a / 0.06), clamp01((1.0 - a) / 0.06));

  // The turn happens as the card crosses the middle third of its way round, over about a fifth of the
  // loop — long enough to be seen, short enough that most of the time a card is one language or the
  // other rather than mid-morph.
  // THE TRANSLATION, STREAMED — the way the app actually does it, rather than a card flipping over.
  //
  // The flip was a graphic idea with nothing behind it. The screen recording of the real feature shows
  // something better and more specific: the source paragraph DIMS, a block caret appears at its head,
  // and the translation writes in over about a second, one paragraph at a time with the next starting
  // before the last has settled. That is a thing only this app does, so drawing what it does is worth
  // more than drawing a transition.
  //
  // `turn` runs over 0.16 of the loop — 144 frames, 4.8s — which is close to the 4s per paragraph
  // measured off the recording. The two lines are staggered by 0.18 of that so the second is still
  // going when the first finishes.
  const turn = clamp01((a - 0.42) / 0.16);
  /// Per line: dim the source, then write the translation in. The windows are SEQUENTIAL — line 1 does
  /// not start until line 0 is done — because overlapping them put two carets on one card at once,
  /// which no editor and no translator has ever done.
  const SPAN = 0.46;
  const lineState = (i: number) => {
    const p = clamp01((turn - i * 0.5) / SPAN);
    return {
      /// The source, fading out just before its replacement starts.
      fade: 1 - smoothstep(0, 0.3, p),
      /// How much of the translation has been written.
      chars: Math.round(card.mine[i].length * smoothstep(0.3, 1, p)),
      /// The caret rides the end of this line only while this line is the one being written.
      writing: p > 0.26 && p < 0.995,
      p,
    };
  };
  // A few degrees of settle, so it lands askew among the others rather than square.
  const tilt = Math.sin(theta * 2 + index) * 7 + land * (index % 2 === 0 ? 13 : -11);

  return (
    <g
      transform={`translate(${x} ${y}) rotate(${tilt}) scale(${scale} ${scale * lie})`}
      opacity={alpha}
    >
      <rect x={-300} y={-190} width={600} height={380} rx={34} fill={card.tint} />
      <rect x={-300} y={-190} width={600} height={380} rx={34} fill="none" stroke={INK} strokeWidth={7} />
      <text x={-244} y={-110} fontFamily={UI} fontSize={40} fontWeight={700} fill={CLAY} letterSpacing={2}>
        {card.source}
      </text>
      {card.mine.map((_, i) => {
        const st = lineState(i);
        const y0 = -20 + i * 78;
        const written = card.mine[i].slice(0, st.chars);
        return (
          <g key={i}>
            {/* The source line, still there and dimming — it is not removed until the translation has
                started over it, which is what stops the card looking momentarily empty. */}
            {st.fade > 0.01 ? (
              <text x={-244} y={y0} fontFamily={UI} fontSize={62} fontWeight={700} fill={INK} opacity={st.fade}>
                {card.foreign[i]}
              </text>
            ) : null}
            {/* The caret is a TSPAN inside the same text element, not a rect at a computed x.
                Positioning it by `written.length * anAdvanceIGuessed` put it on top of the last glyph:
                Hangul at 62px bold advances about 62px, not the 34 that was assumed, and the error
                grew with every character. Letting the text engine place it is exact by construction and
                stays exact if the copy or the face ever changes. */}
            <text x={-244} y={y0} fontFamily={UI} fontSize={62} fontWeight={700} fill={INK}>
              {written}
              {st.writing ? <tspan fill={CLAY}>▌</tspan> : null}
            </text>
          </g>
        );
      })}
      {/* The sparkle the app puts beside a translated title, once the whole card is through. */}
      {lineState(card.mine.length - 1).p >= 0.995 ? (
        <g transform="translate(228 -128)" fill={CLAY}>
          <path d="M0 -30 L8 -8 L30 0 L8 8 L0 30 L-8 8 L-30 0 L-8 -8 Z" />
        </g>
      ) : null}
    </g>
  );
};

/* ------------------------------------------------------------------ accents */

/// The scattered marks. In Apple's cards these are what stop a flat field reading as an empty one, and
/// they are drawn loose — open squiggles, a star, a few dots — never centred, never aligned to each
/// other. Positions are fixed; only their breathing moves, on a period that divides 900 so the loop
/// closes.
export const ACCENTS: {x: number; y: number; kind: 'squiggle' | 'star' | 'dot' | 'arc'; s: number; c: string}[] = [
  {x: 520, y: 420, kind: 'squiggle', s: 1.2, c: GOLD},
  {x: 3320, y: 560, kind: 'star', s: 1.5, c: CREAM},
  {x: 900, y: 2050, kind: 'dot', s: 1.8, c: SAGE},
  {x: 3060, y: 1980, kind: 'squiggle', s: 1.0, c: CLAY},
  {x: 1980, y: 300, kind: 'arc', s: 1.4, c: CREAM},
  {x: 3560, y: 1320, kind: 'dot', s: 1.2, c: GOLD},
  {x: 320, y: 1280, kind: 'star', s: 1.1, c: CLAY},
  {x: 2660, y: 2320, kind: 'arc', s: 1.0, c: SAGE},
  {x: 1420, y: 2380, kind: 'star', s: 0.9, c: GOLD},
];

export const Accent: React.FC<{a: (typeof ACCENTS)[number]; u: number; i: number}> = ({a, u, i}) => {
  const b = 1 + Math.sin(u * TAU * 2 + i) * 0.08;
  const common = {stroke: a.c, strokeWidth: 9, fill: 'none', strokeLinecap: 'round' as const};
  return (
    <g transform={`translate(${a.x} ${a.y}) scale(${a.s * b})`} opacity={0.9}>
      {a.kind === 'squiggle' ? (
        <path d="M -70 0 q 23 -34 46 0 q 23 34 46 0 q 23 -34 46 0" {...common} />
      ) : null}
      {a.kind === 'arc' ? <path d="M -80 26 a 80 80 0 0 1 160 0" {...common} /> : null}
      {a.kind === 'star' ? (
        <path d="M0 -44 L11 -11 L44 0 L11 11 L0 44 L-11 11 L-44 0 L-11 -11 Z" fill={a.c} />
      ) : null}
      {a.kind === 'dot' ? <circle r={17} fill={a.c} /> : null}
    </g>
  );
};

/* ------------------------------------------------------------------ the nest */

/// A MASS WITH STICKS DRAWN ON IT, and every stick drawn the way the cards are drawn.
///
/// Three nests were built and looked at properly — full size, cropped 1:1, at 900px, and at 600px and
/// 300px, which is the size the store actually draws this asset. Two of them failed at the only
/// question that matters, which is what a stranger names in the first half-second:
///
///   A — outlined sticks laid as courses on nested ellipses. Beautiful at 1:1 and the best container of
///       the three, but its courses are continuous concentric hoops crossed by regular staves, and that
///       is the definition of BASKETRY. At 900px and at 300px it reads "wicker bowl", never "nest".
///   C — an over-under weave resolved by a topological sort. Genuinely woven, genuinely a bowl, and its
///       strands are 60-92px bars with a dome on each end, so at 1:1 they read as sausages and at 300px
///       as beans. "Bowl of noodles" is the exact thing the brief warned against.
///   B — this one. A light BARK mass on the dark field with a near-black opening in it, a blunt lobed
///       silhouette made of stick-ends pressing outward, and sticks laid across the wall in two
///       transverse families. It is the only one of the three that reads NEST first at every size from
///       3840 down to 300, and the only one whose silhouette never resolves into an eye.
///
/// WHAT WAS TAKEN FROM THE OTHER TWO. Lane B's own worst fault, seen at 1:1, was that its dark marks
/// were INK-cored with a bark knockout around them: on a bare stretch of the mass an ink stroke with no
/// outline reads as a SLOT CUT INTO A SOLID, so the back rim looked like a scored loaf rather than
/// wood. Lane A's single best decision fixes it exactly — EVERY STICK IS AN OUTLINED SHAPE, a wood
/// fill inside a 7px INK line, which is how the cards themselves are built. So the nest's weight
/// matches the cards by construction, over/under stays legible at a grazing angle because the upper
/// stick carries its own dark edge, and a dark stick is dark WOOD rather than a hole. From lane C: the
/// inner face of the far wall is drawn as sticks inside the opening, because that is the one surface
/// that proves there is an inside rather than a hole.
///
/// THREE FLAT TONES, ASSIGNED BY WHICH WAY THE WOOD FACES, never scattered — the rejected version mixed
/// two tones at random so neither meant anything. GOLD is the lit top of the near rim and nothing else.
/// DUSK is wood turned away. BARK is both the mass and the wood facing the viewer, so a BARK stick on
/// the mass reads by its outline alone, which is what keeps the object from turning into speckle.
const BARK = '#B07A42';
const DUSK = '#6B3A1C';

/// The one added tone is BARK, and it is added because a mass needs a fill and every palette colour is
/// spoken for: FIELD is the ground it has to separate from, INK is the hollow, and GOLD/CREAM/SAGE are
/// card tints. Reusing a card tint is what killed the rejected version — its light stick colour was
/// literally GOLD, so the NORDLYS card and the nest fused into one blob at store size. BARK sits in the
/// empty band at relative luminance 129: 43 from FIELD, 38 from SAGE, 60 from GOLD, 101 from INK.
/// Nothing it can touch is within 38 of it, and in any case every stick carries an ink line.
///
/// EDGE is 7.78 rather than 7 because the whole nest is drawn inside the FIT transform below: 7.78 *
/// 0.9 is 7.0 on the canvas, which is exactly the cards' outline. Matching the cards' weight is the
/// point of drawing every stick as an outlined shape; it would be silly to lose it to a transform.
const NEST_S = 1.45;
const EDGE = 7 / NEST_S;

/// The nest is built in its OWN space, centred where the brief originally put it, and then fitted. The
/// drawn object's centre in that space is (1920, 1543) — measured off a render, not derived, because
/// the lobes are not symmetric — and the transform lands that point on `NEST`.
const LOCAL = {x: W / 2, y: 1560};
const NEST_FIT = `translate(${(LOCAL.x * (1 - NEST_S)).toFixed(1)} ${(NEST.y - 1543 * NEST_S).toFixed(
  1,
)}) scale(${NEST_S})`;

/// `NC` is the CONSTRUCTION centre, not the drawn one. The body is 70px deeper below it than above, and
/// its lobes are not symmetric, so the ink pixels centre 75px lower and 31px left of it — the offsets
/// here put the drawn object on the local anchor.
const NC = {x: LOCAL.x + 31, y: LOCAL.y - 75};
const BODY = {rx: 840, ryTop: 330, ryBot: 400};

/// A BOWL, NOT A WASHER, and this asymmetry is the whole container cue. The rejected nest's hollow was
/// concentric with its silhouette — the same 45px of wall above the hole as below it — which is a
/// washer, and at 600px a washer with a dark hole in it reads as a closed eye. Here the opening sits
/// HIGH in the body: 125px of wood above it, 315px below, 240px at the sides. That 1:2.5 is what a bowl
/// seen from slightly above looks like, and it is the only depth cue flat illustration is allowed.
const HOLE = {x: NC.x, y: NC.y - 60, rx: 600, ry: 145};

const VERTS = 72;
const HVERTS = 48;

/// Deterministic, and cheap: the same nest every render without carrying a seeded generator around.
const rnd = (n: number) => {
  const x = Math.sin(n * 127.1 + 311.7) * 43758.5453;
  return x - Math.floor(x);
};

type Pt = [number, number];

const mix = (a: Pt, b: Pt, t: number): Pt => [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t];
const pt = (p: Pt) => `${p[0].toFixed(1)} ${p[1].toFixed(1)}`;

/// Catmull-Rom through the outline vertices, kept as SEGMENTS rather than a finished string, because
/// the front wall has to reuse a sub-arc of the hollow's curve exactly. Rebuilding that boundary as a
/// polyline would leave a sliver of hollow showing along the rim.
type Seg = {a: Pt; b: Pt; c1: Pt; c2: Pt};

const segsOf = (pts: Pt[], t: number): Seg[] => {
  const n = pts.length;
  return pts.map((_, i) => {
    const p0 = pts[(i - 1 + n) % n];
    const p1 = pts[i];
    const p2 = pts[(i + 1) % n];
    const p3 = pts[(i + 2) % n];
    return {
      a: p1,
      b: p2,
      c1: [p1[0] + ((p2[0] - p0[0]) * t) / 3, p1[1] + ((p2[1] - p0[1]) * t) / 3] as Pt,
      c2: [p2[0] - ((p3[0] - p1[0]) * t) / 3, p2[1] - ((p3[1] - p1[1]) * t) / 3] as Pt,
    };
  });
};

const closedPath = (segs: Seg[]) =>
  `M ${pt(segs[0].a)} ` + segs.map((s) => `C ${pt(s.c1)}, ${pt(s.c2)}, ${pt(s.b)}`).join(' ') + ' Z';

const fwd = (segs: Seg[], a: number, b: number) =>
  segs
    .slice(a, b)
    .map((s) => `C ${pt(s.c1)}, ${pt(s.c2)}, ${pt(s.b)}`)
    .join(' ');

const rev = (segs: Seg[], a: number, b: number) => {
  const out: string[] = [];
  for (let i = b - 1; i >= a; i--) out.push(`C ${pt(segs[i].c2)}, ${pt(segs[i].c1)}, ${pt(segs[i].a)}`);
  return out.join(' ');
};

/// THE SILHOUETTE IS WHAT SURVIVES 300px, so it is not an ellipse with noise on it.
///
/// `lobes` are blunt outward bumps about 120px wide and 26-56px proud, twenty of them around a ~3900px
/// perimeter, each one a stick end pressing against the outside of the mass. They are what stops this
/// reading as a blob with scratches on it, and they are what kills the eye: an eye has two clean
/// tapered corners and this has none — at the far left and right there are lobes, not points.
const outlineOf = (
  verts: number,
  centre: Pt,
  radius: (th: number) => Pt,
  wob: [number, number, number, number],
  lobeCount: number,
  lobeAmp: [number, number],
  seed: number,
): Pt[] => {
  const lobes = new Array(lobeCount).fill(0).map((_, k) => ({
    at: (k + 0.5) * (verts / lobeCount) + (rnd(k + seed) - 0.5) * 2.4,
    amp: lobeAmp[0] + rnd(k + seed + 61) * (lobeAmp[1] - lobeAmp[0]),
    hw: 1.1 + rnd(k + seed + 131) * 1.2,
  }));
  const pts: Pt[] = [];
  for (let i = 0; i < verts; i++) {
    const th = (i / verts) * TAU;
    const [px, py] = radius(th);
    const dx = px - centre[0];
    const dy = py - centre[1];
    const len = Math.hypot(dx, dy) || 1;
    const nx = dx / len;
    const ny = dy / len;
    let out = wob[0] * Math.sin(th * wob[1] + 1.2) + wob[2] * Math.sin(th * wob[3] + 0.4);
    for (const L of lobes) {
      let di = i - L.at;
      if (di > verts / 2) di -= verts;
      if (di < -verts / 2) di += verts;
      if (Math.abs(di) <= L.hw) out += L.amp * Math.cos((Math.PI / 2) * (di / L.hw));
    }
    pts.push([px + nx * out, py + ny * out]);
  }
  return pts;
};

const bodyPts = outlineOf(
  VERTS,
  [NC.x, NC.y],
  (th) => [
    NC.x + Math.cos(th) * BODY.rx,
    NC.y + Math.sin(th) * (Math.sin(th) > 0 ? BODY.ryBot : BODY.ryTop),
  ],
  [5, 3.7, 3, 7.1],
  20,
  [26, 56],
  5,
);

const holePts = outlineOf(
  HVERTS,
  [HOLE.x, HOLE.y],
  (th) => [HOLE.x + Math.cos(th) * HOLE.rx, HOLE.y + Math.sin(th) * HOLE.ry],
  [9, 4.3, 5, 8.7],
  11,
  [10, 22],
  211,
);

const bodySegs = segsOf(bodyPts, 0.34);
const holeSegs = segsOf(holePts, 0.45);

const BODY_PATH = closedPath(bodySegs);
const HOLE_PATH = closedPath(holeSegs);

/// The near wall as its own shape, so it can be drawn a second time ON TOP of an arriving card. Its
/// upper boundary is the hollow's own lower arc, vertex for vertex, so a card entering the nest is cut
/// exactly at the rim. That occlusion is the strongest container cue available — "things go INTO this"
/// stated by geometry rather than implied — and it is the reason the nest is exported in two halves.
const FRONT_PATH = `M ${pt(bodySegs[0].a)} ${fwd(bodySegs, 0, VERTS / 2)} L ${pt(
  holeSegs[HVERTS / 2 - 1].b,
)} ${rev(holeSegs, 0, HVERTS / 2)} Z`;

/* ------------------------------------------------------------------ the marks */

const holePt = (th: number): Pt => [HOLE.x + Math.cos(th) * HOLE.rx, HOLE.y + Math.sin(th) * HOLE.ry];
const bodyPt = (th: number): Pt => [
  NC.x + Math.cos(th) * BODY.rx,
  NC.y + Math.sin(th) * (Math.sin(th) > 0 ? BODY.ryBot : BODY.ryTop),
];
/// `s` runs 0 at the rim to 1 at the silhouette, so a mark can be placed on the wall without caring how
/// thick the wall is at that angle — it is 315px at the bottom and 240px at the sides.
const wallPt = (th: number, s: number): Pt => mix(holePt(th), bodyPt(th), s);

/// Arc length per radian, sampled. Without it the circumferential sticks would be 250px long at the
/// bottom of the bowl and 95px at its sides, purely because the rim ellipse is squashed 4:1.
const speed = (th: number, s: number) => {
  const a = wallPt(th - 0.01, s);
  const b = wallPt(th + 0.01, s);
  return Math.max(1, Math.hypot(b[0] - a[0], b[1] - a[1]) / 0.02);
};

type Mark = {d: string; w: number; core: string};

/// Positions with UNEVEN gaps. Even spacing plus a small jitter is still even spacing, and it showed:
/// the marks came out as a comb of parallel spokes round the bottom edge and a lattice across the front
/// wall. A cumulative walk with a random step gives real clusters and real gaps, which is what a nest
/// has and what a fence does not. The step ratio is capped near 1:2.5 — unbounded, four sticks landed
/// together on the narrow left wall and merged into one blot, because clusters only read where there is
/// room for them and there is no room where the bowl turns away.
const spread = (n: number, from: number, to: number, seed: number, wobble: number) => {
  const steps = new Array(n).fill(0).map((_, i) => 0.62 + rnd(i + seed) * wobble);
  const total = steps.reduce((a, b) => a + b, 0);
  let acc = 0;
  return steps.map((s) => {
    const at = from + ((acc + s / 2) / total) * (to - from);
    acc += s;
    return at;
  });
};

/// One bow per stick, pushed perpendicular to its own chord. Two bows would be a squiggle; none would
/// be a matchstick.
const bowed = (p0: Pt, p1: Pt, bow: number) => {
  const dx = p1[0] - p0[0];
  const dy = p1[1] - p0[1];
  const len = Math.hypot(dx, dy) || 1;
  const mx = (p0[0] + p1[0]) / 2 - (dy / len) * bow;
  const my = (p0[1] + p1[1]) / 2 + (dx / len) * bow;
  return `M ${pt(p0)} Q ${mx.toFixed(1)} ${my.toFixed(1)} ${pt(p1)}`;
};

/// A WEAVE NEEDS TWO TRANSVERSE FAMILIES. The measured reason the rejected nest read as straw is that
/// it had one: 18 of its 34 sticks lay within 15° of horizontal, because every one was a chord of the
/// same 3.5:1 ellipse, and at 16° two 28px strokes overlap over a 100px lens — a merge, not a cross.
///
/// The marks here live in the wall's own (th, s) coordinates, so `s` is perpendicular to `th` by
/// construction. But laying one family exactly along `th` and the other exactly along `s` is not a
/// weave either — 90° everywhere is window screen, and it looked like wickerwork woven by a machine. So
/// `ring` runs along the rim and `cross` runs OBLIQUELY down it, drifting sideways as it descends, and
/// the crossings land in the 35-70° band where over/under is legible and where hand-laid rods sit.
///
/// They run the FULL half-turn. Held back from the tips to keep ink off the narrow side walls, the two
/// ends of the bowl came out as bare plates of flat bark with a lobe on them, and at 1:1 the right tip
/// read as a bird's head. Nothing on this object may be undrawn.
const woodOf = (r: number) => (r < 0.42 ? BARK : DUSK);

const ring: Mark[] = spread(13, 0.03, Math.PI - 0.03, 17, 0.9).map((th0, i) => {
  const r1 = rnd(i + 17);
  const r2 = rnd(i + 83);
  const r3 = rnd(i + 149);
  const s = 0.34 + r2 * 0.54;
  const span = (300 + r3 * 230) / speed(th0, s);
  return {
    d: bowed(wallPt(th0, s), wallPt(th0 + span, s + (r1 - 0.5) * 0.24), (r2 - 0.5) * 48),
    w: 26 + r3 * 12,
    core: woodOf(r1),
  };
});

const cross: Mark[] = spread(11, 0.03, Math.PI - 0.03, 233, 1.1).map((th, i) => {
  const r1 = rnd(i + 241);
  const r2 = rnd(i + 311);
  const r3 = rnd(i + 397);
  const s0 = 0.3 + r2 * 0.2;
  const s1 = Math.min(1.02, s0 + 0.4 + r3 * 0.38);
  // Sideways travel expressed in PIXELS and then converted, so the lean is the same everywhere rather
  // than collapsing to vertical at the sides where a radian is worth 250px instead of 720. It has a
  // FLOOR and it alternates: allowed near zero, a run of them came out vertical and parallel and the
  // right-hand wall turned into a ladder — three uprights crossed by two rails, visible at store size.
  const drift = ((i % 2 ? 1 : -1) * (150 + r1 * 260)) / speed(th, s0);
  return {
    d: bowed(wallPt(th, s0), wallPt(th + drift, s1), (r3 - 0.5) * 30),
    w: 24 + r2 * 11,
    core: woodOf(r3),
  };
});

/// THE MARKS THAT BREAK THE OUTLINE, which is where a mass-plus-sticks drawing is won or lost.
///
/// A STICK IS A LENGTH AND A DIRECTION, and two earlier versions got that wrong by specifying it in
/// wall coordinates instead: an end at `s = 1.3` means "a bit past the edge", which is a different
/// length and a different angle at every point around a bowl whose wall is 315px thick at the bottom
/// and 240px at the sides. Store-size inspection showed exactly that — a skirt of near-parallel
/// down-pointing sticks along the bottom reading as fur, with three 600px whiskers off the sides.
///
/// So a stick is specified by the two things that are actually visible: how far its END clears the
/// silhouette, and how long it is; it is then built BACKWARDS from that tip. Protrusion 45-140px and
/// length 200-340 against a 31-42px width — aspect 5-11:1, both ends in view, which is what separates a
/// stick from a strap. The base is forced at least 90px inside the outline so no stick floats free.
const outward = (th: number): Pt => {
  const o = bodyPt(th);
  const h = holePt(th);
  const l = Math.hypot(o[0] - h[0], o[1] - h[1]) || 1;
  return [(o[0] - h[0]) / l, (o[1] - h[1]) / l];
};

const spin = (dir: Pt, turn: number): Pt => [
  dir[0] * Math.cos(turn) - dir[1] * Math.sin(turn),
  dir[0] * Math.sin(turn) + dir[1] * Math.cos(turn),
];

const along = (from: Pt, dir: Pt, len: number): Pt => [from[0] + dir[0] * len, from[1] + dir[1] * len];

/// Tip out at `poke`, base back along `turn` — and neighbours turn opposite ways by construction. Left
/// to chance at this count they came out as three parallel diagonals down one side: a comb again, just
/// a slanted one.
const pokeOut = (th: number, i: number, r1: number, r3: number, poke: number, len: number): string => {
  const o = bodyPt(th);
  const h = holePt(th);
  const thick = Math.hypot(o[0] - h[0], o[1] - h[1]);
  const dir = outward(th);
  const tip = along(o, dir, poke);
  const turn = (i % 2 ? 1 : -1) * (0.2 + r1 * 0.95);
  const back = spin(dir, turn + Math.PI);
  const reach = Math.max(len, (poke + 90) / Math.max(0.35, Math.cos(turn)));
  return bowed(along(tip, back, reach), tip, (r3 - 0.5) * 26 * (thick / 300));
};

const breakers: Mark[] = spread(11, 0.02, Math.PI - 0.02, 557, 1.5).map((th, i) => {
  const r1 = rnd(i + 509);
  const r2 = rnd(i + 601);
  const r3 = rnd(i + 719);
  return {
    d: pokeOut(th, i, r1, r3, 45 + r2 * 95, 200 + r3 * 140),
    w: 29 + r1 * 11,
    core: r2 < 0.3 ? DUSK : BARK,
  };
});

/// Sticks poking out from BEHIND the mass, drawn before it. Half of a stick disappearing under the
/// silhouette says the silhouette is solid; a stick that only ever lies on top says it is a decal.
const behind: Mark[] = spread(8, Math.PI + 0.12, TAU - 0.12, 821, 1.3).map((th, i) => {
  const r1 = rnd(i + 829);
  const r2 = rnd(i + 907);
  const r3 = rnd(i + 1013);
  return {
    d: pokeOut(th, i + 1, r1, r3, 35 + r2 * 75, 180 + r3 * 110),
    w: 27 + r2 * 12,
    core: r1 < 0.35 ? DUSK : BARK,
  };
});

/// The far rim, which in a bowl is the thin band above the opening. Short sticks only — there is 125px
/// of wood there and anything longer would turn the band into a drawn line, which is how you get an
/// eyelid. This is the quadrant where the rejected treatment failed hardest: dark marks with no outline
/// lying on a bare stretch of mass read as SLOTS CUT INTO A LOAF rather than as wood on wood. They
/// carry an ink outline now, like everything else, and the count is up because a bare plate anywhere on
/// this object makes the mass read as mass.
const farRim: Mark[] = spread(14, Math.PI + 0.05, TAU - 0.05, 1117, 1.0).map((th, i) => {
  const r1 = rnd(i + 1123);
  const r2 = rnd(i + 1231);
  const s = 0.28 + r2 * 0.4;
  const span = (150 + r1 * 130) / speed(th, s);
  return {
    d: bowed(wallPt(th, s), wallPt(th + span, s + (r2 - 0.5) * 0.24), (r1 - 0.5) * 22),
    w: 22 + r2 * 9,
    core: woodOf(r2),
  };
});

/// Twigs on the INNER face of the far wall — the only marks inside the hollow, and the reason the
/// hollow is a space rather than a plate. Light wood on near-black: at 1:1 this is the surface that
/// proves there is an inside, and it is the one thing worth keeping from lane C.
const inner: Mark[] = spread(7, Math.PI + 0.35, TAU - 0.35, 1301, 1.0).map((th, i) => {
  const r1 = rnd(i + 1307);
  const r2 = rnd(i + 1409);
  const s0 = -0.1 - r2 * 0.18;
  const span = (170 + r1 * 120) / speed(th, 0);
  return {
    d: bowed(wallPt(th, s0), wallPt(th + span, s0 - (r1 - 0.5) * 0.12), (r2 - 0.5) * 18),
    w: 20 + r1 * 8,
    core: r2 < 0.3 ? DUSK : BARK,
  };
});

/// THE LIGHT, assigned rather than scattered. Gold appears in exactly one place — the top of the near
/// wall, just under the rim, where an edge catches it — in five separate sticks with gaps between them,
/// never a continuous line. A continuous gold line along that rim is an eyelid, which is the failure
/// being fixed, and gold anywhere else would compete with the NORDLYS card for the same tone.
const lit: Mark[] = spread(5, 0.5, Math.PI - 0.5, 1511, 1.4).map((th, i) => {
  const r1 = rnd(i + 1517);
  const r2 = rnd(i + 1613);
  const s = 0.05 + r2 * 0.3;
  const span = (190 + r1 * 130) / speed(th, s);
  return {
    d: bowed(wallPt(th, s), wallPt(th + span, s + (r1 - 0.5) * 0.14), (r2 - 0.5) * 20),
    w: 26 + r2 * 10,
    core: GOLD,
  };
});

/// Sticks laid ACROSS the opening. A nest has them, and structurally they are the anti-lens device: an
/// eye is an unbroken almond, and three sticks bridging it are three places where that almond fails to
/// close. They also cross an arriving card, so wood passes in FRONT of it as well as behind — which is
/// what makes a card look caught rather than pasted on.
const bridges: Mark[] = [
  {d: bowed(wallPt(0.62, 0.16), wallPt(3.55, -0.5), 60), w: 28, core: BARK},
  {d: bowed(wallPt(2.6, 0.12), wallPt(5.4, -0.42), -46), w: 24, core: DUSK},
  {d: bowed(wallPt(1.55, 0.2), wallPt(4.35, -0.36), 34), w: 22, core: BARK},
];

/// The one construction in the drawing: a wood fill inside an ink line, exactly as the cards are built,
/// emitted as a pair so z-order is per stick rather than per layer.
/// The highest point of a mark, read off its own `d` rather than recomputed from the angles that made
/// it. The path is "M x y Q x y x y" with no curves that leave their control hull, so the minimum of
/// the numbers is the top to within a couple of units — enough to sort marks into layers by it.
const topOfMark = (d: string) => {
  const n = d.match(/-?\d+(?:\.\d+)?/g);
  if (!n) return Infinity;
  let top = Infinity;
  for (let i = 1; i < n.length; i += 2) top = Math.min(top, Number(n[i]));
  return top;
};

/// Marks that reach high enough to touch a card at its hover, and the rest.
///
/// Moving ALL of `ring` and `cross` behind the near wall fixed the sudden covering and broke the nest:
/// the near wall is drawn over them there, so the front rim lost its sticks. Only some of them are the
/// problem. A hovering card spans canvas y 1514..1806, which through the nest's fit transform
/// (canvas = 1.45 * local - 262.4) is local 1225..1426 — so a mark whose top is above local 1426 can
/// reach it, and one whose top is below cannot. Split on that and each mark sits where it belongs.
const HOVER_REACH = 1426;
const splitByReach = (set: Mark[]) => ({
  high: set.filter((m) => topOfMark(m.d) < HOVER_REACH),
  low: set.filter((m) => topOfMark(m.d) >= HOVER_REACH),
});

const Stick: React.FC<{m: Mark}> = ({m}) => (
  <>
    <path d={m.d} stroke={INK} strokeWidth={m.w + EDGE * 2} strokeLinecap="round" fill="none" />
    <path d={m.d} stroke={m.core} strokeWidth={m.w} strokeLinecap="round" fill="none" />
  </>
);

const Marks: React.FC<{set: Mark[]}> = ({set}) => (
  <>
    {set.map((m, i) => (
      <Stick key={i} m={m} />
    ))}
  </>
);

/// Split in two so a card can be dropped BETWEEN them. The illustration draws NestBack, then the cards,
/// then NestFront, so a card arriving at the end of its spiral is cut off at the near rim and the last
/// thing that happens to it is that the nest closes over it.
export const NestBack: React.FC = () => (
  <g transform={NEST_FIT}>
    <Marks set={behind} />
    <path d={BODY_PATH} fill={BARK} />
    <Marks set={farRim} />
    <path d={HOLE_PATH} fill={INK} />
    <Marks set={inner} />
    {/* The three sticks that SPAN the opening live here, before the cards, and not with the near wall
        where they started. They are the only marks that cross the hollow, so while they were drawn in
        front every card went behind all three the instant it reached its hover — the last remaining
        "cards suddenly hide" fault, and the one the near-wall geometry could not explain because these
        sticks are nowhere near the near wall. Everything still in NestFront lives BELOW the hollow's
        lower arc, so a card above that arc is now occluded by nothing at all. */}
    <Marks set={bridges} />
    {/* `ring` and `cross` moved here from the front. They are near-wall marks, so drawing them in
        front of an arriving card is defensible in principle and wrong in practice: measured on a
        render, ring's ink reaches y 1469 and cross's y 1502 in the columns cards hover over, while a
        card at its hover spans 1514..1806 — so the moment a card began its descent it went behind both,
        all at once. Raising the hover cannot fix it: the type block ends at 1285 and ring starts at
        1469, and 184px will not hold a 292px card. What still covers a landing card is the near wall
        itself and `breakers`, both of which live below y 2000, which is where being covered means the
        card is genuinely down in the bowl. */}
    <Marks set={splitByReach(ring).high} />
    <Marks set={splitByReach(cross).high} />
  </g>
);

export const NestFront: React.FC = () => (
  <g transform={NEST_FIT}>
    <path d={FRONT_PATH} fill={BARK} />
    <Marks set={splitByReach(ring).low} />
    <Marks set={splitByReach(cross).low} />
    <Marks set={lit} />
    {/* The silhouette redrawn last at the cards' own weight, so the one edge that has to survive 600px
        is never nibbled by a mark that happens to land on it. */}
    <path d={BODY_PATH} fill="none" stroke={INK} strokeWidth={EDGE} />
    <Marks set={breakers} />
  </g>
);

/* ------------------------------------------------------------------ the piece */

/// THE HEADLINE, in the four languages the listing ships.
///
/// The Korean was briefed as "어떤 언어로 쓰였든, 당신이 읽고 싶은 언어로" and two edits earn their keep.
/// 당신 is dropped: this product's own voice never addresses the reader that way — the onboarding says
/// "좋아하는 사이트를 구독하면 새 글이 자동으로 이곳에 모여요" and the config's headline is "피드는 내가
/// 고릅니다" — and a compulsory subject is the clearest tell of copy translated out of English. The
/// 쓰다/읽다 pair either side of the comma is kept, because it IS the line: written in one language,
/// read in another, the feature stated without being named. Ending on the particle 로 is deliberate;
/// in a headline that reads as confident, where the same thing at a mid-sentence line break would read
/// as severed.
///
/// The English is left as it was. It was already doing the same work in its own idiom, and rewriting
/// it to mirror the Korean's structure would have made it a translation of a translation.
///
/// The subtitle names the SCOPE, not the mechanism. It used to say "Apple Intelligence가 제목부터
/// 본문까지 옮깁니다" and that was worse for five reasons, none of them about taste: it hands the credit
/// for the product's own headline to somebody else's brand one line later; it puts a third-party
/// trademark in our creative, which has usage rules worth not stepping on; Apple Intelligence is
/// device- and region-limited, so it promises something a listing cannot guarantee to the person
/// reading it; it breaks if the translation backend ever changes; and a run of Latin letters through
/// the middle of a Korean, Japanese or Chinese line wrecks the texture of the setting.
///
/// What survives is the part a competitor cannot print: the title AND the body, whole. That is what
/// separates this from a browser's page translation and from a summary.
const COPY = {
  ko: {
    title: ['어떤 언어로 쓰였든,', '읽고 싶은 언어로'],
    sub: '제목부터 본문까지, 통째로 옮깁니다.',
  },
  en: {
    title: ['Every language', 'arrives as yours'],
    sub: 'Titles and bodies, translated in place.',
  },
  ja: {
    title: ['どの言語で書かれていても、', '読みたい言語で'],
    sub: 'タイトルから本文まで、まるごと訳します。',
  },
  'zh-Hans': {
    title: ['无论用哪种语言写成，', '都以你想读的语言呈现'],
    sub: '从标题到正文，整篇翻译。',
  },
} as const;

export const SearchIllustration: React.FC<{locale: Lang; guides?: boolean}> = ({
  locale,
  guides = false,
}) => {
  const frame = useCurrentFrame();
  const u = frame / TOTAL;
  const copy = COPY[locale];
  const deck = React.useMemo(() => deckFor(locale), [locale]);

  return (
    <AbsoluteFill style={{background: FIELD}}>
      <svg width={W} height={H} viewBox={`0 0 ${W} ${H}`}>
        {ACCENTS.map((a, i) => (
          <Accent key={i} a={a} u={u} i={i} />
        ))}
        {/* THE ORDER IS THE POINT. The nest's back wall, then the cards, then its near wall — so a card
            at the end of its spiral is cut off exactly at the rim and the last thing that happens to it
            is that the wood closes over it. Drawn after the whole nest, as it was, a card can only ever
            be hidden BY the nest; drawn between the halves, it goes INTO it.

            The split is by `a`, how far round the spiral a card is, not by z-order alone: a card still
            far out sits over the bottom of the frame at a radius that reads as nearer than the nest, so
            it stays in front. Past 0.42 the radius is under ~1150px and the card is inside the bowl's
            footprint, which is where being swallowed is the correct reading. */}
        <NestBack />
        {/* Cards that have reached the hover and are sinking: behind the near wall, so the nest closes
            over them. */}
        {/* Sinking into the bowl: behind the near wall, so the nest closes over them.
            The threshold is SWAP and not the 0.42 this used to be. At 0.42 a card is still out at
            r=1040 on the spiral — world (1400, 2195), BELOW the nest and at full size — so it passed
            behind the near wall while plainly in mid-air, which is the "cards hide under the bottom of
            the nest" fault. At SWAP every card is parked on its hover point above the opening, where
            the near wall is not between it and the viewer, so the change of layer moves no pixels. */}
        {/* Landing cards are stacked BY HOW FAR ALONG THEY ARE, not by their index in the deck. They
            were drawn in deck order, so whether an arriving card landed on top of the ones already in
            the nest or slid underneath them was decided by an array position — and a card that starts
            its descent after another and ends up beneath it is the one thing a pile of falling objects
            cannot do. Sorting by `a` descending puts the most advanced card first, which is furthest
            back, so each new arrival lands on top of everything already there. */}
        {deck
          .map((c, i) => ({c, i, a: cardPhase(i, u)}))
          .filter((e) => e.a >= SWAP)
          .sort((x, y) => y.a - x.a)
          .map((e) => (
            <Card key={e.i} index={e.i} u={u} card={e.c} />
          ))}
        <NestFront />
        {/* Still in the air: in front of everything, because a card crossing the nest on its way in is
            nearer the viewer than the nest is. */}
        {deck.map((c, i) => (cardPhase(i, u) < SWAP ? <Card key={i} index={i} u={u} card={c} /> : null))}
      </svg>

      {/* Straight on top of the picture, as the reference does it — no plate, no band. The field is
          one flat colour, so cream type on it is legible wherever it lands. */}
      <div
        style={{
          position: 'absolute',
          left: SAFE.x0 + 40,
          top: SAFE.y0 + 20,
          width: SAFE.x1 - SAFE.x0 - 80,
          fontFamily: UI,
          fontWeight: 800,
          fontSize: 168,
          lineHeight: 1.1,
          letterSpacing: '-0.02em',
          color: CREAM,
          whiteSpace: 'pre',
        }}
      >
        {copy.title.join('\n')}
      </div>
      <div
        style={{
          position: 'absolute',
          left: SAFE.x0 + 40,
          top: SAFE.y0 + 420,
          fontFamily: UI,
          fontWeight: 600,
          fontSize: 70,
          color: GOLD,
        }}
      >
        {copy.sub}
      </div>

      {guides ? (
        <svg width={W} height={H} style={{position: 'absolute', inset: 0}}>
          <rect
            x={SAFE.x0}
            y={SAFE.y0}
            width={SAFE.x1 - SAFE.x0}
            height={SAFE.y1 - SAFE.y0}
            fill="none"
            stroke="#FF00FF"
            strokeWidth={6}
          />
        </svg>
      ) : null}
    </AbsoluteFill>
  );
};
