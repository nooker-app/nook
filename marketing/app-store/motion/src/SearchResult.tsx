import React from 'react';
import {AbsoluteFill, interpolate, spring, staticFile, useCurrentFrame, useVideoConfig} from 'remotion';
import {Nest} from './Nest';
import {CANVAS, PALETTE} from './theme';

/// What a search result has to do, in Apple's words: state the obvious, because somebody
/// searching is looking for a specific thing, and show the firsthand experience. So the
/// same world as the header, a line that names what this is, and the app itself in it —
/// which is how Forest Explorer and Airline build theirs.
export const searchCopy = {
  ko: {title: '고른 글만 남습니다', subtitle: '광고도 알고리즘도 없는 RSS 리더.'},
  en: {title: 'The reading you chose', subtitle: 'An RSS reader with no ads and no algorithm.'},
  ja: {title: '選んだ記事だけが残る', subtitle: '広告もアルゴリズムもないRSSリーダー。'},
  'zh-Hans': {title: '只留下你选择的阅读', subtitle: '没有广告与算法的 RSS 阅读器。'},
} as const;

/// Where each capture can be entered without landing mid-sentence. The sets are of
/// different articles scrolled to different places — Korean and Japanese open on a title,
/// English sits at a section heading, Chinese at a paragraph — so one offset cannot serve
/// all four.
const readerStart = {ko: 0.095, en: 0.395, ja: 0.1, 'zh-Hans': 0.255} as const;

export const SearchResult: React.FC<{locale: keyof typeof searchCopy; spread: number}> = ({
  locale,
  spread,
}) => {
  const frame = useCurrentFrame();
  const {durationInFrames, width, height} = useVideoConfig();
  const cycle = (frame / durationInFrames) * Math.PI * 2;

  const safe = CANVAS.search.safe;
  const safeLeft = (width - safe.width) / 2;
  const safeTop = (height - safe.height) / 2;
  const centreY = safeTop + safe.height * 0.62;
  // Quieter than the header's: there is type over this one, and a nest at full strength
  // behind a sentence is a nest nobody can read through.
  const radius = safe.height * 0.42 * spread;

  const warmth = (Math.sin(cycle) + 1) / 2;
  const mix = (a: string, b: string) => (warmth > 0.5 ? b : a);
  const copy = searchCopy[locale];

  const rise = spring({frame, fps: 30, config: {damping: 200}, durationInFrames: 50});
  const fade = interpolate(frame, [0, 20], [0, 1], {extrapolateRight: 'clamp'});
  const float = Math.sin(cycle) * safe.height * 0.012;

  return (
    <AbsoluteFill
      style={{
        background: `linear-gradient(196deg, ${mix(PALETTE.paperTop, PALETTE.duskTop)} 0%, ${mix(
          PALETTE.paperMid,
          PALETTE.duskMid
        )} 52%, ${mix(PALETTE.paperLow, PALETTE.duskLow)} 100%)`,
      }}
    >
      <Nest
        width={width}
        height={height}
        centreY={centreY}
        radius={radius}
        count={11}
        seed={0x4e6f}
      />

      {/* A wash over the nest where the words go, so the line stays readable at card size. */}
      <AbsoluteFill
        style={{
          background: `linear-gradient(180deg, rgba(255,251,240,0.92) 0%, rgba(255,251,240,0.72) ${
            (safeTop + safe.height * 0.45) / height * 100
          }%, rgba(255,251,240,0) ${(safeTop + safe.height * 0.72) / height * 100}%)`,
        }}
      />

      <AbsoluteFill style={{opacity: fade}}>
        <div
          style={{
            position: 'absolute',
            left: safeLeft,
            top: safeTop + safe.height * 0.06,
            width: safe.width * 0.62,
            transform: `translateY(${(1 - rise) * safe.height * 0.05}px)`,
          }}
        >
          <div
            style={{
              fontFamily: 'SF Pro Display, -apple-system, Helvetica, sans-serif',
              fontWeight: 800,
              fontSize: safe.height * 0.125,
              lineHeight: 1.06,
              letterSpacing: -safe.height * 0.002,
              color: PALETTE.ink,
            }}
          >
            {copy.title}
          </div>
          <div
            style={{
              marginTop: safe.height * 0.035,
              fontFamily: 'SF Pro Text, -apple-system, Helvetica, sans-serif',
              fontWeight: 500,
              fontSize: safe.height * 0.05,
              lineHeight: 1.2,
              color: PALETTE.inkSoft,
            }}
          >
            {copy.subtitle}
          </div>
        </div>

        {/* The app itself, sitting in the world rather than beside it. */}
        <div
          style={{
            position: 'absolute',
            left: safeLeft + safe.width * 0.66,
            top: safeTop + safe.height * 0.20 + float,
            width: safe.width * 0.30,
            height: safe.height * 0.92,
            borderRadius: safe.height * 0.07,
            background: '#FBF4E4',
            boxShadow: `0 ${safe.height * 0.03}px ${safe.height * 0.09}px rgba(90,62,27,0.30)`,
            border: `${safe.height * 0.004}px solid rgba(90,62,27,0.14)`,
            overflow: 'hidden',
            transform: `translateY(${(1 - rise) * safe.height * 0.08}px)`,
          }}
        >
          <img
            src={staticFile(`captures/${locale}.png`)}
            style={{
              width: '100%',
              display: 'block',
              // Pulled up so the panel opens on the article rather than on the status bar.
              marginTop: `${-readerStart[locale] * 100}%`,
            }}
          />
        </div>
      </AbsoluteFill>
    </AbsoluteFill>
  );
};
