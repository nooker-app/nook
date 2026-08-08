import React from 'react';
import {AbsoluteFill} from 'remotion';
import {buildTwig, LIGHT_WORLD_DEG, RAMP} from './twig';
import type {Arch, Sweep, Weight} from './twig';

// The distinct families, not slices of the deal bags — those hold repeats, and slicing them
// showed twelve copies of bare/stiff while claiming to show the range.
const ARCHES: Arch[] = ['bare', 'single', 'forked', 'brushy'];
const SWEEPS: Sweep[] = ['stiff', 'bowed', 'hooked'];
const WEIGHTS: Weight[] = ['wisp', 'ordinary', 'stick'];

/// A contact sheet for the twig generator, at the two sizes the video actually uses.
///
/// The twigs have to work at both: about 300px long when the bird is carrying one, and
/// 40–90px as a strand in the nest. Every earlier attempt looked acceptable at one size and
/// fell apart at the other — stroked capsules read as twigs when small and as pills when
/// large, and a noisy outline reads as a twig when large and as lint when small. So both are
/// drawn side by side, and each small strand is shown again magnified, because "does it
/// survive being small" and "is it still clean when you look closely" are different
/// questions.
///
/// The grid is dealt from consecutive seeds on purpose: the requirement is that no two twigs
/// look alike, and consecutive seeds are the case most likely to break it.
export const TwigSheet: React.FC<{label?: string}> = ({label = 'twig generator'}) => {
  const carried = React.useMemo(
    () =>
      ARCHES.flatMap((arch, archIndex) =>
        SWEEPS.map((sweep, sweepIndex) => {
          const seed = 0x1000 + archIndex * 977 + sweepIndex * 131;
          const geometry = buildTwig({
            seed,
            length: 300,
            arch,
            sweep,
            weight: WEIGHTS[(archIndex + sweepIndex) % WEIGHTS.length],
            maxDepth: 2,
            lightLocalDeg: LIGHT_WORLD_DEG,
          });
          return {geometry, arch, sweep, rung: RAMP[(archIndex * 3 + sweepIndex) % RAMP.length]};
        })
      ),
    []
  );

  const strands = React.useMemo(
    () =>
      new Array(24).fill(0).map((_, index) => {
        const length = 40 + (index % 6) * 10;
        const geometry = buildTwig({
          seed: 0x2000 + index,
          length,
          maxDepth: 1,
          lightLocalDeg: LIGHT_WORLD_DEG,
        });
        return {geometry, rung: RAMP[index % RAMP.length], length};
      }),
    []
  );

  const heading = (text: string, left: number, top: number) => (
    <div
      style={{
        position: 'absolute',
        left,
        top,
        fontFamily: "Georgia, 'Times New Roman', serif",
        fontSize: 30,
        color: '#9A7038',
      }}
    >
      {text}
    </div>
  );

  return (
    <AbsoluteFill style={{background: '#FBEFD4'}}>
      <div
        style={{
          position: 'absolute',
          left: 70,
          top: 40,
          fontFamily: "Georgia, 'Times New Roman', serif",
          fontSize: 44,
          color: '#5B4326',
        }}
      >
        {label}
      </div>

      {heading('carried · 300px · one per arch × sweep', 70, 118)}
      <svg width={1780} height={1420} style={{position: 'absolute', left: 70, top: 170}}>
        {carried.map(({geometry, arch, sweep, rung}, index) => {
          const column = index % 2;
          const row = Math.floor(index / 2);
          return (
            <g key={index} transform={`translate(${40 + column * 880} ${70 + row * 220})`}>
              <path d={geometry.body} fill={rung.hex} fillRule="nonzero" />
              {geometry.highlight ? (
                <path d={geometry.highlight} fill={rung.light} fillRule="nonzero" />
              ) : null}
              <text x={0} y={54} fontFamily="Georgia, serif" fontSize={22} fill="#A9702F">
                {arch}/{sweep}/{geometry.weight} · {geometry.kids} shoots
              </text>
            </g>
          );
        })}
      </svg>

      {heading('nest strand · 40–90px, each shown again at 5×', 1980, 118)}
      <svg width={1800} height={1420} style={{position: 'absolute', left: 1980, top: 170}}>
        {strands.map(({geometry, rung, length}, index) => {
          const column = index % 4;
          const row = Math.floor(index / 4);
          return (
            <g key={index} transform={`translate(${30 + column * 440} ${60 + row * 230})`}>
              <path d={geometry.body} fill={rung.hex} fillRule="nonzero" />
              {geometry.highlight ? (
                <path d={geometry.highlight} fill={rung.light} fillRule="nonzero" />
              ) : null}
              <g transform="translate(0 40) scale(5)">
                <path d={geometry.body} fill={rung.hex} fillRule="nonzero" />
                {geometry.highlight ? (
                  <path d={geometry.highlight} fill={rung.light} fillRule="nonzero" />
                ) : null}
              </g>
              <text x={0} y={-16} fontFamily="Georgia, serif" fontSize={20} fill="#A9702F">
                {length}px · {geometry.arch}/{geometry.sweep}
              </text>
            </g>
          );
        })}
      </svg>
    </AbsoluteFill>
  );
};
