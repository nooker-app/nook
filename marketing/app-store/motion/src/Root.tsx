import React from 'react';
import {Composition} from 'remotion';
import {ConceptPage} from './ConceptPage';
import {ConceptBird} from './ConceptBird';
import {ConceptSill} from './ConceptSill';
import {TwigSheet} from './TwigSheet';
import {Header} from './Header';
import {SearchResult, searchCopy} from './SearchResult';
import {ProbeA} from './probes/ProbeA';
import {ProbeB} from './probes/ProbeB';
import {ProbeC} from './probes/ProbeC';
import {ProbeD} from './probes/ProbeD';
import {SearchStory} from './SearchStory';
import {StoryA} from './stories/StoryA';
import {StoryB} from './stories/StoryB';
import {StoryC} from './stories/StoryC';
import {StoryB1} from './stories/StoryB1';
import {StoryB2} from './stories/StoryB2';
import {CANVAS} from './theme';

// Six seconds at 30fps, and every motion in it is periodic over that window: the asset
// autoplays and repeats, and Apple asks for a loop with no visible jump.
const DURATION = 180;
const FPS = 30;

/// The search-results video runs long. The header is a six-second loop because it sits above a page
/// somebody already opened; this one has to carry a sequence with room to breathe, and the shorter
/// cut was rejected for being hurried. 900 frames is 30s.
///
/// UNVERIFIED: Apple publishes no duration ceiling for this slot that I have been able to read —
/// their video templates 403 for us — so confirm in App Store Connect before this is submitted.
const SEARCH_FRAMES = 900;

export const RemotionRoot: React.FC = () => {
  return (
    <>
      {/* A test surface for the twig generator, judged by looking at it. */}
      <Composition
        id="twig-sheet"
        component={TwigSheet}
        durationInFrames={1}
        fps={FPS}
        width={3840}
        height={1646}
        defaultProps={{label: 'current'}}
      />
      {/* One scratch surface per agent during a quality pass, on the real header canvas.
          Each is a separate file and a separate composition so parallel work does not
          collide; they are scaffolding, not deliverables. */}
      {([['a', ProbeA], ['b', ProbeB], ['c', ProbeC], ['d', ProbeD]] as const).map(
        ([key, component]) => (
          <Composition
            key={`probe-${key}`}
            id={`probe-${key}`}
            component={component}
            durationInFrames={DURATION}
            fps={FPS}
            width={CANVAS.header.width}
            height={CANVAS.header.height}
          />
        )
      )}
      {/* Scratch surfaces for a search-video pass: one file and one composition per lane, on the
          real search canvas, so parallel work never collides. Scaffolding, not deliverables. */}
      {([['b1', StoryB1], ['b2', StoryB2]] as const).map(([key, component]) =>
        (['en', 'ko'] as const).map((locale) => (
          <Composition
            key={`story-${key}-${locale}`}
            id={`story-${key}-${locale}`}
            component={component}
            durationInFrames={SEARCH_FRAMES}
            fps={FPS}
            width={CANVAS.search.width}
            height={CANVAS.search.height}
            defaultProps={{locale, guides: false}}
          />
        ))
      )}
      {([['a', StoryA], ['b', StoryB], ['c', StoryC]] as const).map(([key, component]) =>
        (['en', 'ko'] as const).map((locale) => (
          <Composition
            key={`story-${key}-${locale}`}
            id={`story-${key}-${locale}`}
            component={component}
            durationInFrames={DURATION}
            fps={FPS}
            width={CANVAS.search.width}
            height={CANVAS.search.height}
            defaultProps={{locale, guides: false}}
          />
        ))
      )}
      {/* The search results asset: six shots and five transitions, against the header's one held
          image. A different slot with a different job — it appears in a list being scrolled past. */}
      {(['en', 'ko'] as const).map((locale) => (
        <Composition
          key={`search-story-${locale}`}
          id={`search-story-${locale}`}
          component={SearchStory}
          durationInFrames={SEARCH_FRAMES}
          fps={FPS}
          width={CANVAS.search.width}
          height={CANVAS.search.height}
          defaultProps={{locale, guides: false}}
        />
      ))}
      <Composition
        id="concept-bird"
        component={ConceptBird}
        durationInFrames={DURATION}
        fps={FPS}
        width={CANVAS.header.width}
        height={CANVAS.header.height}
        defaultProps={{guides: false}}
      />
      {(['en', 'ko'] as const).map((locale) => (
        <Composition
          key={`concept-sill-${locale}`}
          id={`concept-sill-${locale}`}
          component={ConceptSill}
          durationInFrames={DURATION}
          fps={FPS}
          width={CANVAS.header.width}
          height={CANVAS.header.height}
          defaultProps={{locale, guides: false}}
        />
      ))}
      {(['en', 'ko'] as const).map((locale) => (
        <Composition
          key={`concept-page-${locale}`}
          id={`concept-page-${locale}`}
          component={ConceptPage}
          durationInFrames={DURATION}
          fps={FPS}
          width={CANVAS.header.width}
          height={CANVAS.header.height}
          defaultProps={{locale, guides: false}}
        />
      ))}
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
