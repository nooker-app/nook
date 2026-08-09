import React from 'react';
import {Composition} from 'remotion';
import {ConceptBird} from './ConceptBird';
import {SearchIllustration} from './SearchIllustration';
import {SearchHybrid} from './SearchHybrid';
import {CANVAS} from './theme';

/// The two App Store creative assets, and nothing else.
///
/// This file once registered twenty-three compositions — concept variants, per-lane probes, per-lane
/// story cuts, a twig contact sheet, two rival cuts of the search slot. All of it was scaffolding for
/// passes that needed a surface to iterate on without overwriting one another, and all of it made the
/// deliverables impossible to find. The design history is in the git log, which is where history
/// belongs.
///
/// What ships:
///   concept-bird                            the product page header, 3840x1646, a six-second loop
///   search-illustration-{ko,en,ja,zh-Hans}  the search results video, 3840x2560, thirty seconds
///
/// A screenshot-based cut of the search slot was built alongside this one, out of real captures and a
/// simulator recording driven through idb. It was the more honest asset — those were real screens and
/// a viewer could check them — and the illustrated cut won on what this slot is actually judged on: it
/// states the product's one differentiating claim in a single image, and it has nothing in it small
/// enough to lose at browsing size, which is the failure the screenshot cut spent six revisions
/// fighting. Its captures and its reasoning are in the log.
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
      {/* A hybrid cut, Korean only: the illustration's field, type and nest carrying real screens. It
          exists because Apple's guidance for this slot asks for two things the illustrated cut does
          not do — state the app's purpose at a glance, and show the interface.

          900, the same as SEARCH_FRAMES, down from a 1800 that was never justified. The ceiling above
          is UNVERIFIED, the sibling ships at 900, and once the unusable footage was cut there was not
          sixty seconds of material — there was thirty. */}
      <Composition
        id="search-hybrid-ko"
        component={SearchHybrid}
        durationInFrames={SEARCH_FRAMES}
        fps={FPS}
        width={CANVAS.search.width}
        height={CANVAS.search.height}
        defaultProps={{guides: false}}
      />
    </>
  );
};
