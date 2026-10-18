// bun build-runtime.ts /path/to/blobatar
import { resolve } from "node:path";
import { execFileSync } from "node:child_process";
const source = resolve(process.argv[2]);
const revision = "a7fd546ebede49d0a9fa638945b9e534489782a2";
if (execFileSync("git", ["-C", source, "rev-parse", "HEAD"], { encoding: "utf8" }).trim() !== revision) {
  throw new Error(`Expected Blobatar revision ${revision}`);
}
const result = await Bun.build({
  entrypoints: [resolve(import.meta.dir, "runtime.ts")], target: "browser", format: "iife", minify: true,
  plugins: [{ name: "pinned-blobatar", setup(build) {
    build.onResolve({ filter: /^blobatar\// }, args => ({ path: resolve(source, "packages/blobatar/src", args.path.slice(9) + ".ts") }));
  } }],
});
if (!result.success) throw new AggregateError(result.logs, "Blobatar bundle failed");
const utf8 = await Bun.file(resolve(import.meta.dir, "utf8.js")).text();
await Bun.write(resolve(import.meta.dir, "../../HeyMate/BlobatarRuntime.js"), utf8 + "\n" + await result.outputs[0].text());
console.log(`Bundled upstream Blobatar runtime (${result.outputs[0].size} bytes).`);
