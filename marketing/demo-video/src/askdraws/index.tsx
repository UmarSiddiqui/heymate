import React from 'react';
import {Composition, registerRoot} from 'remotion';
import {AskDraws, FPS, TOTAL} from './Film';

const Root = () => (
	<>
		<Composition id="AskDraws" component={AskDraws} durationInFrames={TOTAL} fps={FPS} width={1920} height={1080} />
		<Composition id="AskDrawsVertical" component={AskDraws} durationInFrames={TOTAL} fps={FPS} width={1080} height={1920} />
	</>
);
registerRoot(Root);
