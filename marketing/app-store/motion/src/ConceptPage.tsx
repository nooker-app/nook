import React from 'react';
import {AbsoluteFill, useCurrentFrame, useVideoConfig} from 'remotion';
import {buildNest} from './Nest';
import {pageCopy} from './copy';
import {CANVAS} from './theme';

/// Concept A — "Held to the Light".
///
/// The banner is not a picture of a page; it is one. A sheet of warm paper fills the frame,
/// NOOK is set as its display title in a well of blank paper, columns of real type run off
/// the bottom edge, and a slow shaft of window light crosses the sheet and lifts a
/// blind-embossed nest out of the paper as it passes.
///
/// It answers both of the earlier failures directly. It is a page rather than a device
/// screenshot with copy beside it — a page of set type with headlines is the most legible
/// picture of reading there is, and nobody has to decode it. And the nest stops competing
/// with the wordmark: pressed into the paper, it has no colour of its own to fight with.
export const ConceptPage: React.FC<{locale: keyof typeof pageCopy; guides?: boolean}> = ({
  locale,
  guides = false,
}) => {
  const frame = useCurrentFrame();
  const {durationInFrames, width, height} = useVideoConfig();
  const safe = CANVAS.header.safe;
  const safeLeft = (width - safe.width) / 2;
  const safeTop = (height - safe.height) / 2;

  // Everything periodic over the loop, and nothing eased across the seam: the asset repeats
  // and Apple asks for a repeat with no visible jump.
  const theta = (frame / durationInFrames) * Math.PI * 2;
  const copy = pageCopy[locale];

  // Two panes of light rather than one. A single shaft crossing 3840px in six seconds lights
  // the centre — the only part guaranteed to be shown — for about a second in six, so a
  // stranger giving it two seconds would probably see nothing move.
  const panes = [0, 0.5].map((offset) => {
    const t = ((frame / durationInFrames + offset) % 1) * (width + 2400) - 1200;
    return t;
  });

  const rules = [548, 904];
  const nest = React.useMemo(
    () => buildNest({centreX: 1920, centreY: 706, radius: 250, count: 7, seed: 0x4e6f}),
    []
  );

  const columnX = [126, 532, 938, 1344, 1750, 2156, 2562, 2968, 3374];

  return (
    <AbsoluteFill style={{background: '#FFFDF7'}}>
      {/* The sheet: lit from the upper left, turning away into shade at the lower right. */}
      <AbsoluteFill
        style={{background: 'linear-gradient(118deg, #FFFDF7 0%, #F7ECD6 55%, #EFE0C2 100%)'}}
      />
      <AbsoluteFill
        style={{
          background:
            'radial-gradient(120% 140% at 22% 12%, transparent 45%, rgba(201,169,110,0.22) 100%)',
          mixBlendMode: 'multiply',
        }}
      />

      {/* The light, under the ink so it lifts the paper rather than washing the type. */}
      {panes.map((x, index) => (
        <div
          key={index}
          style={{
            position: 'absolute',
            left: x,
            top: -477,
            width: 1000,
            height: 2600,
            transform: 'rotate(-12deg)',
            transformOrigin: '50% 50%',
            filter: 'blur(60px)',
            mixBlendMode: 'screen',
            opacity: 0.65,
            background:
              'linear-gradient(90deg, transparent 0%, rgba(255,246,220,0.55) 50%, transparent 100%)',
          }}
        />
      ))}

      <svg
        width={width}
        height={height}
        viewBox={`0 0 ${width} ${height}`}
        style={{position: 'absolute', inset: 0}}
      >
        <defs>
          <filter id="emboss" x="-20%" y="-20%" width="140%" height="140%">
            <feGaussianBlur stdDeviation="1.5" />
          </filter>
          <filter id="grain">
            <feTurbulence type="fractalNoise" baseFrequency="0.85" numOctaves="3" seed="7" stitchTiles="stitch" />
            <feColorMatrix type="saturate" values="0" />
          </filter>
        </defs>

        {/* The nest, pressed into the sheet: no colour of its own, only a shadow and a
            highlight, so it can never compete with the word sitting on it. */}
        <g opacity={0.38} filter="url(#emboss)">
          {nest.map((strand, index) => (
            <g key={index}>
              <path d={strand.d} transform="translate(2 3)" stroke="#DCC49A" strokeOpacity={0.7} strokeWidth={26} strokeLinecap="round" fill="none" />
              <path d={strand.d} transform="translate(-2 -3)" stroke="#FFFEFA" strokeOpacity={0.9} strokeWidth={26} strokeLinecap="round" fill="none" />
            </g>
          ))}
        </g>

        {/* Debossed rules: what makes this read as a printed page rather than a poster. */}
        {rules.map((y) => (
          <g key={y}>
            <rect x={0} y={y} width={width} height={2} fill="#D9C49A" opacity={0.7} />
            <rect x={0} y={y + 2} width={width} height={1} fill="#FFFDF6" opacity={0.6} />
          </g>
        ))}

        {/* The columns. Real prose, ragged right, falling away into the paper rather than
            being cut off by the frame. */}
        <mask id="columnFade">
          <rect x={0} y={904} width={width} height={742} fill="url(#fadeGrad)" />
        </mask>
        <defs>
          <linearGradient id="fadeGrad" x1="0" y1="904" x2="0" y2="1646" gradientUnits="userSpaceOnUse">
            <stop offset="0%" stopColor="#fff" />
            <stop offset="72%" stopColor="#fff" />
            <stop offset="100%" stopColor="#000" />
          </linearGradient>
        </defs>
        <g mask="url(#columnFade)">
          {columnX.map((x, index) => {
            const item = copy.columns[index % copy.columns.length];
            return (
              <g key={x}>
                <circle cx={x + 7} cy={944} r={7} fill="#A9702F" />
                <text
                  x={x + 30}
                  y={952}
                  fontSize={24}
                  letterSpacing={3.8}
                  fill="#9A7038"
                  fontFamily="Georgia, 'Times New Roman', serif"
                >
                  {item.source}
                </text>
                {item.headline.map((line, lineIndex) => (
                  <text
                    key={lineIndex}
                    x={x}
                    y={1012 + lineIndex * 46}
                    fontSize={38}
                    fontWeight={600}
                    fill="#3A2412"
                    fontFamily="Georgia, 'Times New Roman', serif"
                  >
                    {line}
                  </text>
                ))}
                {[...item.body, ...item.body, ...item.body].slice(0, 15).map((line, lineIndex) => (
                  <text
                    key={`b-${lineIndex}`}
                    x={x}
                    y={1108 + lineIndex * 33}
                    fontSize={20}
                    fill="#5B4326"
                    fillOpacity={0.82}
                    fontFamily="Georgia, 'Times New Roman', serif"
                  >
                    {line}
                  </text>
                ))}
              </g>
            );
          })}
        </g>

        {/* Grain: texture, and dither for the wide cream gradients that H.264 would band.
            A fixed seed — turbulence that re-randomises per frame boils. */}
        <rect x={0} y={0} width={width} height={height} filter="url(#grain)" opacity={0.035} style={{mixBlendMode: 'multiply'}} />

        {guides ? (
          <rect x={safeLeft} y={safeTop} width={safe.width} height={safe.height} fill="none" stroke="#FF00FF" strokeWidth={4} />
        ) : null}
      </svg>

      {/* The name, in the well of blank paper the page deliberately leaves it. Nothing else
          is allowed into this band. */}
      <div
        style={{
          position: 'absolute',
          left: 0,
          right: 0,
          top: 560,
          textAlign: 'center',
          fontFamily: "Georgia, 'Times New Roman', serif",
          fontWeight: 600,
          fontSize: 200,
          letterSpacing: '0.06em',
          textIndent: '0.06em',
          color: '#3A2412',
          lineHeight: 1,
        }}
      >
        NOOK
      </div>
      <div
        style={{
          position: 'absolute',
          left: 0,
          right: 0,
          top: 800,
          textAlign: 'center',
          fontFamily: "Georgia, 'Times New Roman', serif",
          fontSize: 40,
          letterSpacing: '0.24em',
          textIndent: '0.24em',
          color: '#9A7038',
          opacity: 0.9 + Math.sin(theta) * 0.1,
        }}
      >
        {copy.tagline}
      </div>
    </AbsoluteFill>
  );
};
