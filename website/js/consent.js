(function () {
  "use strict";

  // This is the only entry point for website analytics. Pages without data-hotjar
  // offer the same site-wide choice but never load recordings themselves.
  var siteId = Number(document.currentScript.getAttribute("data-hotjar"));
  if (!Number.isSafeInteger(siteId) || siteId <= 0) siteId = 0;
  var storageKey = "heymate.analytics-consent.v1";
  var lifetime = 180 * 24 * 60 * 60 * 1000;
  var loaded = false;
  var expiryTimer;
  var returnFocus;

  function readChoice() {
    try {
      var value = JSON.parse(localStorage.getItem(storageKey));
      if (value && value.version === 1 && typeof value.analytics === "boolean" &&
          Number.isFinite(value.expiresAt) && value.expiresAt > Date.now() &&
          value.expiresAt <= Date.now() + lifetime) return value;
    } catch (_) { /* Storage unavailable or invalid: analytics stays off. */ }
    return null;
  }

  var choice = readChoice();
  var banner = document.createElement("section");
  banner.id = "cookie-notice";
  banner.className = "cookie-notice";
  banner.setAttribute("aria-labelledby", "cookie-notice-title");
  banner.setAttribute("data-hj-suppress", "");
  banner.innerHTML = '<div class="cookie-notice-copy"><h2 id="cookie-notice-title" tabindex="-1">A little insight. Your choice.</h2>' +
    '<p>Optional Hotjar cookies and session recordings help us improve this site. Change your choice anytime in Cookie settings. <a href="/privacy#this-website">Privacy details</a></p></div>' +
    '<div class="cookie-notice-actions"><button type="button" data-cookie-accept>Accept analytics</button>' +
    '<button type="button" data-cookie-reject>Reject analytics</button></div>';
  document.body.appendChild(banner);

  var settings = document.createElement("button");
  settings.type = "button";
  settings.className = "cookie-settings";
  settings.textContent = "Cookie settings";
  settings.setAttribute("aria-controls", "cookie-notice");
  var footer = document.querySelector("footer nav") || document.querySelector("footer");
  if (footer) footer.appendChild(settings);
  settings.addEventListener("click", function () {
    returnFocus = settings;
    banner.hidden = false;
    banner.querySelector("h2").focus();
  });

  function clearHotjarData() {
    // Hotjar cookies can live on the hostname or a parent domain and path.
    var domains = [""];
    var parts = location.hostname.split(".");
    for (var i = 0; i < parts.length - 1; i++) domains.push(parts.slice(i).join("."));
    var paths = ["/"];
    var segments = location.pathname.split("/");
    for (var j = 1; j < segments.length; j++) {
      var path = segments.slice(0, j + 1).join("/");
      paths.push(path, path + "/");
    }
    document.cookie.split(";").forEach(function (cookie) {
      var name = cookie.split("=")[0].trim();
      if (!/^_hj/.test(name)) return;
      domains.forEach(function (domain) {
        paths.forEach(function (path) {
          document.cookie = name + "=; Max-Age=0; Path=" + path +
            (domain ? "; Domain=" + domain : "") + "; SameSite=Lax";
        });
      });
    });
    ["localStorage", "sessionStorage"].forEach(function (kind) {
      try {
        var storage = window[kind];
        Object.keys(storage).forEach(function (key) {
          if (/^_?hj/.test(key)) storage.removeItem(key);
        });
      } catch (_) { /* Browser may deny storage access. */ }
    });
  }

  function startHotjar() {
    if (loaded || !siteId || !window.heyMateAnalyticsAllowed) return;
    loaded = true;
    // Never expose form contents to recordings, even with analytics consent.
    document.querySelectorAll("input, textarea, [contenteditable]").forEach(function (el) {
      el.setAttribute("data-hj-suppress", "");
    });
    window.hj = function () { (window.hj.q = window.hj.q || []).push(arguments); };
    window._hjSettings = { hjid: Number(siteId), hjsv: 6 };
    var script = document.createElement("script");
    script.async = true;
    script.src = "https://static.hotjar.com/c/hotjar-" + siteId + ".js?sv=6";
    document.head.appendChild(script);
  }

  function applyChoice() {
    clearTimeout(expiryTimer);
    window.heyMateAnalyticsAllowed = !!(choice && choice.analytics);
    banner.hidden = !!choice;
    if (choice) {
      // setTimeout is limited to roughly 24 days; recheck long-lived tabs daily.
      expiryTimer = setTimeout(function () {
        if (choice.expiresAt <= Date.now()) choice = null;
        applyChoice();
      }, Math.min(choice.expiresAt - Date.now(), 86400000));
    }
    if (window.heyMateAnalyticsAllowed) {
      startHotjar();
    } else {
      clearHotjarData();
      if (loaded) {
        // Reload destroys the recorder and its listeners, not just its script tag.
        window.hj = function () {};
        location.reload();
      }
    }
  }

  function choose(analytics) {
    choice = { version: 1, analytics: analytics, updatedAt: Date.now(), expiresAt: Date.now() + lifetime };
    try { localStorage.setItem(storageKey, JSON.stringify(choice)); }
    catch (_) {
      // Keep the current page usable if storage is blocked. Next visit asks again.
      try { localStorage.removeItem(storageKey); } catch (_) {}
    }
    applyChoice();
    if (returnFocus) returnFocus.focus();
  }
  banner.querySelector("[data-cookie-accept]").addEventListener("click", function () { choose(true); });
  banner.querySelector("[data-cookie-reject]").addEventListener("click", function () { choose(false); });
  window.addEventListener("storage", function (event) {
    if (event.key !== storageKey && event.key !== null) return;
    choice = readChoice();
    applyChoice();
  });
  window.addEventListener("pageshow", function (event) {
    // A history-cache restore may have missed a withdrawal in another page.
    if (!event.persisted) return;
    choice = readChoice();
    applyChoice();
  });
  // Reserve space so the fixed notice never makes the footer unreachable.
  new ResizeObserver(function () {
    document.body.style.setProperty("--cookie-notice-space", banner.hidden ? "0px" : (banner.offsetHeight + 32) + "px");
  }).observe(banner);
  applyChoice();
})();
