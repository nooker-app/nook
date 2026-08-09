import {Easing, interpolate} from 'remotion';
import {CANVAS} from './theme';

/// NOOK'S MOTION DESIGN SYSTEM.
///
/// Every number here was paid for. This file is the distillate of the header and the search assets:
/// the rules that survived being rendered and looked at, with the measurement that decided each one.
/// It exists so the next asset starts where this one finished instead of rediscovering the same
/// failures — which happened repeatedly, and is the reason it is a code module and not a document. A
/// document describes the system; this one IS the system, and an asset that ignores it has to do so
/// visibly.

/* ------------------------------------------------------------------ 1. THE FRAME */

export const SAFE = (canvas: {width: number; height: number; safe: {width: number; height: number}}) => ({
  x0: (canvas.width - canvas.safe.width) / 2,
  y0: (canvas.height - canvas.safe.height) / 2,
  x1: (canvas.width + canvas.safe.width) / 2,
  y1: (canvas.height + canvas.safe.height) / 2,
  w: canvas.safe.width,
  h: canvas.safe.height,
});

export const HEADER_SAFE = SAFE(CANVAS.header);
export const SEARCH_SAFE = SAFE(CANVAS.search);

/// Nothing that has to be understood sits within this of a safe-area edge. Measured, not chosen: the
/// wordmark's ink flush against the safe box's left edge rendered the N as a sliced stem in the
/// guaranteed crop, and 55px was the smallest inset at which it read as placed rather than cropped.
export const SAFE_INSET = 55;

/* ------------------------------------------------------------------ 2. TYPE */

/// Cap height as a fraction of the guaranteed height, which is the only scale that means anything —
/// px on a 3840 canvas says nothing about what a person sees.
///
///   0.138  the header's wordmark before this system. Read as a caption on someone else's picture,
///          and was rejected twice in those words.
///   0.26   where it landed after the ceiling was found. That ceiling is not the safe box: the nest's
///          ink starts at x 1971, the word has to keep the same 70px clearance everything else keeps,
///          and 1901 - 1097 = 804px of width is size 208 at this face's 3.86:1 ink ratio.
///   0.30   tried, centred, and it fails for a reason arithmetic makes plain — stacked, the safe box's
///          659px must hold the cap (198) plus its clearances (140) plus a lane for the bird (~140)
///          plus the nest (~290) = 768. Over-constrained by 109px.
export const CAP_FRACTION = {floor: 0.2, target: 0.26, ceiling: 0.3};

/// The search canvas's type, in px, from the illustrated cut. Title and subtitle are a pair; changing
/// one without the other breaks the only hierarchy the frame has.
export const TYPE = {
  title: 168,
  titleLead: 1.1,
  titleWeight: 800,
  titleTracking: '-0.02em',
  sub: 70,
  subWeight: 600,
  /// Distance from the title block's top to the subtitle's, per title line.
  linePitch: 185,
} as const;

/// SVG applies letterSpacing after EVERY glyph including the last, so an N-letter word gains N times
/// the tracking and not N-1. The wordmark's ink ratio was wrong on both terms until this was measured
/// off a render: 3.14 untracked, not 3.86, and 3 gaps in a four-letter word, not 4.
export const inkRatio = (untracked: number, letters: number, track: number) =>
  untracked + (letters - 1) * track;

export const UI =
  "-apple-system, 'SF Pro Display', 'Apple SD Gothic Neo', 'Helvetica Neue', Helvetica, sans-serif";
export const SERIF = "Georgia, 'Times New Roman', serif";

/* ------------------------------------------------------------------ 3. COLOUR */

/// Two families, and they do not mix inside one asset.
///
/// PHOTO is the header's world — a lit scene with depth, where wood is shaded and the sky is a
/// gradient. FLAT is the search asset's — one saturated ground, no gradients, no perspective, in the
/// language of Apple's own editorial cards.
///
/// Putting one element of one family inside the other is the single most reliable way to make a frame
/// look wrong: `twig.ts` renders beautiful tapered wood for PHOTO, and dropped onto FLAT it read as a
/// heap of scratchy debris. Flat illustration works by leaving things out.
export const PHOTO = {
  ink: '#2B1A0E',
  bark: '#5C3A18',
  strawLight: '#F0D5A6',
  skyHigh: '#FFF9EA',
  skyLow: '#E9C892',
} as const;

export const FLAT = {
  field: '#8A4B2A',
  cream: '#FFF3DC',
  ink: '#2B1A0E',
  gold: '#F0B865',
  sage: '#9DAE86',
  clay: '#D9714B',
  /// For beats that carry dark-mode footage. The recordings are dark and the field is not; taking the
  /// GROUND dark with them turns a mismatch into the app's appearance following the reader, which is
  /// also how the header says the app has a dark mode without a caption claiming it.
  fieldDark: '#2A1509',
} as const;

/* ------------------------------------------------------------------ 4. TIME */

/// The house curve. Remotion's guidance is to keep `interpolate` inline in the style prop with an
/// easing, and this is the one to reach for; `Easing.spring` is banned here because a spring is not
/// periodic and cannot be reasoned about at a loop seam.
export const CURVE = Easing.bezier(0.16, 1, 0.3, 1);

/// Beat-local progress, 0..1. Every asset here is a list of beats over a fixed frame count rather than
/// a TransitionSeries, because a beat needs to know where it sits on the ABSOLUTE timeline: inside a
/// TransitionSeries.Sequence `useCurrentFrame()` restarts at 0, and anything periodic keyed to that
/// pops at every cut and again at the seam.
export const beatT = (frame: number, from: number, to: number) => (frame - from) / (to - from);

/// The standard entrance and exit, as fractions of a beat. An element enters over the first tenth and
/// leaves over the last seventh; staggered siblings are 0.12 apart, which is what reads as "one at a
/// time" rather than "a list appearing".
export const ENTER = 0.1;
export const EXIT = 0.14;
export const STAGGER = 0.12;

export const enterAt = (t: number, delay = 0) =>
  interpolate(t, [delay, delay + ENTER], [0, 1], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
    easing: CURVE,
  });

/// A quantity that must be identical at frame 0 and frame N. Anything that moves across the seam has
/// to be built from this, not from an eased ramp.
export const periodic = (frame: number, total: number) => (frame / total) * Math.PI * 2;

/// Verifying a seam: frame 0 and the last frame should NOT be identical — they should differ by one
/// frame of motion. Compare the seam's frame-to-frame difference against a mid-loop baseline. Measured
/// this way the shipped header changes 70,067 px across the seam against 69,497 on the step before it.
///
/// And never track a fading object by colour threshold. A SAGE card at alpha 0.65 composited over the
/// hollow falls outside any tolerance tight enough to be useful; two separate measurements said a card
/// had vanished when it was plainly still on screen.

/* ------------------------------------------------------------------ 5. SHOWING THE APP */

/// THE PANEL RULE, and it is the most expensive lesson in this project.
///
/// An iPhone capture is 1320x2868 — a 1:2.17 portrait object — and the search canvas's guaranteed box
/// is 2167x1029, which is 2.1:1 landscape. Fitting the capture inside that box puts it at scale 0.26:
/// 340px wide, 16% of the box, and the app's own 17pt body type lands at 13 canvas px, which is 4px at
/// the ~1200px the store draws this asset. Not "small" — invisible. Four separate layouts died on it.
///
/// So a panel is scaled to a WIDTH and allowed to run off the bottom of the canvas, exactly as Apple's
/// own screenshot cards crop their devices. At 2300px that is 1.74x, the app's body type is 89 canvas
/// px and ~28px as drawn, and the part of the screen that carries the claim — the top third — is the
/// part that stays.
export const PANEL_W = 2300;
export const PANEL_SCALE = (srcW: number) => PANEL_W / srcW;

/// Where the panel's top edge goes: under the type, with enough of it inside the guaranteed box that a
/// crop to the safe area still shows type over a real piece of screen rather than type over a sliver.
export const panelTop = (safe: ReturnType<typeof SAFE>, titleLines: number) =>
  safe.y0 + 40 + titleLines * TYPE.linePitch + TYPE.sub * 1.6;

/// The app's own body type in a capture, in source px, for checking a panel is big enough to read.
export const APP_BODY_PX = 51;
/// What the store is assumed to draw the asset at. Everything legibility is judged against this.
export const STORE_WIDTH = 1200;
export const atStoreScale = (canvasPx: number, canvasW = CANVAS.search.width) =>
  (canvasPx * STORE_WIDTH) / canvasW;

/* ------------------------------------------------------------------ 6. DEPTH */

/// Three rules about draw order, each of which cost a round of "why did that just disappear".
///
/// 1. A LAYER SWAP MUST HAPPEN WHERE NOTHING OVERLAPS. An object that changes which side of another
///    object it is drawn on pops unless, at that instant, the two do not overlap on screen. Cards move
///    from in-front to inside the nest at a hover point above the opening, where the near wall is not
///    between them and the viewer, so the change moves no pixels.
///
/// 2. LIST EVERYTHING IN FRONT, NOT THE ONE YOU SUSPECT. "The near wall starts below the arc, so a
///    card above the arc cannot be occluded" was proved and wrong: three sticks SPANNED the opening
///    and were nowhere near the near wall. Later the same shape of error again, twice.
///
/// 3. STACK BY PROGRESS, NOT BY INDEX. Falling objects drawn in array order let an arriving card land
///    underneath one already in the pile. Sort by how far along each is.
///
/// And when an occlusion boundary is computed from nominal dimensions it will not match the drawn
/// silhouette: a trunk with a nominal 288 half-width tapers to 283 where it matters, so a limb cut
/// exactly at the nominal flank left a hairline of sky between wood and wood. Cut into the covering
/// object, not against its edge.
export const OVERLAP_MARGIN = 120;

/* ------------------------------------------------------------------ 7. WHAT THE SLOT IS FOR */

/// Apple asks the search asset to "state the obvious — be sure your app's purpose is obvious at a
/// glance", and to "showcase the firsthand experience... the interface, content, or gameplay".
///
/// Both are testable, and an asset that cannot pass them is not finished:
///   - Cover everything but the first beat. Does a stranger learn what the app IS, not what makes it
///     special? A differentiator in the headline answers the wrong question.
///   - Is there a real screen on the frame at all?
export const SLOT_TEST = ['purpose obvious in the first beat', 'a real interface on screen'] as const;
