/* Real totals, no manufactured social proof. A shared server cache avoids
   spending each visitor's GitHub rate limit. Last good session data stays
   visible and labelled if the refresh fails. */
(function () {
  "use strict";
  var downloads = document.querySelector('[data-stat="downloads"]');
  var stars = document.querySelector('[data-stat="stars"]');
  var status = document.querySelector("[data-stats-status]");
  if (!downloads || !stars) return;
  var KEY = "heymate.community.v2", TTL = 600000, cached;
  function valid(data) { return data && Number.isSafeInteger(data.downloads) && data.downloads >= 0 && Number.isSafeInteger(data.stars) && data.stars >= 0; }
  function show(data, stale) {
    downloads.textContent = data.downloads.toLocaleString("en-US");
    stars.textContent = data.stars.toLocaleString("en-US");
    status.textContent = stale ? "Last known GitHub totals · live refresh unavailable" : "Live GitHub totals · downloads, not unique users";
  }
  try { cached = JSON.parse(sessionStorage.getItem(KEY)); } catch (_) {}
  if (cached && valid(cached.data)) { show(cached.data, Date.now() - cached.at >= TTL); if (Date.now() - cached.at < TTL) return; }
  fetch("/api/stats", { signal: AbortSignal.timeout(12000) }).then(function (r) { if (!r.ok) throw new Error("Stats unavailable"); return r.json(); }).then(function (data) {
    if (!valid(data)) throw new Error("Invalid stats");
    show(data, false);
    try { sessionStorage.setItem(KEY, JSON.stringify({ at: Date.now(), data: data })); } catch (_) {}
  }).catch(function () {
    if (cached && valid(cached.data)) show(cached.data, true);
    else { downloads.textContent = "—"; stars.textContent = "—"; status.textContent = "GitHub totals unavailable right now · explore the source ↗"; }
  });
})();
