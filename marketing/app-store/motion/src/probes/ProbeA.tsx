import React from 'react';
import {AbsoluteFill, useCurrentFrame, useVideoConfig} from 'remotion';
import {ARCH_BAG, buildTwig, dealer, rngOf, LIGHT_WORLD, LIGHT_WORLD_DEG} from '../twig';
import type {Arch, Sweep, TipStyle, TwigGeometry, Weight} from '../twig';
import {CANVAS} from '../theme';

/// Concept C — "One twig at a time".
///
/// A bird crosses the sky carrying a twig, drops it into the nest below, and goes back for the
/// next one. That is the whole app in a picture: nobody handed you a feed, you went and fetched
/// each piece of it yourself, and what you built is yours.
///
/// The frame is ONE illustrated scene with one subject — a 1248px woven nest wedged in the fork
/// of a bough, lit by a low sun off to the upper right, with the wordmark set beside it in the
/// upper left and the bird small and far away in the sky. It is not a diagram and not a
/// collage; the reference examples for this slot (Forest Explorer, The Coast) are single
/// confident scenes with real depth and slow motion, and this is aimed at that.
///
/// WHY EVERY MOTION IS A WHOLE CYCLE. The asset autoplays silently and loops, so frame 179 has
/// to hand over to frame 0 as if it were any other frame. Nothing here uses spring() or a
/// one-way eased interpolate(): the sway is two sines whose periods divide the loop, the shafts
/// breathe on sin(theta), the bird's position/scale/roll/wingbeat are all functions of the loop
/// phase built to be periodic in it, and the one state change in the whole piece — an empty beak
/// becoming a full one — happens off-canvas at the seam where nobody can see it.
///
/// THE STRUCTURAL DECISION, and it was made the wrong way once. The guaranteed region is only
/// 1645x659 — x 1097..2742, y 493..1152 — and an earlier pass composed for the 3840x1646 canvas
/// and let the safe box take what it took. Measured, that cost 35% of the nest, every pixel of
/// its contact with the bough, and the bird: its ink was fully inside the guaranteed view for 24
/// of 180 frames, so the thing a browsing user actually saw was a word and a texture.
///
/// So the box is the frame now, and everything is sized to it: the nest is 676px wide (41% of
/// the box) with its underside three pixels inside the bottom edge, the lashings that tie it to
/// the bough are inside the box, the wordmark is 475px in the upper left, and the bird's whole
/// working leg — approach, flare, release, exit — flies the band y 660..925 between them, which
/// is the one lane nothing else wants. The canvas outside the box is bleed and carries only
/// atmosphere: the sun, the shafts, the trunk running out of the corner, the return leg.

/* ------------------------------------------------------------------ helpers */

const TAU = Math.PI * 2;
const D2R = Math.PI / 180;
const lerp = (a: number, b: number, t: number) => a + (b - a) * t;
const clamp = (v: number, lo: number, hi: number) => (v < lo ? lo : v > hi ? hi : v);
const clamp01 = (v: number) => clamp(v, 0, 1);
const uni = (r: () => number, a: number, b: number) => a + r() * (b - a);
const f1 = (n: number) => Math.round(n * 10) / 10;
/// For animated ANGLES only, and it is a bug fix. `f1` quantises to 0.1, which on a static path
/// coordinate is invisible and on a rotation about a pivot 3264 units away is a 3.1px jump on
/// screen. The sway's whole amplitude is 0.92 degrees, i.e. nine of those steps, so the nest was
/// sitting still for three or four frames and then snapping — measured on the delivered MP4 as
/// bit-identical runs of up to 13 frames followed by a single 4-5px catch-up, which three
/// reviewers correctly called a stutter and which was diagnosed as a bitrate problem. It was not:
/// at 29.6 Mbps with no B-frames the staircase was still there, on exactly the 0.1-degree period.
const f4 = (n: number) => n.toFixed(4);
/// Shortest signed difference between two headings, so a tangent wrapping past 180 does not
/// send the bird into a barrel roll for one frame.
const angleDelta = (from: number, to: number) => {
  let d = (to - from) % 360;
  if (d > 180) d -= 360;
  if (d < -180) d += 360;
  return d;
};

const W = CANVAS.header.width; // 3840
const H = CANVAS.header.height; // 1646
/// The only region the store guarantees to show: 1645x659 centred, i.e. x 1097..2742,
/// y 493..1152. Everything outside it is bleed that may be cropped at any breakpoint, so it
/// must be filled but must not carry meaning.
const SAFE = {
  x0: (W - CANVAS.header.safe.width) / 2,
  y0: (H - CANVAS.header.safe.height) / 2,
  x1: (W + CANVAS.header.safe.width) / 2,
  y1: (H + CANVAS.header.safe.height) / 2,
};

/* ------------------------------------------------------------------ the light */

/// Where the sun is, SOLVED rather than picked. `twig.ts` bakes its highlight direction into
/// `LIGHT_WORLD_DEG` (-37.674 degrees), and every generated flank in the piece is oriented to
/// it. From the nest's centre on screen (2360, 990) the bearing to (3310, 257) is
/// atan2(-733, 950) = -37.65 degrees, so the generator is not touched and no highlight in the
/// frame disagrees with the sky. Every shadow and contact offset here runs along the opposite
/// unit vector, (-0.79, +0.61).
///
/// It stays outside the safe box on purpose. Its 1500px aureole reaches x 1810, so the
/// guaranteed view gets the light without a 960px white disc parked against the nest's rim.
const SUN = {x: 3310, y: 257};

/* ------------------------------------------------------------------ the wood ramp */

/// The nest's own ramp, and the reason the old art's pale strands read as grey: eight rungs,
/// every one of them wood — hue 27-34 (the paper is hue 40) and HSV saturation 0.59-0.73, so no
/// rung sits at the paper's own hue with half its chroma. The full 35..160 luma span is kept:
/// compressing it (an earlier pass squeezed the nest to luma 26-146) is what turned the mass
/// into a near-monotone black scratch. The pale rungs are made to read as sunlit wood by
/// darkening what is BEHIND them — see the shaded pocket — not by darkening them.
const NEST_RAMP = [
  {hex: '#31210E', light: '#4A3419'},
  {hex: '#412C12', light: '#5C3A18'},
  {hex: '#533617', light: '#6E4520'},
  {hex: '#68431F', light: '#8A5A2C'},
  {hex: '#825229', light: '#A8703A'},
  {hex: '#9E6A32', light: '#C08544'},
  {hex: '#B98244', light: '#D6A05B'},
  {hex: '#CE9A55', light: '#E8BC7C'},
] as const;

const lumaOf = (hex: string) => {
  const n = parseInt(hex.slice(1), 16);
  return 0.2126 * ((n >> 16) & 255) + 0.7152 * ((n >> 8) & 255) + 0.0722 * (n & 255);
};
const LUMA = NEST_RAMP.map((c) => lumaOf(c.hex));

/// MATERIAL. Every strand, lashing and sprig in the nest is filled with a continuous ramp
/// ACROSS ITS OWN THICKNESS instead of one flat hex, and that single change is what turns 486
/// tapered slabs into rods. A flat fill gives a shape a hard edge on both flanks, and 470 hard
/// edges at this scale read as wood-wool — excelsior, pencil shavings. A cross-thickness ramp
/// has no edge to read as a bevel, so the same silhouette reads as a cylinder.
///
/// 48 shared defs, not 486 per-path ones: 8 rungs x lit-up/lit-down x 3 thickness buckets.
/// `gradientUnits="userSpaceOnUse"` with x1=x2=0 makes the ramp run along the strand's LOCAL y
/// axis, so it rotates with the strand's own group for free — the mechanism the bough's bark
/// already uses. `spreadMethod="reflect"` is the one thing not in the original plan: a strand
/// with a 30-degree bow wanders 20-40px off its own axis, which puts its far half outside a
/// +-9px gradient band and back to one flat colour. Reflecting the ramp keeps a continuous
/// cross-section ramp everywhere on the rod at the cost of the lit flank sometimes swapping
/// sides mid-strand, which at 18px of thickness reads as a knuckle rather than as an error.
const THICK_BUCKETS = [9.0, 6.0, 3.5];
const bucketOfHalf = (baseHalf: number) => (baseHalf >= 7.5 ? 0 : baseHalf >= 4.75 ? 1 : 2);
/// True when the strand's local -y flank faces the sun. cos((rot - 52.33) * D2R) is exactly the
/// dot product of that flank's world normal with the direction to the sun: a horizontal strand
/// (rot 0) gives cos(-52.33) = 0.61 > 0, so its top is lit, which is right for a sun up and to
/// the right.
const litUpAt = (rotateDeg: number) => Math.cos((rotateDeg - 52.33) * D2R) > 0;
const gradId = (k: number, litUp: boolean, bucket: number) => `g${k}${litUp ? 'u' : 'd'}${bucket}`;

const WoodGradients: React.FC = () => (
  <>
    {NEST_RAMP.map((rung, k) =>
      [true, false].map((up) =>
        THICK_BUCKETS.map((half, bucket) => {
          const stops = [
            {o: '0%', c: rung.light},
            {o: '36%', c: rung.hex},
            {o: '78%', c: NEST_RAMP[Math.max(0, k - 1)].hex},
            {o: '100%', c: NEST_RAMP[Math.max(0, k - 2)].hex},
          ];
          const list = up ? stops : stops.slice().reverse().map((s, i) => ({o: stops[i].o, c: s.c}));
          return (
            <linearGradient
              key={gradId(k, up, bucket)}
              id={gradId(k, up, bucket)}
              gradientUnits="userSpaceOnUse"
              spreadMethod="reflect"
              x1={0}
              y1={-half}
              x2={0}
              y2={half}
            >
              {list.map((s) => (
                <stop key={s.o} offset={s.o} stopColor={s.c} />
              ))}
            </linearGradient>
          );
        })
      )
    )}
  </>
);

/* ------------------------------------------------------------------ the torus */

/// The nest is a TORUS (ring radius R, tube radius T) projected orthographically from 18
/// degrees above the horizon, and that is the single idea that makes it a nest rather than a
/// broom. Strands are placed at surface points (phi around the ring, psi around the tube) and
/// aimed along directions that exist ON the surface, so they cross each other at up to 90
/// degrees on screen and the mass interlocks. On the old parabola the tangent never exceeded 34
/// degrees, so nothing COULD cross.
///
/// R = 435, T = 148 at 18 degrees, with a wall thickness T/R of 0.34 (thinner reads as a
/// wreath). These are LOCAL units and they are not the screen size: the whole wood scene is
/// solved in this space and then placed through one similarity — see SCENE — which is what let
/// the nest be re-sized for the safe box without re-deriving the blotch field's phase, the cup
/// wobble, the end-length caps or a single filter region.
const CX = 2140;
const CY = 969;
const R = 435;
const T = 148;
/// 15 degrees made a hollow the near rim's own strands then filled in. At 18 the hollow is 253px
/// tall and 870 wide and survives being woven around.
const ALPHA = 18 * D2R;
const VY = Math.cos(ALPHA); // 0.9511 — how much "up" survives the projection
const KD = Math.sin(ALPHA); // 0.3090 — how much "towards the viewer" turns into "down"

/// THE CAMERA. One similarity that takes the whole wood scene from the space it was solved in
/// to the space the store actually shows: local (CX, CY) lands at (2360, 990) at 0.58.
///
/// This is the fix for the framing failure, and it is a transform rather than 200 edited numbers
/// for a specific reason — every measured constant in the nest (the 128-column silhouette scan,
/// the seat, the strand-rejection slacks, the cup's wobble, the blotch field, all eleven filter
/// regions and every stdDeviation in them) is stated in local units, and `filterUnits`
/// `userSpaceOnUse` resolves inside the group's own user space. So the scene shrinks with its
/// blurs, its drop-shadow offsets and its rejection tests intact, and the only things that had to
/// be re-solved are the handful of objects that live in WORLD space: the sun, the shafts, the
/// shaded pocket, the falling twig and its two filter regions.
///
/// What the numbers buy, MEASURED against the safe box from the audit rather than intended: the
/// nest's ink runs x 2027.2..2730.1 and y 787.4..1113.9, so it is 703px wide (43% of the box) with
/// 11.9px of clearance at the right edge and 38.1px under its underside. Both matter — at 3px,
/// which is where an earlier pass left the floor, an object flush with the frame edge reads as
/// cropped even when it is not. There is a 294px-deep lane above the nest for the bird.
/// cx 2380, not the 2332 this was solved at, nor the 2430 a later pass tried, nor the 2392 that
/// stood before the crook went in. The nest was moved right to open width for the wordmark, and
/// 2430 took it 49px past the safe box's right edge — an object flush with a crop line reads as
/// cropped whether it is or not, which is the same mistake in the other direction. The last 12px
/// are a correction and not a preference: raising the bough into the weave changed which strands
/// the seat rejects, and the surviving set reached x 2742.1 against a box that ends at 2742. 2380
/// puts it back to 11.9px, which is inside the antialiasing of its own outermost strand.
///
/// The floor gained 11px in the same move for the same reason: with the bough raised, `seatTrim`
/// rather than `boughTopAt + 55` is what governs the underside, and it cuts higher.
const SCENE = {k: 0.55, cx: 2380, cy: 950};
const SCENE_XF = `translate(${SCENE.cx} ${SCENE.cy}) scale(${SCENE.k}) translate(${-CX} ${-CY})`;
const toWorld = (x: number, y: number) => ({
  x: SCENE.cx + SCENE.k * (x - CX),
  y: SCENE.cy + SCENE.k * (y - CY),
});
const toLocal = (x: number, y: number) => ({
  x: CX + (x - SCENE.cx) / SCENE.k,
  y: CY + (y - SCENE.cy) / SCENE.k,
});

/// The sun as a 3D direction: right, a little towards the viewer, mostly up. Its screen
/// projection is LIGHT_WORLD_DEG, which is what every generated highlight is already aimed at.
const LIGHT = {x: 0.5, d: 0.35, y: 0.79};

type P = {x: number; y: number; D: number};

/// (phi, psi) -> screen. `D` is depth towards the viewer; nearer projects lower.
const proj = (phi: number, psi: number): P => {
  const rad = R + T * Math.cos(psi);
  const D = rad * Math.sin(phi);
  return {x: CX + rad * Math.cos(phi), y: CY - VY * T * Math.sin(psi) + KD * D, D};
};

/// d(screen)/d(phi) — along the ring. Horizontal at front and back centre, VERTICAL at the two
/// ends, which is where the weave gets its steep strands for free.
const dPhi = (phi: number, psi: number) => {
  const rad = R + T * Math.cos(psi);
  return {x: -rad * Math.sin(phi), y: KD * rad * Math.cos(phi)};
};

/// d(screen)/d(psi) — over the tube, perpendicular to `dPhi` on the surface. This is the weave.
const dPsi = (phi: number, psi: number) => {
  const s = Math.sin(psi);
  const c = Math.cos(psi);
  return {x: -T * s * Math.cos(phi), y: -VY * T * c - KD * T * s * Math.sin(phi)};
};

const angOf = (v: {x: number; y: number}) => Math.atan2(v.y, v.x) / D2R;

/* ------------------------------------------------------------------ the bough */

/// The branch the nest is built on, and the fix for two named defects: a smooth diagonal tube
/// that crossed IN FRONT OF the nest without touching it, and a straight tan pole standing out
/// of the top of the frame beside it. The pole — a second fork arm — is gone entirely. What is
/// left is one limb whose placement is SOLVED from its two ends rather than picked:
///
///   the butt has to leave the canvas — it exits the BOTTOM edge at screen x 3387, 250px short of
///   the corner and with 250px of overshoot past the edge, so no sway can pull it back on screen.
///   rot 206 rather than 199 for exactly that: at 199 the limb ran all the way to the far corner
///   and 1943px of near-straight diagonal is the "plank across a landscape" this asset has already
///   been rejected for once. At 206 the visible run is 1368px and it leaves downwards;
///
///   the needle tip has to die INSIDE the nest's left fringe (screen x 2124, about 100px in from
///   the nest's left end), because the seat below only stops cutting where the wood runs out and
///   a tip in open paper is the dart the earlier version was rejected for.
///
/// `baseHalf` is clamped to 9px inside the generator — a deliberate ceiling, past which a twig
/// stops being a twig — so a bough this thick is built SHORT and scaled UNIFORMLY: 349 units at
/// 10.42. The taper and the knuckles scale with it instead of smearing, which is what a
/// non-uniform stretch does. On screen that is 2000px long and 102px thick at the butt.
///
/// AND THAT IS THE WHOLE STORY ABOUT THICKNESS UNDER THE NEST, measured rather than hoped for:
/// `baseHalf` is `0.0255 * length` clamped at 9, so for `len <= 353` the limb's aspect is LOCKED at
/// 39:1 and world thickness is 0.051 * world length no matter how you split it between `len` and
/// `scale`. A grid over scale 9.6-16.6 x length 1843-2150 moved the thickness under the nest's
/// centre from 57px to 65px and no further. The wood under the nest cannot be thickened by scaling
/// this limb; it has to come from a JUNCTION, which is what BOUGH2 now is.
///
/// 349 units at 10.42, not 9.6: the extra 157px of world length walks the needle tip from screen
/// x 2205 to x 2141, so the tip dies 100px further inside the nest's left fringe and — because
/// `seatTop` reads `boughTopAt` — the anti-float clause reaches 100px further left too.
///
/// `tip: 'needle'` and not 'spear': a needle stays fat for 90% of its length and whips to a point
/// in the last few percent, so there is still real wood under the load where a spear left a wedge.
const BOUGH = {at: {x: 4987, y: 2572}, rot: 206, scale: 10.42, len: 349};

const BOUGH_GEOM = buildTwig({
  seed: 0x1188,
  length: BOUGH.len,
  arch: 'bare',
  sweep: 'stiff',
  weight: 'stick',
  tip: 'needle',
  maxDepth: 0,
  lightLocalDeg: LIGHT_WORLD_DEG - BOUGH.rot,
  allowHighlight: false,
});
const BOUGH_XF = `translate(${BOUGH.at.x} ${BOUGH.at.y}) rotate(${BOUGH.rot}) scale(${BOUGH.scale})`;

/// ------------------------------------------------------------------ THE TRUNK
///
/// WHY THERE IS ONE, measured on the state this replaces rather than argued from taste.
///
///   1. The nest's own underside, rendered with the wood hidden and read off the PNG, is FLAT:
///      world y 1082-1120 across x 2160..2700, turning up to 982 at its left tip. The wood's top
///      edge under it ran 1007 at x 2150 down to 1163 at x 2700 on the main limb, and 1140 up to
///      1071 on the far arm. So the two only touched over x 2300..2600 — 300px of a 703px nest,
///      43% — and the rest of the nest hung over bare paper: a 110px void at x 2100 and a 78px
///      void at x 2700. The nest was not sitting on the wood, it was bridging between two sticks.
///   2. Where they did touch, the wood was 55-85px thick against a nest 327px tall — 1:5. Both
///      members were at their thin ends there: the main limb at 87% of a needle taper.
///   3. The two limbs' top edges PEAKED at the contact and fell 250px to the right and 160px to
///      the left. That is a ridge, and a nest on a ridge is balanced, not seated.
///   4. Every piece of wood in the frame travelled downwards away from the nest and left the
///      bottom edge. There was no ink above the nest at all, so the wood had no origin, no implied
///      mass and nowhere to have grown from.
///
/// (3) and (4) are the reason a shallow fork did not fix (1): both arms of a Λ are, by definition,
/// running out of the picture, and no amount of burying the apex changes that they are falling.
///
/// The trunk is the answer to (4) and to half of (2): something visibly thicker and more vertical
/// that the nest is set against, whose lower half leaves the BOTTOM of the frame (so it is going
/// to the ground) and whose upper half leaves the TOP (so there is more tree). It stands behind
/// the nest's right third — x 2613..2795 at the nest's floor, 2481..2603 at the safe box's ceiling
/// — so the weave's near strands close over its near flank and the nest is wedged against it
/// rather than perched on it.
///
/// SOLVED, not picked:
///   the lean is 16.7 degrees off vertical with the crown to the LEFT, which is what walks it from
///   x 2871 at the canvas floor to x 2378 at the ceiling: at 0 degrees it is a post, and past ~22
///   it stops being able to clear the bird's exit ramp at waypoint 10 (2740, 630);
///
///   3592px long so the taper is real — `baseHalf` is `0.0255 * length` clamped at 9, so the ONLY
///   way to a thick limb is a long one, and 3592px is what buys 187px at the canvas floor thinning
///   to 123px at the safe ceiling. A trunk that does not visibly thin upward reads as a pipe;
///
///   seed 0x900b out of a swept set, chosen on a ROW scan of its own outline rather than on looks:
///   the generator's kink can wander a 3600px limb 400px sideways (0x9004 did exactly that, and
///   0x9003 missed the nest entirely), and 0x900b is the one whose flanks stay monotone and whose
///   thickness falls cleanly from 187 to 91 top to bottom.
///
/// WHERE IT STANDS, and this was solved by rendering the alternative. Its left flank runs x 2498
/// at the nest's crown to 2528 at the nest's floor, so it stands behind the nest's last 200px —
/// a third of the nest's width, which sounds like a lot and is the whole point: the nest's near
/// strands are drawn AFTER the trunk, so the weave visibly crosses it and the nest is WEDGED
/// against the wood rather than ending beside it. Moved 70px right to give the nest its width
/// back, the trunk lost the safe box: 191px of it survived the crop at the ceiling and none of it
/// read as a trunk any more — just a bevel on the frame's right edge. The overlap is what buys
/// the presence.
const TRUNK = {at: {x: 3214.6, y: 5241.7}, rot: -98.64, scale: 24.75, len: 353};
const TRUNK_GEOM = buildTwig({
  seed: 0x9214,
  length: TRUNK.len,
  arch: 'bare',
  sweep: 'stiff',
  weight: 'stick',
  tip: 'needle',
  maxDepth: 0,
  lightLocalDeg: LIGHT_WORLD_DEG - TRUNK.rot,
  allowHighlight: false,
});
const TRUNK_XF = `translate(${TRUNK.at.x} ${TRUNK.at.y}) rotate(${TRUNK.rot}) scale(${TRUNK.scale})`;

/// Grain on the trunk, in the trunk's own frame: `s` is the fraction of TRUNK.len from the butt,
/// `off` the offset across its 9-unit half-thickness. The trunk's visible run is s 0.45 (the canvas
/// floor) to 0.91 (the ceiling), so every rod lives inside that; a rod at s 0.2 would be 1500px
/// below the frame. Two dark and four lit, none of them across the middle where the gradient
/// already carries the round.
/// Grain on the far limb, same argument as the trunk's. At 1:1 the re-cut limb was a smooth
/// rubber tube — one cross-thickness ramp over a 3000px cylinder with no incident anywhere. `s`
/// is the fraction of BOUGH2.len from its butt (which is inside the trunk), so s 0.12..0.75 is the
/// run from just clear of the nest's fringe to the canvas's left edge.
const LIMB_GRAIN = [
  {seed: 0x8a1, s: 0.13, off: -4.6, len: 46, rot: 1.1, rung: 0, op: 0.3},
  {seed: 0x8b2, s: 0.19, off: 5.4, len: 32, rot: -1.4, rung: 5, op: 0.22},
  {seed: 0x8c3, s: 0.25, off: -1.4, len: 40, rot: 0.8, rung: 1, op: 0.2},
  {seed: 0x8d4, s: 0.32, off: 3.0, len: 26, rot: -0.6, rung: 6, op: 0.2},
  {seed: 0x8e5, s: 0.39, off: -6.2, len: 36, rot: 1.5, rung: 0, op: 0.28},
  {seed: 0x8f6, s: 0.46, off: 1.0, len: 44, rot: -1.0, rung: 2, op: 0.16},
  {seed: 0x901, s: 0.54, off: 5.8, len: 24, rot: 1.2, rung: 4, op: 0.2},
  {seed: 0x912, s: 0.62, off: -3.2, len: 34, rot: -0.9, rung: 1, op: 0.22},
  {seed: 0x923, s: 0.71, off: 2.2, len: 28, rot: 1.3, rung: 0, op: 0.18},
] as const;

const TRUNK_GRAIN = [
  {seed: 0x7a1, s: 0.365, off: -5.4, len: 74, rot: 0.7, rung: 0, op: 0.3},
  {seed: 0x7b2, s: 0.383, off: 6.1, len: 40, rot: -1.2, rung: 5, op: 0.22},
  {seed: 0x7c3, s: 0.4, off: -1.8, len: 58, rot: 1.4, rung: 1, op: 0.2},
  {seed: 0x7d4, s: 0.421, off: 3.4, len: 34, rot: -0.5, rung: 6, op: 0.18},
  {seed: 0x7e5, s: 0.444, off: -6.6, len: 46, rot: 0.9, rung: 0, op: 0.26},
  {seed: 0x7f6, s: 0.462, off: 1.2, len: 62, rot: -1.5, rung: 2, op: 0.16},
  {seed: 0x801, s: 0.487, off: 5.2, len: 30, rot: 1.1, rung: 4, op: 0.22},
  {seed: 0x812, s: 0.508, off: -3.6, len: 52, rot: -0.8, rung: 1, op: 0.22},
  {seed: 0x823, s: 0.53, off: 6.8, len: 38, rot: 1.6, rung: 6, op: 0.18},
  {seed: 0x834, s: 0.552, off: -0.9, len: 44, rot: -1.1, rung: 0, op: 0.17},
  {seed: 0x845, s: 0.577, off: 2.6, len: 28, rot: 0.6, rung: 5, op: 0.2},
  {seed: 0x856, s: 0.599, off: -5.8, len: 40, rot: -1.4, rung: 1, op: 0.24},
  {seed: 0x867, s: 0.624, off: 4.4, len: 32, rot: 1.2, rung: 4, op: 0.18},
  {seed: 0x878, s: 0.652, off: -2.8, len: 26, rot: -0.7, rung: 0, op: 0.2},
] as const;

/// THE SECOND LIMB — and it is a CROOK, which is the answer to two rejections at once.
///
/// Rejection A, in the human's words: "둥지가 너무 가지 끝에 있어. 떨어질것같이 불안정해" — the nest is out
/// on the end of the branch and looks like it will fall off. Measured, that is exactly what the frame
/// showed: the main limb's needle tip died at screen x 2205, only 165px inside a nest 713px wide, so
/// the nest's whole left half hung over bare paper, and the wood that was under it was the last 11%
/// of a taper — 36px thick at x 2300 against a nest 349px tall.
///
/// Rejection B: this arm read as a spear driven through the main limb. Measured on the old numbers,
/// 86% of its ink lay outside the main limb's silhouette and its butt sat 110px ABOVE the limb's top
/// edge, in open air — so it was never buried at all, and what the eye saw was one stick passing
/// clean through another and coming out the far side as a flat dark blade with a needle point in the
/// middle of the paper.
///
/// Both are one problem: the nest has nothing under it but a tip. A nest belongs in a CROOK, so this
/// arm is now the other half of one. Its butt is buried inside the main limb DIRECTLY UNDER THE NEST
/// and it falls away to the lower left, so the two limbs make a shallow Λ whose apex is hidden by the
/// weave and whose arms leave the frame at the bottom on either side. The nest is no longer at the
/// end of anything — it sits across a branch that continues out of the frame both ways — and the
/// joint, which is the thing you do not want to have to draw, is under the nest where it belongs.
///
/// Butt at local (2009, 1251) = screen (2320, 1105). That point is inside the main limb's silhouette
/// (which runs y 1090..1145 in that column) AND under the nest's fringe, so the flat end cap is
/// double-covered. Measured on the outline: the arm's ink in its butt column lies entirely within the
/// main limb's, and the arm's ink ABOVE the main limb's top edge — the "wrong side", the whole of
/// defect B — is 0 pixels. The arm can only ever emerge from the limb's UNDERSIDE, which is where a
/// fork arm that is falling away should emerge.
///
/// 160 degrees, not 166 and not 150, and the two failures either side of it are worth recording.
/// At 150 the arm dropped away steeply and the pair rendered as a symmetric tent — two limbs of
/// similar weight meeting at a sharp peak with the nest balanced on top, which trades "on the end of
/// a branch" for "on the top of a roof" and is no more stable. At 166 it ran so nearly level that it
/// stopped reading as a second limb and became one bent stick crossing the whole lower left, which
/// is the "plank across a landscape" this asset has been rejected for once already. 160 leaves the
/// two limbs at an included angle of 134 degrees, and the asymmetry that stops it reading as a tent
/// is carried by WEIGHT rather than angle: 52px against the main limb's 102.
///
/// len 675, not 300, and that is a THICKNESS control, not a length one: `baseHalf` is 0.0255 * len
/// clamped at 9, so past 353 units a twig gets relatively THINNER — which is the only way to have a
/// long arm that is not also a fat one. 675 at scale 5.25 is 1950px long and 52px thick, half the
/// main limb, which is what a second arm of a fork should be. At len 300 the same length would have
/// come out 99px thick, as wide as the main limb and far too wide for its butt to fit inside it.
///
/// The 1950px is not the visible run either: the arm crosses the bottom edge at x 642 and its needle
/// tip lands 95px below the canvas. That margin is sized against the sway — the rigid group turns up
/// to 0.92 degrees about a pivot 4000 local units away, which walks this tip 36px, and at the 1800px
/// length tried first it cleared the edge by only 45px and would have flicked a taper on screen
/// twice a loop.
///
/// RE-CUT AGAINST THE TRUNK. Everything above stays true about what this arm is FOR; three things
/// about it were wrong, and all three are measured off the render rather than argued.
///
///   IT WAS 52px THICK. Under a nest 327px tall that is 1:6, and it is why "a fork of two thin
///   arms is a springy V" was the right diagnosis. `baseHalf` clamps at 9, so thickness is 0.051 x
///   LENGTH and nothing else: 675 units at 5.25 was a deliberately thin choice. This one is 3100px
///   long against the old 1950 and — the part that actually matters — is cut at len 353 rather than
///   675, which is the exact point where `0.0255 * length` reaches the clamp. Below it the twig is
///   proportionally thinner; above it the clamp holds and it gets thinner still. 353 is the fattest
///   the generator will ever draw, and it measures 140-176px across the visible run.
///
///   ITS TOP EDGE MISSED THE NEST. At x 2100 the old arm's top edge was world y 1140 against a nest
///   whose underside there is 1030 — 110px of daylight under the nest's left third, in the
///   guaranteed view. This one runs 1050 at x 2100 and 1043 at 2160 against 1030 and 1082, so it
///   makes contact from x ~2090 rightward instead of x ~2280. What is left is a ~60px void under
///   the outermost 60px of fringe, where the nest's own silhouette turns up to 982 and there are
///   19 pixels of ink in the column; wood there would be wood in front of nothing.
///
///   ITS BUTT WAS IN OPEN AIR UNDER THE NEST. The old butt sat inside the main limb, which made a
///   joint but not a support — two sticks meeting is still two sticks. This butt is at world
///   (2687, 1050), which is inside the TRUNK's silhouette (2600..2775 in that row) AND behind the
///   nest's ink, so the arm can only be read as a limb leaving the trunk. The crotch is at x 2687,
///   55px inside the safe box's right edge, and the safe box's floor is 1152.
///
/// seed 0xb108 out of a swept set, chosen on its own top-edge profile: it is the one that descends
/// fast enough to the left to drop under the safe box's floor by x 1500 instead of running level
/// along it, which is what turns "a plank across the landscape" back into a limb going somewhere.
const BOUGH2 = {at: {x: 2594.6, y: 1141.7}, rot: 172.77, scale: 11.53, len: 480};
const BOUGH2_GEOM = buildTwig({
  seed: 0xb313,
  length: BOUGH2.len,
  arch: 'bare',
  sweep: 'stiff',
  weight: 'stick',
  // 'needle' for the same reason the main bough uses it: a wedge taper loses half its thickness in
  // the first third, and the part of this limb the viewer sees is all past that point.
  tip: 'needle',
  maxDepth: 0,
  lightLocalDeg: LIGHT_WORLD_DEG - BOUGH2.rot,
  allowHighlight: false,
});
const BOUGH2_XF = `translate(${BOUGH2.at.x} ${BOUGH2.at.y}) rotate(${BOUGH2.rot}) scale(${BOUGH2.scale})`;

/// The bough's REAL top edge, by column, read off its own outline.
///
/// `buildTwig` emits polylines and nothing else — "M x y L x y … Z", straight segments, no
/// control points, by design ("a woodcut silhouette") — so every number in `body` is a point ON
/// the silhouette and its upper envelope is exact rather than fitted. Segments are walked and
/// rasterised across columns, not just their vertices, because the outline is sampled at joints
/// and the envelope between two joints is a line, not a point.
///
/// This replaces four hand-measured constants — a height, a slope and two floors — that between
/// them cut the nest's underside along a dead-straight horizontal ruler with bare paper beneath
/// it, in the guaranteed view, twice. The generator's undulation term rides on this edge, so the
/// seat now wobbles by ±7px on screen and there is no straight line anywhere in the contact.
const envelopeTop = (d: string, at: {x: number; y: number}, rotDeg: number, scale: number) => {
  const a = rotDeg * D2R;
  const ca = Math.cos(a) * scale;
  const sa = Math.sin(a) * scale;
  const px = (x: number, y: number) => at.x + ca * x - sa * y;
  const py = (x: number, y: number) => at.y + sa * x + ca * y;
  const cols = 384;
  const x0 = 1000;
  const x1 = 5400;
  const step = (x1 - x0) / cols;
  const top = new Array<number>(cols).fill(Infinity);
  const put = (x: number, y: number) => {
    const c = Math.floor((x - x0) / step);
    if (c < 0 || c >= cols) return;
    if (y < top[c]) top[c] = y;
  };
  for (const sub of d.split('M').slice(1)) {
    const nums = sub.match(/-?\d+(?:\.\d+)?/g);
    if (!nums || nums.length < 4) continue;
    const xs: number[] = [];
    const ys: number[] = [];
    for (let i = 0; i + 1 < nums.length; i += 2) {
      const lx = Number(nums[i]);
      const ly = Number(nums[i + 1]);
      xs.push(px(lx, ly));
      ys.push(py(lx, ly));
    }
    for (let i = 0; i < xs.length; i++) {
      const j = (i + 1) % xs.length;
      const n = Math.max(1, Math.ceil((Math.abs(xs[j] - xs[i]) / step) * 2));
      for (let k = 0; k <= n; k++) put(lerp(xs[i], xs[j], k / n), lerp(ys[i], ys[j], k / n));
    }
  }
  return (x: number) => {
    const c = Math.floor((x - x0) / step);
    if (c < 0 || c >= cols) return Infinity;
    return top[c];
  };
};
const boughTopAt = envelopeTop(BOUGH_GEOM.body, BOUGH.at, BOUGH.rot, BOUGH.scale);
const bough2TopAt = envelopeTop(BOUGH2_GEOM.body, BOUGH2.at, BOUGH2.rot, BOUGH2.scale);
/// The top of whatever wood is under a given column, main limb or far arm. Used for anything that
/// has to SIT ON the wood — the lashings — because after the crook went in, the wood under the
/// nest's left half is the far arm and not the main limb, and a lashing anchored to the main limb
/// alone floated in the paper there.
/// The TRUNK is deliberately NOT in here. It is a near-vertical column, so its "top edge by
/// column" is its needle tip 4000 local units above the nest — anchoring a lashing to that would
/// launch it into the sky. Nothing sits on the trunk; things sit on the two limbs.
const woodTopAt = (x: number) => Math.min(boughTopAt(x), bough2TopAt(x));

/// THE SEAT — an upper bound on where nest wood may be built. Two terms, and both are answering
/// a rejection.
///
/// It reads `boughTopAt` and NOT `woodTopAt`, and that is deliberate: the far arm falls away from
/// the crotch, so at local x 2035 its top edge is local 1364, and 1364 + 55 would license nest wood
/// down to screen y 1197 — 45px past the safe box's floor. The anti-float clause only makes sense
/// against wood the nest is actually sitting ON, which is the main limb.
///
/// `boughTopAt(x) + 55` is the anti-float clause: wherever the bough passes under the nest the
/// nest is REQUIRED to reach 55 local units past its top edge, so there can never be a seam of
/// bare paper between them, and since the near wall and near rim are drawn AFTER the bough the
/// weave visibly drapes over the bark. That plus the four lashings crossing in front is what
/// makes it one object instead of a bowl resting on a tube.
///
/// The wobbled 1193 line is the crop guard, and only that. Left to its own silhouette the nest's
/// ink reaches local 1294, which is screen 1178 — 26px into the bleed. Trimmed here it lands at
/// screen 1140-1154, and because the trim only ever bites where the bough is already lower it
/// never shows: the columns it touches are the ones the bough is behind.
const seatTrim = (x: number) => 1193 + 18 * Math.sin(x * 0.031) + 11 * Math.sin(x * 0.073 + 1.4);
const seatTop = (x: number) => {
  const b = boughTopAt(x);
  return isFinite(b) ? Math.max(seatTrim(x), b + 55) : seatTrim(x);
};

/// The projected outline of the whole torus, scanned by columns rather than guessed — the
/// outline of a projected torus is not an ellipse. Used twice: once for the under-shape that
/// turns the back band from a row of separate sticks into a mass, and once as the test that
/// rejects strands landing outside the silhouette as detached debris.
const SCAN = (() => {
  const cols = 128;
  const x0 = CX - (R + T);
  const x1 = CX + (R + T);
  const top = new Array<number>(cols).fill(Infinity);
  const bot = new Array<number>(cols).fill(-Infinity);
  for (let i = 0; i <= 480; i++) {
    const phi = (i / 480) * TAU;
    for (let j = 0; j <= 120; j++) {
      const psi = (j / 120) * TAU;
      const p = proj(phi, psi);
      const c = clamp(Math.floor(((p.x - x0) / (x1 - x0)) * cols), 0, cols - 1);
      if (p.y < top[c]) top[c] = p.y;
      if (p.y > bot[c]) bot[c] = p.y;
    }
  }
  return {cols, x0, x1, top, bot, xOf: (c: number) => x0 + ((c + 0.5) / cols) * (x1 - x0)};
})();

const colOf = (x: number) =>
  clamp(Math.floor(((x - SCAN.x0) / (SCAN.x1 - SCAN.x0)) * SCAN.cols), 0, SCAN.cols - 1);
/// How far outside the scanned silhouette a point falls, in px. Negative inside.
const outsideBy = (x: number, y: number) => {
  const c = colOf(x);
  if (!isFinite(SCAN.top[c])) return 1e4;
  return Math.max(SCAN.top[c] - y, y - SCAN.bot[c]);
};

const bodyPath = (insetTop: number, insetBot: number, insetX: number): string => {
  // A smooth outline blurred 13px was the old "halo": a Gaussian tail on a large dark shape
  // against cream paper is visible for three sigma in every direction and read as smoke. The
  // blur is 4px now and the edge is broken by a deterministic wobble, so where it does peek
  // between strands it reads as packed material rather than as a cut shape.
  const wob = (c: number, seed: number) =>
    13 * Math.sin(c * 0.62 + seed) + 8 * Math.sin(c * 1.41 + seed * 2.3) + 5 * Math.sin(c * 2.9 + seed);
  const keep: number[] = [];
  for (let c = 0; c < SCAN.cols; c++) {
    if (!isFinite(SCAN.top[c])) continue;
    if (SCAN.bot[c] - SCAN.top[c] < insetTop + insetBot + 10) continue;
    const x = SCAN.xOf(c);
    if (x < SCAN.x0 + insetX || x > SCAN.x1 - insetX) continue;
    keep.push(c);
  }
  if (keep.length < 4) return '';
  const up = keep.map((c) => `${f1(SCAN.xOf(c))} ${f1(SCAN.top[c] + insetTop + wob(c, 1.7))}`);
  const down = keep
    .slice()
    .reverse()
    .map((c) => `${f1(SCAN.xOf(c))} ${f1(SCAN.bot[c] - insetBot + wob(c, 4.1))}`);
  return `M ${up.join(' L ')} L ${down.join(' L ')} Z`;
};

/// The cup: the rim ring's own projected ellipse, wobbled off true and softened. Drawn as a
/// plain ellipse its boundary was a clean 900px arc, and on the right flank — where fewer
/// strands cross it — the join between the lit rim and the dark hollow read as a drawn line.
/// The outer extent is R-6 rather than R-16 so the cup fully covers the under-shape inside the
/// rim; that 10px overlap gap was showing as a pale smear on the near rim's inner face.
const cupPath = (): string => {
  const pts: string[] = [];
  const cy = CY - VY * T;
  const rx = R - 6;
  // ry -22 and not -8, and the blur below is 6 and not 10. At the smaller scene scale the far rim's
  // own strands are thinner on screen, so the blurred cup edge was showing ABOVE them at the nest's
  // upper right as a soft dark patch with no wood in it — out-of-focus murk rather than a hollow.
  // Pulling the cup's far edge 14 units down puts it back behind the rim that is meant to hide it.
  const ry = KD * R - 22;
  for (let i = 0; i < 108; i++) {
    const a = (i / 108) * TAU;
    const w =
      1 + 0.05 * Math.sin(a * 3.3 + 1.1) + 0.034 * Math.sin(a * 5.7 + 0.4) + 0.02 * Math.sin(a * 8.1);
    pts.push(`${f1(CX + rx * w * Math.cos(a))} ${f1(cy + ry * w * Math.sin(a))}`);
  }
  return `M ${pts.join(' L ')} Z`;
};

const HOLLOW = {cy: CY - VY * T, ry: KD * R - 8};

/* ------------------------------------------------------------------ the nest set */

/// Blunt only. An earlier deal ran 8 spear / 3 needle / 9 wedge and the left and lower-left
/// silhouette grew barbs, thorns and what the human called "literally little bird feet". Zero
/// needles, four spears, sixteen wedges: softness was the standing note and this goes that way
/// deliberately, at the cost of some silhouette incident.
const TIP_BAG: TipStyle[] = [
  ...(Array(16).fill('wedge') as TipStyle[]),
  ...(Array(4).fill('spear') as TipStyle[]),
];
/// No `hooked` either — a hook on a 150px rod is a claw. Three bowed to one stiff.
const NEST_SWEEP_BAG: Sweep[] = [
  ...(Array(3).fill('bowed') as Sweep[]),
  ...(Array(1).fill('stiff') as Sweep[]),
];
const WEIGHT_BAG: Weight[] = [
  ...(Array(6).fill('wisp') as Weight[]),
  ...(Array(8).fill('ordinary') as Weight[]),
  ...(Array(6).fill('stick') as Weight[]),
];

/// How many strands. Measured as bbox fill / widest bare-paper run along a scanline through the
/// wall: 42 (the old nest) 8.7% / 907px; 190 was a woven ring on a smooth dark blob; 340 wove
/// but banded; 430 -> 66.8% / 34px; 470 -> 63.6% / 57px; 520 -> 63.4% / 50px. It saturates
/// between 430 and 470 — past that the new strands land on strands.
const COUNT = 470;
/// The armature: a handful of long thick sticks in shadow tones that the finer material packs
/// around. Without them 470 equal strands read as shredded wheat; a nest has a hierarchy.
const SPARS = 16;
const SEED = 0x4e6f;

type Band = 'rim' | 'wall' | 'cup';
type Fam = 'ring' | 'wrap' | 'radial' | 'free';

type Strand = {
  i: number;
  geom: TwigGeometry;
  grad: string;
  transform: string;
  layer: 0 | 1 | 2;
  bucket: number;
  D: number;
  /// World endpoints, kept so the audit can assert on the same numbers the builder rejected on.
  ends: [number, number, number, number];
};

const buildNest = (count: number, seed: number): Strand[] => {
  const r = rngOf(seed);
  const decks = [0, 1, 2].map(() => ({
    arch: dealer(ARCH_BAG, r),
    sweep: dealer(NEST_SWEEP_BAG, r),
    tip: dealer(TIP_BAG, r),
    weight: dealer(WEIGHT_BAG, r),
  }));
  const prevLuma: (number | null)[] = [null, null, null];
  const out: Strand[] = [];
  let palest = 0;
  const palestCap = Math.round(count * 0.09);
  let guard = 0;

  while (out.length < count && guard < count * 200) {
    guard++;

    const spar = out.length < SPARS;

    // ---- where on the surface ------------------------------------------------
    // Three bands by tube angle, weighted by VISIBLE AREA. An earlier pass gave the rim 40% and
    // the rim is only about a third of the visible surface, so the rim packed solid while the
    // outer wall stayed muddy.
    const u = r();
    const band: Band = spar ? (r() < 0.5 ? 'rim' : 'wall') : u < 0.36 ? 'rim' : u < 0.78 ? 'wall' : 'cup';
    const psiDeg =
      band === 'rim' ? uni(r, 50, 132) : band === 'wall' ? uni(r, -72, 50) : uni(r, 132, 248);
    const near = band === 'wall' ? true : band === 'cup' ? false : r() < 0.55;
    // Uniform in screen x, not in phi: uniform phi piles every strand up at the two ends where
    // dx/dphi goes to zero. Spars stay off the ends, where the ring tangent is vertical and a
    // 340px spar hangs off the nest as a lone dark post.
    const xn = spar ? uni(r, -0.86, 0.86) : uni(r, -0.995, 0.995);
    const phi = near ? Math.acos(xn) : -Math.acos(xn);
    const psi = psiDeg * D2R;

    // Outward tube normal, and the facing test against the view vector (0, cos a, sin a).
    const nx = Math.cos(psi) * Math.cos(phi);
    const nd = Math.cos(psi) * Math.sin(phi);
    const ny = Math.sin(psi);
    if (nd * VY + ny * KD < 0.07) continue; // back of the nest: nobody sees it

    const p = proj(phi, psi);
    const dn = clamp((p.D + (R + T)) / (2 * (R + T)), 0, 1);
    const layer: 0 | 1 | 2 = dn < 0.34 ? 0 : dn < 0.66 ? 1 : 2;

    // ---- which direction it runs --------------------------------------------
    // Measured mix over the finished set: 38.1% ring, 24.7% wrap, 8.9% radial, 28.4% free. The
    // free quarter is not laziness — fully combing them looked artificial and the human said so.
    const f = spar ? 0 : r();
    const fam: Fam =
      band === 'rim'
        ? f < 0.46
          ? 'ring'
          : f < 0.66
            ? 'wrap'
            : f < 0.72
              ? 'radial'
              : 'free'
        : band === 'wall'
          ? f < 0.3
            ? 'ring'
            : f < 0.58
              ? 'wrap'
              : f < 0.72
                ? 'radial'
                : 'free'
          : f < 0.42
            ? 'ring'
            : f < 0.7
              ? 'wrap'
              : f < 0.74
                ? 'radial'
                : 'free';

    const aRing = angOf(dPhi(phi, psi));
    const aWrap = angOf(dPsi(phi, psi));
    const aRadial = angOf({x: Math.cos(phi), y: KD * Math.sin(phi)});
    const rotateDeg =
      fam === 'ring'
        ? aRing + uni(r, -11, 11)
        : fam === 'wrap'
          ? aWrap + uni(r, -13, 13)
          : fam === 'radial'
            ? aRadial + uni(r, -16, 16)
            : uni(r, -180, 180);

    // ---- how long -----------------------------------------------------------
    // These were 120-210 / 96-185 / 70-140, chosen together with a thickness that put the mass at
    // 6-16:1 length-to-thickness, on the theory that 18:1 "read as straw rather than as wood".
    // That optimised the wrong thing, and the result was 470 small BRANCHES: a branch shrunk is
    // still shaped like a branch, and the nest read as wood chips packed into a bowl. Real nest
    // strands run 40-150:1. Lengthened 1.9x and thinned to ~32-45:1 (see `stoutBand`), rendered
    // and compared at 1:1 and at 600px wide, which is nearer the size the store actually shows.
    // Longer AND thinner together, because a fine strand still has to be long enough to wrap the
    // ring and cross its neighbours — thinning alone gave chopped fibre.
    const span = spar
      ? uni(r, 250, 340)
      : band === 'rim'
        ? uni(r, 228, 399)
        : band === 'wall'
          ? uni(r, 182, 352)
          : uni(r, 133, 266);
    // radial 0.34, not 0.62. The radial family is the loose end poking OUT of the mass, and when the
    // band spans were lengthened 1.9x to fix the strands' branch-like proportions these got longer
    // too — so the loose ends nearly doubled and became the spikes strewn under the nest and lying
    // across the bough. Their absolute length is back where it was; the ring and wrap families keep
    // the extra, because that length is what makes them wrap and cross.
    const famScale = fam === 'ring' ? 1 : fam === 'wrap' ? 0.78 : fam === 'radial' ? 0.34 : 0.8;
    // Bimodal: one length band gave 470 strands of the same size and the mass read as shredded
    // wheat. A quarter of them are long sticks that arc right across the weave.
    const longOne = !spar && r() < 0.26 ? 1.28 : 1;
    // At the two ends of the ring a long strand leaves the mass entirely and lands on bare paper
    // as a single detached twig. The ends carry fringe, and fringe is short.
    const endCap = Math.abs(xn) > 0.9 ? 200 : Math.abs(xn) > 0.8 ? 280 : 430;
    const length = clamp(span * famScale * longOne, 56, endCap);

    // The radial family is the loose end poking out of the mass, so it is anchored near its butt
    // and spends its length outwards; everything else is centred on its site. A near-side `wrap`
    // at the rim runs straight up on screen, so centred it would put half its length INSIDE the
    // cup — 470 of those filled the hollow in and the bowl read went with it. Anchored at 0.82 it
    // climbs over the rim and shows only its last fifth, which is what a looped strand shows.
    const overRim = fam === 'wrap' && near && psiDeg > 68;
    const frac = fam === 'radial' ? 0.16 : overRim ? 0.82 : 0.5;
    const rad = rotateDeg * D2R;
    // The rim band gets three times the vertical jitter of the rest: at +-12 every rim strand
    // landed on the same line and the near rim rendered as one clean pale belt across the middle
    // of the nest — a wicker basket band, visible from across the room.
    const jy = band === 'rim' ? 34 : 14;
    const x = p.x - Math.cos(rad) * length * frac + uni(r, -18, 18);
    const y = p.y - Math.sin(rad) * length * frac + uni(r, -jy, jy);
    const ex = x + Math.cos(rad) * length;
    const ey = y + Math.sin(rad) * length;

    // ---- what does not get built -------------------------------------------
    // The sky above the nest is the BIRD'S, and it is 265px deep on screen: the bird's flare
    // altitude puts its belly at y 719 and its wing tip at 544, and the nest's ink may not climb
    // into that. 645 local is screen 800 for a strand endpoint and about screen 785 once a bowed
    // strand's own bulge and thickness are counted — 34px under the lowest point of the bird.
    // Fine fringe reaching the top of that band is what stops the far rim reading as a smooth
    // dome; a 300px post standing up into the flight lane is a different thing.
    const topY = Math.min(y, ey);
    if (topY < 645) continue;
    if (topY < 690 && length > 260) continue;
    // SEAT: nothing below the bough's top edge. Cheaper than drawing it and hiding it, and it
    // returns about a tenth of the strand budget to the bands that are actually visible. Each
    // endpoint is tested at ITS OWN x — testing both against the seat under the rightmost end let
    // five strands through, because the seat descends to the right.
    if (y > seatTop(x) + 26 || ey > seatTop(ex) + 26) continue;
    // OUTLINE: an endpoint well outside the projected silhouette is a detached splinter floating
    // on the paper, which is the single most-reported defect in the old art. Relaxed at the two
    // ends, where protruding fringe is correct.
    const slack = Math.abs(xn) > 0.9 ? 46 : 34;
    if (outsideBy(x, y) > slack || outsideBy(ex, ey) > slack) continue;
    // BOUNDS: a hard box, so no strand can reach the wordmark or the frame's right edge.
    if (x < 1470 || x > 2810 || ex < 1470 || ex > 2810) continue;

    // ---- what tone ----------------------------------------------------------
    const shade = nx * LIGHT.x + nd * LIGHT.d + ny * LIGHT.y;
    // Inside the cup the sky is mostly blocked. Without this the far inner wall comes out
    // LIGHTER than the outer wall, because its normal points up and at the viewer.
    const ao = psiDeg <= 95 ? 1 : clamp(1 - ((psiDeg - 95) / 105) * 0.68, 0.32, 1);
    // Blotch: a smooth deterministic field over the surface, standing in for the self-shadowing a
    // woven mass does to itself. Without it the tone is a pure function of the normal, so the rim
    // comes out as one clean lit ring and the wall as one clean darker one — two tidy bands. Real
    // wood packed into a bowl is patchy, and this is the cheapest thing that makes the mass read
    // as woven rather than as a lit torus. It is a function of (phi, psi) only, so translating
    // the nest cannot move its phase.
    const blotch =
      0.17 * Math.sin(phi * 3.1 + psi * 2.3) +
      0.12 * Math.sin(phi * 5.7 - psi * 1.4) +
      0.09 * Math.sin(psi * 4.1 + 2);
    const lit = clamp(((shade + 1) / 2) * ao + blotch, 0, 1);
    // Compressed towards the middle of the ramp and jittered nearly a whole rung. The raw score
    // gave two tones — a near-black mass with pale straw on it — because the lit near wall all
    // landed on rung 6/7 and everything else on 0-2. A woven mass needs a LADDER: rungs 2-6 all
    // present, side by side.
    const score = 0.07 + 0.76 * (0.72 * lit + 0.28 * dn);
    let k = Math.round(clamp(score, 0, 1) * 7 + uni(r, -1, 1));
    // Dark salt: about a fifth of the strands are simply darker wood than their neighbours,
    // whichever way they face. Deriving every tone from the shading made the whole front of the
    // nest rungs 4-6, a wall of straw.
    if (!spar && r() < 0.22) k -= 2;
    k = clamp(k, 0, 7);
    if (spar) k = clamp(k - 2, 0, 5);
    // The cup has to stay DARK or the thing stops being a container.
    if (band === 'cup') k = clamp(k - 1, 1, 3);
    // Rung 0 (luma 35) is only used behind other wood: it is part of why the voids between chips
    // read as holes punched in the paper rather than as shadow.
    else k = Math.max(1, k);
    // The palest rung belongs to the lit near rim and nowhere else, and to less than a tenth of
    // the set. Spraying it around is what made the old nest look bleached and detached.
    if (k >= 7 && !(near && psiDeg > 64 && psiDeg < 116)) k = 6;
    if (k >= 7) {
      if (palest >= palestCap) k = 6;
      else palest++;
    }
    const pl = prevLuma[layer];
    if (pl !== null && Math.abs(LUMA[k] - pl) < 14) {
      const dir = LUMA[k] >= pl ? 1 : -1;
      for (let s = 0; s < 2 && Math.abs(LUMA[k] - pl) < 14; s++) k = clamp(k + dir, 0, 7);
    }
    prevLuma[layer] = LUMA[k];

    // ---- build it -----------------------------------------------------------
    const deck = decks[layer];
    const archDealt = deck.arch();
    // A short strand with one shallow shoot plus one armature elbow is a chevron, and twenty
    // chevrons read as a flock of gulls. The old threshold was 115px, and forked shoots on
    // anything under ~200px are exactly the thorns and the bird feet — so below 200, and
    // anywhere in the cup, the strand is a plain rod.
    const arch: Arch = spar ? 'single' : length < 200 || band === 'cup' ? 'bare' : archDealt;
    const sweep: Sweep = spar ? 'bowed' : deck.sweep();
    // The sixteen spars keep their thickness — they ARE the hierarchy, and they are the only
    // strands that have to be legible individually at store display size. The mass was as thick as
    // the spars, which collapsed that hierarchy into one uniform gauge; worse, at 2.15-2.5 the
    // generator's 9px `baseHalf` ceiling was binding, so every strand over ~240px came out at the
    // same flat 18px and the set lost its variation in gauge as well. Thinning the mass to
    // ~32-45:1 also lets the fine material do what fine material is for: it stops being 470
    // readable sticks and becomes a texture, which is what survives downscaling. Checked at 600px
    // wide — the thin strands merge rather than disappear, which was the fear that drove them thick.
    const stoutBand = spar ? 2.5 : band === 'cup' ? 0.89 : band === 'wall' ? 0.86 : 0.82;

    const geom = buildTwig({
      seed: (seed ^ (out.length * 0x9e3779b1) ^ (guard * 0x85ebca6b)) >>> 0,
      length,
      arch,
      sweep,
      tip: deck.tip(),
      weight: spar ? 'stick' : deck.weight(),
      maxDepth: band === 'cup' ? 0 : 1,
      lightLocalDeg: LIGHT_WORLD_DEG - rotateDeg,
      // The generator's own tapered highlight ribbon would double up with the cross-thickness
      // gradient, and its hard inner boundary is the chamfered-edge signature at large scale.
      allowHighlight: false,
      stout: stoutBand * uni(r, 0.92, 1.1),
    });

    out.push({
      i: out.length,
      geom,
      grad: gradId(k, litUpAt(rotateDeg), bucketOfHalf(geom.baseHalf)),
      transform: `translate(${f1(x)} ${f1(y)}) rotate(${f1(rotateDeg)})`,
      layer,
      bucket: out.length % 6,
      D: p.D,
      ends: [x, y, ex, ey],
    });
  }

  // Painter's order: far first. Layer is derived from the same depth, so grouping by layer below
  // does not fight it.
  return out.sort((a, b) => a.D - b.D);
};

const STRANDS = buildNest(COUNT, SEED);
/// insetBot 100 and insetX 130, not 50 and 76. At the smaller insets the under-shape's own edge
/// showed OUTSIDE the strands — a soft scalloped grey fringe hanging below the nest's underside and
/// a soft vertical step in the paper at its left end, both of which read as smudges rather than as
/// wood. Its whole job is to fill the gaps BETWEEN strands, so it has no business reaching the
/// silhouette.
const BODY_PATH = bodyPath(58, 100, 130);
const CUP_PATH = cupPath();

/// Grouped by layer, then by sway bucket. Six transforms a frame instead of 470.
const LAYERS = (() => {
  const byLayer: Strand[][] = [[], [], []];
  for (const s of STRANDS) byLayer[s.layer].push(s);
  return byLayer.map((list) => {
    const groups = new Map<number, Strand[]>();
    for (const s of list) {
      const g = groups.get(s.bucket) ?? [];
      g.push(s);
      groups.set(s.bucket, g);
    }
    return Array.from(groups.entries()).sort((a, b) => a[0] - b[0]);
  });
})();

/* ------------------------------------------------------------------ bough furniture */

/// BARK. The diagonal read as a polished leather strap: one smooth cross-thickness ramp with one
/// soft highlight and no grain at all, materially unrelated to the straw sitting on it. Grain is
/// four long thin rods laid ALONG the limb and clipped to its own silhouette, so they can only
/// ever be marks on the wood and never a stick beside it. Stated as a fraction of the bough's
/// length and an offset across its thickness, in the bough's OWN local frame, so they follow it
/// if it ever moves again.
/// `s` is measured from the BUTT, and the first version of this had all four rods at s 0.12-0.60 —
/// which is 12% to 60% of the way up a limb whose butt is off the bottom-right corner, so every one
/// of them sat right of screen x 2852, outside the safe box and outside the part of the bough anyone
/// looks at. They live at 0.66-0.95 now: the run from just past the frame's edge to the tip, which
/// is the whole of the visible limb.
const GRAIN = [
  {seed: 0x5a1, s: 0.66, off: -4.6, len: 150, rot: 1.6, rung: 4, op: 0.5},
  {seed: 0x5b2, s: 0.74, off: 1.6, len: 130, rot: -1.2, rung: 0, op: 0.45},
  {seed: 0x5c3, s: 0.82, off: 4.4, len: 100, rot: 2.4, rung: 0, op: 0.4},
  {seed: 0x5d4, s: 0.88, off: -2.4, len: 78, rot: -2.0, rung: 3, op: 0.45},
  {seed: 0x5e5, s: 0.93, off: 2.2, len: 52, rot: 1.1, rung: 5, op: 0.34},
] as const;

/// Fine twigs off the bough, built at FINAL size so their taper is real. A quarter-size shoot
/// stretched 4x has its taper curve stretched into a straight line, which is how an older perch's
/// one side shoot became a 255x180px solid triangle. All three sit right of screen x 2900, i.e.
/// well outside the safe box: a sprig is bleed interest, and the one that used to stand near the
/// box's edge was a flat near-black three-pronged claw in open paper.
///
/// `y` is `boughTopAt(x) + 60` rather than a typed number, so the butts are inside the wood by
/// construction and the bough can be re-placed without them coming loose.
const SPRIGS = [
  {seed: 0x711, x: 3300, rot: 202, len: 260, scale: 1.35},
  {seed: 0xc19, x: 4100, rot: 176, len: 220, scale: 1.2},
] as const;

/// Strands lashed ACROSS the bough, drawn in front of it. This is the mark that says "built
/// around" rather than "resting on", and it is now INSIDE the guaranteed view: the first two land
/// at screen (2299, 1112) and (2385, 1138), against a safe bottom of 1152. They are 190-240 local
/// units. At 190-240 with their butts 45 units under the bark's top edge they showed as four small
/// dark forked marks SITTING ON the limb — barbs, not lashings. At 280-370 with their butts 130
/// units down, they start inside the wood, cross the whole thickness of it and finish up inside the
/// weave, which is the difference between a mark on a surface and a strand tying two things
/// together. Rung 4 rather than 2 so they read as straw over dark bark rather than as more bark.
///
/// `dy` is per-lashing rather than the flat 130 it used to be, because the limb is not one
/// thickness. Measured in local units on the current outline, the main limb runs 100 units thick at
/// x 2010 and 162 at x 2520, so a flat 130 started the two left-hand butts 5-30 units BELOW the
/// bark — outside the wood, which is the one thing a lashing must not be. Each `dy` is inside its
/// own column's thickness with room to spare.
///
/// 0xee5 at x 2090 is the CROTCH TIE and it is the only one placed at a feature rather than on a
/// rhythm: it crosses the notch where the far arm leaves the main limb. That notch is a hard corner
/// between two straight silhouette edges — correct for a fork seen from below, but the only place in
/// the picture where two generated outlines meet at an angle nothing softens. A strand of the nest's
/// own material laid across it is both the cheapest fix and the true one, since a nest built in a
/// crook is exactly a thing that binds the crook.
const LASHINGS = [
  {seed: 0xaa1, x: 2010, rot: -66, len: 300, dy: 95},
  {seed: 0xee5, x: 2090, rot: -74, len: 340, dy: 100},
  {seed: 0xbb2, x: 2180, rot: -60, len: 370, dy: 130},
  {seed: 0xcc3, x: 2340, rot: -68, len: 330, dy: 130},
  {seed: 0xdd4, x: 2520, rot: -57, len: 280, dy: 130},
] as const;

/* ------------------------------------------------------------------ shafts */

/// Air. Long lens-shaped quads down the light ray, soft across their width by gradient and
/// tapered to nothing at both ends by GEOMETRY — so there is not one blur filter among them. A
/// feGaussianBlur wide enough to soften a 3000px shaft costs a full-canvas surface a frame; a
/// twelve-point profile costs twelve numbers. An earlier hexagon showed its two long straight
/// edges and the hard corner where the taper began as a graphic stripe across the sky; a
/// cos^0.7 profile has no corner anywhere.
const shaftPath = (cx: number, cy: number, len: number, w: number) => {
  const ux = -LIGHT_WORLD.x;
  const uy = -LIGHT_WORLD.y;
  const px = -uy;
  const py = ux;
  const N = 12;
  const at = (t: number, sign: number) => {
    const s = Math.pow(Math.max(0, Math.cos(t * Math.PI)), 0.7) * sign;
    return `${(cx + ux * len * t + px * w * s).toFixed(1)} ${(cy + uy * len * t + py * w * s).toFixed(1)}`;
  };
  const up: string[] = [];
  const down: string[] = [];
  for (let i = 0; i <= N; i += 1) {
    const t = -0.5 + i / N;
    up.push(at(t, 1));
    down.push(at(t, -1));
  }
  return `M${up.join(' L')} L${down.reverse().join(' L')} Z`;
};

/// Anchors follow the sun — the whole set moved with it — and the DIRECTION is untouched because
/// it comes from LIGHT_WORLD.
const SHAFTS = [
  {cx: 2830, cy: 687, len: 3300, w: 260, op: 0.2, ph: 0.0},
  {cx: 3310, cy: 517, len: 3000, w: 150, op: 0.17, ph: 1.3},
  // Kept weak: this is the one shaft whose path crosses the subject, and a pale band over the
  // nest is a defect on it, not atmosphere around it.
  {cx: 2260, cy: 700, len: 2700, w: 320, op: 0.07, ph: 2.6},
  {cx: 3650, cy: 877, len: 2500, w: 190, op: 0.16, ph: 3.9},
  {cx: 1890, cy: 1167, len: 2200, w: 260, op: 0.1, ph: 5.2},
  {cx: 1510, cy: 807, len: 2000, w: 200, op: 0.09, ph: 2.0},
];

/* ------------------------------------------------------------------ 2x3 matrices */

/// The bird's rig has a mirror in it — it flies both ways round the circuit — and a mirror
/// reverses the sense of every local rotation. Composing real matrices instead of concatenating
/// transform strings means the sign bookkeeping happens once, here, and the carried twig's world
/// pose can be read straight back out of the composite, which is what makes the release frame
/// continuous to the pixel.
type M = readonly [number, number, number, number, number, number];
const mMul = (m: M, n: M): M => [
  m[0] * n[0] + m[2] * n[1],
  m[1] * n[0] + m[3] * n[1],
  m[0] * n[2] + m[2] * n[3],
  m[1] * n[2] + m[3] * n[3],
  m[0] * n[4] + m[2] * n[5] + m[4],
  m[1] * n[4] + m[3] * n[5] + m[5],
];
const mChain = (...ms: M[]): M => ms.reduce(mMul);
const mT = (x: number, y: number): M => [1, 0, 0, 1, x, y];
const mR = (deg: number): M => {
  const a = deg * D2R;
  return [Math.cos(a), Math.sin(a), -Math.sin(a), Math.cos(a), 0, 0];
};
const mS = (sx: number, sy: number): M => [sx, 0, 0, sy, 0, 0];
/// rotate(deg cx cy), the SVG form, as a matrix — so the falling twig can be told exactly where
/// the swaying nest has moved its landing site to.
const mRAbout = (deg: number, cx: number, cy: number): M => mChain(mT(cx, cy), mR(deg), mT(-cx, -cy));
const mStr = (m: M) => `matrix(${m.map((v) => v.toFixed(5)).join(' ')})`;
/// Only ever called where the matrix is a similarity (no bank, no mirror), which is the case at
/// the release and at the landing site.
const mDecompose = (m: M) => ({
  x: m[4],
  y: m[5],
  deg: Math.atan2(m[1], m[0]) / D2R,
  scale: Math.hypot(m[0], m[1]),
});

/* ------------------------------------------------------------------ the circuit */

/// The loop is one closed circuit flown by one bird. Position, scale, heading, roll, wing phase,
/// tail fan and the falling twig are all functions of a single loop phase u = frame/180, and
/// every one of them is periodic in u by construction rather than by fading out and waiting for
/// the seam to arrive.
///
/// THE HAND-OFF. The loop contains exactly one state change — an empty beak becomes a full one —
/// and a loop cannot show a state change, so it happens where nobody can see it: at waypoint 0,
/// off canvas at x -300, along with the 180-degree turn from the leftward high leg into the
/// rightward near leg. Occluding it behind foliage was tried three times; a mass big enough to
/// cover the bird, its twig and its downstroke wing is a dark dome over a quarter of the canvas.
/// The price is about six frames of absence, which is what a bird whipping round out of frame
/// looks like anyway.
///
/// ALTITUDE — the constraint that shaped this circuit, and it has now been re-solved twice
/// against measurements rather than against intent.
///
/// The first routing flew the near leg at y 424-545, above the word: the bird's ink was inside the
/// safe crop for 36 of 180 frames. The second dropped it to y 492-562, into the band between the
/// safe box's top edge and the nest's rim: measured on 28 rendered frames its ink was FULLY inside
/// for 11 frames, sliced flat by the crop line for 34 more, and absent for the rest — so 94% of
/// the loop delivered a still life, and the frames that did show something showed a body with its
/// raised wing cut off at the frame edge, which is worse than a clean absence.
///
/// The mistake both times was treating the sky above the nest as the lane. It is 200px deep and
/// the bird's ink box is 175px, so there is no altitude in it that clears both edges. So the nest
/// came down to 41% of the safe width instead — see SCENE — and the lane is the middle band. These
/// are the four numbers the routing is solved against, all of them MEASURED off renders:
///
///   the word's ink       x 1155..1982, y 787..962                                (ceiling)
///   the word's guard     x 1082..2053, y 717..1032   the ink grown 70px          (ceiling)
///   the nest's ink top   772 at world x 2320-2440, 893 at 2040, absent left of 2027   (floor)
///   the safe box         x 1097..2742, y 493..1152
///
/// THE LANE ROSE ~100px WHEN THE WORDMARK DID, and that is the whole reason waypoints 1-9 are not
/// where they were. The word is now anchored to the nest's crown (see WORD), so its guard rectangle
/// came up to y 717 and the bird's old flat cruise at y 700..728 was inside it. Flying UNDER the
/// word instead was measured and is not available: the guard's floor is 1032 and the bough is at
/// ~1150, and a bird squeezed into that 120px slot could not then climb over a rim whose ink starts
/// at 787.
///
/// TWO THINGS ABOUT THE SHAPE, both measured rather than guessed.
///
/// The sag was FLATTENED, not merely translated. The old leg ran 700/715/728/715 — a shallow
/// catenary whose low point sat at x 1660, dead centre of the word. Translating that shape up by 90
/// as a rigid curve reported onWORD=[62,72,73], because it is the wing on the DOWNSTROKE, ~68px
/// below the path point, that enters the rectangle, not the waypoint. The margin that remains is on
/// the audit's own line: `birdHi` maxes at 682 across the word's columns (x 1000..2000) against a
/// guard top of 716, so 34px on the PROBE points — which push the wing tip 160 local units further
/// than the rendered ink does. Measured off a render at frame 60 the real ink bottom is 640, 147px
/// clear of the word's ink. This is the tightest coupling in the file: raise the word, grow the cap,
/// or lower this leg, and onWORD goes red within 34px. The audit will catch it; expect it.
///
/// The flare came back DOWN rather than rising with the rest. Lifting waypoint 8 to 578 with its
/// neighbours put the carried twig's tip through the safe box's ceiling — frame 98's rendered ink
/// top measured 490 against a boundary at 493 — and dropped the audit's `whole` count from 84 to
/// 70. Waypoints 7 and 8 sit right of the guard's edge at x 2053, so they were free to descend.
///
/// A LOWER WORD WAS THE ALTERNATIVE AND IT WAS RENDERED. Holding the lane where it was and raising
/// the word only as far as the old routing allowed put its ink top at 873 — 61px off the floor of
/// the guaranteed crop with 423px of dead paper above it, which is the state a reviewer had already
/// called too low twice. The lane had to move or the word could not.
///
/// The audit at the bottom of this file proves every frame of that against the exact wing tip from
/// the same `wingGeom` the renderer uses, and against a wordmark rectangle grown by 70px, because an
/// earlier version's point-collision test reported zero while the tail was visibly merging with the K.
type Way = {x: number; y: number; s: number};
const CIRCUIT: Way[] = [
  // Waypoint 0 is the hand-off: it only has to be invisible on the ONE frame where the beak fills,
  // and at x -190 with the twig held up-forward the bird's rightmost ink is x -95.
  {x: -150, y: 640, s: 0.5}, // 0  OFF-CANVAS — hand-off and the 180-degree turn
  {x: 190, y: 650, s: 0.58}, // 1  back on canvas
  {x: 610, y: 632, s: 0.68}, // 2  the long descent out of the left bleed
  {x: 1170, y: 604, s: 0.78}, // 3  crossing into the safe box
  // 4-9 are the whole point of the asset and they are all inside the guaranteed view. The bird is
  // at its biggest here — 244px beak to tail — because this is the only part of the loop a browsing
  // user is certain to see. Its SIZE is not a lever for buying clearance: shrinking the bird here to
  // fit a lane was tried in an adjacent pass at s 0.74 and gives back exactly what this block was
  // written to protect.
  {x: 1340, y: 604, s: 0.82}, // 4  ABOVE the word now — ~115px of paper between its ink and the cap
  {x: 1660, y: 600, s: 0.85}, // 5  crossing the middle of the box, over the second O
  {x: 1998, y: 610, s: 0.86}, // 6  clear of the word's guard (ends x 2053) and of the nest
  // 7-8 SINK THEN FLARE, the one part of the shape that changed rather than moved. With 3-6 up at
  // ~605 the old "climb over the rim" had nothing left to climb from, so the approach now sinks 46px
  // onto the nest and pulls up 26px into the release — a bird settling onto a nest rather than
  // cresting it. Checked at frames 90 and 103 rather than argued.
  {x: 2170, y: 656, s: 0.86}, // 7  sinking onto the nest, 176px above the weave
  {x: 2260, y: 630, s: 0.85}, // 8  THE FLARE — the release is here, over the cup
  {x: 2530, y: 684, s: 0.82}, // 9  past the drop, still whole inside the box
  {x: 2740, y: 630, s: 0.74}, // 10 leaving the box to the right
  {x: 3080, y: 470, s: 0.62}, // 11 climbing out
  {x: 3430, y: 295, s: 0.48}, // 12 over the top, banking left, deep in the bleed
  {x: 2900, y: 205, s: 0.42}, // 13 high leg, right to left, 340px above the word's ink
  {x: 1950, y: 178, s: 0.39}, // 14 furthest point — smallest bird in the loop
  {x: 830, y: 330, s: 0.44}, // 15 heading for the edge
];
const FLARE_WAY = 8;

const crAt = (p0: number, p1: number, p2: number, p3: number, t: number) => {
  const t2 = t * t;
  const t3 = t2 * t;
  return (
    0.5 * (2 * p1 + (-p0 + p2) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2 + (-p0 + 3 * p1 - 3 * p2 + p3) * t3)
  );
};

const SAMPLES = 2048;

/// Closed Catmull-Rom through the waypoints, resampled to constant arclength. Arclength first,
/// speed shaping second: doing both at once is how you get a path that mysteriously races
/// through its own corners.
const buildPath = (ways: Way[]) => {
  const n = ways.length;
  const pts: Way[] = [];
  for (let i = 0; i < SAMPLES; i++) {
    const g = (i / SAMPLES) * n;
    const seg = Math.floor(g);
    const t = g - seg;
    const p = (k: number) => ways[(seg + k + n) % n];
    pts.push({
      x: crAt(p(-1).x, p(0).x, p(1).x, p(2).x, t),
      y: crAt(p(-1).y, p(0).y, p(1).y, p(2).y, t),
      s: crAt(p(-1).s, p(0).s, p(1).s, p(2).s, t),
    });
  }
  const cum: number[] = [0];
  for (let i = 1; i <= SAMPLES; i++) {
    const a = pts[i - 1];
    const b = pts[i % SAMPLES];
    cum.push(cum[i - 1] + Math.hypot(b.x - a.x, b.y - a.y));
  }
  return {pts, cum, total: cum[SAMPLES]};
};

const PATH = buildPath(CIRCUIT);

/// The arclength fraction of a (possibly fractional) waypoint index. Closed Catmull-Rom puts
/// waypoint `i` exactly at sample `i * SAMPLES / n`, so this is a lookup with a lerp — and it is
/// what lets the speed profile be anchored to PLACES ON THE PATH ("slow from just before the bird
/// enters the guaranteed view until just after it has dropped the twig") instead of to times.
const wayFrac = (i: number) => {
  const g = (i / CIRCUIT.length) * SAMPLES;
  const lo = Math.floor(g);
  const a = ((lo % SAMPLES) + SAMPLES) % SAMPLES;
  return lerp(PATH.cum[a], PATH.cum[a + 1], g - lo) / PATH.total;
};
const FLARE_FRAC = wayFrac(FLARE_WAY);

const pathAt = (frac: number) => {
  const f = frac - Math.floor(frac);
  const d = f * PATH.total;
  let lo = 0;
  let hi = SAMPLES;
  while (hi - lo > 1) {
    const mid = (lo + hi) >> 1;
    if (PATH.cum[mid] <= d) lo = mid;
    else hi = mid;
  }
  const seg = PATH.cum[lo + 1] - PATH.cum[lo];
  const t = seg > 0 ? (d - PATH.cum[lo]) / seg : 0;
  const a = PATH.pts[lo % SAMPLES];
  const b = PATH.pts[(lo + 1) % SAMPLES];
  return {x: lerp(a.x, b.x, t), y: lerp(a.y, b.y, t), s: lerp(a.s, b.s, t)};
};

const headingAt = (frac: number, span = 0.005) => {
  const a = pathAt(frac - span);
  const b = pathAt(frac + span);
  return (Math.atan2(b.y - a.y, b.x - a.x) * 180) / Math.PI;
};

/* ------------------------------------------------------------------ speed */

/// A gaussian on the circle, so every speed term is periodic and the seam cannot land inside one.
const gaussCirc = (u: number, mu: number, sd: number) => {
  let d = u - mu;
  d -= Math.round(d);
  return Math.exp(-(d * d) / (2 * sd * sd));
};

/// A flat-topped window on the circle: 1 from `a` to `b` the short way round, falling to 0 over
/// `ease` at each end by raised cosine. Periodic by construction, and flat in the middle, which a
/// gaussian is not — a plateau is what "hold this whole leg slow" actually needs.
const wrap01 = (v: number) => v - Math.floor(v);
const window01 = (s: number, a: number, b: number, ease: number) => {
  const d = wrap01(s - a);
  const len = wrap01(b - a);
  if (d > len) return 0;
  const e = Math.min(clamp01(d / ease), clamp01((len - d) / ease));
  return 0.5 - 0.5 * Math.cos(Math.PI * e);
};

/// SPEED AS A FUNCTION OF PLACE, and the reason it is not a function of time is measured. Stating
/// the stall as "u = uFlare - 0.13" needs uFlare, which depends on the stall, so it was solved by a
/// four-pass fixed point — and every time the depth of the slow-down changed, uFlare moved and the
/// slow region landed somewhere ELSE on the path. Deepening it by 15% moved the number of frames
/// with the whole bird inside the safe box DOWN from 54 to 34, which is the opposite of what the
/// edit was for. Anchored to arclength instead, the windows mean what they say and stay meaning it.
///
/// Three terms. The near leg — waypoints 2.6 to 9.6, which is the run in, the whole of the
/// guaranteed view and the drop — is held at 0.44 of the base rate, because it is the only stretch
/// a browsing user is certain to see and it should last. The flare itself takes another 0.25 off,
/// which is the brake. The return leg through the bleed runs at 2.9x: it is transit, not an event,
/// and it is not paced as one.
const SLOW_FROM = wayFrac(2.6);
const SLOW_TO = wayFrac(9.6);
const FAST_FROM = wayFrac(9.95);
const FAST_TO = wayFrac(16.35);
const speedAtFrac = (s: number) =>
  1 -
  0.52 * window01(s, SLOW_FROM, SLOW_TO, 0.045) -
  0.25 * gaussCirc(s, FLARE_FRAC, 0.014) +
  1.45 * window01(s, FAST_FROM, FAST_TO, 0.06);

const WARP_N = 2880;

/// t(s), then inverted to s(u).
///
/// Time to travel to arclength fraction s is the integral of ds / v(s), so the forward table is a
/// cumulative sum of reciprocals and the thing the renderer wants — the arclength reached at loop
/// phase u — is its inverse. Both are normalised, so s(0) = 0 and s(1) = 1 exactly and the seam is
/// closed by arithmetic rather than by easing towards it and hoping.
const WARP = (() => {
  const t: number[] = [0];
  for (let i = 0; i < WARP_N; i++) t.push(t[i] + 1 / speedAtFrac((i + 0.5) / WARP_N));
  const total = t[WARP_N];
  const tOf = t.map((v) => v / total);
  const sAt = new Array<number>(WARP_N + 1);
  let i = 0;
  for (let j = 0; j <= WARP_N; j++) {
    const target = j / WARP_N;
    while (i < WARP_N - 1 && tOf[i + 1] < target) i++;
    const seg = tOf[i + 1] - tOf[i];
    sAt[j] = (i + clamp01(seg > 0 ? (target - tOf[i]) / seg : 0)) / WARP_N;
  }
  sAt[WARP_N] = 1;
  return {tOf, sAt};
})();

/// Arclength fraction at loop phase u.
const warpAt = (u: number) => {
  const g = wrap01(u) * WARP_N;
  const i = Math.min(WARP_N - 1, Math.floor(g));
  return lerp(WARP.sAt[i], WARP.sAt[i + 1], g - i);
};
/// Loop phase at which a given arclength fraction is reached — used once, to find the release.
const timeAtFrac = (frac: number) => {
  const g = wrap01(frac) * WARP_N;
  const i = Math.min(WARP_N - 1, Math.floor(g));
  return lerp(WARP.tOf[i], WARP.tOf[i + 1], g - i);
};
const U_FLARE = timeAtFrac(FLARE_FRAC);

/* ------------------------------------------------------------------ the roll */

/// The roll, precomputed and smoothed, because a bird cannot change its roll in one frame and a
/// path corner can.
///
/// The bird's frame carries scale(s, s * roll): +1 flying right, -1 flying left, so the mirror is
/// just the far side of a roll rather than a flip in the code. Taking `roll` straight from
/// cos(heading) failed and the audit is what caught it — at the top of the climb the heading
/// swings 85 degrees between two consecutive frames, so `roll` went from +1 to -1 in one frame at
/// full height: a silhouette reversing left-for-right instantly. No amount of speed tuning fixes
/// it, because the corner is sharp in ARCLENGTH.
///
/// So cos(heading) is sampled over the whole loop and convolved with a circular gaussian four
/// frames wide. The plateaus stay at +-1 and each crossing is stretched over five or six frames,
/// during which the bird is edge-on and has almost no silhouette to reverse. Circular
/// convolution of a periodic function is still periodic, so this costs nothing at the seam.
const ROLL_N = 720;
const ROLL = (() => {
  const raw = new Array<number>(ROLL_N);
  for (let i = 0; i < ROLL_N; i++) raw[i] = Math.cos(headingAt(warpAt(i / ROLL_N)) * D2R);
  // sd 0.030 of the loop = 5.4 frames. It was 0.022 (4 frames) and the audit measured a 0.560
  // roll step on the frame the bird whips round off canvas — over the 0.5 ceiling, i.e. a
  // silhouette reversing faster than the eye reads as a roll. Widening the kernel is the only fix
  // that does not slow the seam back down.
  const sd = 0.03 * ROLL_N;
  const half = Math.ceil(sd * 3);
  const kernel: number[] = [];
  let sum = 0;
  for (let k = -half; k <= half; k++) {
    const w = Math.exp(-(k * k) / (2 * sd * sd));
    kernel.push(w);
    sum += w;
  }
  const out = new Array<number>(ROLL_N + 1);
  for (let i = 0; i < ROLL_N; i++) {
    let acc = 0;
    for (let k = -half; k <= half; k++) acc += raw[(i + k + ROLL_N * 4) % ROLL_N] * kernel[k + half];
    const v = clamp(acc / sum / 0.42, -1, 1);
    // A floor of 0.14, sign preserved: a bird rolling through vertical really does go to a line,
    // but at exactly 0 it vanishes for a frame, and the sliver left at 0.07 reads for an instant
    // like a loose twig.
    out[i] = v >= 0 ? Math.max(0.14, v) : Math.min(-0.14, v);
  }
  out[ROLL_N] = out[0];
  return out;
})();
const rollAt = (u: number) => {
  const f = u - Math.floor(u);
  const g = f * ROLL_N;
  const i = Math.min(ROLL_N - 1, Math.floor(g));
  return lerp(ROLL[i], ROLL[i + 1], g - i);
};

/* ------------------------------------------------------------------ the wing */

/// A whole number of beats per loop is the only way a wing survives a seam. The rate is modulated
/// but the modulation is a sine that returns to zero, so phase(1) = phase(0) + TAU * BEATS
/// exactly and the wing at frame 180 is the wing at frame 0.
///
/// 15 beats over 180 frames is 2.5Hz, twelve frames a beat. 26 beats (4.3Hz, true to a martin)
/// strobed: the phase advances 0.144 of a cycle per frame, so a 2.5-frame downstroke was sampled
/// twice and the beat read as a stutter. Without motion blur, 2.5Hz is the fastest a wing can
/// beat on this canvas and still be a wing.
const BEATS = 15;
const flapRaw = (u: number) => BEATS * u + 1.1 * Math.sin(TAU * (u - 0.16));

/// Downstroke 36% of the cycle, recovery 64%. That asymmetry is the difference between a wing
/// beat and a sine wave. -1 fully up, +1 fully down.
const DOWN = 0.36;
/// The release is the one frame in the loop that has to be right, so the beat is phase-locked to
/// it: this offset puts the wing at the BOTTOM of a downstroke at exactly U_REL, so the twig
/// leaves the beak on a power stroke. A constant offset cannot affect periodicity.
const U_REL = U_FLARE - 0.004;
const FLAP_PHASE0 = DOWN - (flapRaw(U_REL) - Math.floor(flapRaw(U_REL)));
const flapPhase = (u: number) => TAU * (flapRaw(u) + FLAP_PHASE0);

const wingSwing = (phase: number) => {
  const p = (phase / TAU) % 1;
  const q = p < 0 ? p + 1 : p;
  if (q < DOWN) {
    const k = q / DOWN;
    return -1 + 2 * (1 - (1 - k) * (1 - k));
  }
  const k = (q - DOWN) / (1 - DOWN);
  return 1 - 2 * (0.5 - 0.5 * Math.cos(Math.PI * k));
};

/// The floor is 0.62 and not 0.2: at low amplitude the wing sits near its mid position, which in
/// a strict side view points FORWARD and is the one pose that does not read as a wing at all. An
/// earlier version glided at amp 0.26 and the bird became a fish with a lump. Gliding is carried
/// by the beat RATE instead.
const flapAmpAt = (u: number) =>
  clamp(
    0.64 +
      0.5 * gaussCirc(u, U_FLARE + 0.02, 0.13) +
      0.3 * gaussCirc(u, U_FLARE + 0.42, 0.14) +
      0.3 * gaussCirc(u, 0.005, 0.03),
    0.62,
    1
  );

/* ------------------------------------------------------------------ the bird */

/// Local units: nose at +x, up at -y, one unit-bird 284 long beak-tip to tail-tip and 48 deep.
/// Martin proportions — a long swept hand, a shallow-forked tail, a body under three times its
/// own depth. An earlier tail was 76 units with a 30-unit fork on a 62-deep body and the whole
/// thing read as a fish: a forked tail at this size wants to be a NOTCH, not fletching.
const HEAD_PIVOT = {x: 34, y: -6};
const BEAK = {x: 132, y: -7};
const SHOULDER = {x: 16, y: -12};

/// `fan` opens the tail when the bird brakes over the nest — the one gesture that says
/// "stopping" rather than "passing through".
const birdBody = (fan: number) =>
  [
    'M 92 -6',
    'C 76 -16, 62 -20, 46 -20',
    'C 22 -26, -6 -26, -34 -22',
    'C -52 -20, -66 -18, -80 -15',
    `C -104 ${(-19 * fan).toFixed(1)}, -128 ${(-23 * fan).toFixed(1)}, -148 ${(-27 * fan).toFixed(1)}`,
    `L -132 ${(-11 * fan).toFixed(1)}`,
    `L -150 ${(2 * fan).toFixed(1)}`,
    `C -128 ${(4 * fan).toFixed(1)}, -102 ${(4 * fan).toFixed(1)}, -80 3`,
    'C -54 14, -20 19, 12 17',
    'C 40 15, 68 10, 84 3',
    'Z',
  ].join(' ');

/// Head and beak are one shape at the body's ink, pivoting at the neck, so the head can lead the
/// turn — and so the twig, parented into this group, is held at the BEAK and swings with it. The
/// beak is a 28-unit cone: in silhouette that is a bird's profile, whereas an eye at this size is
/// a cartoon.
const HEAD_PATH =
  'M 132 -7 L 104 -14 C 96 -28, 76 -34, 58 -31 C 40 -28, 28 -18, 30 -6 ' +
  'C 32 7, 46 15, 62 13 C 80 11, 98 4, 106 -1 L 132 -7 Z';

/// Canonical wing: extended, pointing up from the shoulder, 160 units long and 34 at its widest —
/// a 4.4:1 blade. An earlier sheet drew it 67 wide and it read as a slab pasted on the shoulder.
/// The leading edge pushes out to 27 and the hand sweeps BACK to a point, which is the difference
/// between a wing and a paddle.
const WING_PATH =
  'M 0 0 C 13 -32, 26 -70, 28 -106 C 29 -132, 22 -148, 10 -160 ' +
  'C 6 -140, 1 -110, -8 -78 C -15 -50, -21 -22, -21 -6 C -15 -2, -8 0, 0 0 Z';

const INK = '#3B2114'; // the wordmark's ink, so the bird must never overlap it
/// The near wing is only 15.3 luma off the body, DELIBERATELY under the 22 that twig.ts enforces
/// for adjacent strands. That rule exists so two shapes do not merge into one — but the wing beat
/// here is carried entirely by the OUTLINE (the blade leaves the body silhouette by 120 units
/// above and below), so the internal contrast has no work to do, and at 23 luma the wing read as
/// a slab of a different material pasted onto the bird. The HUE matters more than the luma: at
/// #4A3419 the blade measured olive-brown against a redder body and read as a leaf stuck on, so it
/// is #4E2C16 now — the same red-brown family as the ink, one step lighter.
const WING_NEAR = '#4E2C16';
const WING_FAR = '#2C170B';

/// The wing, projected properly — the fix for the defect that made two versions of this bird read
/// as a fish. Rotating the wing shape through the picture plane sweeps it from up, through
/// POINTING FORWARD at full length, to down, and a full-length wing lying along the flight line
/// is a football on the bird's shoulder. What a wing does in a strict side view is sweep in a
/// plane roughly across the flight line, so its span projects VERTICALLY at all times and its
/// projected LENGTH is |sin(elevation)|. So elevation is the real degree of freedom and the
/// picture-plane angle only leans the blade.
///
/// WHAT WAS WRONG WITH THAT, measured on a rendered flap cycle: the projected length was floored
/// at 0.07, so for one or two frames of every twelve-frame beat there was NO WING — the bird
/// became a smooth dark bean, and a reviewer sampling stills found frames with no wing at all and
/// concluded, correctly from what was in front of them, that this is not a bird. The old code also
/// stepped from the up branch (angle -26t) to the down branch (180 - 50t) at elevation 0, a
/// 180-degree jump justified by the length being zero there — which it no longer is.
///
/// Both are fixed by the same observation: a wing crossing the horizontal in a side view is not
/// absent, it is SWEPT BACK and foreshortened. So the floor is 0.30 of full span, and both
/// branches converge on -90 degrees — blade pointing straight back along the body — as elevation
/// goes to zero. Angle and length are now continuous through the handover, the wing is present on
/// every frame of the loop, and the pose at mid-stroke is the one a photograph shows.
const ELEV_UP = 74;
/// 38 and not 56. The downstroke's projected reach is what sets the bird's box height, and the box
/// has to fit a lane bounded above by the wordmark's guard rectangle and the safe box's top edge and
/// below by the nest's measured ink top — which at the nest's LEFT END is 858, not the 778 of its
/// centre, because the projected torus is at mid-height where it ends. At 56 degrees the box was
/// 272px deep and the audit caught the down-wing tip inside the nest's fringe; at 44 it still did on
/// five frames. At 38 the box is 196px, the wing reaches 131px above the origin and 65px below it,
/// and the climb from under the word to over the cup fits with 10-50px to spare at every frame. A
/// shallower downstroke is also what a bird flaring to a stop actually does.
const ELEV_DN = 38;
const wingGeom = (swing: number, amp: number) => {
  const elev = lerp(ELEV_UP, -ELEV_DN, (swing + 1) / 2) * amp;
  const up = elev >= 0;
  const t = up ? elev / ELEV_UP : -elev / ELEV_DN;
  const len = lerp(0.3, 1, Math.abs(Math.sin(elev * D2R)));
  // -90 back, -26 up-and-swept, -212 (i.e. 148) down-and-forward, passing through -180 (straight
  // down) at t = 0.72 on the downstroke.
  const angle = up ? lerp(-90, -26, t) : lerp(-90, -212, t);
  // The chord follows the length about halfway, which keeps the blade's aspect ratio roughly
  // constant: scaling y alone squashed the tip taper flat and blunted the point.
  return {angle, len, chord: 0.55 + 0.45 * len};
};

type BirdPose = {
  frame: M;
  swing: number;
  amp: number;
  fan: number;
  headRot: number;
  bob: number;
};

const Bird: React.FC<{pose: BirdPose}> = ({pose}) => {
  const w = wingGeom(pose.swing, pose.amp);
  return (
    <g transform={mStr(pose.frame)}>
      <g transform={`translate(0 ${pose.bob.toFixed(2)})`}>
        {/* The far wing is at the same elevation, so it projects to the same blade a few degrees
            off — it reads as the blade's thickness, which is all it should do. */}
        <g
          transform={`translate(${SHOULDER.x - 10} ${SHOULDER.y + 2}) rotate(${(w.angle + 6).toFixed(2)}) scale(${(
            w.chord * 0.88
          ).toFixed(3)} ${(w.len * 0.9).toFixed(3)})`}
        >
          <path d={WING_PATH} fill={WING_FAR} />
        </g>
        {/* A tucked foot. 24 units of hairline under the belly, and at 1:1 it is the cheapest
            mark in the piece that is unambiguously a bird rather than a dart — a reviewer
            looking at 1:1 crops listed "no leg" among the reasons this read as a swordfish. It
            disappears below about 300px of display width, which is the right way round: it is
            paid for where it is legible. */}
        <path
          d="M 14 13 L 7 30 L 22 27"
          fill="none"
          stroke={INK}
          strokeWidth={5}
          strokeLinecap="round"
          strokeLinejoin="round"
        />
        <path d={birdBody(pose.fan)} fill={INK} />
        <g
          transform={`translate(${HEAD_PIVOT.x} ${HEAD_PIVOT.y}) rotate(${pose.headRot.toFixed(2)}) translate(${-HEAD_PIVOT.x} ${-HEAD_PIVOT.y})`}
        >
          <path d={HEAD_PATH} fill={INK} />
          {/* A pale throat. On a dark bird at small size this is the single strongest species
              cue there is — it is what makes a swallow a swallow at fifty metres — and it is
              also what tells the eye which end of the silhouette is the head, which was the
              specific complaint: "no head or bill distinct from the load". Kept to a crescent
              behind the bill so the bill stays a bill. */}
          <path d="M 98 -1 C 90 9, 75 13, 62 10 C 71 2, 84 -3, 98 -1 Z" fill="#CFA76B" opacity={0.9} />
        </g>
        <g
          transform={`translate(${SHOULDER.x} ${SHOULDER.y}) rotate(${w.angle.toFixed(2)}) scale(${w.chord.toFixed(
            3
          )} ${w.len.toFixed(3)})`}
        >
          <path d={WING_PATH} fill={WING_NEAR} />
        </g>
      </g>
    </g>
  );
};

const poseAt = (u: number): BirdPose & {x: number; y: number; scale: number; heading: number; roll: number} => {
  const s = warpAt(u);
  const p = pathAt(s);
  const heading = headingAt(s);
  const roll = rollAt(u);
  const mirror = roll >= 0 ? 1 : -1;
  // The head is aimed where the body will be pointing, not where it points now. A mirrored frame
  // reverses the sense of a local rotation, hence the mirror factor.
  const headRot = mirror * clamp(angleDelta(heading, headingAt(s + 0.024)) * 0.5, -17, 17);
  const swing = wingSwing(flapPhase(u));
  const amp = flapAmpAt(u);
  // Pitch up into the flare: the brake, and the most bird-like moment in the loop.
  const pitch = -14 * gaussCirc(u, U_FLARE - 0.005, 0.04);
  const fan = 1 + 0.36 * gaussCirc(u, U_FLARE, 0.042);
  return {
    frame: mChain(mT(p.x, p.y), mR(heading), mS(p.s, p.s * roll), mR(pitch)),
    swing,
    amp,
    fan,
    headRot,
    bob: -5.5 * swing,
    x: p.x,
    y: p.y,
    scale: p.s,
    heading,
    roll,
  };
};

/* ------------------------------------------------------------------ the carried twig */

/// 225 local units, which at the bird's flare scale of 0.85 is a 191px twig against a bird whose
/// body is 244px. That ratio is the picture; a smaller twig measured as a 3px mark at store scale
/// and the drop — the event the whole asset is about — was not legible.
const TWIG_LEN = 225;
/// A bird carries a stick near its balance point, not by one end.
const GRIP = 0.42 * TWIG_LEN;
/// THE ANGLE, and it is a blocker fixed rather than a taste. At +10 degrees the twig was
/// effectively COLLINEAR with the body: it started where the body tapers and ran straight out past
/// the beak, so body and load formed one long spike and three separate reviewers independently
/// read the silhouette as a swordfish, a snipe's bill, a mosquito's proboscis and a paper dart.
/// The concept of the asset was not communicated at any scale.
///
/// A carried object has to CROSS the flight axis to read as carried. At -34 degrees, gripped at
/// 0.42 along, the twig runs up-and-forward from the beak to local (240, -80) and down-and-back to
/// (54, 46) — 32 units below the belly line, in clear air under the chin. So there is ink on both
/// sides of the body axis, the bill stays a distinct wedge between the two, and the composite
/// silhouette is a bird with a stick across its face.
const CARRY_DEG = -34;
/// The twig's rung. It was 7 (the palest wood in the frame) on the argument that it lands against
/// the dark hollow at maximum contrast — and it does, but MEASURED IN FLIGHT it was luma 161
/// against a 164 sky, i.e. invisible for the 38 frames that are the whole point of the piece.
/// No rung wins everywhere: measured, the twig has to cross a 155-165 sky, then the far rim's own
/// 80-140 wood, then land inside a 30-45 hollow. Rung 6 (137, light flank 170) is right for the two
/// moments that matter — the landing and the settled strand — and the flight is fixed the honest
/// way instead, with a hard drop shadow on the FALLING instance only. A pale object with a shadow
/// under it separates from any background; a pale object without one vanished into the sky at 161
/// against 164.
const TWIG_RUNG = 6;
/// Where the twig ends up, in the nest's local frame — and this moved, because where it was is why
/// the drop did not read. It landed ON the near rim, which is a dense field of pale strands at the
/// same rungs and the same angles as the twig itself: two reviewers tracked the fall in 1:1 crops
/// and could not pick the twig out of the mass for the last third of it, or at any scale for the
/// whole of it. A pale mark cannot arrive against pale marks.
///
/// (2192, 900) is INSIDE THE CUP — 0.34 of the hollow's own radius from its centre, in front of the
/// hollow's lower edge, well clear of the rim. The cup is the darkest thing in the frame at luma
/// 32-45 and rung 6 is 137, so the last third of the fall and the landing itself happen at the
/// highest contrast available anywhere in the picture, which is the one background this event can
/// be seen against.
const SETTLED = {x: 2192, y: 900, deg: 6};

/// The carried twig's chain, in the bird's local frame. It mirrors the SVG group nesting used for
/// the head exactly, which is what guarantees the twig sits at the beak rather than near it.
const twigLocal = (headRot: number, bob: number): M =>
  mChain(
    mT(0, bob),
    mT(HEAD_PIVOT.x, HEAD_PIVOT.y),
    mR(headRot),
    mT(-HEAD_PIVOT.x, -HEAD_PIVOT.y),
    mT(BEAK.x, BEAK.y),
    mR(CARRY_DEG),
    mT(-GRIP, 0)
  );

/// The pose the twig leaves the beak in, from the same functions that drive the bird, computed once
/// so nothing can drift. Its scale is the bird's scale at the release — and since a dropped stick
/// does not change size, that scale IS the settled strand's scale, converted into the nest's local
/// space by dividing out the camera. Matching them exactly is what makes the hand-over from
/// "falling twig" to "strand in the nest" a true no-op.
const RELEASE = mDecompose(mMul(poseAt(U_REL).frame, twigLocal(poseAt(U_REL).headRot, poseAt(U_REL).bob)));
const TWIG_SCALE = RELEASE.scale / SCENE.k;

/// 26 frames, not 38. The fall is 270px now (the release is at screen y ~660 and the cup at ~950),
/// where it used to be a 380px drop that spent its second half camouflaged; 26 frames at 30fps is
/// 0.87s, which is a stick falling rather than a leaf.
// 20, not 26. At 26 frames (0.87s) a twig covering 244px hung in the air — the eye reads a fall that
/// slow as a float, and it made the release the least believable moment in a loop that is ABOUT the
/// release.
const FALL_FRAMES = 20;
const REL_FRAME = U_REL * 180;
const LAND_FRAME = REL_FRAME + FALL_FRAMES;

/* ------------------------------------------------------------------ sway */

/// ONE rigid group carries the bough, the nest and everything lashed to it.
///
/// AMPLITUDE, and it is an encode fix as much as an art one. At 0.42 degrees about a pivot below
/// and right of the nest, the travel was 9.7px of amplitude and — this is the measurement that
/// matters — a peak speed of 0.34px per frame. Rate control cannot carry sub-pixel motion of fine
/// high-contrast texture at that rate: the delivered video held the nest's silhouette BIT-IDENTICAL
/// for runs of up to 13 frames and then caught up in a single 4-5px jump, so the only slow motion
/// in the piece arrived as a stutter. Doubled to 0.92 degrees peak, about a pivot moved almost
/// straight down (local (2600, 4200)) so the travel is 30px horizontal and only 4px vertical —
/// sideways, like a branch, and without walking the nest's underside out of the safe box. Peak
/// speed is now 1.05px per frame, over the threshold where an encoder has to encode it.
/// Two harmonics, both whole cycles over the 180 frames, so the seam is exact and the motion is not
/// a metronome.
const rigidSway = (theta: number) => 0.68 * Math.sin(theta) + 0.24 * Math.sin(2 * theta + 1.1);
const RIGID_PIVOT = {x: 2600, y: 4200};
/// And inside it, the fine material flutters against the bough: six phase-offset buckets per
/// layer, +-0.30 degrees about a point below the nest so the tops move sideways and the base stays
/// planted. 0.42 was the earlier amplitude; at 0.42 the two motions added into visible boiling.
const bucketSway = (theta: number, bucket: number) => 0.3 * Math.sin(theta + bucket * 1.05);
const BUCKET_PIVOT = {x: 2140, y: 1269};

/// THE NEST'S ANSWER TO THE LANDING, and it exists because a loop cannot show a state change: the
/// settled strand has to be present on every frame, so "twig in nest" is true before the drop as
/// well as after it and the event produced no visible result anywhere. Measured, the landing zone's
/// mean luma moved 79.5 -> 76.9 across the landing and its standard deviation not at all.
///
/// What CAN change is the nest's motion. A branch dips when something lands on it and the weave
/// shivers, so the impulse rides on both sway terms: 0.4 degrees of dip on the rigid group and 0.55
/// degrees of counter-phased shiver on the six strand buckets, over 14 frames.
///
/// sin(pi w) * exp(-3w) is exactly zero at w = 0, which matters twice: the falling twig is glued to
/// the landing site through the same transform, so a nonzero impulse at the moment of contact would
/// make it jump; and it is exactly zero again by w = 1, sixty frames before the seam, so this is
/// periodic by being absent at both ends rather than by cancelling across them.
const landImpulse = (frame: number) => {
  const w = (frame - LAND_FRAME) / 14;
  if (w <= 0 || w >= 1) return 0;
  return Math.sin(Math.PI * w) * Math.exp(-3 * w);
};
const rigidAt = (theta: number, frame: number) => rigidSway(theta) - 0.4 * landImpulse(frame);
const bucketAt = (theta: number, bucket: number, frame: number) =>
  bucketSway(theta, bucket) + 0.55 * landImpulse(frame) * Math.cos(bucket * 1.9);

/* ------------------------------------------------------------------ the audit */

/// THE WORDMARK IS SVG TEXT, NOT AN HTML DIV, and that is a correctness fix rather than a
/// preference. The div's ink box was derived from a calibration of the CSS box — "ink top = css top
/// + 0.254 * size, 3.601 * size wide, 0.688 * size of cap height" — and measured on a real render
/// it was wrong on two of the three: at size 210 the ink came out 808x153 at (1100, 483), i.e.
/// 3.848 * size wide and 0.729 * size tall, with the ink top at 0.133 * size below the CSS top and
/// not 0.254. A rectangle two thirds of the ink's real height is a large part of why the previous
/// audit could report zero wordmark collisions while two reviewers watched the bird's tail merge
/// with the K.
///
/// In SVG there is no CSS box to calibrate against: `y` IS the baseline, so the ink box is the
/// font's own metrics and nothing else. The constants below are MEASURED, not looked up — at size
/// 158 the render puts the ink at (1170, 542) to (1778, 657), so the advance for NOOK at 0.18em
/// tracking is 3.848 * size and the cap height is 0.728 * size. Those are not Georgia's numbers
/// (3.61 and 0.692); the headless Chrome does not have Georgia and falls through the stack to a
/// Times-class serif, which is worth knowing but is not worth chasing — it is a competent serif and
/// the ink box is right for the face that actually draws.
/// `left` is 1152 and not the safe box's own edge at 1097. Sitting the ink exactly on the boundary
/// rendered the N as a sliced stem in the guaranteed-view crop; 55px is the smallest margin at which
/// it reads as placed rather than as cropped. Measured, the ink starts at 1155 — 58px inside.
///
/// SIZE 239, cap 176px = 26.7% of the guaranteed-visible height. It was 126 (cap 91px, 13.8%) and a
/// reviewer called that too small twice, so this number is not up for renegotiation downward. Two
/// levers got it here and neither should be undone without a measured reason: tracking, which was
/// 0.18em and spent 19% of the ink width on letterspacing; and SCENE.cx, which moved the nest right
/// to open the room. A top-band variant at size 235 was rendered in an adjacent pass and came out at
/// cap 173 (26.25%) — smaller, on the one axis the reviewer has been vocal about.
///
/// BASELINE 958, AND IT IS ANCHORED TO THE NEST RATHER THAN TO THE FRAME. The previous 1088 put the
/// ink at y 917..1092 in a safe box ending at 1152: 424px of empty paper above the word and 60px
/// below it, so the name read as having slid to the floor. The fix is not "nudge it up until it
/// looks right" — it is to give the type a horizontal the picture already contains. Three candidate
/// lines were measured off a render, and the useful result is that they agree to within 8px:
///
///   crown        787.4  the nest's own ink top (the audit's `nest` box). The flat top of its
///                       rendered silhouette across x 2260..2620 has a median of ~800 with isolated
///                       needle tips reaching 763, so 787 sits in the crown BAND, not on a stray tip
///   cup axis       866  centroid of the cup's deep shadow — rows with luma < 55 in x 2150..2700 run
///                       820..910 and peak at 870. The middle of the hollow the twig falls into
///   centreline  950.65  the nest ink box's own vertical centre, which is SCENE.cy by construction
///
/// Setting the CAP-TOP on the crown gives baseline = 787 + 0.7155 * 239 = 958. That baseline then
/// lands 7px off the centreline and the cap's optical centre (958 - 0.358 * 239 = 872) lands 6px off
/// the cup axis, so one number satisfies all three and the lockup is not a compromise between them.
/// Rendered and measured: ink y 787..962, cap-top exactly on the crown.
///
/// The CROWN is the line that gets cited because it is the only one of the three a viewer can see —
/// the cup axis and the centreline are constructions, the crown is an edge. What the eye gets is one
/// horizontal shared by the top of the N and the top of the nest, and it survives the 600px crop.
///
/// Two nearby positions were rendered and rejected. Cap CENTRE on the nest's centreline (baseline
/// 1035, a 53px lift) needs no change to the bird at all and is therefore the cheap answer — but it
/// buys only 53px, leaves the ink centre still 129px below the box centre, and aligns to an
/// invisible construction, so the relationship it creates cannot be seen. BASELINE on the crown
/// (802) is the literal reading of "anchor it to the rim" and the audit killed it in one render:
/// onWORD ran from frame 31 through 60+, because a word that high occupies exactly the airspace the
/// bird needs to carry a twig over the rim — the same failure a 275pt centred version produced.
///
/// TRACK 0.05, down from 0.08, and it buys CLEARANCE, not size — cap height is untouched. The
/// binding gap is not box-to-box: the nest's left profile is a diagonal (x 2364 at y 780, 2168 at
/// 820, 2105 at 880, 2045 at 960), so the constraint is the K's foot serif against the fringe on the
/// baseline row. And that fringe MOVES. The audit's `nest` box is computed from unswayed endpoints,
/// but the rigid sway turns the whole group about a pivot ~3200 local units away, so the rendered
/// silhouette translates ~40px over the loop — which is why `nestNearWord` below now measures it per
/// frame instead of trusting a static number. Measured per row on real renders, worst case over the
/// loop (frame 140, the sway extreme) against best case (frame 60, at rest):
///
///   track 0.08   K ink ends 2004    gap  48px at rest    ~8px swayed   the shipped setting
///   track 0.06   K ink ends 1990    gap  62px at rest     18px swayed
///   track 0.05   K ink ends 1982    gap  70px at rest     26px swayed   <- this
///   track 0.04   K ink ends 1975    gap  77px at rest     33px swayed
///
/// 0.04 was rendered and looked at 1:1: the OO pair closes to a near-kiss and reads as one blot, and
/// 7px measured against a pale antialiased strand tip is not worth the letterfit of the app's name.
/// Track 0 was tried in the top-band variant and fuses the OO into a single dark mass at 600px.
/// 26px at the extreme is below the 60px everything else in this composition keeps, and it cannot be
/// closed at this cap height — 60px needs the ink to end at 1938, which is 44px of width the word
/// does not have with the N held 55px off the safe box. It is three times the shipped setting's
/// worst case, and at browsing size it reads as adjacency rather than contact.
///
/// WHAT THIS POSITION DOES NOT FIX, so nobody re-derives it: the word is no longer low relative to
/// the NEST, but the PAIR is still low relative to the FRAME. Combined subject ink is y 787..1114
/// against a safe box of 493..1152, so the composition's centre sits ~116px below the box's, and
/// rows 493..762 — 41% of the guaranteed height — carry nothing on the ~44% of frames where the bird
/// is outside the box. Two independent reviews of two different wordmark positions both landed on
/// the same remedy: raise the whole subject (SCENE.cy up ~50, WORD.baseline following it so the
/// crown anchor survives) rather than move the type again.
///
/// That is deliberately NOT done here, and the reason is arithmetic rather than nerve. SCENE.cy
/// moves the boughs too — they are drawn inside the group — and BOUGH2's needle tip currently lands
/// 95px below the canvas with the rigid sway walking it 36px. A 50px raise leaves 9px, so the taper
/// would flick on screen twice a loop. Raising the subject means re-solving BOUGH2's length first,
/// which is the seating pass's geometry and not the wordmark's.
const WORD = {left: 1152, baseline: 958, size: 239, track: 0.05};
/// MEASURED, and the formula this replaces was wrong on BOTH terms. It said `3.14 + 4 * track` on
/// the reasoning that SVG applies letterSpacing after every glyph including the last. It does — but
/// that trailing space is ADVANCE, not INK: the ink box ends at the K's right serif, so only the
/// three internal gaps move it. Read off four real renders spanning two sizes and four tracking
/// values, the ink width is size * (3.312 + 3 * track) to within 0.4px everywhere:
///
///   size 239 track 0.08  ink 1155..2004  849px  ratio 3.5523   formula 3.5520
///   size 239 track 0.06  ink 1155..1990  835px  ratio 3.4937   formula 3.4920
///   size 239 track 0.05  ink 1155..1982  827px  ratio 3.4603   formula 3.4620
///   size 235 track 0.00  ink 1155..1933  778px  ratio 3.3106   formula 3.3120
///
/// This is not a tidy-up. WORD_GUARD is built on WORD_RATIO, so for two passes the rectangle the
/// bird was tested against was 22-45px NARROWER than the type it was guarding, and the audit was
/// quietly lying about the one thing it exists to prove.
const WORD_RATIO = 3.312 + 3 * WORD.track;
const WORD_RECT = {
  x0: WORD.left,
  y0: WORD.baseline - 0.72 * WORD.size,
  // +4 is the N's left side bearing, measured: with `left` at 1152 the first dark pixel is 1155, so
  // the ink starts 3px in and ends 3px past `left + ratio * size`. x0 keeps the untrimmed edge
  // because erring left is erring away from the bird and into the safe box's own margin; x1 has to
  // be pushed out or the rectangle stops short of the K.
  x1: WORD.left + 4 + WORD_RATIO * WORD.size,
  y1: WORD.baseline + 4,
};
/// The rectangle the bird is actually tested against: the ink grown by 70px on every side.
///
/// The previous version's audit reported ZERO word collisions and was right about the geometry and
/// wrong about the picture — at 70px of clearance the tail and the wing blade are the same dark
/// brown as the letters and read as a fifth glyph or a swash on the lockup, which is what two
/// reviewers saw. Proximity to type is the defect, not intersection with it.
const WORD_GUARD = {
  x0: WORD_RECT.x0 - 70,
  y0: WORD_RECT.y0 - 70,
  x1: WORD_RECT.x1 + 70,
  y1: WORD_RECT.y1 + 70,
};
/// The nest's INK top by column, in world coordinates — not its surface top. Two constraints bound
/// where wood can be: `outsideBy` lets a strand endpoint sit 46 local units outside the scanned
/// silhouette, and the builder refuses any endpoint above local y 645. Both hold, so the ink's
/// highest point is the lower of the two, and the bird has to clear THAT. Fitting this by eye is
/// how a routing that skimmed the nest's left shoulder once got as far as a render.
const nestInkTopWorld = (xWorld: number) => {
  const lx = toLocal(xWorld, 0).x;
  if (lx < SCAN.x0 - 40 || lx > SCAN.x1 + 40) return Infinity;
  const t = SCAN.top[colOf(lx)];
  if (!isFinite(t)) return Infinity;
  return toWorld(0, Math.max(t - 46, 645)).y;
};

const PROBES: [number, number][] = [
  [132, -7],
  [-150, -27],
  [-150, 7],
  [0, -26],
  [0, 19],
  [70, 46],
];
/// The bird's silhouette as local probe points pushed through its flight frame — nose, tail tip,
/// back, belly, the carried twig's ends, and the wing tip taken from the same `wingGeom` the
/// renderer uses. Claims about what the bird overlaps are worth nothing unless they are made
/// against its extent rather than its centre.
/// Every probe point in world coordinates. Overlap has to be tested POINT BY POINT and not against
/// a bounding box: at the flare the box spans the wing tip 90px below the shoulder and the tail
/// 300px behind it, and asking whether that rectangle touches the wordmark reported three
/// collisions that were 45px of clear paper. The box is still the right test for "is it on canvas".
const birdPoints = (u: number) => {
  const pose = poseAt(u);
  const carried = mMul(pose.frame, twigLocal(pose.headRot, pose.bob));
  const w = wingGeom(pose.swing, pose.amp);
  const tip = mChain(mT(SHOULDER.x, SHOULDER.y), mR(w.angle), mS(w.chord, w.len));
  const wingAt = (s: number): [number, number] => [
    tip[0] * 13 * s + tip[2] * -160 * s + tip[4],
    tip[1] * 13 * s + tip[3] * -160 * s + tip[5],
  ];
  const local = PROBES.concat([wingAt(1), wingAt(0.66), wingAt(0.33)]);
  const out: [number, number][] = [];
  for (const pt of local) {
    out.push([
      pose.frame[0] * pt[0] + pose.frame[2] * pt[1] + pose.frame[4],
      pose.frame[1] * pt[0] + pose.frame[3] * pt[1] + pose.frame[5],
    ]);
  }
  // The carried twig, sampled along its own length rather than at its ends only.
  for (let i = 0; i <= 4; i++) {
    const lx = (i / 4) * TWIG_LEN;
    out.push([
      carried[0] * lx + carried[4],
      carried[1] * lx + carried[5],
    ]);
  }
  return out;
};
const boxOf = (pts: [number, number][]) => {
  const box = {x0: Infinity, y0: Infinity, x1: -Infinity, y1: -Infinity};
  for (const p of pts) {
    box.x0 = Math.min(box.x0, p[0]);
    box.y0 = Math.min(box.y0, p[1]);
    box.x1 = Math.max(box.x1, p[0]);
    box.y1 = Math.max(box.y1, p[1]);
  }
  return box;
};
type Rect = {x0: number; y0: number; x1: number; y1: number};
const hits = (a: Rect, b: Rect) => a.x0 < b.x1 && a.x1 > b.x0 && a.y0 < b.y1 && a.y1 > b.y0;

/// Everything this file claims, computed from the same functions that draw the frame. It has
/// caught, so far: a wing flying 80px into the letters, a roll reversing in one frame at three
/// quarters height, and two strands landing outside the nest.
const AUDIT = (() => {
  let onCanvas = 0;
  let inSafe = 0;
  /// The number that the last two versions of this file got wrong, and the only one that describes
  /// what a browsing user sees: frames where the bird's ink is WHOLLY inside the 1645x659 box. A
  /// bird that grazes the crop line is a fragment, and a fragment at the frame edge is worse than a
  /// clean absence.
  let wholeInSafe = 0;
  let clipped = 0;
  const wordFrames: number[] = [];
  const nestFrames: number[] = [];
  const offRun: number[] = [];
  let maxRollStep = 0;
  let minAbsRoll = Infinity;
  let minSpeed = Infinity;
  let maxSpeed = -Infinity;
  let prevRoll = poseAt(179 / 180).roll;
  /// The bird's ink envelope by 200px column over the WHOLE loop, printed on the audit line. This is
  /// the number that decides how high the wordmark may go, and it was worth a rendered sweep to find
  /// once: the word's ceiling is not the safe box, it is the bird's belly, because the audit tests
  /// every probe point against the ink grown 70px. With it recorded here the next person can compute
  /// that ceiling as max(birdHi over the word's columns) + 70 + cap, without repeating the sweep.
  const binLo: number[] = [];
  const binHi: number[] = [];
  for (let i = 0; i < 9; i++) {
    binLo.push(Infinity);
    binHi.push(-Infinity);
  }
  for (let f = 0; f < 180; f++) {
    const u = f / 180;
    const pts = birdPoints(u);
    for (const [x, y] of pts) {
      const i = Math.floor((x - 1000) / 200);
      if (i >= 0 && i < 9) {
        binLo[i] = Math.min(binLo[i], y);
        binHi[i] = Math.max(binHi[i], y);
      }
    }
    const box = boxOf(pts);
    if (hits(box, {x0: 0, y0: 0, x1: W, y1: H})) onCanvas++;
    else offRun.push(f);
    if (hits(box, SAFE)) inSafe++;
    const whole = box.x0 >= SAFE.x0 && box.y0 >= SAFE.y0 && box.x1 <= SAFE.x1 && box.y1 <= SAFE.y1;
    if (whole) wholeInSafe++;
    else if (hits(box, SAFE)) clipped++;
    let onWord = false;
    let onNest = false;
    for (const [x, y] of pts) {
      if (x > WORD_GUARD.x0 && x < WORD_GUARD.x1 && y > WORD_GUARD.y0 && y < WORD_GUARD.y1) onWord = true;
      if (y > nestInkTopWorld(x)) onNest = true;
    }
    if (onWord) wordFrames.push(f);
    if (onNest) nestFrames.push(f);
    const roll = rollAt(u);
    minAbsRoll = Math.min(minAbsRoll, Math.abs(roll));
    maxRollStep = Math.max(maxRollStep, Math.abs(roll - prevRoll));
    prevRoll = roll;
    const v = (warpAt((f + 1) / 180) - warpAt(u) + 1) % 1;
    minSpeed = Math.min(minSpeed, v * PATH.total);
    maxSpeed = Math.max(maxSpeed, v * PATH.total);
  }
  let outOfBounds = 0;
  let belowSeat = 0;
  for (const s of STRANDS) {
    for (const [ex, ey] of [
      [s.ends[0], s.ends[1]],
      [s.ends[2], s.ends[3]],
    ]) {
      if (ex < 1470 || ex > 2810) outOfBounds++;
      if (ey > seatTop(ex) + 26) belowSeat++;
    }
  }
  /// Where the nest's ink actually ends, by column, in world coordinates — the number the safe box
  /// is judged on. Endpoints only, plus the strand's own half-thickness, which is what the two
  /// rejection tests bound.
  let inkBottom = -Infinity;
  let inkTop = Infinity;
  let inkLeft = Infinity;
  let inkRight = -Infinity;
  for (const s of STRANDS) {
    for (const [ex, ey] of [
      [s.ends[0], s.ends[1]],
      [s.ends[2], s.ends[3]],
    ]) {
      const w = toWorld(ex, ey + s.geom.baseHalf);
      const t = toWorld(ex, ey - s.geom.baseHalf);
      if (w.y > inkBottom) inkBottom = w.y;
      if (t.y < inkTop) inkTop = t.y;
      if (w.x < inkLeft) inkLeft = w.x;
      if (w.x > inkRight) inkRight = w.x;
    }
  }
  /// THE NEST AGAINST THE WORD, PER FRAME — the safety net this file did not have, and the reason it
  /// needed one. Every other clearance here is computed from `nest` above, which is built from
  /// UNSWAYED endpoints; but the rigid group turns up to 0.92 degrees about a pivot ~3200 local units
  /// below the nest, so the rendered silhouette TRANSLATES ~40px across the loop. Measured on real
  /// renders, the K-to-fringe gap runs 70px at rest (frame 60) and 26px at the sway extreme (frame
  /// ~140) — a static number describes one instant of a moving picture, and the audit only ever
  /// tested the BIRD against the word, never the nest. The shipped 0.08em setting was 8px at that
  /// extreme, close enough to read as touching at browsing size, and nobody had measured it.
  ///
  /// Endpoints only, mapped through the same two rotations the renderer applies and in the same
  /// order (bucket inside rigid inside camera), then tested against the word's ink band rather than
  /// its box, because the nest's left profile is a diagonal and only the rows the type occupies
  /// matter. `nestNearWord` is the smallest horizontal gap over all 180 frames; `nearFrame` says
  /// where to go and look.
  let nestNearWord = Infinity;
  let nearFrame = -1;
  const rot = (x: number, y: number, deg: number, px: number, py: number) => {
    const a = (deg * Math.PI) / 180;
    const c = Math.cos(a);
    const s = Math.sin(a);
    const dx = x - px;
    const dy = y - py;
    return {x: px + dx * c - dy * s, y: py + dx * s + dy * c};
  };
  for (let f = 0; f < 180; f++) {
    const th = (f / 180) * TAU;
    const rg = rigidAt(th, f);
    for (const s of STRANDS) {
      const bk = bucketAt(th, s.bucket, f);
      for (const [ex, ey] of [
        [s.ends[0], s.ends[1]],
        [s.ends[2], s.ends[3]],
      ]) {
        for (const oy of [-s.geom.baseHalf, s.geom.baseHalf]) {
          const b = rot(ex, ey + oy, bk, BUCKET_PIVOT.x, BUCKET_PIVOT.y);
          const r = rot(b.x, b.y, rg, RIGID_PIVOT.x, RIGID_PIVOT.y);
          const w = toWorld(r.x, r.y);
          if (w.y < WORD_RECT.y0 || w.y > WORD_RECT.y1) continue;
          const gap = w.x - WORD_RECT.x1;
          if (gap < nestNearWord) {
            nestNearWord = gap;
            nearFrame = f;
          }
        }
      }
    }
  }
  return {
    onCanvas,
    inSafe,
    wholeInSafe,
    clipped,
    wordFrames,
    nestFrames,
    offRun,
    minSpeed,
    maxSpeed,
    minAbsRoll,
    maxRollStep,
    strands: STRANDS.length,
    outOfBounds,
    belowSeat,
    nest: [f1(inkLeft), f1(inkTop), f1(inkRight), f1(inkBottom)],
    binLo,
    binHi,
    nestNearWord,
    nearFrame,
  };
})();

/// Scaffolding, off in the shipped composition. Turning it on prints the audit to the render log
/// rather than drawing on the art, because 40px of monospace in the corner of a 3840px frame is
/// not readable at any downscale anyone actually looks at.
const DEBUG = false;

/* ------------------------------------------------------------------ component */

export const ProbeA: React.FC<{guides?: boolean}> = ({guides = false}) => {
  const frame = useCurrentFrame();
  const {durationInFrames} = useVideoConfig();
  const u = frame / durationInFrames;
  const theta = u * TAU;

  if (DEBUG && frame === 0) {
    // eslint-disable-next-line no-console
    console.log('AUDIT', JSON.stringify(AUDIT), 'uFlare', U_FLARE, 'rel', REL_FRAME, 'land', LAND_FRAME);
  }

  /* ---- geometry, built once. A twig re-dealt every frame boils. ---- */
  /// The bough itself is built at module scope, not here: the seat the nest is cut against is read
  /// off its own outline, and `buildNest` needs the seat before this component exists.
  const grain = React.useMemo(
    () =>
      GRAIN.map((g) => ({
        ...g,
        geom: buildTwig({
          seed: g.seed,
          length: g.len,
          arch: 'bare',
          sweep: 'bowed',
          weight: 'wisp',
          tip: 'wedge',
          maxDepth: 0,
          stout: 0.35,
          lightLocalDeg: LIGHT_WORLD_DEG - BOUGH.rot,
          allowHighlight: false,
        }),
      })),
    []
  );
  const limbGrain = React.useMemo(
    () =>
      LIMB_GRAIN.map((g) => ({
        ...g,
        geom: buildTwig({
          seed: g.seed,
          length: g.len,
          arch: 'bare',
          sweep: 'bowed',
          weight: 'wisp',
          tip: 'wedge',
          maxDepth: 0,
          stout: 0.2,
          lightLocalDeg: LIGHT_WORLD_DEG - BOUGH2.rot,
          allowHighlight: false,
        }),
      })),
    []
  );
  const trunkGrain = React.useMemo(
    () =>
      TRUNK_GRAIN.map((g) => ({
        ...g,
        geom: buildTwig({
          seed: g.seed,
          length: g.len,
          arch: 'bare',
          sweep: 'bowed',
          weight: 'wisp',
          tip: 'wedge',
          maxDepth: 0,
          stout: 0.2,
          lightLocalDeg: LIGHT_WORLD_DEG - TRUNK.rot,
          allowHighlight: false,
        }),
      })),
    []
  );
  const sprigs = React.useMemo(
    () =>
      SPRIGS.map((s) => ({
        ...s,
        y: boughTopAt(s.x) + 60,
        geom: buildTwig({
          seed: s.seed,
          length: s.len,
          arch: 'forked',
          sweep: 'bowed',
          weight: 'ordinary',
          // 'needle' here was a thin dark blade in open paper; a wedge is a long even taper.
          tip: 'wedge',
          maxDepth: 2,
          stout: 1.15,
          lightLocalDeg: LIGHT_WORLD_DEG - s.rot,
          allowHighlight: false,
        }),
      })),
    []
  );
  const lashings = React.useMemo(
    () =>
      LASHINGS.map((s) => ({
        ...s,
        y: woodTopAt(s.x) + s.dy,
        geom: buildTwig({
          seed: s.seed,
          length: s.len,
          arch: 'single',
          sweep: 'bowed',
          weight: 'ordinary',
          tip: 'wedge',
          maxDepth: 1,
          stout: 2.4,
          lightLocalDeg: LIGHT_WORLD_DEG - s.rot,
          allowHighlight: false,
        }),
      })),
    []
  );
  /// Two cast shadows on the paper from branches off-camera, at two different seeds — three at one
  /// geometry is a repeat that buys nothing at 0.16 opacity. Steeper than the bough (32-38 degrees
  /// against 11) so they read as another plane rather than as an echo of it. This is what fills
  /// the left of the frame: atmosphere that cannot be mistaken for a subject and cannot be hurt by
  /// a crop.
  const backdrop = React.useMemo(
    () =>
      [0x33f1, 0x21c7].map((seed) => ({
        seed,
        geom: buildTwig({
          seed,
          length: 420,
          arch: 'forked',
          sweep: 'bowed',
          weight: 'stick',
          tip: 'wedge',
          maxDepth: 1,
          lightLocalDeg: 0,
          allowHighlight: false,
        }),
      })),
    []
  );
  /// THE NEAR PLANE, and it is answering "in the guaranteed view half the frame is empty". Two
  /// branches a metre in front of the lens, so blurred past recognition as individual twigs but not
  /// past recognition as WOOD: they fill the safe box's bottom-left corner, put a third plane
  /// between the viewer and the nest, and cannot be hurt by any crop. The first reaches screen
  /// (1278, 1120) — 165px below the bird's lane and 32px inside the safe bottom — and the second
  /// lives entirely in the bleed under it.
  ///
  /// They are branch SHAPES at wood colour, not soft grey creases: the existing off-camera cast
  /// shadows in the left third were read as "a wrinkled bedsheet, mildew, or a stain on a wall"
  /// precisely because nothing in the frame explained what cast them. These are the thing itself.
  const nearPlane = React.useMemo(
    () =>
      [
        {seed: 0x6f01, x: 700, y: 1420, rot: -34, len: 340, scale: 2.2, blur: 15, op: 0.34},
        {seed: 0x6f02, x: 1560, y: 1720, rot: -74, len: 240, scale: 1.7, blur: 22, op: 0.26},
      ].map((b) => ({
        ...b,
        geom: buildTwig({
          seed: b.seed,
          length: b.len,
          arch: 'forked',
          sweep: 'bowed',
          weight: 'stick',
          tip: 'wedge',
          maxDepth: 2,
          stout: 1.25,
          lightLocalDeg: LIGHT_WORLD_DEG - b.rot,
          allowHighlight: false,
        }),
      })),
    []
  );
  /// One geometry, drawn twice: once in the beak and falling, once as the strand it becomes.
  const hero = React.useMemo(
    () =>
      buildTwig({
        seed: 0x9a1f,
        length: TWIG_LEN,
        arch: 'single',
        sweep: 'bowed',
        weight: 'ordinary',
        tip: 'wedge',
        maxDepth: 1,
        stout: 1.9,
        lightLocalDeg: LIGHT_WORLD_DEG - SETTLED.deg,
        allowHighlight: false,
      }),
    []
  );
  const heroGrad = gradId(TWIG_RUNG, litUpAt(SETTLED.deg), bucketOfHalf(hero.baseHalf));

  /* ---- the drop ---- */
  const pose = poseAt(u);
  const carrying = frame < REL_FRAME;
  const release = RELEASE;
  /// Where the landing site IS this frame, IN WORLD COORDINATES. The nest sways and the landing
  /// nudges it, so a fixed target would have the twig land 30px off the wood at the extremes and
  /// pop when it merged; the camera is the first factor in the chain because the falling twig is
  /// drawn outside the scene group, in world space, and has to be told where the scene put the cup.
  const target = React.useMemo(
    () =>
      mDecompose(
        mChain(
          mT(SCENE.cx, SCENE.cy),
          mS(SCENE.k, SCENE.k),
          mT(-CX, -CY),
          mRAbout(rigidAt(theta, frame), RIGID_PIVOT.x, RIGID_PIVOT.y),
          mRAbout(bucketAt(theta, 0, frame), BUCKET_PIVOT.x, BUCKET_PIVOT.y),
          mT(SETTLED.x, SETTLED.y),
          mR(SETTLED.deg)
        )
      ),
    [theta, frame]
  );

  const fallK = clamp01((frame - REL_FRAME) / FALL_FRAMES);
  // The twig falls very nearly straight down: it stops sharing the bird's speed the instant the
  // beak opens, so the bird flies out from over it. Separation has to come from the bird going
  // FORWARD fast while the twig goes DOWN, because the bird cannot climb away — at the top of the
  // frame is the return leg's lane.
  // LINEAR in x, quadratic in y — a parabola, which is the one thing an audience recognises without
  // being told. The horizontal was `fallK * (0.5 + 0.5 * fallK)`, i.e. it started at half rate and
  // ACCELERATED sideways; nothing accelerates sideways in free fall, and it read as the twig being
  // drawn towards the nest by a magnet rather than falling into it. Vertically it is now a true
  // fallK^2: the old cubic term made the arc slightly wrong in the way a compressed spring is wrong.
  const fx = lerp(release.x, target.x, fallK);
  const fy = lerp(release.y, target.y, fallK * fallK);
  const contact = clamp01((frame - LAND_FRAME) / 9);
  // A settle, not a bounce: one small rock that damps out.
  const rock = (1 - contact) * Math.sin(contact * Math.PI * 1.7) * 6;
  // Front-loaded tumble, so the twig's silhouette stops being parallel to the bird's within two
  // or three frames of leaving the beak.
  // The turn is monotonic towards the settled angle, with the swing folded in as a bump that is zero
  // at BOTH ends rather than a 42-degree snap taken in the first three frames and slowly given back.
  // `sqrt(fallK)` put the whole excursion at the start, so the twig jerked flat the instant it left
  // the beak and then crept back — the single most mechanical-looking thing in the loop. 26 degrees
  // peaking mid-fall reads as a stick swinging about its own weight while it drops.
  const turn = ((((target.deg - release.deg + 180) % 360) + 360) % 360) - 180;
  const swingDir = turn >= 0 ? 1 : -1;
  const fdeg =
    release.deg +
    turn * (1 - Math.pow(1 - fallK, 3)) +
    26 * swingDir * 4 * fallK * (1 - fallK) +
    rock;
  // Constant by construction: TWIG_SCALE was DERIVED from release.scale, so `SCENE.k * TWIG_SCALE`
  // is release.scale again. The lerp stays because it states the invariant — a dropped stick does
  // not change size — and would catch it if either number were ever edited alone.
  const fscale = lerp(release.scale, SCENE.k * TWIG_SCALE, fallK);
  // Once down it is the same geometry in the same pose as the strand beneath it, so the fade is
  // invisible; it exists only so antialiased edges do not tick.
  const heroOpacity = 1 - clamp01((frame - (LAND_FRAME + 6)) / 10);
  const carriedM = mMul(pose.frame, twigLocal(pose.headRot, pose.bob));
  // A falling stick over a nest needs a contact shadow, and it needs it for the whole fall and not
  // just the last six frames — a shadow that tightens and darkens as the gap closes is the only
  // cue that says the twig is ABOVE the mass rather than drawn on top of it. It also lands the
  // twig: without it the last frames read as a twig stopping in mid-air.
  const shadowOp = 0.4 * Math.pow(fallK, 1.5);
  const shadowRx = lerp(95, 52, fallK);
  const shadowRy = lerp(22, 12, fallK);
  const shadowX = lerp(fx - 50, target.x, fallK);

  const rigid = rigidAt(theta, frame);

  /// Three shadow offsets instead of one for the whole nest: one filter over the group gave a back
  /// strand and a front strand the same 16px twin, which is the signature of die-cut paper. The
  /// flood is warmer and weaker than it was (luma 74 at 0.16-0.20 against luma 44 at 0.20-0.24)
  /// because the voids between strands were measuring at near-black against 232-luma paper and
  /// read as holes punched in it.
  const shadows = [
    {dy: 3, blur: 4, op: 0.2},
    {dy: 6, blur: 7, op: 0.18},
    {dy: 8, blur: 10, op: 0.16},
  ];
  /// Filter regions are hand-typed and clamped to the canvas, because region AREA is what costs —
  /// not blur radius and not path count.
  const fx0 = {x: 1360, y: 560, w: 1560, h: 900};

  return (
    <AbsoluteFill style={{background: '#F3E3C4'}}>
      <svg width={W} height={H} viewBox={`0 0 ${W} ${H}`}>
        <defs>
          <WoodGradients />
          {/* The sky as ONE gradient laid down the light ray rather than a vertical ramp, with
              the hue rotating 44 -> 21 along it: gold at the sun, rose-grey at the far corner.
              Hue distance is what reads as light; luma alone reads as sepia. It is darker than a
              cream ramp by design — that is what gives the sun headroom. */}
          <linearGradient id="cbSky" x1={3840} y1={-120} x2={-160} y2={1646} gradientUnits="userSpaceOnUse">
            <stop offset="0%" stopColor="#F4E3B5" />
            <stop offset="26%" stopColor="#EAD2A4" />
            <stop offset="55%" stopColor="#DEBC90" />
            <stop offset="80%" stopColor="#D1A67F" />
            <stop offset="100%" stopColor="#C18D70" />
          </linearGradient>
          {/* The aureole. An earlier one had a linear falloff and measured as a PLATEAU — luma
              234-241 across the whole right third of the frame, a bright field with no source in
              it. Front-loaded now: half the opacity is gone by 30% of the radius, so the glow has
              a centre you can point at. */}
          <radialGradient id="cbGlow" cx="50%" cy="50%" r="50%">
            <stop offset="0%" stopColor="#FFF6D8" stopOpacity="0.95" />
            <stop offset="18%" stopColor="#FFF2CC" stopOpacity="0.62" />
            <stop offset="40%" stopColor="#FFECBE" stopOpacity="0.3" />
            <stop offset="70%" stopColor="#FFE8B4" stopOpacity="0.09" />
            <stop offset="100%" stopColor="#FFE6AE" stopOpacity="0" />
          </radialGradient>
          <radialGradient id="cbCore" cx="50%" cy="50%" r="50%">
            <stop offset="0%" stopColor="#FFFFFB" stopOpacity="1" />
            <stop offset="16%" stopColor="#FFFDF2" stopOpacity="0.96" />
            <stop offset="34%" stopColor="#FFF6D6" stopOpacity="0.6" />
            <stop offset="64%" stopColor="#FFEFC0" stopOpacity="0.2" />
            <stop offset="100%" stopColor="#FFE9B0" stopOpacity="0" />
          </radialGradient>
          {/* Eleven stops on a bell, not three: a linear alpha ramp across a shaft's width has a
              discontinuity in its first derivative at the peak and at both ends, and the eye
              resolves that as a Mach band — at 1:1 the shafts showed as hard-edged diagonal
              stripes with a visible line down each side. */}
          <linearGradient id="cbShaft" x1="0" y1="-1" x2="0" y2="1">
            {[0, 0.02, 0.08, 0.24, 0.55, 1, 0.55, 0.24, 0.08, 0.02, 0].map((a, i) => (
              <stop key={i} offset={`${i * 10}%`} stopColor="#FFF9E8" stopOpacity={a} />
            ))}
          </linearGradient>
          {/* Aerial haze — it also softens the pocket's outer edge for free. */}
          {/* THE SHADED POCKET, the load-bearing photometric invention in this frame, RE-SOLVED for
              the smaller nest. The palest wood in the ramp measures 189 on the render and unshaded
              sky behind the nest measures 198, so without this every pale strand sits below its
              background and reads as a grey chip rather than as lit wood. Darkening what is BEHIND
              them is the fix; darkening the wood itself turns the mass into a monotone scratch.

              SIZE IS THE WHOLE PROBLEM AND IT WAS GOT WRONG TWICE ON THIS PASS. Scaled with the
              nest — r 950, 0.52 at the core — it is twice the width of a 676px nest, so half of its
              dark core lies on empty paper and it reads as a thumbprint: measured, paper at
              (1500,700) 203 against paper at (1900,1000), beside the nest with nothing in it, 153.
              Derived from the nest's own silhouette instead — the column scan grown 130 above and
              150 below, blurred 85 — it becomes a dark ring hugging the mass, i.e. the halo this
              file already has a warning about, and worse than the ellipse.

              What works is a shade sized to the FRAME, not to the subject: 3000x2040, peaking at
              0.40, falling to nothing by the upper-left corner. At that size it does not read as an
              object at all, it reads as the light coming from the upper right — which is what the
              sun says too. Measured on the render below: sky behind the nest 144-152, paper under
              the wordmark 171, upper-left corner 200, palest wood 189. Normal blend, not multiply.
              The gradient circle lives in a space scaled 0.68 in y, which is how a userSpaceOnUse
              radial becomes an ellipse. */}
          <radialGradient
            id="cbPocket"
            gradientUnits="userSpaceOnUse"
            cx={2150}
            cy={1010 / 0.68}
            r={1500}
            gradientTransform="scale(1 0.68)"
          >
            <stop offset="0%" stopColor="#6B3B1E" stopOpacity="0.4" />
            <stop offset="25%" stopColor="#6E3E1F" stopOpacity="0.38" />
            <stop offset="48%" stopColor="#7A4A28" stopOpacity="0.3" />
            <stop offset="72%" stopColor="#8A5A32" stopOpacity="0.16" />
            <stop offset="88%" stopColor="#96683E" stopOpacity="0.05" />
            <stop offset="100%" stopColor="#96683E" stopOpacity="0" />
          </radialGradient>
          <linearGradient id="cbHaze" x1="0" y1="0" x2="0" y2={H} gradientUnits="userSpaceOnUse">
            <stop offset="0%" stopColor="#FFF7E2" stopOpacity="0.5" />
            <stop offset="58%" stopColor="#FDF1DC" stopOpacity="0.28" />
            <stop offset="100%" stopColor="#F6E3BC" stopOpacity="0.08" />
          </linearGradient>
          <radialGradient id="cbVig" cx={2500} cy={620} r={2500} gradientUnits="userSpaceOnUse">
            <stop offset="58%" stopColor="#8A6A3F" stopOpacity="0" />
            <stop offset="100%" stopColor="#7A5324" stopOpacity="0.2" />
          </radialGradient>
          {/* A bough is a cylinder, not a board: one continuous cross-thickness ramp in the
              bough's OWN frame, so it rotates with the wood. The generator's highlight ribbon on
              a shape this large is a 1450px chamfered-plank edge. */}
          <linearGradient
            id="cbBark"
            x1="0"
            y1={-9.4}
            x2="0"
            y2={9.4}
            gradientUnits="userSpaceOnUse"
            spreadMethod="reflect"
          >
            <stop offset="0%" stopColor="#A67A3B" />
            <stop offset="14%" stopColor="#8A6033" />
            <stop offset="30%" stopColor="#74502A" />
            <stop offset="52%" stopColor="#5C3A18" />
            <stop offset="76%" stopColor="#452912" />
            <stop offset="100%" stopColor="#33200F" />
          </linearGradient>
          {/* The same ramp, reflected. `cbBark` runs light-to-dark down the twig's OWN +y, and for
              a limb lying at rot 173-206 that puts the lit flank UNDERNEATH — which is what the two
              limbs already ship with and reads as bounce off the ground. A near-vertical trunk at
              rot -99 turns the same ramp into a lit LEFT flank with the sun on the right, which is
              a lighting error big enough to see at browsing size. Reversed for the trunk only. */}
          <linearGradient
            id="cbBarkUp"
            x1="0"
            y1={-9.4}
            x2="0"
            y2={9.4}
            gradientUnits="userSpaceOnUse"
            spreadMethod="reflect"
          >
            <stop offset="0%" stopColor="#2B1B0C" />
            <stop offset="30%" stopColor="#3B240F" />
            <stop offset="58%" stopColor="#4E3116" />
            <stop offset="78%" stopColor="#65431F" />
            <stop offset="91%" stopColor="#82602F" />
            <stop offset="100%" stopColor="#A67A3B" />
          </linearGradient>
          <linearGradient
            id="cbCup"
            x1="0"
            y1={HOLLOW.cy - HOLLOW.ry}
            x2="0"
            y2={HOLLOW.cy + HOLLOW.ry}
            gradientUnits="userSpaceOnUse"
          >
            <stop offset="0%" stopColor="#452C12" />
            <stop offset="50%" stopColor="#2C1B09" />
            <stop offset="100%" stopColor="#221507" />
          </linearGradient>

          <filter id="cbBlur26" filterUnits="userSpaceOnUse" x={0} y={0} width={W} height={H}>
            <feGaussianBlur stdDeviation="26" />
          </filter>
          <filter id="cbSoft" filterUnits="userSpaceOnUse" x={fx0.x} y={fx0.y} width={fx0.w} height={fx0.h}>
            <feGaussianBlur stdDeviation="4" />
          </filter>
          <filter id="cbCupSoft" filterUnits="userSpaceOnUse" x={fx0.x} y={fx0.y} width={fx0.w} height={fx0.h}>
            <feGaussianBlur stdDeviation="6" />
          </filter>
          <filter id="cbAmbient" filterUnits="userSpaceOnUse" x={1500} y={1150} width={1500} height={450}>
            <feGaussianBlur stdDeviation="26" />
          </filter>
          {/* Blur for the near plane. A big region because the shapes are big and the whole point
              is a wide soft falloff; it is the only full-height filter in the piece outside the
              backdrop's, and it is confined to the left third. */}
          <filter id="cbNear" filterUnits="userSpaceOnUse" x={500} y={800} width={1500} height={846}>
            <feGaussianBlur stdDeviation="15" />
          </filter>
          <filter id="cbNear2" filterUnits="userSpaceOnUse" x={1100} y={1150} width={900} height={496}>
            <feGaussianBlur stdDeviation="22" />
          </filter>
          {shadows.map((s, i) => (
            <filter
              key={i}
              id={`cbSh${i}`}
              filterUnits="userSpaceOnUse"
              x={fx0.x}
              y={fx0.y}
              width={fx0.w}
              height={fx0.h}
            >
              <feDropShadow dx="0" dy={s.dy} stdDeviation={s.blur} floodColor="#4A3116" floodOpacity={s.op} />
            </filter>
          ))}
          <filter id="cbContact" filterUnits="userSpaceOnUse" x={1560} y={1020} width={1600} height={620}>
            <feGaussianBlur stdDeviation="26" />
          </filter>
          {/* World space, both of these: the falling twig is drawn outside the scene group. The
              corridor runs from the release at about (2360, 660) to the cup at (2390, 950). */}
          <filter id="cbDrop" filterUnits="userSpaceOnUse" x={2180} y={840} width={440} height={270}>
            <feGaussianBlur stdDeviation="12" />
          </filter>
          {/* Separation for the falling twig, and ONLY for the falling twig: the carried one has
              the bird's own ink beside it and needs no help, and a filter that had to follow the
              bird would be a full-canvas region. */}
          <filter id="cbTwigFall" filterUnits="userSpaceOnUse" x={2160} y={540} width={500} height={540}>
            <feDropShadow dx="-4" dy="7" stdDeviation="5" floodColor="#2A1A0A" floodOpacity="0.55" />
          </filter>
          {/* The load shadow and the bark grain both live ON THE WOOD. Without this clip a blurred
              ellipse spills off the bough's silhouette and darkens bare paper beside it, which
              reads as a stain on the backdrop rather than as shadow on a surface, and a grain rod
              becomes a stick lying next to the branch. SVG runs the filter first and the clip
              second, so a blur stays soft inside the wood and stops dead at its edge. */}
          <clipPath id="cbWood">
            <path d={BOUGH_GEOM.body} transform={BOUGH_XF} />
          </clipPath>
          <clipPath id="cbTrunkClip">
            <path d={TRUNK_GEOM.body} transform={TRUNK_XF} />
          </clipPath>
          <clipPath id="cbLimbClip">
            <path d={BOUGH2_GEOM.body} transform={BOUGH2_XF} />
          </clipPath>
          {/* Dither, tiled. `stitchTiles` makes feTurbulence seamless across the tile and
              baseFrequency * 512 = 448 keeps it on an integer period, so the noise is generated
              once for a 512px square and repeated instead of once for 6.3 megapixels on every one
              of 180 frames. The component transfer steepens it: raw fractalNoise sits inside about
              +-15 levels premultiplied, which at this opacity is below the 1 LSB a dither has to
              reach to break a band. */}
          <filter id="cbNoise" filterUnits="userSpaceOnUse" x={0} y={0} width={512} height={512}>
            <feTurbulence
              type="fractalNoise"
              baseFrequency="0.875"
              numOctaves="2"
              seed="7"
              stitchTiles="stitch"
            />
            <feColorMatrix type="saturate" values="0" />
            <feComponentTransfer>
              <feFuncR type="linear" slope="2.6" intercept="-0.8" />
              <feFuncG type="linear" slope="2.6" intercept="-0.8" />
              <feFuncB type="linear" slope="2.6" intercept="-0.8" />
              <feFuncA type="linear" slope="1" intercept="0" />
            </feComponentTransfer>
          </filter>
          <pattern id="cbGrain" width="512" height="512" patternUnits="userSpaceOnUse">
            <rect width="512" height="512" filter="url(#cbNoise)" />
          </pattern>
        </defs>

        {/* 1-2 sky */}
        <rect x={0} y={0} width={W} height={H} fill="url(#cbSky)" />
        {/* 3 the sun. Nothing is ever drawn over the core. */}
        <circle cx={SUN.x} cy={SUN.y} r={1500} fill="url(#cbGlow)" />
        <circle cx={SUN.x} cy={SUN.y} r={480} fill="url(#cbCore)" />

        {/* 4 air */}
        <g>
          {SHAFTS.map((s, i) => (
            <path
              key={i}
              d={shaftPath(
                s.cx + Math.sin(theta + s.ph) * 46,
                s.cy + Math.cos(theta + s.ph) * 30,
                s.len,
                s.w
              )}
              fill="url(#cbShaft)"
              opacity={s.op * (0.68 + 0.32 * Math.sin(theta + s.ph * 0.7))}
            />
          ))}
        </g>

        {/* 5 backdrop: shadows of branches that are off camera */}
        <g filter="url(#cbBlur26)" opacity={0.16}>
          <g transform="translate(1680 1920) rotate(214) scale(5.0)">
            <path d={backdrop[0].geom.body} fill={NEST_RAMP[1].hex} fillRule="nonzero" />
          </g>
          <g transform="translate(1120 1340) rotate(232) scale(3.2)">
            <path d={backdrop[1].geom.body} fill={NEST_RAMP[1].hex} fillRule="nonzero" />
          </g>
        </g>

        {/* 6 aerial haze — the plane separator, and the reason the far backdrop recedes. */}
        <rect x={0} y={0} width={W} height={H} fill="url(#cbHaze)" />

        {/* 7 the shaded pocket, drawn AFTER the haze and not before it. Measured: with the haze on
            top, 0.35 alpha of a 247-luma wash puts 30 of the pocket's luma straight back and the
            sky behind the nest measures 188 — the palest wood then sits BELOW its background, which
            is the defect the pocket exists to kill. Nothing may be laid over it but the subject. */}
        <ellipse cx={2150} cy={1010} rx={1510} ry={1028} fill="url(#cbPocket)" />

        {/* 8 ------------------------- THE CAMERA, then the RIGID SWAY GROUP inside it. Everything
            from here to the close is in the nest's own solved local space. */}
        <g transform={SCENE_XF}>
        <g transform={`rotate(${f4(rigid)} ${RIGID_PIVOT.x} ${RIGID_PIVOT.y})`}>
          {/* Ambient contact shadow, so the mass has weight where the bough leaves it. */}
          <ellipse cx={2200} cy={1300} rx={520} ry={70} fill="#6B4A22" opacity={0.1} filter="url(#cbAmbient)" />

          {/* 9 the under-shape: packed wood, inset so the strands own the whole silhouette edge.
              Filled at luma 69.5 rather than 55 because this is the shape that shows in the gaps
              between strands, and at 55 those gaps measured near-black. */}
          <path d={BODY_PATH} fill="#5E4220" opacity={0.92} filter="url(#cbSoft)" />
          {/* 10 the cup. This is the single mark that makes it a container rather than a clump. */}
          <path d={CUP_PATH} fill="url(#cbCup)" filter="url(#cbCupSoft)" />

          {/* 11 the far rim and far wall, BEHIND the wood */}
          <g filter="url(#cbSh0)">
            {LAYERS[0].map(([bucket, group]) => (
              <g
                key={bucket}
                transform={`rotate(${f4(bucketAt(theta, bucket, frame))} ${BUCKET_PIVOT.x} ${BUCKET_PIVOT.y})`}
              >
                {group.map((s) => (
                  <g key={s.i} transform={s.transform}>
                    <path d={s.geom.body} fill={`url(#${s.grad})`} fillRule="nonzero" />
                  </g>
                ))}
              </g>
            ))}
          </g>

          {/* 12 sprigs BEFORE the wood, with their butts on the bough's own centreline. Drawn
              after it they showed a flat butt cut sitting on the bark in a different tone — a
              twig glued to a pipe. */}
          {sprigs.map((s) => (
            <g key={s.seed} transform={`translate(${s.x} ${s.y}) rotate(${s.rot}) scale(${s.scale})`}>
              <path
                d={s.geom.body}
                fill={`url(#${gradId(1, litUpAt(s.rot), bucketOfHalf(s.geom.baseHalf))})`}
                fillRule="nonzero"
              />
            </g>
          ))}

          {/* 13 THE WOOD, and the draw order is the whole trick: far limb, near limb, TRUNK over
              both. Behind them the trunk left a shallow X under the nest — the main limb crossed
              the far limb and the trunk at 26 degrees and read as a dark strap laid over the
              picture, and four members radiating from one hidden point read as a turbine. In
              front, the trunk covers the crossing and each limb simply passes behind it and comes
              out the other side, which is what a limb attached to a trunk does. It also means no
              butt cap on either limb is ever drawn in the open.

              It carries the SAME bark gradient as the main limb, which is a correction: the old flat
              #41301A was chosen because "the bark gradient is fixed in world space" and would light a
              second limb wrongly. That was wrong — cbBark is `userSpaceOnUse` on y -9.4..9.4, and
              user space for a path is the group's own frame, so the ramp lies across whichever twig
              references it and turns with it. Flat fill was what made this arm read as a cast shadow
              rather than as wood. The overlay below is what keeps it from reading as the SAME wood:
              a far arm of a fork is in its own shade, and 0.22 of #2A1A0A over the ramp is a stop and
              a half down the same material instead of a different one. */}
          <g transform={BOUGH2_XF}>
            <path d={BOUGH2_GEOM.body} fill="url(#cbBarkUp)" fillRule="nonzero" />
            {/* 0.3 down to 0.14. That number was set when this arm was a FAR arm falling away from
                a crook and had to sit a stop and a half back. It is now the limb that leaves the
                trunk in the nest's own plane, and at 0.3 it read as a dark ramp. */}
            <path d={BOUGH2_GEOM.body} fill="#2A1A0A" fillRule="nonzero" opacity={0.2} />
          </g>
          <g clipPath="url(#cbLimbClip)">
            <g transform={BOUGH2_XF}>
              {limbGrain.map((g) => (
                <g
                  key={g.seed}
                  transform={`translate(${(g.s * BOUGH2.len).toFixed(1)} ${g.off}) rotate(${g.rot})`}
                >
                  <path d={g.geom.body} fill={NEST_RAMP[g.rung].hex} fillRule="nonzero" opacity={g.op} />
                </g>
              ))}
            </g>
          </g>
          <g transform={BOUGH_XF}>
            <path d={BOUGH_GEOM.body} fill="url(#cbBarkUp)" fillRule="nonzero" />
          </g>

          {/* 13b THE TRUNK, drawn IN FRONT of both limbs and that order is the whole point. Behind
              them it made a shallow X under the nest: the main limb crossed the far limb and the
              trunk at 26 degrees and read as a dark strap laid over the picture, and the four
              members radiating from one hidden point read as a turbine. In front, the trunk simply
              covers the crossing, and each limb is a limb that goes behind the trunk and comes out
              the other side — which is what a limb does. */}
          <g transform={TRUNK_XF}>
            <path d={TRUNK_GEOM.body} fill="url(#cbBarkUp)" fillRule="nonzero" />
            {/* A whisper of the sky's own haze. Not aerial perspective — the trunk is a metre
                behind the nest, not a kilometre — but a 240px vertical must not turn into a black
                bar, and there is a harder constraint underneath: the bird's exit leg crosses this
                column at world (2440, 640) around frame 120, and at 0.06 the trunk's shaded flank
                measured luma 40 against a bird whose ink is 45 — the bird dissolved into it for
                about eight frames. 0.13 lifts the shaded flank to ~63 and buys ~18 luma of
                separation while leaving the lit flank 70 below the sky. */}
            <path d={TRUNK_GEOM.body} fill="#F6E3BC" fillRule="nonzero" opacity={0.13} />
          </g>

          {/* Trunk bark. A 240px column with one smooth cross-thickness ramp and two dead-straight
              flanks over 1600px is a ceramic pillar, and that is exactly what it rendered as. Long
              rods laid ALONG the wood and clipped to its own silhouette, so they can only ever be
              marks on the surface. Stated as a fraction along and an offset across in the trunk's
              OWN frame; the visible run is s 0.35..0.70, which is where all six sit. */}
          <g clipPath="url(#cbTrunkClip)">
            <g transform={TRUNK_XF}>
              {trunkGrain.map((g) => (
                <g
                  key={g.seed}
                  transform={`translate(${(g.s * TRUNK.len).toFixed(1)} ${g.off}) rotate(${g.rot})`}
                >
                  <path d={g.geom.body} fill={NEST_RAMP[g.rung].hex} fillRule="nonzero" opacity={g.op} />
                </g>
              ))}
            </g>
            {/* The nest's own shade ON the trunk. This is the mark that says the two objects are
                touching rather than overlapping: without it the nest's right end simply stopped
                against a lit column. Clipped to the trunk, so it can never darken bare sky. */}
            <g filter="url(#cbContact)">
              <ellipse cx={2360} cy={1180} rx={300} ry={190} fill="#2A1A0A" opacity={0.4} />
            </g>
          </g>

          {/* 14 BARK, clipped to the limb. This is what the diagonal was missing: it was one smooth
              cross-thickness ramp with a single soft highlight, so at 1:1 it read as a polished
              leather strap or a chocolate bar — a material unrelated to the straw sitting on it.
              Four long rods laid along the wood, two dark and two lit, at 0.4-0.5 alpha. Placed in
              the BOUGH's own local frame (fraction along, offset across) so they cannot slide off
              it, and clipped so they can only ever be marks on the surface. */}
          <g clipPath="url(#cbWood)">
            <g transform={BOUGH_XF}>
              {grain.map((g) => (
                <g
                  key={g.seed}
                  transform={`translate(${(g.s * BOUGH.len).toFixed(1)} ${g.off}) rotate(${g.rot})`}
                >
                  <path
                    d={g.geom.body}
                    fill={NEST_RAMP[g.rung].hex}
                    fillRule="nonzero"
                    opacity={g.op}
                  />
                </g>
              ))}
            </g>
          </g>

          {/* 15 the load, three soft marks clipped to the wood, following the limb's real top edge.
              Strand-shaped cast shadows were tried here and were indistinguishable from more dark
              splinters; they made the lit face look littered, and they cost a 1300x520 blur plus
              470 redundant path draws a frame. */}
          <g clipPath="url(#cbWood)">
            <g filter="url(#cbContact)">
              <ellipse
                cx={2250}
                cy={1290}
                rx={520}
                ry={90}
                transform="rotate(19 2250 1290)"
                fill="#2A1A0A"
                opacity={0.46}
              />
              <ellipse cx={1950} cy={1160} rx={260} ry={55} fill="#201306" opacity={0.2} />
              <ellipse cx={2700} cy={1430} rx={300} ry={60} fill="#201306" opacity={0.18} />
            </g>
          </g>

          {/* 16 strands lashed across the bough: the bough is occluded by the nest above the
              contact AND crossed by wood below it, which is what stops the mass floating. */}
          {lashings.map((s) => (
            <g key={s.seed} transform={`translate(${s.x} ${s.y}) rotate(${s.rot})`}>
              <path
                d={s.geom.body}
                fill={`url(#${gradId(4, litUpAt(s.rot), bucketOfHalf(s.geom.baseHalf))})`}
                fillRule="nonzero"
              />
            </g>
          ))}

          {/* 17-18 the near wall and the near rim, IN FRONT of the wood */}
          {[1, 2].map((li) => (
            <g key={li} filter={`url(#cbSh${li})`}>
              {LAYERS[li].map(([bucket, group]) => (
                <g
                  key={bucket}
                  transform={`rotate(${f4(bucketAt(theta, bucket, frame))} ${BUCKET_PIVOT.x} ${BUCKET_PIVOT.y})`}
                >
                  {group.map((s) => (
                    <g key={s.i} transform={s.transform}>
                      <path d={s.geom.body} fill={`url(#${s.grad})`} fillRule="nonzero" />
                    </g>
                  ))}
                </g>
              ))}
            </g>
          ))}

          {/* 19 the strand the flying twig becomes. Present at EVERY frame of the loop, at the
              same pose and the same scale the falling twig lands at, so the cross-fade is a
              no-op and nothing in the loop ever appears or disappears. */}
          <g filter="url(#cbSh2)">
            <g transform={`rotate(${f4(bucketAt(theta, 0, frame))} ${BUCKET_PIVOT.x} ${BUCKET_PIVOT.y})`}>
              <g
                transform={`translate(${SETTLED.x} ${SETTLED.y}) rotate(${SETTLED.deg}) scale(${TWIG_SCALE.toFixed(4)})`}
              >
                <path d={hero.body} fill={`url(#${heroGrad})`} fillRule="nonzero" />
              </g>
            </g>
          </g>
        </g>
        </g>
        {/* 20 ------------------------ RIGID SWAY GROUP AND CAMERA CLOSE */}

        {/* 21 the falling twig, in world space, with its contact shadow on the nest */}
        {!carrying && shadowOp > 0.004 ? (
          <ellipse
            cx={shadowX}
            cy={target.y + 22}
            rx={shadowRx}
            ry={shadowRy}
            fill="#2A1A0A"
            opacity={shadowOp}
            filter="url(#cbDrop)"
          />
        ) : null}
        {heroOpacity > 0 ? (
          /* The separation filter has to sit on an OUTER group with NO transform of its own. A
             userSpaceOnUse region on the transformed group is interpreted in the group's LOCAL
             space — the twig's own 0..225 units — so a region typed in canvas coordinates misses
             the content entirely and the twig renders as nothing at all. It did, for one render. */
          <g filter={carrying ? undefined : 'url(#cbTwigFall)'} opacity={carrying ? 1 : heroOpacity}>
            <g
              transform={
                carrying
                  ? `${mStr(carriedM)}`
                  : `translate(${fx.toFixed(1)} ${fy.toFixed(1)}) rotate(${fdeg.toFixed(2)}) scale(${fscale.toFixed(4)})`
              }
            >
              <path d={hero.body} fill={`url(#${heroGrad})`} fillRule="nonzero" />
            </g>
          </g>
        ) : null}

        {/* 22 the bird, over its own twig */}
        <Bird pose={pose} />

        {/* 23 the near plane, in FRONT of everything: two branches close to the lens, blurred, that
            fill the safe box's empty bottom-left corner and put a third plane in the frame. */}
        {nearPlane.map((b, i) => (
          <g key={b.seed} filter={`url(#cbNear${i === 0 ? '' : '2'})`} opacity={b.op}>
            <g transform={`translate(${b.x} ${b.y}) rotate(${b.rot}) scale(${b.scale})`}>
              <path d={b.geom.body} fill="#452F16" fillRule="nonzero" />
            </g>
          </g>
        ))}

        {/* 24 vignette, 25 dither. The dither is 0.075 and not 0.055: MEASURED through the encoder
            the source PNG's detrended noise of 1.24-1.57 LSB came out at 0.36-0.56, the longest
            flat run on a sky scanline went from 4-8px to 91-124px, and what replaced the dither was
            a correlated macroblock quilt. Half of that is the encode (see render.mjs — CRF 14,
            lossless PNG intermediates instead of JPEG, bt709) and half is having enough amplitude
            in the source to survive quantisation at all. */}
        <rect x={0} y={0} width={W} height={H} fill="url(#cbVig)" />
        <rect
          x={0}
          y={0}
          width={W}
          height={H}
          fill="url(#cbGrain)"
          opacity={0.075}
          style={{mixBlendMode: 'multiply'}}
        />

        {/* 26 the wordmark. LEFT of the nest and LOCKED TO IT: measured on a real render the ink is
            x 1155..1982, y 787..962, and the nest's is x 2027..2730, y 787..1114. The two share a
            TOP LINE at 787 — the word's cap-top is the nest's crown — and the word's baseline sits
            7px off the nest's own vertical centre. Horizontally it butts the silhouette rather than
            standing clear of it: standing it clear at size 200 with a ~200px gap was rendered and
            gave two unrelated objects with a hole between them, and the type went straight back to
            reading as a caption. 58px inside the safe box's left edge, 190px above its floor.
            It is the last thing in the composition and nothing, including proximity, may enter its
            rectangle: the audit tests the bird against WORD_GUARD, the ink grown by 70px, which is
            why waypoints 1-9 fly ~100px higher than they did before the word came up. */}
        <text
          x={WORD.left}
          y={WORD.baseline}
          fontFamily="Georgia, 'Times New Roman', serif"
          fontWeight={600}
          fontSize={WORD.size}
          letterSpacing={WORD.track * WORD.size}
          fill={INK}
        >
          NOOK
        </text>

        {DEBUG ? (
          <g fontFamily="monospace" fontSize={38} fill="#B00000">
            <text x={40} y={1478}>
              {`onCanvas=${AUDIT.onCanvas}/180 inSafe=${AUDIT.inSafe} onWORD=[${AUDIT.wordFrames.join(',')}] onNEST=[${AUDIT.nestFrames.join(',')}] off=[${AUDIT.offRun.join(',')}]`}
            </text>
            <text x={40} y={1525}>
              {`whole=${AUDIT.wholeInSafe} clipped=${AUDIT.clipped} nest=[${AUDIT.nest.join(',')}] px/frame ${AUDIT.minSpeed.toFixed(1)}..${AUDIT.maxSpeed.toFixed(1)} minAbsRoll=${AUDIT.minAbsRoll.toFixed(3)} maxRollStep=${AUDIT.maxRollStep.toFixed(3)} strands=${AUDIT.strands} oob=${AUDIT.outOfBounds} belowSeat=${AUDIT.belowSeat}`}
            </text>
            <text x={40} y={1572}>
              {`uFlare=${U_FLARE.toFixed(4)} rel=${REL_FRAME.toFixed(1)} land=${LAND_FRAME.toFixed(1)} pathLen=${PATH.total.toFixed(0)} WORDink=[${WORD_RECT.x0.toFixed(0)},${WORD_RECT.y0.toFixed(0)},${WORD_RECT.x1.toFixed(0)},${WORD_RECT.y1.toFixed(0)}] nestNearWord=${AUDIT.nestNearWord.toFixed(1)}@${AUDIT.nearFrame}`}
            </text>
            <text x={40} y={1619}>
              {`birdHi=[${AUDIT.binHi.map((v) => (isFinite(v) ? v.toFixed(0) : '-')).join(',')}] birdLo=[${AUDIT.binLo.map((v) => (isFinite(v) ? v.toFixed(0) : '-')).join(',')}]  (x 1000..2800 by 200)`}
            </text>
          </g>
        ) : null}

        {guides ? (
          <g>
            <rect
              x={SAFE.x0}
              y={SAFE.y0}
              width={SAFE.x1 - SAFE.x0}
              height={SAFE.y1 - SAFE.y0}
              fill="none"
              stroke="#FF00FF"
              strokeWidth={4}
            />
            <rect
              x={WORD_RECT.x0}
              y={WORD_RECT.y0}
              width={WORD_RECT.x1 - WORD_RECT.x0}
              height={WORD_RECT.y1 - WORD_RECT.y0}
              fill="none"
              stroke="#00A000"
              strokeWidth={4}
            />
          </g>
        ) : null}
      </svg>

    </AbsoluteFill>
  );
};
