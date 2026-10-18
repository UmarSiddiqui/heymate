// Run: bun generate.ts /path/to/blobatar
// Upstream checkout must be a7fd546ebede49d0a9fa638945b9e534489782a2 (v2.7.0).
// Generated PNGs ship offline; no JavaScript runtime is used by HeyMate.
import { Resvg } from "@resvg/resvg-js";
import { mkdirSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { execFileSync } from "node:child_process";
const source = resolve(process.argv[2]);
const revision = "a7fd546ebede49d0a9fa638945b9e534489782a2";
if (execFileSync("git", ["-C", source, "rev-parse", "HEAD"], { encoding: "utf8" }).trim() !== revision) {
  throw new Error(`Expected Blobatar revision ${revision}`);
}
const { blobatar } = await import(`${source}/packages/blobatar/src/blob.ts`);
const expressions = await import(`${source}/packages/blobatar/src/expression.ts`);
const variants = [
  ["Tide", 190, 0.32], ["Lilac", 290, 0.1], ["Peach", 35, 0.51],
  ["Cloud", 220, 0.82], ["Sun", 80, 0.96], ["Mint", 155, 0.74],
] as const;
const output = resolve(import.meta.dir, "../../HeyMate/Assets.xcassets");
for (const [label, hue, shape] of variants) {
  for (const expression of ["idle", "happy", "sad", "surprised", "thinking", "wink"] as const) {
    const token = `Blobatar${label}${expression === "idle" ? "" : `-${expression}`}`;
    const svg = blobatar(`HeyMate Blobatar ${label}`, {
      size: 512, background: false, hue, tone: 0.25,
      traits: { shape }, expression: expressions[expression],
    });
    const directory = resolve(output, `${token}.imageset`);
    mkdirSync(directory, { recursive: true });
    writeFileSync(resolve(directory, "character.png"), new Resvg(svg).render().asPng());
    writeFileSync(resolve(directory, "Contents.json"), JSON.stringify({
      images: [{ filename: "character.png", idiom: "universal" }],
      info: { author: "xcode", version: 1 },
    }, null, 2) + "\n");
  }
}
console.log("Generated 6 Blobatar characters × 6 poses.");
