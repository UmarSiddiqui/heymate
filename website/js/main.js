(function () {
  var cfg = window.HEYMATE || {};
  document.querySelectorAll("[data-download]").forEach(function (el) {
    if (cfg.DOWNLOAD_URL) el.setAttribute("href", cfg.DOWNLOAD_URL);
  });
  document.querySelectorAll("[data-github]").forEach(function (el) {
    if (cfg.GITHUB_URL) el.setAttribute("href", cfg.GITHUB_URL);
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
    });
    nav.querySelectorAll(".nav-sheet a").forEach(function (a) {
      a.addEventListener("click", function () {
        nav.classList.remove("open");
        menu.setAttribute("aria-expanded", "false");
        menu.textContent = "Menu";
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
