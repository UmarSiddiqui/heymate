#!/bin/zsh
# Renders every export into out/. Run from this folder.
set -e
R=../node_modules/.bin/remotion
for id in planets keynote; do
  for s in wide square vertical; do
    $R render $id-$s out/heymate-$id-$s.mp4 --codec=h264 --crf=18 --pixel-format=yuv420p --audio-codec=aac --log=error
  done
done
for s in wide vertical; do
  $R render sizzle-$s out/heymate-sizzle-$s.mp4 --codec=h264 --crf=18 --pixel-format=yuv420p --audio-codec=aac --log=error
done
$R render gif-wide out/gif-src.mp4 --scale=0.5 --muted --codec=h264 --crf=16 --log=error
ffmpeg -v error -y -i out/gif-src.mp4 -vf "fps=15,scale=800:-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=sierra2_4a" -loop 0 out/heymate-keynote-steps-800w.gif
rm -f out/gif-src.mp4
