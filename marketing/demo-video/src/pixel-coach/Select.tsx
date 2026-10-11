import React from 'react';
import {LessonLayout} from './LessonLayout';

export const PixelSelect: React.FC = () => <LessonLayout stage="select" number={4} step="SELECT THE WHITE" title="One step. Then your turn." portraitTitle={'One step.\nThen your turn.'} sub="Pixel explains. You make the click." instruction={'Choose Magic Wand.\nClick the white background.\nTell me when it’s selected.'} reply="Selected." replyAt={4.7}/>;
