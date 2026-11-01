import React from 'react';
import {Composition, registerRoot} from 'remotion';
import {FPS, HookVideo, lengthOf} from './Hooks';

const Root = () => (
	<>
		<Composition id="HookAnger" component={HookVideo} defaultProps={{hook: 'anger' as const}} durationInFrames={lengthOf('anger')} fps={FPS} width={1080} height={1920} />
		<Composition id="HookInsider" component={HookVideo} defaultProps={{hook: 'insider' as const}} durationInFrames={lengthOf('insider')} fps={FPS} width={1080} height={1920} />
		<Composition id="HookLazy" component={HookVideo} defaultProps={{hook: 'lazy' as const}} durationInFrames={lengthOf('lazy')} fps={FPS} width={1080} height={1920} />
	</>
);
registerRoot(Root);
