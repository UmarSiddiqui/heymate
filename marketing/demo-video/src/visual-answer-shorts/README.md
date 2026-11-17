# Visual answer shorts

Three 9.5-second, 1440×944, 30 fps videos. Each shows the full existing desktop recording, including its real notch, at the source's native aspect ratio. The original first frame is held during the ElevenLabs-generated question, with a caption near the bottom. Playback then shows the answer. The source recordings remain unchanged. The final half-second holds the completed recording.

## Voice

ElevenLabs Charlie, `IKne3meq5aSn9XLyUdCD`, Australian English, `eleven_multilingual_v2`. Original generated voice is slowed to 88% with pitch preserved and normalized to -16 LUFS / -1.5 dBTP. The API key was used in memory and is not stored in project files.

- Biryani: “Hey mate, how do I cook chicken biryani?”
- Camera: “Hey mate, where does the camera connect to a Raspberry Pi?”
- Board: “Hey mate, show me this board in three D.”

## Sources and output

Source footage: `website/assets/video/visual-answers/{biryani,camera,board}.mp4`, the three recordings identified in the user's screenshot. No retired footage was recovered. Public render assets live in `marketing/demo-video/public/visual-answer-shorts/`.

Run from `marketing/demo-video`:

```sh
node src/visual-answer-shorts/render.mjs
```

Outputs: `out/visual-answers-2026-11-12/heymate-{biryani,camera,board}-real-notch-9.5s.mp4`. These supersede the earlier cropped exports.

Original generated audio and character alignment are retained in the output folder's `audio/` directory. These clips contain synthesized prompts, not recorded user speech. Production website files are not changed by rendering.
