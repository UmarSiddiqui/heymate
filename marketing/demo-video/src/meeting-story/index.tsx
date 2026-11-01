import React from 'react';
import {Composition, registerRoot} from 'remotion';
import {MeetingStory, FPS, TOTAL} from './Film';

const Root = () => (
	<>
		<Composition id="MeetingStory" component={MeetingStory} durationInFrames={TOTAL} fps={FPS} width={1920} height={1080} />
		<Composition id="MeetingStoryVertical" component={MeetingStory} durationInFrames={TOTAL} fps={FPS} width={1080} height={1920} />
	</>
);
registerRoot(Root);
