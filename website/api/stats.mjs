/* Public, cached GitHub totals. Count only exact HeyMate.dmg release assets;
   downloads are not unique users or installations. No credentials required. */
const ROOT = "https://api.github.com/repos/UmarSiddiqui/heymate";
export function sumDownloads(releases) {
  if (!Array.isArray(releases)) throw new Error("Invalid releases response");
  return releases.filter(r => !r.draft).reduce((total, release) => total + (release.assets || []).reduce((n, asset) => n + (asset.name === "HeyMate.dmg" && Number.isSafeInteger(asset.download_count) && asset.download_count >= 0 ? asset.download_count : 0), 0), 0);
}
async function github(path, fetcher) {
  const response = await fetcher(ROOT + path, { headers: { Accept: "application/vnd.github+json", "User-Agent": "HeyMate-website" }, signal: AbortSignal.timeout(8000) });
  if (!response.ok) throw new Error("GitHub unavailable");
  return { data: await response.json(), link: response.headers.get("link") || "" };
}
export async function loadStats(fetcher = fetch) {
  const starsJob = github("", fetcher).then(({ data }) => {
    if (!Number.isSafeInteger(data.stargazers_count) || data.stargazers_count < 0) throw new Error("Invalid stars response");
    return data.stargazers_count;
  });
  const downloadsJob = (async () => {
    let downloads = 0;
    for (let page = 1; page <= 30; page++) {
      const { data, link } = await github("/releases?per_page=100&page=" + page, fetcher);
      downloads += sumDownloads(data);
      if (!/rel="next"/.test(link)) return downloads;
    }
    throw new Error("Incomplete release pagination");
  })();
  // Consume both promises even when one fails.
  const [stars, downloads] = await Promise.all([starsJob, downloadsJob]);
  return { stars, downloads, updatedAt: new Date().toISOString() };
}
export default async function handler(req, res) {
  if (req.method !== "GET") { res.setHeader("Allow", "GET"); return res.status(405).json({ error: "Method not allowed" }); }
  try {
    const stats = await loadStats();
    res.setHeader("Cache-Control", "public, max-age=60, s-maxage=600, stale-while-revalidate=3600");
    return res.status(200).json(stats);
  } catch (_) {
    res.setHeader("Cache-Control", "no-store");
    return res.status(503).json({ error: "GitHub totals are temporarily unavailable" });
  }
}
