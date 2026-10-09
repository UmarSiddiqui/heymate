(function () {
  var cfg = window.HEYMATE || {};
  document.querySelectorAll("[data-download]").forEach(function (el) {
    if (cfg.DOWNLOAD_URL) el.setAttribute("href", cfg.DOWNLOAD_URL);
  });
  document.querySelectorAll("[data-github]").forEach(function (el) {
    if (cfg.GITHUB_URL) el.setAttribute("href", cfg.GITHUB_URL);
  });

  // Hotjar events (disclosed on privacy.html), so recordings and heatmaps can
  // be filtered to visitors who took the install step.
  function track(name) {
    try { if (typeof window.hj === "function") window.hj("event", name); } catch (e) {}
  }
  document.querySelectorAll("[data-download]").forEach(function (el) {
    el.addEventListener("click", function () { track("download_click"); });
  });
  document.querySelectorAll("[data-github]").forEach(function (el) {
    el.addEventListener("click", function () { track("github_click"); });
  });

  // Click an install command to copy it.
  document.querySelectorAll("[data-copy]").forEach(function (el) {
    el.setAttribute("role", "button");
    el.setAttribute("tabindex", "0");
    el.setAttribute("title", "Copy");
    function copy() {
      var text = el.getAttribute("data-copy") || el.textContent.trim();
      track(el.getAttribute("data-copy-event") || "command_copy");
      if (!navigator.clipboard) return;
      navigator.clipboard.writeText(text).then(function () {
        el.classList.add("copied");
        setTimeout(function () { el.classList.remove("copied"); }, 1600);
      }, function () {});
    }
    el.addEventListener("click", copy);
    el.addEventListener("keydown", function (event) {
      if (event.key === "Enter" || event.key === " ") { event.preventDefault(); copy(); }
    });
  });

  var nav = document.querySelector(".nav");
  var reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  function onScroll() {
    if (!nav) return;
    nav.classList.toggle("scrolled", window.scrollY > 24);
  }
  onScroll();
  window.addEventListener("scroll", onScroll, { passive: true });

  var menu = document.querySelector(".menu-btn");
  if (menu && nav) {
    menu.addEventListener("click", function () {
      var open = nav.classList.toggle("open");
      menu.setAttribute("aria-expanded", open ? "true" : "false");
      menu.textContent = open ? "Close" : "Menu";
      document.documentElement.classList.toggle("menu-open", open);
    });
    nav.querySelectorAll(".nav-sheet a").forEach(function (a) {
      a.addEventListener("click", function () {
        nav.classList.remove("open");
        menu.setAttribute("aria-expanded", "false");
        menu.textContent = "Menu";
        document.documentElement.classList.remove("menu-open");
      });
    });
  }

  document.addEventListener("keydown", function (event) {
    if (event.key === "Escape" && nav && nav.classList.contains("open")) {
      nav.classList.remove("open");
      if (menu) {
        menu.setAttribute("aria-expanded", "false");
        menu.textContent = "Menu";
        menu.focus();
      }
    }
  });

  // Silent feature loops play only while on screen, and never with reduced motion.
  var loops = document.querySelectorAll("video[data-autoloop]");
  if (reduce || !("IntersectionObserver" in window)) {
    loops.forEach(function (v) { v.setAttribute("controls", ""); });
  } else {
    var vio = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        var v = entry.target;
        if (entry.isIntersecting) {
          if (v.preload === "none") { v.preload = "auto"; v.load(); }
          var p = v.play();
          if (p && p.catch) p.catch(function () {});
        } else {
          v.pause();
        }
      });
    }, { threshold: 0.35 });
    loops.forEach(function (v) { vio.observe(v); });
  }

  if (reduce) return;

  var nodes = document.querySelectorAll(".reveal");
  if (!("IntersectionObserver" in window)) {
    nodes.forEach(function (n) { n.classList.add("in"); });
    return;
  }
  var io = new IntersectionObserver(function (entries) {
    entries.forEach(function (entry) {
      if (!entry.isIntersecting) return;
      entry.target.classList.add("in");
      io.unobserve(entry.target);
    });
  }, { threshold: 0.15 });
  nodes.forEach(function (n, i) {
    n.style.transitionDelay = (i % 4) * 80 + "ms";
    io.observe(n);
  });

  var counter = document.querySelector("[data-count]");
  if (counter) {
    var target = Number(counter.getAttribute("data-count"));
    var started = false;
    var cio = new IntersectionObserver(function (entries) {
      if (!entries[0].isIntersecting || started) return;
      started = true;
      var t0 = performance.now();
      function frame(now) {
        var p = Math.min(1, (now - t0) / 1200);
        var eased = 1 - Math.pow(1 - p, 3);
        var value = Math.round(target * eased);
        counter.textContent = value.toLocaleString("en-US") + "+";
        if (p < 1) requestAnimationFrame(frame);
      }
      requestAnimationFrame(frame);
    }, { threshold: 0.6 });
    cio.observe(counter);
  }
})();
