import React from 'react';
import {Composition,registerRoot} from 'remotion';
import {LaunchFilm} from './Film';
const Root=()=> <Composition id="HeyMateLaunch60" component={LaunchFilm} durationInFrames={3600} fps={60} width={1920} height={1080}/>;
registerRoot(Root);
