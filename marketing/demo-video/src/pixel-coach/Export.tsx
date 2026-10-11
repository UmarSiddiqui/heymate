import React from 'react';
import {LessonLayout} from './LessonLayout';

export const PixelExport: React.FC = () => <LessonLayout stage="export" number={6} step="KEEP THE TRANSPARENCY" title="Your logo. Ready to use." portraitTitle={'Your logo.\nReady to use.'} sub="Choose the format that keeps the result." instruction={'File → Export as → PNG.\nThen click Save.\nPNG keeps transparency.'} reply="Saved as PNG." replyAt={5.7}/>;
