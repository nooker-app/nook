import React from 'react';
import {Composition} from 'remotion';
import {ConceptBird} from './ConceptBird';
import {SearchStory} from './SearchStory';
import {SearchIllustration} from './SearchIllustration';
import {CANVAS} from './theme';

/// The two App Store creative assets, and nothing else.
///
/// This file used to register twenty-three compositions — concept variants, per-lane probes, per-lane
/// story cuts, a twig contact sheet — because several passes each needed a surface to iterate on
/// without overwriting one another. That scaffolding did its job and then made the deliverables
/// impossible to find. The design history is in the git log, which is where history belongs.
///
/// What ships:
///   concept-bird         the product page header, 3840x1646, a six-second loop
///   search-story-{ko,en} the search results video, 3840x2560, thirty seconds
///   search-illustration-{ko,en}  a second draft of the same slot, drawn rather than photographed —
///                                kept alongside so the two can be compared before one is chosen
const FPS = 30;

/// The header autoplays and repeats, so every motion in it is periodic over six seconds and frame 179
/// has to flow into frame 0.
const HEADER_FRAMES = 180;

/// The search video is long because it has to carry a sequence; a six-second version was rejected as
/// hurried.
///
/// UNVERIFIED: Apple publishes no duration ceiling for this slot that we have been able to read —
/// their video templates 403 — so confirm in App Store Connect before submitting.
const SEARCH_FRAMES = 900;

export const RemotionRoot: React.FC = () => {
  return (
    <>
      <Composition
        id="concept-bird"
        component={ConceptBird}
        durationInFrames={HEADER_FRAMES}
        fps={FPS}
        width={CANVAS.header.width}
        height={CANVAS.header.height}
        defaultProps={{guides: false}}
      />
      {(['ko', 'en'] as const).map((locale) => (
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
      {/* The illustrated asset ships in every language the listing does; the screenshot cut still only
          has Korean captures, which is why the two lists differ. */}
      {(['ko', 'en', 'ja', 'zh-Hans'] as const).map((locale) => (
        <Composition
          key={`search-illustration-${locale}`}
          id={`search-illustration-${locale}`}
          component={SearchIllustration}
          durationInFrames={SEARCH_FRAMES}
          fps={FPS}
          width={CANVAS.search.width}
          height={CANVAS.search.height}
          defaultProps={{locale, guides: false}}
        />
      ))}
    </>
  );
};
