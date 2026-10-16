// Milo, docked at the bottom of the screen: blinks, waves when greeted,
// says hi at the finale, and ducks out of the way of the footer.
(function () {
  var mate = document.querySelector("[data-mate]");
  if (!mate) return;
  var btn = mate.querySelector("button");
  var bubble = mate.querySelector(".mate-bubble");
  var still = window.matchMedia("(prefers-reduced-motion: reduce)");
  var lines = ["Hey! I'm Milo.", "Hold ⌃⌥ and ask me anything.", "I live in your notch."];
  var said = 0;
  var busy = false;
  var talkTimer;

  function frame(name) { mate.setAttribute("data-frame", name); }

  function blink() {
    setTimeout(function () {
      if (!busy && !still.matches && !document.hidden) {
        frame("blink");
        setTimeout(function () { if (!busy) frame("idle"); }, 150);
      }
      blink();
    }, 2600 + Math.random() * 3600);
  }

  function greet(text) {
    busy = true;
    clearTimeout(talkTimer);
    bubble.textContent = text;
    frame("wave");
    mate.classList.add("talking", "awake");
    talkTimer = setTimeout(function () {
      mate.classList.remove("talking", "awake");
      frame("idle");
      busy = false;
    }, 2600);
  }

  btn.addEventListener("click", function () { greet(lines[said++ % lines.length]); });
  btn.addEventListener("mouseenter", function () { if (!busy) frame("wave"); });
  btn.addEventListener("mouseleave", function () { if (!busy) frame("idle"); });

  if ("IntersectionObserver" in window) {
    var footer = document.querySelector(".footer");
    if (footer) {
      new IntersectionObserver(function (entries) {
        mate.classList.toggle("away", entries[0].isIntersecting);
      }).observe(footer);
    }
    var finale = document.querySelector(".finale h2");
    if (finale) {
      var waved = false;
      new IntersectionObserver(function (entries) {
        if (entries[0].isIntersecting && !waved) { waved = true; greet("Say hey!"); }
      }, { threshold: 1 }).observe(finale);
    }
  }

  frame("idle");
  blink();
})();
