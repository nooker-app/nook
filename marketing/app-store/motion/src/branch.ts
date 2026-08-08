import {seeded} from './theme';

/// A branch that looks like a branch.
///
/// Stroked bézier paths with round caps gave uniform capsules: the same thickness end to
/// end, a single smooth bend, and a blunt stop wherever they were clipped. Real twigs taper
/// to nothing at the tip, kink rather than curve, and are never the same width twice.
///
/// So a branch is built as an outline instead of a stroke: a centre line walked in small
/// steps with a little jitter at each, and a half-width that falls to zero at both ends. It
/// is a filled path, which also means it can never be sliced flat by a clip edge — the tips
/// are already points.
export const branchPath = ({
  x0,
  y0,
  x1,
  y1,
  bend,
  width,
  seed,
  segments = 26,
}: {
  x0: number;
  y0: number;
  x1: number;
  y1: number;
  /// Perpendicular offset at the middle, as a fraction of length.
  bend: number;
  /// The widest half-width, reached around a third of the way along.
  width: number;
  seed: number;
  segments?: number;
}): string => {
  const random = seeded(seed);
  const dx = x1 - x0;
  const dy = y1 - y0;
  const length = Math.hypot(dx, dy);
  const nx = -dy / length;
  const ny = dx / length;

  const centre: {x: number; y: number}[] = [];
  for (let i = 0; i <= segments; i++) {
    const t = i / segments;
    // One broad bend plus a slow wander, so it reads as grown rather than drawn with a
    // compass.
    const arc = Math.sin(t * Math.PI) * bend * length;
    const wander = Math.sin(t * Math.PI * 3 + seed) * width * 0.9 + (random() - 0.5) * width * 0.5;
    centre.push({
      x: x0 + dx * t + nx * (arc + wander),
      y: y0 + dy * t + ny * (arc + wander),
    });
  }

  // Thickest a third along, tapering to a point at both ends — the taper is what stops it
  // looking like a drawn line.
  const halfWidth = (t: number) => {
    const shape = Math.sin(Math.PI * Math.pow(t, 0.72));
    return Math.max(0.6, width * shape * (0.82 + random() * 0.36));
  };

  const left: string[] = [];
  const right: string[] = [];
  for (let i = 0; i <= segments; i++) {
    const t = i / segments;
    const w = halfWidth(t);
    const point = centre[i];
    const previous = centre[Math.max(0, i - 1)];
    const next = centre[Math.min(segments, i + 1)];
    const tx = next.x - previous.x;
    const ty = next.y - previous.y;
    const len = Math.hypot(tx, ty) || 1;
    const px = -ty / len;
    const py = tx / len;
    left.push(`${point.x + px * w} ${point.y + py * w}`);
    right.push(`${point.x - px * w} ${point.y - py * w}`);
  }

  return `M ${left.join(' L ')} L ${right.reverse().join(' L ')} Z`;
};
