import React from 'react';
import {AbsoluteFill, interpolate, spring, useCurrentFrame, useVideoConfig} from 'remotion';
import {Nest} from './Nest';
import {CANVAS, PALETTE} from './theme';

/// The product page header: the band at the very top of the page, above the icon and the
/// Get button. One idea, no screenshots, and the only words are the app's own name — which
/// is how Apple's three examples are built.
export const Header: React.FC<{spread: number}> = ({spread}) => {
  const frame = useCurrentFrame();
  const {durationInFrames, width, height} = useVideoConfig();
  const cycle = (frame / durationInFrames) * Math.PI * 2;

  const safe = CANVAS.header.safe;
  const safeTop = (height - safe.height) / 2;
  const centreY = safeTop + safe.height * 0.56;
  const radius = safe.height * 0.54 * spread;

  // The light turns through the loop the way The Coast turns through a day, and returns to
  // where it started so the repeat is invisible.
  const warmth = (Math.sin(cycle) + 1) / 2;
  const mix = (a: string, b: string) => (warmth > 0.5 ? b : a);

  const rise = spring({frame, fps: 30, config: {damping: 200}, durationInFrames: 45});
  const markOpacity = interpolate(frame, [0, 18], [0, 1], {extrapolateRight: 'clamp'});

  return (
    <AbsoluteFill
      style={{
        background: `linear-gradient(196deg, ${mix(PALETTE.paperTop, PALETTE.duskTop)} 0%, ${mix(
          PALETTE.paperMid,
          PALETTE.duskMid
        )} 52%, ${mix(PALETTE.paperLow, PALETTE.duskLow)} 100%)`,
      }}
    >
      <Nest width={width} height={height} centreY={centreY} radius={radius} count={15} seed={0x4e6f} />
      <AbsoluteFill
        style={{
          alignItems: 'center',
          justifyContent: 'flex-start',
          paddingTop: safeTop - safe.height * 0.02,
        }}
      >
        <div
          style={{
            fontFamily: 'SF Pro Display, -apple-system, Helvetica, sans-serif',
            fontWeight: 800,
            fontSize: safe.height * 0.30,
            letterSpacing: safe.height * 0.042,
            color: PALETTE.ink,
            opacity: markOpacity,
            transform: `translateY(${(1 - rise) * safe.height * 0.06}px)`,
            textIndent: safe.height * 0.042,
          }}
        >
          NOOK
        </div>
      </AbsoluteFill>
    </AbsoluteFill>
  );
};
