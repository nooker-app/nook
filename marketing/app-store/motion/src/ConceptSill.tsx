import React from 'react';
import {AbsoluteFill, useCurrentFrame, useVideoConfig} from 'remotion';
import {branchPath} from './branch';
import {sillCopy} from './copy';
import {CANVAS, PALETTE, seeded} from './theme';

/// Concept B — "The Sill".
///
/// You are looking out from inside a quiet room. A wide low window whose lattice *is* the
/// nest — woven branches arching over the top and down the sides — leaves a clear bowl of
/// sky in the middle where the name sits. Below the sill line, in the near foreground, an
/// open page of real type lies in a shaft of light, and the striped shadow of the branches
/// crawls across it as the hour turns from late morning to golden and back.
///
/// This is the pictorial answer to the same two failures: the nest is not an object
/// floating in a frame, it *is* the frame — window lattice and sheltering canopy at once,
/// deliberately leaving a clear bowl for the name it holds — and the page on the sill says
/// "reading" without a device or a screenshot anywhere in it.
const VPX = 1920;
const VPY = -1800;
const YREF = 950;

/// Scale at a screen row, and the projection of a far-edge x onto it. Every coordinate
/// below the horizon comes from here: three separate things imply depth in this frame — the
/// sill, the page and the shadow's shear — and when they disagree it reads as clip art.
const scaleAt = (y: number) => (y - VPY) / (YREF - VPY);
const px = (x: number, y: number) => VPX + (x - VPX) * scaleAt(y);

const lerp = (a: number, b: number, t: number) => a + (b - a) * t;

const mixHex = (from: string, to: string, t: number) => {
  const parse = (hex: string) => [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16));
  const [r1, g1, b1] = parse(from);
  const [r2, g2, b2] = parse(to);
  // Through linear light rather than straight sRGB: the sky's top stop travels a long way,
  // and a straight lerp takes it through grey-tan on the way.
  const toLinear = (v: number) => (v / 255) ** 2.2;
  const toSrgb = (v: number) => Math.round(255 * v ** (1 / 2.2));
  const channel = (a: number, b: number) => toSrgb(lerp(toLinear(a), toLinear(b), t));
  return `rgb(${channel(r1, r2)}, ${channel(g1, g2)}, ${channel(b1, b2)})`;
};

type Branch = {d: string; width: number; colour: string; tier: 'far' | 'mid' | 'near'};

const buildLattice = (): Branch[] => {
  const random = seeded(0x4e6f);
  const branches: Branch[] = [];
  const tiers: {tier: Branch['tier']; count: number; scale: number}[] = [
    {tier: 'far', count: 5, scale: 0.7},
    {tier: 'mid', count: 5, scale: 1},
    {tier: 'near', count: 4, scale: 1.15},
  ];
  // The bowl the name lives in. No branch may cross it.
  const bowl = {x0: 1450, x1: 2390, y0: 540, y1: 840};
  const insideBowl = (x: number, y: number) =>
    x > bowl.x0 && x < bowl.x1 && y > bowl.y0 && y < bowl.y1;

  for (const {tier, count, scale} of tiers) {
    for (let i = 0; i < count; i++) {
      let attempt = 0;
      while (attempt < 40) {
        attempt++;
        // Midpoints ride an ellipse over the aperture, so the lattice arches rather than
        // lying flat across it.
        const phi = ((200 + random() * 140) * Math.PI) / 180;
        const mx = 1920 + Math.cos(phi) * 1620;
        const my = 1010 + Math.sin(phi) * 790;
        const tangent = phi + Math.PI / 2 + ((random() - 0.5) * 44 * Math.PI) / 180;
        const length = 620 + random() * 780;
        const dx = (Math.cos(tangent) * length) / 2;
        const dy = (Math.sin(tangent) * length) / 2;
        const x0 = mx - dx;
        const y0 = my - dy;
        const x1 = mx + dx;
        const y1 = my + dy;
        // Twigs bend; capsules do not — and at 3% the bend was invisible, which left a
        // scatter of straight sticks rather than a woven arch.
        const bend = length * (0.12 + random() * 0.10);
        const cx = mx + Math.cos(tangent + Math.PI / 2) * bend;
        const cy = my + Math.sin(tangent + Math.PI / 2) * bend;

        let clear = true;
        for (let s = 0; s <= 60; s++) {
          const t = s / 60;
          const bx = (1 - t) * (1 - t) * x0 + 2 * (1 - t) * t * cx + t * t * x1;
          const by = (1 - t) * (1 - t) * y0 + 2 * (1 - t) * t * cy + t * t * y1;
          if (insideBowl(bx, by)) {
            clear = false;
            break;
          }
        }
        if (!clear) continue;

        const width = (22 + random() * 24) * scale;
        branches.push({
          // An outline rather than a stroke: stroked capsules were uniform end to end and
          // stopped flat wherever the clip caught them. These taper to a point, so a tip is
          // a tip whichever way it leaves the frame.
          d: branchPath({
            x0,
            y0,
            x1,
            y1,
            bend: 0.10 + random() * 0.08,
            width: width / 2,
            seed: 0x4e6f + branches.length * 91,
          }),
          width,
          colour: PALETTE.strands[Math.floor(random() * PALETTE.strands.length)],
          tier,
        });
        break;
      }
    }
  }
  return branches;
};

export const ConceptSill: React.FC<{locale: keyof typeof sillCopy; guides?: boolean}> = ({
  locale,
  guides = false,
}) => {
  const frame = useCurrentFrame();
  const {durationInFrames, width, height} = useVideoConfig();
  const safe = CANVAS.header.safe;
  const safeLeft = (width - safe.width) / 2;
  const safeTop = (height - safe.height) / 2;

  // One breath of light: late morning, deep golden hour, back. Zero derivative at both ends,
  // so the repeat has neither a jump nor a kink — not a full day cycle, which at six seconds
  // would be frantic and would put a night frame in a warm app.
  const theta = (frame / durationInFrames) * Math.PI * 2;
  const u = (1 - Math.cos(theta)) / 2;

  const sky = [
    mixHex('#E8DCC0', '#C98F52', u),
    mixHex('#F8EFDC', '#ECBE84', u),
    mixHex('#FFFCF3', '#FFE7BC', u),
  ];
  const wall = mixHex('#EFDDBB', '#DFBE8E', u);
  const sillBack = mixHex('#E3C795', '#D6AE74', u);
  const sillFront = mixHex('#D9BC85', '#C79A5B', u);
  const room = mixHex('#C7A87A', '#AF8A57', u);
  const pageFar = mixHex('#FFFCF3', '#FFF3DC', u);
  const pageNear = mixHex('#FFF6E4', '#FFE9C4', u);

  const lattice = React.useMemo(buildLattice, []);
  const copy = sillCopy[locale];

  // The page's own trapezoid, and the rows of type lying on it.
  const pageFarLeft = 1180;
  const pageFarRight = 2660;
  const rows: {y: number; s: number}[] = [];
  let y = 1010;
  for (let i = 0; i < 5; i++) {
    const s = scaleAt(y);
    rows.push({y, s});
    y += 62 * s * s;
  }

  // The shaft, and the branch shadows it throws, both sliding with the hour.
  const shaftShift = Math.sin(theta) * 120;

  return (
    <AbsoluteFill style={{background: wall}}>
      <svg width={width} height={height} viewBox={`0 0 ${width} ${height}`}>
        <defs>
          <linearGradient id="skyGrad" x1="0" y1="180" x2="0" y2="900" gradientUnits="userSpaceOnUse">
            <stop offset="0%" stopColor={sky[0]} />
            <stop offset="55%" stopColor={sky[1]} />
            <stop offset="100%" stopColor={sky[2]} />
          </linearGradient>
          <linearGradient id="sillGrad" x1="0" y1="900" x2="0" y2={height} gradientUnits="userSpaceOnUse">
            <stop offset="0%" stopColor={sillBack} />
            <stop offset="100%" stopColor={sillFront} />
          </linearGradient>
          <linearGradient id="pageGrad" x1="0" y1="950" x2="0" y2={height} gradientUnits="userSpaceOnUse">
            <stop offset="0%" stopColor={pageFar} />
            <stop offset="100%" stopColor={pageNear} />
          </linearGradient>
          <clipPath id="aperture">
            <path
              d={`M 620 440 Q 620 180 880 180 L 2960 180 Q 3220 180 3220 440 L 3220 900 L 620 900 Z`}
            />
          </clipPath>
          {/* The lattice lives on the window, with a little of the reveal either side; it
              has no business raking across the sill or the room. */}
          <clipPath id="latticeArea">
            <rect x={430} y={0} width={2980} height={912} />
          </clipPath>
          <clipPath id="belowHorizon">
            <rect x={0} y={900} width={width} height={height - 900} />
          </clipPath>
          <filter id="farBlur" x="-20%" y="-20%" width="140%" height="140%">
            <feGaussianBlur stdDeviation="3" />
          </filter>
          <filter id="latticeShadow" x="-20%" y="-20%" width="140%" height="140%">
            <feDropShadow dx="14" dy="18" stdDeviation="18" floodColor="#6B4A22" floodOpacity="0.12" />
          </filter>
          <filter id="sillGrain">
            <feTurbulence type="fractalNoise" baseFrequency="0.9" numOctaves="2" seed="7" />
            <feColorMatrix type="saturate" values="0" />
          </filter>
          <radialGradient id="vignette" cx="50%" cy="50%" r="72%">
            <stop offset="55%" stopColor="#B98F4E" stopOpacity="0" />
            <stop offset="100%" stopColor="#B98F4E" stopOpacity="0.10" />
          </radialGradient>
        </defs>

        {/* Sky, seen through the window. */}
        <g clipPath="url(#aperture)">
          <rect x={620} y={180} width={2600} height={720} fill="url(#skyGrad)" />
        </g>
        {/* The reveal, so the wall has thickness. */}
        <path
          d={`M 620 440 Q 620 180 880 180 L 2960 180 Q 3220 180 3220 440 L 3220 900 L 620 900 Z`}
          fill="none"
          stroke="#A8763C"
          strokeOpacity={0.2}
          strokeWidth={20}
        />

        {/* The sill, coming toward the viewer, and the room in shadow either side of it. */}
        <g clipPath="url(#belowHorizon)">
          <path
            d={`M 620 900 L 3220 900 L ${px(3220, height)} ${height} L ${px(620, height)} ${height} Z`}
            fill="url(#sillGrad)"
          />
          <rect x={620} y={900} width={2600} height={14} fill="#C9A870" opacity={0.9} />
          <path d={`M 0 900 L 620 900 L ${px(620, height)} ${height} L 0 ${height} Z`} fill={room} />
          <path
            d={`M 3220 900 L ${width} 900 L ${width} ${height} L ${px(3220, height)} ${height} Z`}
            fill={room}
          />

          {/* The light falling in, and the page it falls on. */}
          <path
            d={`M ${940 + shaftShift} 900 L ${2200 + shaftShift} 900 L ${px(2700 + shaftShift, height)} ${height} L ${px(560 + shaftShift, height)} ${height} Z`}
            fill={u > 0.5 ? '#FFE9BE' : '#FFF6DE'}
            opacity={0.34 + u * 0.12}
            style={{filter: 'blur(26px)'}}
          />
          <path
            d={`M ${pageFarLeft} 950 L ${pageFarRight} 950 L ${px(pageFarRight, height)} ${height} L ${px(pageFarLeft, height)} ${height} Z`}
            fill="url(#pageGrad)"
          />
          <path
            d={`M ${pageFarLeft} 950 L ${pageFarRight} 950`}
            stroke="#FFFFFF"
            strokeWidth={3}
            opacity={0.8}
          />

          {/* Real prose, foreshortened by the same projection as everything else. */}
          <g>
            {rows.map((row, index) => (
              <text
                key={index}
                x={0}
                y={0}
                textAnchor="middle"
                transform={`translate(${1920} ${row.y}) scale(${row.s} ${row.s})`}
                fontFamily="Georgia, 'Times New Roman', serif"
                fontSize={index === 0 ? 52 : 30}
                fontWeight={index === 0 ? 600 : 400}
                fill="#3A2412"
                fillOpacity={index === 0 ? 0.92 : 0.74}
              >
                {index === 0 ? copy.headline : copy.body[(index - 1) % copy.body.length]}
              </text>
            ))}
          </g>

          {/* The branches' shadow crawling over the page as the hour turns. */}
          <g opacity={0.16 + u * 0.1}>
            {lattice.slice(0, 8).map((branch, index) => (
              <path
                key={index}
                d={branch.d}
                fill="#5A3E1B"
                transform={`translate(${-260 + shaftShift * 1.6} 980) skewX(-14) scale(1.05 0.55)`}
                style={{filter: 'blur(9px)'}}
              />
            ))}
          </g>
        </g>

        {/* The nest as the window's lattice: architecture and canopy at once, holding a clear
            bowl for the name. */}
        <g filter="url(#latticeShadow)" clipPath="url(#latticeArea)">
          {(['far', 'mid', 'near'] as const).map((tier) => (
            <g
              key={tier}
              opacity={tier === 'far' ? 0.55 : tier === 'mid' ? 0.9 : 1}
              filter={tier === 'far' ? 'url(#farBlur)' : undefined}
            >
              {lattice
                .filter((branch) => branch.tier === tier)
                .map((branch, index) => (
                  <g key={index}>
                    <path d={branch.d} fill={branch.colour} />
                    {/* One offset highlight is what turns a flat stroke into a lit round
                        twig — the cheapest depth in the whole frame. */}
                    {tier === 'far' ? null : (
                      <path
                        d={branch.d}
                        fill="#FFF3DC"
                        fillOpacity={0.26 + u * 0.16}
                        transform={`translate(${-branch.width * 0.16} ${-branch.width * 0.2}) scale(0.995)`}
                        style={{transformOrigin: 'center'}}
                      />
                    )}
                  </g>
                ))}
            </g>
          ))}
        </g>

        <rect x={0} y={0} width={width} height={height} fill="url(#vignette)" />
        <rect
          x={0}
          y={0}
          width={width}
          height={height}
          filter="url(#sillGrain)"
          opacity={0.05}
          style={{mixBlendMode: 'multiply'}}
        />

        {guides ? (
          <>
            <rect x={safeLeft} y={safeTop} width={safe.width} height={safe.height} fill="none" stroke="#FF00FF" strokeWidth={4} />
            <rect x={1450} y={540} width={940} height={300} fill="none" stroke="#00AAFF" strokeWidth={4} />
          </>
        ) : null}
      </svg>

      {/* The name, in the bowl the lattice leaves open for it. */}
      <div
        style={{
          position: 'absolute',
          left: 0,
          right: 0,
          top: 596,
          textAlign: 'center',
          fontFamily: "Georgia, 'Times New Roman', serif",
          fontWeight: 500,
          fontSize: 210,
          letterSpacing: '0.22em',
          textIndent: '0.22em',
          color: mixHex('#3A2412', '#4A2E14', u),
          lineHeight: 1,
        }}
      >
        NOOK
      </div>
    </AbsoluteFill>
  );
};
