/// Twigs that look like twigs: a branching armature, outlined as filled tapered rods.
///
/// A twig is a trunk of 3–5 straight links joined at small angles, plus 0–3 side shoots
/// grown from its joints (and 0–2 grandchildren on the longest shoot at hero size), every
/// rod emitted as a filled ribbon and unioned into ONE `<path>` with `fill-rule: nonzero`.
/// The silhouette comes from the branching topology, never from noise — which is why no two
/// twigs look like the same shape rotated, and why the difference survives at 40px.
///
/// The two rules that keep the outline coherent:
///   1. There is exactly ONE width function, `halfWidth`, and both flanks read it at the
///      same arc position. No `random()` is ever called per outline step.
///   2. Every rng draw happens while building the *spec*. The emitter is a pure function of
///      the spec, so the same seed is the same twig on every frame and at every scale.

/* ------------------------------------------------------------------ constants */

const D2R = Math.PI / 180;
const R2D = 180 / Math.PI;

const clamp = (v: number, lo: number, hi: number) => (v < lo ? lo : v > hi ? hi : v);
const f1 = (n: number) => Math.round(n * 10) / 10;
const wrap180 = (deg: number) => ((((deg + 180) % 360) + 360) % 360) - 180;

/// The nest's palette as one luminance ramp (Rec.709 luma measured, not guessed), each rung
/// paired with the palette entry that lights it. `#7F6B48` and `#8A6A3F` are 1.0 luma apart —
/// side by side they read as one shape, which is why neighbours are separated by luma below
/// and not by index.
export const RAMP = [
  {hex: '#4A3419', luma: 54.7, light: '#7F6B48'},
  {hex: '#5C3A18', luma: 62.8, light: '#8A6A3F'},
  {hex: '#6E5330', luma: 86.2, light: '#A8763C'},
  {hex: '#7F6B48', luma: 108.7, light: '#C79A5B'},
  {hex: '#8A6A3F', luma: 109.7, light: '#C79A5B'},
  {hex: '#A8763C', luma: 124.4, light: '#D9B278'},
  {hex: '#C79A5B', luma: 159.0, light: '#D9B278'},
  {hex: '#D9B278', luma: 182.1, light: '#F0D5A6'},
] as const;

/// Rung ranges per depth layer: 0 back, 1 middle, 2 front. Depth is colour order plus draw
/// order, never a per-twig filter.
export const LAYER_RUNGS: readonly [number, number][] = [
  [0, 2],
  [2, 5],
  [3, 7],
];

/// Where the light is, in world space: the `#sun` gradient in ConceptBird sits at
/// (2560, 330) on a 3840x1646 canvas, above and to the RIGHT of a nest centred near
/// (1920, 820). Screen y grows downwards, so this points up and right.
export const LIGHT_WORLD = {x: 0.79, y: -0.61};
export const LIGHT_WORLD_DEG = Math.atan2(LIGHT_WORLD.y, LIGHT_WORLD.x) * R2D;

/* ------------------------------------------------------------------ rng */

/// The project's LCG (`state * 1664525 + 1013904223`) returns almost the same first value
/// for `n` and `n + 1` — consecutive seeds give near-identical twigs. Every twig seed goes
/// through this hash first. It is not optional; it is the difference between 60 distinct
/// twigs and 60 copies.
export const hash32 = (n: number): number => {
  let h = n >>> 0;
  h ^= h >>> 16;
  h = Math.imul(h, 0x7feb352d) >>> 0;
  h ^= h >>> 15;
  h = Math.imul(h, 0x846ca68b) >>> 0;
  return (h ^ (h >>> 16)) >>> 0;
};

/// mulberry32 on the hashed seed. Deterministic, and decorrelated for nearby seeds.
export const rngOf = (seed: number): (() => number) => {
  let s = hash32(seed);
  return () => {
    s = (s + 0x6d2b79f5) >>> 0;
    let t = s;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
};

const uni = (r: () => number, lo: number, hi: number) => lo + r() * (hi - lo);
const coin = (r: () => number): 1 | -1 => (r() < 0.5 ? 1 : -1);

/* ------------------------------------------------------------------ vectors */

type Vec = {x: number; y: number};
const V = (x: number, y: number): Vec => ({x, y});
const perp = (v: Vec): Vec => V(-v.y, v.x);
const dot = (a: Vec, b: Vec) => a.x * b.x + a.y * b.y;
const norm = (v: Vec): Vec => {
  const l = Math.hypot(v.x, v.y) || 1;
  return V(v.x / l, v.y / l);
};

/* ------------------------------------------------------------------ taxonomy */

/// Topology is the primary variety axis, because "has a fork" and "has three shoots" are
/// the only differences that survive at 40px. Parameter jitter alone gives twigs that differ
/// only where nobody can see it.
export type Arch = 'bare' | 'single' | 'forked' | 'brushy';
/// The broad character of the trunk, drawn as a discrete class rather than a continuous
/// jitter, so silhouettes fall into visibly different families instead of clustering on the
/// mean.
export type Sweep = 'stiff' | 'bowed' | 'hooked';
/// Where the taper bites. One blunt base and one sharp tip; which kind of sharp is the
/// strongest single silhouette knob after topology.
export type TipStyle = 'spear' | 'needle' | 'wedge';
/// Absolute thickness band, so sturdy sticks stand next to fine whips.
export type Weight = 'wisp' | 'ordinary' | 'stick';

const ARCH_KIDS: Record<Arch, number> = {bare: 0, single: 1, forked: 2, brushy: 3};

/// (q, p) for `(1 - s^q)^p`. Measured at base half-width 6.0px:
///   spear  6.0 / 5.2 / 3.6 / 1.8 / 0    at s = 0 / .5 / .75 / .9 / 1
///   needle 6.0 / 5.7 / 4.6 / 3.0 / 0    stays fat, whips to a point in the last few percent
///   wedge  6.0 / 4.4 / 2.5 / 1.1 / 0    a long even taper
/// `wedge` was flatter still at first (q 1.6, p 1.05) and rendered as a machete blade: a long
/// straight edge with one bend in it. Steepening q and softening p bends the edge.
const TIPS: Record<TipStyle, {q: number; p: number}> = {
  spear: {q: 2.6, p: 0.8},
  needle: {q: 3.6, p: 0.55},
  wedge: {q: 1.9, p: 0.9},
};

/// Length-to-thickness ratio at the butt. Chosen in aspect rather than in px because that is
/// what the eye reads, and because the small-size compression below is then one number.
const ASPECT: Record<Weight, number> = {wisp: 34, ordinary: 26, stick: 19};

const SWEEPS: Record<Sweep, {bend: [number, number]; kink: [number, number]; hook: [number, number]}> = {
  stiff: {bend: [2, 10], kink: [5, 14], hook: [0, 0]},
  bowed: {bend: [16, 38], kink: [3, 9], hook: [0, 0]},
  hooked: {bend: [10, 20], kink: [4, 10], hook: [18, 34]},
};

/// Bags, dealt rather than rolled: shuffle, deal one per twig, reshuffle when exhausted and
/// never start the new deck with the card the old one ended on. This turns "probably varied"
/// into "provably no near-neighbour repeats" and guarantees the mix as well as the spread.
export const ARCH_BAG: Arch[] = [
  ...(Array(5).fill('bare') as Arch[]),
  ...(Array(7).fill('single') as Arch[]),
  ...(Array(5).fill('forked') as Arch[]),
  ...(Array(3).fill('brushy') as Arch[]),
];
export const SWEEP_BAG: Sweep[] = [
  ...(Array(7).fill('stiff') as Sweep[]),
  ...(Array(7).fill('bowed') as Sweep[]),
  ...(Array(6).fill('hooked') as Sweep[]),
];
const TIP_BAG: TipStyle[] = [
  ...(Array(7).fill('spear') as TipStyle[]),
  ...(Array(6).fill('needle') as TipStyle[]),
  ...(Array(7).fill('wedge') as TipStyle[]),
];
const WEIGHT_BAG: Weight[] = [
  ...(Array(7).fill('wisp') as Weight[]),
  ...(Array(7).fill('ordinary') as Weight[]),
  ...(Array(6).fill('stick') as Weight[]),
];

export const dealer = <T>(bag: readonly T[], r: () => number): (() => T) => {
  let deck: T[] = [];
  let last: T | null = null;
  return () => {
    if (deck.length === 0) {
      deck = bag.slice();
      for (let i = deck.length - 1; i > 0; i--) {
        const j = Math.floor(r() * (i + 1));
        const t = deck[i];
        deck[i] = deck[j];
        deck[j] = t;
      }
      // A shuffle alone does NOT stop two identical cards landing side by side — with 7 of a
      // kind in 20 it happens often, and it is exactly the repeat the eye catches. Repair by
      // trial swap: a forward-only pass leaves the tail of the deck unfixable and measured 3
      // surviving repeats per 60 twigs; searching the whole deck and reverting a swap that
      // does not fit leaves 0.
      const fits = (d: T[], i: number) =>
        (i === 0 || d[i - 1] !== d[i]) && (i === d.length - 1 || d[i + 1] !== d[i]);
      for (let i = 1; i < deck.length; i++) {
        if (fits(deck, i)) continue;
        for (let j = 0; j < deck.length; j++) {
          if (j === i) continue;
          const a = deck[i];
          const b = deck[j];
          deck[i] = b;
          deck[j] = a;
          if (fits(deck, i) && fits(deck, j)) break;
          deck[i] = a;
          deck[j] = b;
        }
      }
      if (deck.length > 1 && deck[0] === last) {
        const t = deck[0];
        deck[0] = deck[1];
        deck[1] = t;
      }
    }
    last = deck.shift() as T;
    return last;
  };
};

/* ------------------------------------------------------------------ the width function */

/// A collar is a gaussian swelling on the width profile. `side` 0 means both flanks, ±1 means
/// one flank only — a shoot swells the trunk on the side it leaves, and swelling both sides
/// grows a phantom nub on the far side.
type Collar = {s: number; side: 0 | 1 | -1; gain: number; sigma: number};

type WidthSpec = {
  /// Half-width at the butt, in px, before the pinch.
  base: number;
  q: number;
  p: number;
  /// A smooth deterministic swell along the rod. Identical on both flanks.
  und: number;
  freq: number;
  phase: number;
  pinchButt: boolean;
  collars: Collar[];
  /// Ink floor in px, so a thin shoot cannot rasterise away. Never applied at a needle tip.
  floorHalf: number;
};

type HalfFn = (s: number, side: 0 | 1 | -1) => number;

/// half(s) = base · (1 − s^q)^p · (1 + und·sin(2π·freq·s + φ)) · buttPinch(s) · Π collars(s)
///
/// Every term is a smooth closed-form function of arc position. Both flanks call this with
/// the same `s`, so the outline can never disagree with itself. That is the whole fix for the
/// torn-paper edge the previous generator produced.
const halfWidthFn = (w: WidthSpec): HalfFn => {
  return (s, side) => {
    const t = clamp(s, 0, 1);
    if (t >= 0.9999) return 0;
    let h = w.base * Math.pow(Math.max(0, 1 - Math.pow(t, w.q)), w.p);
    if (w.und !== 0) h *= 1 + w.und * Math.sin(t * w.freq * Math.PI * 2 + w.phase);
    // Narrows the very butt so the chisel cut reads as snapped rather than sawn.
    if (w.pinchButt) h *= 0.88 + 0.12 * Math.min(1, t / 0.05);
    for (const c of w.collars) {
      if (c.side !== 0 && c.side !== side) continue;
      const z = (t - c.s) / c.sigma;
      h *= 1 + c.gain * Math.exp(-z * z);
    }
    return Math.max(w.floorHalf, h);
  };
};

/* ------------------------------------------------------------------ the spine */

type Spine = {
  nodes: Vec[]; // links + 1
  dirs: Vec[]; // links
  lens: number[]; // links
  cum: number[]; // links + 1
  total: number;
};

/// Internodes shorten toward the tip, which is what makes the rod read as grown.
const linkLengths = (links: number, length: number, r: () => number): number[] => {
  const w: number[] = [];
  for (let i = 0; i < links; i++) w.push((1 - 0.18 * i) * uni(r, 0.85, 1.15));
  const sum = w.reduce((a, b) => a + b, 0);
  return w.map((v) => (v / sum) * length);
};

const buildSpine = (o: {
  origin: Vec;
  headingDeg: number;
  lens: number[];
  bendDeg: number;
  kinkDeg: number;
  /// Index of the joint carrying the one hard elbow, or -1.
  sharpAt: number;
  sharpDeg: number;
  /// Extra same-sign turn on the last joint — a hook at the tip.
  hookDeg: number;
  r: () => number;
}): Spine => {
  const links = o.lens.length;
  const nodes: Vec[] = [o.origin];
  const dirs: Vec[] = [];
  let ang = o.headingDeg;
  for (let i = 0; i < links; i++) {
    if (i > 0) {
      let turn = o.bendDeg / Math.max(1, links - 1) + uni(o.r, -o.kinkDeg, o.kinkDeg);
      if (i === o.sharpAt) turn += o.sharpDeg;
      if (i === links - 1) turn += o.hookDeg;
      ang += turn;
    }
    const a = ang * D2R;
    dirs.push(V(Math.cos(a), Math.sin(a)));
    const prev = nodes[nodes.length - 1];
    nodes.push(V(prev.x + dirs[i].x * o.lens[i], prev.y + dirs[i].y * o.lens[i]));
  }
  const cum = [0];
  for (let i = 0; i < links; i++) cum.push(cum[i] + o.lens[i]);
  return {nodes, dirs, lens: o.lens, cum, total: cum[links]};
};

const linkOf = (sp: Spine, sn: number): number => {
  const s = clamp(sn, 0, 1) * sp.total;
  let i = 0;
  while (i < sp.dirs.length - 1 && s > sp.cum[i + 1]) i++;
  return i;
};

const posAt = (sp: Spine, sn: number): {p: Vec; d: Vec} => {
  const s = clamp(sn, 0, 1) * sp.total;
  let i = 0;
  while (i < sp.dirs.length - 1 && s > sp.cum[i + 1]) i++;
  const t = s - sp.cum[i];
  return {p: V(sp.nodes[i].x + sp.dirs[i].x * t, sp.nodes[i].y + sp.dirs[i].y * t), d: sp.dirs[i]};
};

/* ------------------------------------------------------------------ the outline */

type Sample = {sn: number; link: number; joint: boolean};

/// Where the outline is sampled. Mid-link samples only buy something where the width is
/// actually curving — the last link (where the taper bites) and any link a collar or the
/// undulation reaches. Everywhere else the joint alone is enough, which is what keeps a 40px
/// strand down to four points a side.
const sampleList = (sp: Spine, w: WidthSpec, tipCut: number, lastSubs: number): Sample[] => {
  const links = sp.dirs.length;
  const out: Sample[] = [];
  for (let i = 0; i < links; i++) {
    const s0 = sp.cum[i] / sp.total;
    const s1 = sp.cum[i + 1] / sp.total;
    let subs = 1;
    if (i === links - 1) subs = lastSubs;
    else if (w.und !== 0) subs = 3;
    else if (w.collars.some((c) => c.s > s0 - 2 * c.sigma && c.s < s1 + 2 * c.sigma)) subs = 3;
    for (let j = 0; j < subs; j++) {
      const sn = s0 + (j / subs) * (s1 - s0);
      if (sn >= tipCut - 1e-4) break;
      out.push({sn, link: i, joint: j === 0});
    }
  }
  if (tipCut < 0.9999) out.push({sn: tipCut, link: links - 1, joint: false});
  return out;
};

/// Outward unit normal and miter factor at a sample.
const frameAt = (sp: Spine, s: Sample, buttSkewDeg: number): {p: Vec; n: Vec; miter: number} => {
  const {p} = posAt(sp, s.sn);
  if (s.joint && s.link > 0) {
    // Joint: the angle bisector, so the two flanks stay parallel through the corner.
    const a = perp(sp.dirs[s.link - 1]);
    const b = perp(sp.dirs[s.link]);
    const m = norm(V(a.x + b.x, a.y + b.y));
    // For turns up to 46 deg this is at most 1.09 — the 1.6 cap is insurance against a barb,
    // and never binds.
    const miter = Math.min(1.6, 1 / Math.max(0.5, dot(m, a)));
    return {p, n: m, miter};
  }
  if (s.link === 0 && s.joint) {
    // Butt: a slanted flat cut. One blunt slanted end against one pointed end is the
    // strongest single readability cue in the whole shape.
    const a = buttSkewDeg * D2R;
    const b = perp(sp.dirs[0]);
    const n = V(b.x * Math.cos(a) - b.y * Math.sin(a), b.x * Math.sin(a) + b.y * Math.cos(a));
    return {p, n, miter: Math.min(1.6, 1 / Math.max(0.4, Math.cos(a)))};
  }
  return {p, n: perp(sp.dirs[s.link]), miter: 1};
};

type Box = {x0: number; y0: number; x1: number; y1: number};
const growBox = (b: Box, p: Vec) => {
  if (p.x < b.x0) b.x0 = p.x;
  if (p.y < b.y0) b.y0 = p.y;
  if (p.x > b.x1) b.x1 = p.x;
  if (p.y > b.y1) b.y1 = p.y;
};

/// One rod as one closed subpath: `M left… (tip) right-reversed… (notch) Z`.
/// Straight `L` commands only — a woodcut silhouette, and quadratics would only add bytes
/// plus a tangent-continuity problem at the corners.
const rodOutline = (
  sp: Spine,
  half: HalfFn,
  o: {buttSkewDeg: number; tipCut: number; notch: boolean; lastSubs: number; w: WidthSpec},
  box: Box
): {d: string; points: number} => {
  const samples = sampleList(sp, o.w, o.tipCut, o.lastSubs);
  const left: string[] = [];
  const right: string[] = [];
  let first: Vec | null = null;
  let firstR: Vec | null = null;
  for (const s of samples) {
    const {p, n, miter} = frameAt(sp, s, o.buttSkewDeg);
    const wl = half(s.sn, 1) * miter;
    const wr = half(s.sn, -1) * miter;
    const l = V(p.x + n.x * wl, p.y + n.y * wl);
    const rr = V(p.x - n.x * wr, p.y - n.y * wr);
    if (!first) {
      first = l;
      firstR = rr;
    }
    growBox(box, l);
    growBox(box, rr);
    left.push(`${f1(l.x)} ${f1(l.y)}`);
    right.push(`${f1(rr.x)} ${f1(rr.y)}`);
  }
  let d = `M ${left.join(' L ')}`;
  if (o.tipCut >= 0.9999) {
    // Both flanks converge on the last spine node, because half(1) is exactly 0: a natural
    // needle, no cap, and it can never be sliced flat by a clip.
    const tip = sp.nodes[sp.nodes.length - 1];
    growBox(box, tip);
    d += ` L ${f1(tip.x)} ${f1(tip.y)}`;
  }
  d += ` L ${right.reverse().join(' L ')}`;
  if (o.notch && first && firstR) {
    // The butt chord's midpoint pushed into the body, so the break is two lines instead of
    // one and reads as snapped fibre rather than a saw cut.
    const push = sp.dirs[0];
    const depth = 0.28 * half(0, 0);
    const mx = (first.x + firstR.x) / 2 + push.x * depth;
    const my = (first.y + firstR.y) / 2 + push.y * depth;
    d += ` L ${f1(mx)} ${f1(my)}`;
  }
  return {d: `${d} Z`, points: left.length * 2 + (o.tipCut >= 0.9999 ? 1 : 0) + (o.notch ? 1 : 0)};
};

/* ------------------------------------------------------------------ the twig */

export type TwigGeometry = {
  /// Every rod as a subpath of one `d`. Fill it with `fillRule="nonzero"`.
  body: string;
  /// One offset ribbon on the lit flank, or null when the twig is too thin to hold two tones.
  highlight: string | null;
  points: number;
  arch: Arch;
  sweep: Sweep;
  tip: TipStyle;
  weight: Weight;
  /// Half-width at the butt in px — what decides whether a highlight is worth its bytes.
  baseHalf: number;
  length: number;
  kids: number;
  bbox: Box;
};

export type TwigOptions = {
  seed: number;
  /// Trunk length in px, butt to tip. Geometry is generated at final size so ink floors and
  /// feature-drop thresholds can be stated in px.
  length: number;
  arch?: Arch;
  sweep?: Sweep;
  tip?: TipStyle;
  weight?: Weight;
  /// 2 hero, 1 nest strand, 0 back layer (trunk only).
  maxDepth?: number;
  /// Thickness multiplier. Natural proportion is too fine to read small; the default raises
  /// it below 100px.
  stout?: number;
  /// Direction of the light expressed in the twig's OWN frame:
  /// `LIGHT_WORLD_DEG - placementRotationDeg`.
  lightLocalDeg?: number;
  allowHighlight?: boolean;
};

export const buildTwig = (o: TwigOptions): TwigGeometry => {
  const r = rngOf(o.seed);
  const L = o.length;
  const maxDepth = o.maxDepth ?? (L >= 150 ? 2 : 1);

  const arch: Arch = o.arch ?? 'single';
  const sweep: Sweep = o.sweep ?? 'stiff';
  const tip: TipStyle = o.tip ?? (L < 110 ? 'wedge' : 'spear');
  const weight: Weight = o.weight ?? 'ordinary';

  // ---- what changes at small size, in one place -----------------------------
  const stout = o.stout ?? 1;
  // Natural proportion is too fine to read small: at 40px a 34:1 wisp is 1.2px thick and
  // greys out. Aspect compresses to 0.42x by 40px, so a short strand is a relatively fatter
  // object — which is also why its forks vanish, and why that is the right outcome.
  const aspectScale = clamp(L / 130, 0.42, 1);
  // A true hairline point anti-aliases to nothing and makes the strand read shorter than it
  // is, so below 110px the tip is trimmed to a snapped break instead of a needle.
  const tipCut = L >= 110 ? 1 : 1 - 0.12 * clamp((110 - L) / 65, 0, 1);
  const floorHalf = L < 110 ? 0.55 : 0.3;
  // Period ~13px, amplitude ~0.15px at nest scale: invisible, and it forces mid-link samples.
  const undOn = L >= 100;
  const lastSubs = L >= 150 ? 4 : 3;
  const notch = L >= 120;

  // ---- trunk ----------------------------------------------------------------
  const links = clamp(Math.round(L / 28), 3, 5);
  const lens = linkLengths(links, L, r);
  const cum = [0];
  for (let i = 0; i < links; i++) cum.push(cum[i] + lens[i]);

  const sw = SWEEPS[sweep];
  const bendSign = coin(r);
  const bendDeg = bendSign * uni(r, sw.bend[0], sw.bend[1]);
  const kinkDeg = uni(r, sw.kink[0], sw.kink[1]);
  const hookDeg = sw.hook[1] === 0 ? 0 : bendSign * uni(r, sw.hook[0], sw.hook[1]);

  const {q, p} = TIPS[tip];
  const baseHalf = clamp(
    (L / (2 * ASPECT[weight] * aspectScale)) * uni(r, 0.88, 1.12) * stout,
    1.1,
    9
  );

  // THE ONE HARD ELBOW, with its angle solved from a target lateral displacement measured in
  // twig-widths rather than picked in degrees. That is what makes the corner ~2x the twig's
  // own visible width at every scale: about 20 deg on a 300px hero and about 45 deg on a 40px
  // strand, automatically. Picking degrees is what made the old generator's wander disappear
  // when the twig got small.
  let sharpAt = -1;
  let sharpDeg = 0;
  if (r() < 0.45) {
    sharpAt = 1 + Math.floor(r() * (links - 1));
    const sj = cum[sharpAt] / L;
    const hj = Math.max(0.6, baseHalf * Math.pow(Math.max(0, 1 - Math.pow(sj, q)), p));
    const run = lens[sharpAt];
    const ratio = uni(r, 1.6, 2.6);
    let turn = Math.asin(clamp((ratio * 2 * hj) / run, 0, 0.82)) * R2D;
    turn = clamp(turn, 8, 46);
    // The inner flank must not out-run its own segment. Insurance; it never binds in range.
    turn = Math.min(turn, 0.55 * (run / hj) * R2D);
    // Mostly a counter-elbow against the sweep, which reads as more grown than a stronger
    // hook in the same direction.
    sharpDeg = turn * (r() < 0.65 ? -bendSign : bendSign);
  }

  const trunk = buildSpine({
    origin: V(0, 0),
    headingDeg: 0,
    lens,
    bendDeg,
    kinkDeg,
    sharpAt,
    sharpDeg,
    hookDeg,
    r,
  });

  const und = undOn ? uni(r, 0.07, 0.15) : 0;
  const freq = uni(r, 2.0, 4.2);
  const phase = r() * Math.PI * 2;
  // Never zero. Without a skew every twig ends in a square saw cut and the mass reads as wood
  // shavings; one scalar is the highest-value-per-byte mark in the whole generator.
  const buttSkewDeg = coin(r) * uni(r, 12, 30);

  const trunkWidth: WidthSpec = {
    base: baseHalf,
    q,
    p,
    und,
    freq,
    phase,
    pinchButt: true,
    collars: [],
    floorHalf,
  };
  // The plan reads a collar-free width function. Nothing is built and thrown away: the fork
  // rejections resolve against a scalar function, not against an outline.
  const probe = halfWidthFn(trunkWidth);

  // ---- resolve the shoots (including the rejections) ------------------------
  let kids = maxDepth < 1 ? 0 : ARCH_KIDS[arch];
  if (L < 46) kids = 0;
  if (L < 70) kids = Math.min(kids, 1);

  // A short strand can only carry a shoot from an early joint: from a late one there is not
  // enough trunk left for the shoot to clear the length floor, and it is rejected every time.
  const slotLimit = L < 95 ? 0.5 : 0.78;
  const slots: number[] = [];
  for (let j = 1; j < links; j++) if (cum[j] / L < slotLimit) slots.push(j);
  for (let i = slots.length - 1; i > 0; i--) {
    const j = Math.floor(r() * (i + 1));
    const t = slots[i];
    slots[i] = slots[j];
    slots[j] = t;
  }
  const chosen = slots.slice(0, kids).sort((a, b) => a - b);
  // The first shoot goes on the CONVEX side of the trunk bend, then they strictly alternate.
  const flip: 1 | -1 = bendDeg > 3 ? -1 : bendDeg < -3 ? 1 : coin(r);

  type Plan = {node: number; sn: number; headingDeg: number; len: number; half: number; side: 1 | -1};
  const plan: Plan[] = [];
  chosen.forEach((node, index) => {
    const sn = cum[node] / L;
    const ph = probe(sn, 0);
    const side: 1 | -1 = index % 2 === 0 ? flip : ((-flip) as 1 | -1);
    const parentAng = Math.atan2(trunk.dirs[node].y, trunk.dirs[node].x) * R2D;
    // Measure the departure against the CHORD from this node to the trunk tip, not against
    // the local link. When the trunk bends toward its own shoot the visual angle collapses
    // and the shoot reads as a barb or a split in the wood.
    const nodePt = trunk.nodes[node];
    const tipPt = trunk.nodes[links];
    const chordAng = Math.atan2(tipPt.y - nodePt.y, tipPt.x - nodePt.x) * R2D;
    let sep = wrap180(parentAng + uni(r, 28, 52) * side - chordAng);
    const sepFloor = L < 95 ? 34 : 24; // a shallow short fork is a bump, not a fork
    if (Math.abs(sep) < sepFloor) sep = sepFloor * (sep === 0 ? side : Math.sign(sep));
    // 52 deg, not 104: a shoot near perpendicular to the trunk reads as two sticks crossing,
    // and one that clears 90 deg reads as a barb pointing back at the butt. Rendered both.
    if (Math.abs(sep) > 52) sep = 52 * Math.sign(sep);
    let headingDeg = chordAng + sep;
    // Hard guard in the twig's own frame: a shoot may never turn back down the trunk.
    if (Math.abs(wrap180(headingDeg)) > 72) headingDeg = 72 * Math.sign(wrap180(headingDeg));

    const remaining = L - cum[node];
    // A shoot on a short strand has to be a big fraction of it or it is a blob on the flank
    // rather than a V. On a long twig the same fraction would read as two sticks crossing.
    // The third shoot on a `brushy` twig is kept short: three shoots of comparable length stop
    // reading as a twig and start reading as a little tree.
    const smallFork = L < 95;
    // Shoot length falls off by index. Two shoots of matched length are a tuning fork or a
    // pair of scissors, whatever their angle; unequal arms read as a twig at a glance.
    const idxScale = index === 0 ? 1 : index === 1 ? 0.78 : 0.55;
    const ceiling = (smallFork ? 0.46 : 0.32) * L * (index === 0 ? 1 : 0.85);
    const frac = (smallFork ? uni(r, 0.42, 0.62) : uni(r, 0.28, 0.5)) * idxScale;
    const len = Math.min(ceiling, remaining * frac);
    const lenFloor = smallFork ? Math.max(13, 0.26 * L) : Math.max(13, 0.14 * L);
    if (len < lenFloor) return; // rejected: no collar for a shoot that does not exist
    // The shoot MUST be visibly thinner at the junction or the Y reads as a tuning fork and
    // the eye cannot tell parent from child — but a small one must stay thick enough to be
    // ink rather than lint, which is why the ratio rises as the twig shortens.
    const half = ph * (smallFork ? uni(r, 0.46, 0.62) : uni(r, 0.38, 0.55));
    if (half < (smallFork ? 0.8 : 0.9)) return;
    plan.push({node, sn, headingDeg, len, half, side});
  });

  // A broken-off stub: the cheapest single mark that says the shape grew rather than was
  // drawn, and it is available to a `bare` twig that has no shoots at all.
  type Stub = {sn: number; headingDeg: number; len: number; half: number; side: 1 | -1};
  let stub: Stub | null = null;
  if (L >= 70 && baseHalf >= 1.9 && r() < 0.55) {
    const free = [];
    for (let j = 1; j < links; j++) if (!plan.some((k) => k.node === j)) free.push(j);
    const pool = free.length ? free : [1 + Math.floor(r() * (links - 1))];
    const node = pool[Math.floor(r() * pool.length)];
    const sn = cum[node] / L;
    const ph = probe(sn, 0);
    const half = ph * uni(r, 0.5, 0.65);
    const len = L * uni(r, 0.06, 0.12);
    if (len >= 7 && half >= 0.8) {
      const side: 1 | -1 = plan.length ? ((-plan[0].side) as 1 | -1) : coin(r);
      const parentAng = Math.atan2(trunk.dirs[node].y, trunk.dirs[node].x) * R2D;
      stub = {sn, headingDeg: parentAng + uni(r, 36, 64) * side, len, half, side};
    }
  }

  // ---- collars, only where a feature really is, and only on its side --------
  if (L >= 70) {
    for (const k of plan) {
      trunkWidth.collars.push({s: k.sn, side: k.side, gain: uni(r, 0.24, 0.36), sigma: 0.055});
    }
    if (stub) {
      trunkWidth.collars.push({s: stub.sn, side: stub.side, gain: uni(r, 0.14, 0.22), sigma: 0.05});
    }
    if (sharpAt >= 0) {
      // A bend and a node are the same feature: put the swelling on the corner and the corner
      // reads as grown rather than as a polyline artefact. Outside swells, inside pinches
      // slightly — swelling both flanks makes a lump, not a kink.
      const sj = cum[sharpAt] / L;
      const outside = ((-Math.sign(sharpDeg) || 1) as 1 | -1);
      trunkWidth.collars.push({s: sj, side: outside, gain: uni(r, 0.14, 0.24), sigma: 0.05});
      trunkWidth.collars.push({
        s: sj,
        side: (-outside) as 1 | -1,
        gain: -uni(r, 0.04, 0.1),
        sigma: 0.05,
      });
    }
  }
  const half = halfWidthFn(trunkWidth);

  // ---- emit ----------------------------------------------------------------
  const box: Box = {x0: Infinity, y0: Infinity, x1: -Infinity, y1: -Infinity};
  const rods: string[] = [];
  let points = 0;

  const t0 = rodOutline(
    trunk,
    half,
    {buttSkewDeg, tipCut, notch, lastSubs, w: trunkWidth},
    box
  );
  rods.push(t0.d);
  points += t0.points;

  /// A child rod. Its butt is buried inside the parent by starting it `back` px behind the
  /// junction along its own axis and adding that to its length, so the union is seamless and
  /// no cap seam can show. `fill-rule: nonzero` does the rest.
  const growRod = (a: {
    at: Vec;
    headingDeg: number;
    len: number;
    targetHalf: number;
    parentHalf: number;
    tipStyle: TipStyle;
    kinkRange: [number, number];
    bendRange: [number, number];
    bendSide: 1 | -1;
    linksWanted: number;
    undScale: number;
  }): {sp: Spine; half: HalfFn; len: number} => {
    const ang = a.headingDeg * D2R;
    const back = a.parentHalf * 1.05;
    const origin = V(a.at.x - Math.cos(ang) * back, a.at.y - Math.sin(ang) * back);
    const total = a.len + back;
    const t = TIPS[a.tipStyle];
    const w: WidthSpec = {
      // ×1.10 because the rod's own taper has already begun by the time it leaves the parent.
      base: a.targetHalf * 1.1,
      q: t.q,
      p: t.p,
      und: und * a.undScale,
      freq: freq * 1.4,
      phase: phase + 1.7,
      pinchButt: false,
      collars: [],
      floorHalf,
    };
    const h = halfWidthFn(w);
    const sp = buildSpine({
      origin,
      headingDeg: a.headingDeg,
      lens: linkLengths(a.linksWanted, total, r),
      bendDeg: a.bendSide * uni(r, a.bendRange[0], a.bendRange[1]),
      kinkDeg: uni(r, a.kinkRange[0], a.kinkRange[1]),
      sharpAt: -1,
      sharpDeg: 0,
      hookDeg: 0,
      r,
    });
    const out = rodOutline(
      sp,
      h,
      {buttSkewDeg: 0, tipCut, notch: false, lastSubs: Math.min(3, lastSubs), w},
      box
    );
    rods.push(out.d);
    points += out.points;
    return {sp, half: h, len: a.len};
  };

  const built: {sp: Spine; half: HalfFn; len: number; side: 1 | -1}[] = [];
  for (const k of plan) {
    const at = posAt(trunk, k.sn).p;
    const rod = growRod({
      at,
      headingDeg: k.headingDeg,
      len: k.len,
      targetHalf: k.half,
      parentHalf: half(k.sn, 0),
      tipStyle: 'spear', // a needle child is hair
      kinkRange: [3, 10],
      // Children carry more bend than the trunk, so the shoot curves away instead of running
      // parallel to it — two straight rods of similar weight read as a pair of sticks.
      bendRange: [10, 30],
      bendSide: k.side, // curve outward, away from the trunk
      linksWanted: k.len < 60 ? 2 : 3,
      undScale: 0.7,
    });
    built.push({...rod, side: k.side});
  }

  if (stub) {
    const at = posAt(trunk, stub.sn).p;
    growRod({
      at,
      headingDeg: stub.headingDeg,
      len: stub.len,
      targetHalf: stub.half,
      parentHalf: half(stub.sn, 0),
      tipStyle: 'wedge',
      kinkRange: [2, 8],
      bendRange: [0, 12],
      bendSide: stub.side,
      linksWanted: 2,
      undScale: 0,
    });
  }

  // Depth 2, hero sizes only, and only on the longest shoot that still carries width worth
  // branching. Grandchildren at nest scale are 4–8px hairs that render as fuzz.
  if (maxDepth >= 2 && L >= 150 && built.length >= 2) {
    const host = built.slice().sort((a, b) => b.len - a.len)[0];
    if (host.half(0, 0) > baseHalf * 0.3) {
      const n = r() < 0.5 ? 1 : r() < 0.5 ? 2 : 0;
      for (let i = 0; i < n; i++) {
        const sn = uni(r, 0.35, 0.7);
        const ph = host.half(sn, 0);
        const len = host.len * uni(r, 0.35, 0.6);
        if (len < 9 || ph < 0.7) continue;
        const at = posAt(host.sp, sn);
        const ang = Math.atan2(at.d.y, at.d.x) * R2D;
        const side: 1 | -1 = i % 2 === 0 ? ((-host.side) as 1 | -1) : host.side;
        growRod({
          at: at.p,
          headingDeg: ang + uni(r, 20, 46) * side,
          len,
          targetHalf: ph * uni(r, 0.55, 0.72),
          parentHalf: ph,
          tipStyle: 'spear',
          kinkRange: [2, 8],
          bendRange: [0, 18],
          bendSide: side,
          linksWanted: 2,
          undScale: 0,
        });
      }
    }
  }

  // ---- the highlight -------------------------------------------------------
  // Not a rim, not a filter, not a gradient: a second filled ribbon from the SAME spine and
  // the SAME width function, its centreline pushed to the lit side by 0.46w with a half-width
  // of 0.28w. It occupies 0.18w to 0.74w, leaving a rim of base colour on the lit edge, and
  // it tapers with the twig for free. Two tones inside a 4px shape is mud, so thin twigs get
  // none and take their tonal separation from the palette instead.
  let highlight: string | null = null;
  if ((o.allowHighlight ?? true) && baseHalf >= 2.6) {
    const lightDeg = o.lightLocalDeg ?? LIGHT_WORLD_DEG;
    const lx = Math.cos(lightDeg * D2R);
    const ly = Math.sin(lightDeg * D2R);
    // Decided ONCE, at the widest visible part, and held for the whole twig. A side that
    // flips mid-twig reads as a crawling worm.
    const mid = posAt(trunk, 0.35);
    const nMid = perp(mid.d);
    const litSide: 1 | -1 = nMid.x * lx + nMid.y * ly >= 0 ? 1 : -1;
    const lo = 0.14;
    const hi = 0.66 * Math.min(1, tipCut);
    // Reuse the trunk's own samples so the ribbon creases where the twig creases, and force
    // the two ends so the taper is not left to wherever a sample happened to land.
    const inner = sampleList(trunk, trunkWidth, tipCut, lastSubs).filter(
      (s) => s.sn > lo && s.sn < hi
    );
    const span: Sample[] = [
      {sn: lo, link: 0, joint: false},
      ...inner,
      {sn: hi, link: 0, joint: false},
    ];
    for (const s of span) if (s.sn === lo || s.sn === hi) s.link = linkOf(trunk, s.sn);
    if (span.length >= 3) {
      const a: string[] = [];
      const b: string[] = [];
      for (const s of span) {
        const {p, n, miter} = frameAt(trunk, s, 0);
        const w = half(s.sn, litSide) * miter;
        const cx = p.x + n.x * litSide * 0.48 * w;
        const cy = p.y + n.y * litSide * 0.48 * w;
        // Pointed at both ends. Flush at the butt with a flat far end, the sliver reads as a
        // second pale plank laid on the twig — that was visible at 2x before this factor.
        const u = (s.sn - lo) / (hi - lo);
        const hw = 0.3 * w * Math.pow(Math.sin(Math.PI * u), 0.55);
        a.push(`${f1(cx + n.x * litSide * hw)} ${f1(cy + n.y * litSide * hw)}`);
        b.push(`${f1(cx - n.x * litSide * hw)} ${f1(cy - n.y * litSide * hw)}`);
      }
      highlight = `M ${a.join(' L ')} L ${b.reverse().join(' L ')} Z`;
      points += span.length * 2;
    }
  }

  return {
    body: rods.join(' '),
    highlight,
    points,
    arch,
    sweep,
    tip,
    weight,
    baseHalf,
    length: L,
    kids: built.length,
    bbox: box,
  };
};

/* ------------------------------------------------------------------ colour */

/// Overlapping or adjacent strands must differ by at least 22 luma or they read as one shape
/// rather than as two strands. Index distance is not enough: `#7F6B48` and `#8A6A3F` are one
/// rung apart and 1.0 luma apart.
export const pickRung = (r: () => number, lo: number, hi: number, prevLuma: number | null): number => {
  const span = hi - lo + 1;
  for (let i = 0; i < 8; i++) {
    const k = lo + Math.floor(r() * span);
    if (prevLuma === null || Math.abs(RAMP[k].luma - prevLuma) >= 22) return k;
  }
  let k = lo;
  let best = -1;
  for (let j = lo; j <= hi; j++) {
    const d = prevLuma === null ? 1 : Math.abs(RAMP[j].luma - prevLuma);
    if (d > best) {
      best = d;
      k = j;
    }
  }
  return k;
};

/* ------------------------------------------------------------------ a set */

export type Placement = {
  x: number;
  y: number;
  rotateDeg: number;
  length: number;
  /// 0 back, 1 middle, 2 front.
  layer: 0 | 1 | 2;
  drift: number;
};

export type PlacedTwig = {
  /// Position in the deal, which is also the layout slot. Use it as the React key: the depth
  /// sort below changes draw order, not identity.
  index: number;
  geom: TwigGeometry;
  fill: string;
  highlightFill: string;
  transform: string;
  layer: 0 | 1 | 2;
  /// Which drift-phase group this twig belongs to. Transform the GROUP, not the twig: 6
  /// style recalcs a frame instead of 60.
  bucket: number;
};

/// A whole nest's worth. Every rng draw and every deal happens here, once. Memoise the result
/// on [seed, count, layout inputs] and NEVER on `frame`.
export const buildTwigSet = ({
  count,
  seed,
  layout,
  buckets = 6,
  stout,
}: {
  count: number;
  seed: number;
  layout: (i: number, r: () => number) => Placement;
  buckets?: number;
  /// Thickness multiplier for the whole set. Natural proportion is correct in isolation and
  /// too fine on a store listing, where the banner is shown at a fraction of 3840px.
  stout?: (place: Placement) => number;
}): PlacedTwig[] => {
  const r = rngOf(seed);
  // One deck PER LAYER. With a single deck and layers interleaved in the deal order, the
  // no-repeat guarantee applies to twigs three apart in the deal and not to the ones drawn
  // next to each other: measured 16 adjacent same-archetype pairs inside a layer before this
  // was split, and 0 after.
  const decks = [0, 1, 2].map(() => ({
    arch: dealer(ARCH_BAG, r),
    sweep: dealer(SWEEP_BAG, r),
    tip: dealer(TIP_BAG, r),
    weight: dealer(WEIGHT_BAG, r),
  }));

  const out: PlacedTwig[] = [];
  const prevLuma: (number | null)[] = [null, null, null];

  for (let i = 0; i < count; i++) {
    const place = layout(i, r);
    const L = place.length;
    const deck = decks[place.layer];
    const arch = deck.arch();
    const sweep = deck.sweep();
    // Below 110px the clean wedge is the only internal feature that survives, and it is the
    // whole difference between a twig and a line.
    const tipDealt = deck.tip();
    const tip: TipStyle = L < 110 ? 'wedge' : tipDealt;
    const weight = deck.weight();

    const geom = buildTwig({
      seed: hash32(seed ^ (i * 0x9e3779b1)),
      length: L,
      arch,
      sweep,
      tip,
      weight,
      maxDepth: place.layer === 0 ? 0 : L >= 150 ? 2 : 1,
      lightLocalDeg: LIGHT_WORLD_DEG - place.rotateDeg,
      allowHighlight: place.layer === 2,
      stout: stout?.(place),
    });

    const [lo, hiRaw] = LAYER_RUNGS[place.layer];
    // The two palest entries are only 5–12% darker than the paper. At nest scale a 60x5px
    // shape in them disappears, so small strands are kept out of them entirely.
    const hi = L < 90 ? Math.min(hiRaw, 5) : hiRaw;
    const rung = pickRung(r, lo, hi, prevLuma[place.layer]);
    prevLuma[place.layer] = RAMP[rung].luma;

    // Mirroring doubles the apparent library for free, exactly where the twig count is
    // highest — but never on a highlighted twig, because it would put the light on the
    // unlit side.
    const mirror = !geom.highlight && L < 100 && r() < 0.5;
    out.push({
      index: i,
      geom,
      fill: RAMP[rung].hex,
      highlightFill: RAMP[rung].light,
      transform:
        `translate(${f1(place.x)} ${f1(place.y)}) rotate(${f1(place.rotateDeg)})` +
        (mirror ? ' scale(1 -1)' : ''),
      layer: place.layer,
      bucket: i % buckets,
    });
  }

  // Back to front, and within the front layer longest first so the small bright bits sit on
  // top. Depth is colour order plus draw order and nothing else.
  return out.sort((a, b) => a.layer - b.layer || (a.layer === 2 ? b.geom.length - a.geom.length : 0));
};

/// The bbox of a whole set in world space, for tightening the nest's one drop-shadow filter
/// region. At 3840 wide, leaving `x="-20%" width="140%"` on a full-canvas svg asks Chrome for
/// a ~5400px surface every frame.
export const setBBox = (twigs: PlacedTwig[]): Box => {
  const box: Box = {x0: Infinity, y0: Infinity, x1: -Infinity, y1: -Infinity};
  for (const t of twigs) {
    const m = /translate\(([-\d.]+) ([-\d.]+)\)/.exec(t.transform);
    if (!m) continue;
    const cx = Number(m[1]);
    const cy = Number(m[2]);
    const rad = Math.max(t.geom.length, Math.hypot(t.geom.bbox.x1 - t.geom.bbox.x0, t.geom.bbox.y1 - t.geom.bbox.y0));
    growBox(box, V(cx - rad, cy - rad));
    growBox(box, V(cx + rad, cy + rad));
  }
  return box;
};
