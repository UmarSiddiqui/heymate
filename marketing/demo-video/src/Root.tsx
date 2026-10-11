import React from 'react';
import {Composition, Folder, Still} from 'remotion';
import {FPS} from './config';
import {LayoutModeContext} from './components/motion';
import {HeyMateDemo, SCENES, sceneFrames, TOTAL_FRAMES} from './HeyMateDemo';
import {SocialCard} from './SocialCard';
import {TeachingFirst} from './TeachingFirst';
import {TeachingHook} from './teaching/TeachingHook';
import {TeachingSteps} from './teaching/TeachingSteps';
import {TeachingMates} from './teaching/TeachingMates';
import {TeachingClose} from './teaching/TeachingClose';
import {TeachingShareCard} from './TeachingShareCard';
import {PixelCoachDemo} from './PixelCoachDemo';
import {PixelInvitation} from './pixel-coach/Invitation';
import {PixelCreate} from './pixel-coach/Create';
import {PixelIdentity} from './pixel-coach/Identity';
import {PixelSelect} from './pixel-coach/Select';
import {PixelClear} from './pixel-coach/Clear';
import {PixelExport} from './pixel-coach/Export';
import {PixelClose} from './pixel-coach/Close';

export const RemotionRoot: React.FC = () => (
  <>
    <Folder name="Pixel-Coach-Demo">
      <Composition id="PixelCoachDemo" component={PixelCoachDemo} durationInFrames={1260} fps={30} width={1920} height={1080}/>
      <Composition id="PixelCoachDemoVertical" component={PixelCoachDemo} durationInFrames={1260} fps={30} width={1080} height={1920}/>
      <Composition id="PixelInvitation" component={PixelInvitation} durationInFrames={120} fps={30} width={1920} height={1080}/>
      <Composition id="PixelCreate" component={PixelCreate} durationInFrames={180} fps={30} width={1920} height={1080}/>
      <Composition id="PixelIdentity" component={PixelIdentity} durationInFrames={150} fps={30} width={1920} height={1080}/>
      <Composition id="PixelSelect" component={PixelSelect} durationInFrames={210} fps={30} width={1920} height={1080}/>
      <Composition id="PixelClear" component={PixelClear} durationInFrames={180} fps={30} width={1920} height={1080}/>
      <Composition id="PixelExport" component={PixelExport} durationInFrames={210} fps={30} width={1920} height={1080}/>
      <Composition id="PixelClose" component={PixelClose} durationInFrames={210} fps={30} width={1920} height={1080}/>
    </Folder>
    <Folder name="Teaching-Concept">
      <Composition id="TeachingFirst" component={TeachingFirst} durationInFrames={720} fps={30} width={1920} height={1080} />
      <Composition id="TeachingFirstVertical" component={TeachingFirst} durationInFrames={720} fps={30} width={1080} height={1920} />
      <Composition id="TeachingHook" component={TeachingHook} durationInFrames={150} fps={30} width={1920} height={1080} />
      <Composition id="TeachingSteps" component={TeachingSteps} durationInFrames={240} fps={30} width={1920} height={1080} />
      <Composition id="TeachingMates" component={TeachingMates} durationInFrames={180} fps={30} width={1920} height={1080} />
      <Composition id="TeachingClose" component={TeachingClose} durationInFrames={150} fps={30} width={1920} height={1080} />
    </Folder>
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
    <Folder name="Share-Cards">
      <Still id="og-teaching" component={TeachingShareCard} width={1200} height={630} />
      <Composition id="og-card" component={SocialCard} durationInFrames={1} fps={FPS} width={1200} height={630} />
      <Composition id="github-social" component={SocialCard} durationInFrames={1} fps={FPS} width={1280} height={640} />
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
