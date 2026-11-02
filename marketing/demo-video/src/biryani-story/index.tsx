import React from 'react';
import {Composition, registerRoot} from 'remotion';
import {BiryaniStory, FPS, TOTAL} from './Film';

const Root = () => (
	<>
		<Composition id="BiryaniStory" component={BiryaniStory} durationInFrames={TOTAL} fps={FPS} width={1920} height={1080} />
		<Composition id="BiryaniStoryVertical" component={BiryaniStory} durationInFrames={TOTAL} fps={FPS} width={1080} height={1920} />
	</>
);
registerRoot(Root);
