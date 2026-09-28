(function () {
  var story = document.querySelector("[data-story]");
  if (!story) return;
  var beats = story.querySelectorAll(".beat");
  var panels = story.querySelectorAll(".panel");
  var mq = window.matchMedia("(max-width: 900px), (prefers-reduced-motion: reduce)");

  function set(index) {
    beats.forEach(function (el, i) { el.classList.toggle("on", i === index); });
    panels.forEach(function (el, i) { el.classList.toggle("on", i === index); });
  }

  function tick() {
    if (mq.matches) {
      beats.forEach(function (el) { el.classList.add("on"); });
      panels.forEach(function (el) { el.classList.add("on"); });
      return;
    }
    var rect = story.getBoundingClientRect();
    var total = story.offsetHeight - window.innerHeight;
    var scrolled = Math.min(Math.max(-rect.top, 0), Math.max(total, 1));
    var p = total > 0 ? scrolled / total : 0;
    var index = Math.min(beats.length - 1, Math.floor(p * beats.length));
    set(index);
  }

  set(0);
  tick();
  window.addEventListener("scroll", tick, { passive: true });
  window.addEventListener("resize", tick);
})();
