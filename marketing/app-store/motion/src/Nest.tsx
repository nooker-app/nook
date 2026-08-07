import React from 'react';
import {interpolate, useCurrentFrame, useVideoConfig} from 'remotion';
import {PALETTE, seeded} from './theme';

export type Strand = {
  d: string;
  width: number;
  colour: string;
  opacity: number;
  drift: number;
  phase: number;
};

/// The nest, as strands crossing at spread angles.
///
/// Apple's own examples for these assets — Forest Explorer, Airline, The Coast — are flat
/// illustrated scenes of the world the icon promises, with the app's name set into them.
/// Nook's icon is a nest of gathered strands, and the app is named for the same idea, so
/// that is what this draws. An earlier attempt used long parallel sweeps and read as
/// stripes; the angles are what make it a nest.
export const buildNest = ({
  centreX,
  centreY,
  radius,
  count,
  seed,
}: {
  centreX: number;
  centreY: number;
  radius: number;
  count: number;
  seed: number;
}): Strand[] => {
  const random = seeded(seed);
  const strands: Strand[] = [];
  for (let layer = 0; layer < 3; layer++) {
    const depth = layer / 2;
    for (let i = 0; i < count; i++) {
      // Even across the width, jittered — not purely random, which left the mass sitting
      // off to one side of a composition that is centred.
      const slot = (i + 0.5) / count - 0.5;
      const offsetX = (slot * 2.1 + (random() - 0.5) * 0.35) * radius;
      const offsetY = (random() - 0.5) * radius * 0.62 - depth * radius * 0.05;

      // Most strands hold the shape — ends above the middle, and the end further from the
      // centre the higher of the two — because when they all curved as chance decided, the
      // pile read as something dropped rather than something built. But when every one of
      // them lifted, it read as a woven basket instead of a nest, so a third are left to
      // lie as they fall: near straight, leaning either way. Screen y grows downwards, so a
      // positive bow dips the middle, and the sign of the angle decides which end is outer.
      const holdsShape = random() < 0.66;
      const raw = Math.abs((random() - 0.5) * Math.PI * 0.42);
      const angle =
        holdsShape && Math.abs(slot) > 0.12
          ? raw * (slot < 0 ? 1 : -1)
          : (random() - 0.5) * Math.PI * 0.42;
      const length = radius * (1.05 + random() * 1.15);
      const bow = holdsShape
        ? radius * (0.10 + random() * 0.24)
        : radius * (random() * 0.08 - 0.03);
      const width = radius * (0.075 + random() * 0.085) * (1 - depth * 0.25);
      const midX = centreX + offsetX;
      const midY = centreY + offsetY;
      const dx = (Math.cos(angle) * length) / 2;
      const dy = (Math.sin(angle) * length) / 2;
      strands.push({
        d: `M ${midX - dx} ${midY - dy} C ${midX - dx * 0.35} ${midY - dy * 0.35 + bow}, ${
          midX + dx * 0.35
        } ${midY + dy * 0.35 + bow}, ${midX + dx} ${midY + dy}`,
        width,
        colour: PALETTE.strands[Math.floor(random() * PALETTE.strands.length)],
        opacity: 1 - depth * 0.22,
        // How far this strand breathes, and where in the cycle it starts, so the nest
        // settles rather than pulsing as one piece.
        drift: radius * (0.012 + random() * 0.03),
        phase: random() * Math.PI * 2,
      });
    }
  }
  return strands;
};

export const Nest: React.FC<{
  width: number;
  height: number;
  centreY: number;
  radius: number;
  count: number;
  seed: number;
}> = ({width, height, centreY, radius, count, seed}) => {
  const frame = useCurrentFrame();
  const {durationInFrames} = useVideoConfig();
  // One turn of the loop, so the last frame meets the first without a jump.
  const cycle = (frame / durationInFrames) * Math.PI * 2;

  const strands = React.useMemo(
    () => buildNest({centreX: width / 2, centreY, radius, count, seed}),
    [width, centreY, radius, count, seed]
  );

  // Long, faint strands running off both edges, so the frame is not empty paper wherever
  // the store crops it.
  const sweeps = React.useMemo(() => {
    const random = seeded(seed + 7);
    return new Array(6).fill(0).map((_, index) => {
      const t = index / 5;
      const y = centreY + (t - 0.5) * radius * 1.9;
      return {
        d: `M ${-width * 0.05} ${y - radius * 0.22} C ${width * 0.32} ${y + radius * 0.3}, ${
          width * 0.68
        } ${y - radius * 0.26}, ${width * 1.05} ${y + radius * 0.18}`,
        width: radius * (0.05 + 0.03 * t),
        phase: random() * Math.PI * 2,
      };
    });
  }, [width, centreY, radius, seed]);

  return (
    <svg
      width={width}
      height={height}
      viewBox={`0 0 ${width} ${height}`}
      style={{position: 'absolute', inset: 0}}
    >
      <defs>
        <radialGradient id="lamp" cx="50%" cy="50%" r="50%">
          <stop offset="0%" stopColor={PALETTE.glow} stopOpacity={1} />
          <stop offset="100%" stopColor={PALETTE.glow} stopOpacity={0} />
        </radialGradient>
        <filter id="soft" x="-20%" y="-20%" width="140%" height="140%">
          <feDropShadow
            dx="0"
            dy={radius * 0.03}
            stdDeviation={radius * 0.05}
            floodColor="#5A3E1B"
            floodOpacity="0.24"
          />
        </filter>
      </defs>

      <ellipse
        cx={width / 2}
        cy={centreY}
        rx={radius * 3.4}
        ry={radius * 2.6}
        fill="url(#lamp)"
        opacity={interpolate(Math.sin(cycle), [-1, 1], [0.55, 0.95])}
      />

      {sweeps.map((sweep, index) => (
        <path
          key={`sweep-${index}`}
          d={sweep.d}
          stroke="#C59B60"
          strokeOpacity={0.22}
          strokeWidth={sweep.width}
          strokeLinecap="round"
          fill="none"
          transform={`translate(0 ${Math.sin(cycle + sweep.phase) * radius * 0.02})`}
        />
      ))}

      <g filter="url(#soft)">
        {strands.map((strand, index) => (
          <path
            key={index}
            d={strand.d}
            stroke={strand.colour}
            strokeOpacity={strand.opacity}
            strokeWidth={strand.width}
            strokeLinecap="round"
            fill="none"
            transform={`translate(0 ${Math.sin(cycle + strand.phase) * strand.drift})`}
          />
        ))}
      </g>
    </svg>
  );
};
