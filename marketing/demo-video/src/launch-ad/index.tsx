import React from 'react';
import {Composition, registerRoot} from 'remotion';
import {FPS, LaunchAd, TOTAL} from './Film';

const Root = () => (
	<>
		<Composition id="LaunchAd" component={LaunchAd} durationInFrames={TOTAL} fps={FPS} width={1920} height={1080} />
		<Composition id="LaunchAdVertical" component={LaunchAd} durationInFrames={TOTAL} fps={FPS} width={1080} height={1920} />
	</>
);
registerRoot(Root);
