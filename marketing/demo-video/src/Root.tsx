import React from 'react';
import {Composition, Folder} from 'remotion';
import {FPS} from './config';
import {LayoutModeContext} from './components/motion';
import {HeyMateDemo, SCENES, sceneFrames, TOTAL_FRAMES} from './HeyMateDemo';

export const RemotionRoot: React.FC = () => (
  <>
    <Composition id="HeyMateDemo" component={HeyMateDemo} durationInFrames={TOTAL_FRAMES} fps={FPS} width={1920} height={1080} />
    <Composition
      id="HeyMateDemoVertical"
      component={HeyMateDemo}
      durationInFrames={TOTAL_FRAMES}
      fps={FPS}
      width={1080}
      height={1920}
    />
    {/* Individual scenes, for previewing and tweaking one at a time. */}
    <Folder name="Scenes-Landscape">
      {SCENES.map(({id, Component}) => (
        <Composition key={id} id={`scene-${id}`} component={Component} durationInFrames={sceneFrames(id)} fps={FPS} width={1920} height={1080} />
      ))}
    </Folder>
    {/* UI-only loops (no callout text) for the landing page and README. */}
    <Folder name="Web-Clips">
      {SCENES.filter((s) => ['notch', 'vision', 'agents', 'mates'].includes(s.id)).map(({id, Component}) => (
        <Composition
          key={id}
          id={`clip-${id}`}
          component={() => (
            <LayoutModeContext.Provider value="stage">
              <Component />
            </LayoutModeContext.Provider>
          )}
          durationInFrames={sceneFrames(id)}
          fps={FPS}
          width={1280}
          height={820}
        />
      ))}
    </Folder>
    <Folder name="Scenes-Vertical">
      {SCENES.map(({id, Component}) => (
        <Composition key={id} id={`vscene-${id}`} component={Component} durationInFrames={sceneFrames(id)} fps={FPS} width={1080} height={1920} />
      ))}
    </Folder>
  </>
);
