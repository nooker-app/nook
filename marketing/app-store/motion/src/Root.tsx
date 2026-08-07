import React from 'react';
import {Composition} from 'remotion';
import {Header} from './Header';
import {SearchResult, searchCopy} from './SearchResult';
import {CANVAS} from './theme';

// Six seconds at 30fps, and every motion in it is periodic over that window: the asset
// autoplays and repeats, and Apple asks for a loop with no visible jump.
const DURATION = 180;
const FPS = 30;

export const RemotionRoot: React.FC = () => {
  return (
    <>
      {(['ios', 'ipados'] as const).map((platform) => (
        <Composition
          key={`header-${platform}`}
          id={`header-${platform}`}
          component={Header}
          durationInFrames={DURATION}
          fps={FPS}
          width={CANVAS.header.width}
          height={CANVAS.header.height}
          defaultProps={{spread: platform === 'ipados' ? 1.15 : 1}}
        />
      ))}
      {(['ios', 'ipados'] as const).map((platform) =>
        (Object.keys(searchCopy) as (keyof typeof searchCopy)[]).map((locale) => (
          <Composition
            key={`search-${platform}-${locale}`}
            id={`search-${platform}-${locale}`}
            component={SearchResult}
            durationInFrames={DURATION}
            fps={FPS}
            width={CANVAS.search.width}
            height={CANVAS.search.height}
            defaultProps={{locale, spread: platform === 'ipados' ? 1.1 : 1}}
          />
        ))
      )}
    </>
  );
};
