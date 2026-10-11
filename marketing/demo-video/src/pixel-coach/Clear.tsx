import React from 'react';
import {LessonLayout} from './LessonLayout';

export const PixelClear: React.FC = () => <LessonLayout stage="clear" number={5} step="SEE WHAT CHANGES" title="Clear it. Understand it." portraitTitle={'Clear it.\nUnderstand it.'} sub="The explanation is part of the lesson." instruction={'Choose Edit → Clear.\nThe checkerboard means\nthe background is transparent.'} reply="The white is gone." replyAt={3.9}/>;
