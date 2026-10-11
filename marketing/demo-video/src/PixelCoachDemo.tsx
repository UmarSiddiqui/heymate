import React from 'react';
import {Series, staticFile, useVideoConfig} from 'remotion';
import {Audio} from '@remotion/media';
import {PixelInvitation} from './pixel-coach/Invitation';
import {PixelCreate} from './pixel-coach/Create';
import {PixelIdentity} from './pixel-coach/Identity';
import {PixelSelect} from './pixel-coach/Select';
import {PixelClear} from './pixel-coach/Clear';
import {PixelExport} from './pixel-coach/Export';
import {PixelClose} from './pixel-coach/Close';

// Authored scenes remain editable independently in Studio.
// All UI is recreated. The result asset is a manually verified Photopea export,
// not evidence that the current HeyMate screen-guidance path completed a lesson.
export const PixelCoachDemo: React.FC = () => {
  const {fps} = useVideoConfig();
  return <><Series>
    <Series.Sequence name="Make it yours" durationInFrames={4 * fps} premountFor={fps}><PixelInvitation/></Series.Sequence>
    <Series.Sequence name="Create Pixel Coach" durationInFrames={6 * fps} premountFor={fps}><PixelCreate/></Series.Sequence>
    <Series.Sequence name="Name job and saved note" durationInFrames={5 * fps} premountFor={fps}><PixelIdentity/></Series.Sequence>
    <Series.Sequence name="Select the white" durationInFrames={7 * fps} premountFor={fps}><PixelSelect/></Series.Sequence>
    <Series.Sequence name="Clear and understand" durationInFrames={6 * fps} premountFor={fps}><PixelClear/></Series.Sequence>
    <Series.Sequence name="Export transparent PNG" durationInFrames={7 * fps} premountFor={fps}><PixelExport/></Series.Sequence>
    <Series.Sequence name="Learn your software" durationInFrames={7 * fps} premountFor={fps}><PixelClose/></Series.Sequence>
  </Series><Audio name="Original instrumental score" src={staticFile('pixel-coach/demo-score.mp3')} premountFor={fps} volume={.65}/></>;
};
