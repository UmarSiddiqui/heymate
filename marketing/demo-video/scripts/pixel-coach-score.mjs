// Original procedural score for this demo. No samples or external recording.
// Reproduce: node scripts/pixel-coach-score.mjs
// ffmpeg -y -i out/pixel-coach-score.wav -codec:a libmp3lame -q:a 3 public/pixel-coach/demo-score.mp3
import {mkdirSync, writeFileSync} from 'node:fs';

const rate = 48000;
const seconds = 42;
const samples = new Float64Array(rate * seconds);
const hz = (midi) => 440 * 2 ** ((midi - 69) / 12);
const chords = [[57, 60, 64, 67], [53, 57, 60, 64], [48, 55, 60, 64], [55, 59, 62, 67]];

function note(start, duration, midi, level, pad = false) {
  const frequency = hz(midi);
  const offset = Math.round(start * rate);
  const count = Math.min(Math.round(duration * rate), samples.length - offset);
  for (let i = 0; i < count; i++) {
    const t = i / rate;
    const attack = Math.min(1, t / (pad ? .22 : .012));
    const release = Math.min(1, (duration - t) / (pad ? 1 : .2));
    const decay = pad ? .7 + .3 * Math.exp(-t / 2) : Math.exp(-t / .7);
    const fundamental = Math.sin(2 * Math.PI * frequency * t);
    const harmonic = Math.sin(2 * Math.PI * frequency * 2 * t) * (pad ? .08 : .23);
    samples[offset + i] += (fundamental + harmonic) * attack * release * decay * level;
  }
}

for (let section = 0; section < 7; section++) {
  const chord = chords[section % chords.length];
  const start = section * 6;
  chord.forEach((midi) => note(start, 6, midi, .025, true));
  note(start, 5.8, chord[0] - 12, .045, true);
  [0, 1.5, 2.25, 3.75, 4.5].forEach((offset, index) => note(start + offset, 1.5, chord[index % 4] + 12, .043));
}
// Soft interaction notes mark the three human actions, without imitating app audio.
note(18.2, .35, 84, .035);
note(24.7, .5, 88, .035);
note(33.5, .7, 91, .035);

let peak = 0;
for (let i = 0; i < samples.length; i++) {
  const t = i / rate;
  samples[i] *= Math.min(1, t / 1.1, (seconds - t) / 1.8);
  peak = Math.max(peak, Math.abs(samples[i]));
}
const output = Buffer.alloc(44 + samples.length * 2);
output.write('RIFF', 0); output.writeUInt32LE(output.length - 8, 4); output.write('WAVE', 8);
output.write('fmt ', 12); output.writeUInt32LE(16, 16); output.writeUInt16LE(1, 20);
output.writeUInt16LE(1, 22); output.writeUInt32LE(rate, 24); output.writeUInt32LE(rate * 2, 28);
output.writeUInt16LE(2, 32); output.writeUInt16LE(16, 34); output.write('data', 36);
output.writeUInt32LE(samples.length * 2, 40);
for (let i = 0; i < samples.length; i++) output.writeInt16LE(Math.round(samples[i] / peak * .42 * 32767), 44 + i * 2);
mkdirSync('out', {recursive: true});
writeFileSync('out/pixel-coach-score.wav', output);
console.log('Created 42-second original score at out/pixel-coach-score.wav');
