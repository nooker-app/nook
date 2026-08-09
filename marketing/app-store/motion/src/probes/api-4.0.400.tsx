/// COMPILE PROBE, not a composition. Every call here is one this project may adopt, written exactly
/// as it would be written in an asset, so that `npx tsc --noEmit` is the thing that decides whether
/// the technique exists at 4.0.400 rather than a doc page written against a later version.
import React from 'react';
import {
  AbsoluteFill,
  Easing,
  Freeze,
  Img,
  Loop,
  OffthreadVideo,
  Sequence,
  Series,
  interpolate,
  staticFile,
  useCurrentFrame,
  useVideoConfig,
} from 'remotion';
import type {CalculateMetadataFunction} from 'remotion';
import {TransitionSeries, linearTiming, springTiming, useTransitionProgress} from '@remotion/transitions';
import {fade} from '@remotion/transitions/fade';
import {slide} from '@remotion/transitions/slide';
import {wipe} from '@remotion/transitions/wipe';
import {flip} from '@remotion/transitions/flip';
import {iris} from '@remotion/transitions/iris';
import {clockWipe} from '@remotion/transitions/clock-wipe';
import {none} from '@remotion/transitions/none';
import {getVideoMetadata} from '@remotion/media-utils';
import {Ellipse} from '@remotion/shapes';
import {CURVE} from '../motion';

/* 1. Video trimming, speed and end-holding on OffthreadVideo. */
const Trimmed: React.FC = () => (
  <OffthreadVideo
    src={staticFile('video/03-translate-body.mp4')}
    trimBefore={15}
    trimAfter={1395}
    playbackRate={1.6}
    muted
    toneMapped={false}
    style={{width: 1178, display: 'block'}}
  />
);

/* 2. Holding the last frame of a clip that is shorter than its beat. `active` takes a predicate. */
const HeldTail: React.FC = () => (
  <Freeze frame={238} active={(f) => f > 238}>
    <OffthreadVideo src={staticFile('video/05-add-feed-sim.mp4')} muted style={{width: 1178}} />
  </Freeze>
);

/* 3. Looping a clip shorter than its beat, as the alternative to freezing. */
const Looped: React.FC = () => (
  <Loop durationInFrames={238} times={2} layout="none">
    <OffthreadVideo src={staticFile('video/05-add-feed-sim.mp4')} muted style={{width: 1178}} />
  </Loop>
);

/* 4. Sequence used ONLY for timeline rows and mount windows: the absolute frame is read in the
   parent and handed down as a prop, so nothing inside depends on the local clock. */
const Beat: React.FC<{u: number}> = ({u}) => (
  <AbsoluteFill style={{opacity: 0.5 + 0.5 * Math.sin(u * Math.PI * 2)}} />
);

const AbsoluteClockUnderSequences: React.FC = () => {
  const frame = useCurrentFrame();
  const u = frame / 1800;
  return (
    <AbsoluteFill>
      {/* `premountFor` lives on the absolute-fill layout variant only: adding layout="none"
          narrows the union to {layout: 'none'} and the prop stops type-checking. */}
      <Sequence name="beat 1" from={0} durationInFrames={220} premountFor={30}>
        <Beat u={u} />
      </Sequence>
      <Sequence name="beat 2" from={200} durationInFrames={380} premountFor={30} postmountFor={30}>
        <Beat u={u} />
      </Sequence>
      <Sequence name="beat 3" from={580} durationInFrames={380} layout="none">
        <Beat u={u} />
      </Sequence>
    </AbsoluteFill>
  );
};

/* 5. TransitionSeries with the background hoisted OUT of it, so the periodic field never restarts. */
const Field: React.FC<{u: number}> = ({u}) => <AbsoluteFill style={{opacity: u}} />;

const SeriesWithContinuousGround: React.FC = () => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();
  const u = frame / 1800;
  const dark = interpolate(frame, [1120, 1160, 1540, 1580], [0, 1, 1, 0], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
    easing: CURVE,
  });
  return (
    <AbsoluteFill>
      <Field u={u} />
      <AbsoluteFill style={{opacity: dark, background: '#2A1509'}} />
      <TransitionSeries name="beats">
        <TransitionSeries.Sequence name="card 1" durationInFrames={220} premountFor={fps}>
          <AbsoluteFill />
        </TransitionSeries.Sequence>
        <TransitionSeries.Transition
          presentation={fade({shouldFadeOutExitingScene: true})}
          timing={linearTiming({durationInFrames: 20, easing: CURVE})}
        />
        <TransitionSeries.Sequence name="screen 1" durationInFrames={380}>
          <AbsoluteFill />
        </TransitionSeries.Sequence>
        <TransitionSeries.Transition
          presentation={slide({direction: 'from-bottom'})}
          timing={springTiming({config: {damping: 200}, durationInFrames: 25})}
        />
        <TransitionSeries.Sequence name="card 2" durationInFrames={160}>
          <AbsoluteFill />
        </TransitionSeries.Sequence>
      </TransitionSeries>
    </AbsoluteFill>
  );
};

/* 6. The remaining presentations, all of which need their props checked. */
const presentations = [
  fade(),
  slide({direction: 'from-right'}),
  wipe({direction: 'from-bottom-left'}),
  flip({direction: 'from-left', perspective: 2000}),
  iris({width: 3840, height: 2560}),
  clockWipe({width: 3840, height: 2560}),
  none({enterStyle: {opacity: 1}}),
];

/* 7. Transition-aware content: a scene can read how far into its own transition it is. */
const KnowsItsTransition: React.FC = () => {
  const {entering, exiting, isInTransitionSeries} = useTransitionProgress();
  return <AbsoluteFill style={{opacity: isInTransitionSeries ? entering * (1 - exiting) : 1}} />;
};

/* 8. Deriving the composition's length from the footage rather than hardcoding it. */
export const calculateMetadata: CalculateMetadataFunction<Record<string, unknown>> = async () => {
  const {durationInSeconds} = await getVideoMetadata(staticFile('video/03-translate-body.mp4'));
  return {durationInFrames: Math.round(durationInSeconds * 30)};
};

/* 9. Timing helpers the docs claim and this version's actual shape. */
const timings = () => {
  const linear = linearTiming({durationInFrames: 20}).getDurationInFrames({fps: 30});
  const spring = springTiming({config: {damping: 200}}).getDurationInFrames({fps: 30});
  const eased = interpolate(0.5, [0, 1], [0, 1], {
    easing: Easing.bezier(0.16, 1, 0.3, 1),
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
  });
  return [linear, spring, eased];
};

/* 10. A shadow shape under an object, from the installed shapes package. */
const Contact: React.FC = () => (
  <Ellipse rx={620} ry={70} fill="rgba(43,26,14,0.35)" style={{filter: 'blur(40px)'}} />
);

/* 11. Series, the no-transition sibling of TransitionSeries. */
const Plain: React.FC = () => (
  <Series>
    <Series.Sequence durationInFrames={200} name="a">
      <AbsoluteFill />
    </Series.Sequence>
    <Series.Sequence durationInFrames={360} offset={-20} name="b">
      <Img src={staticFile('shots/ko__iphone-6.9__08-articles.png')} />
    </Series.Sequence>
  </Series>
);

export const Probe: React.FC = () => (
  <AbsoluteFill>
    <Trimmed />
    <HeldTail />
    <Looped />
    <AbsoluteClockUnderSequences />
    <SeriesWithContinuousGround />
    <KnowsItsTransition />
    <Contact />
    <Plain />
    <Beat u={presentations.length + timings().length} />
  </AbsoluteFill>
);
