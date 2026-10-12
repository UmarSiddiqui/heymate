/* Hero demo: HeyMate listens from the notch, then its pointer walks through a
   short edit in the video editor below it: cut the intro off. It plays by itself, and it
   can be driven the way the app is: hold Control + Option to ask, then
   click the highlighted target to move on. Pointer positions come from the
   real elements, so the layout can change without retuning numbers.
   Reduced motion shows the middle step and stays still. */
(function () {
  var display = document.querySelector("[data-demo]");
  if (!display) return;
  var notch = display.querySelector(".notch");
  var say = display.querySelector(".notch-say");
  var stepLabel = display.querySelector(".notch-step");
  var dots = display.querySelectorAll(".notch-dots i");
  var pointer = display.querySelector(".pointer");
  var tip = display.querySelector(".pointer-tip");
  var tipStep = tip.querySelector(".tip-step");
  var tipSay = tip.querySelector(".tip-say");
  var splitTool = display.querySelector("[data-tool=split]");
  var spot = display.querySelector("[data-spot]");
  var intro = display.querySelector("[data-clip=intro]");
  var viewer = display.querySelector(".viewer");
  var playhead = display.querySelector("[data-playhead]");
  var timecode = display.querySelector("[data-timecode]");
  var keys = document.querySelectorAll("[data-key]");
  var hint = document.querySelector("[data-try-hint]");

  function seek(at, code) {
    playhead.style.setProperty("--at", at);
    timecode.textContent = code;
    display.classList.toggle("on-talk", at > 0.2 || intro.classList.contains("gone"));
  }

  var steps = [
    {
      say: "First, click where the talking starts on the timeline.",
      tip: "Click here",
      target: function () { return spot; },
      hit: function () { return [spot]; },
      enter: function () {}
    },
    {
      say: "That's the spot. Now click Split in the toolbar.",
      tip: "Split",
      target: function () { return splitTool; },
      hit: function () { return [splitTool]; },
      enter: function () { seek(0.22, "00:00:05"); splitTool.classList.add("target"); }
    },
    {
      say: "Now click the intro piece you just cut off. It goes away.",
      tip: "This piece",
      target: function () { return intro; },
      hit: function () { return [intro]; },
      enter: function () { splitTool.classList.remove("target"); intro.classList.add("cut"); }
    },
    {
      say: "Done. Your video now opens on the talking. Want a title next?",
      tip: "Starts here now",
      target: function () { return viewer; },
      hit: function () { return []; },
      enter: function () { intro.classList.remove("cut"); intro.classList.add("gone"); seek(0, "00:00:00"); }
    }
  ];

  var reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  var index = 0;          // next step to show
  var timer = null;
  var running = false;
  var listening = false;
  var driven = false;     // the visitor took over: no autoplay until it ends

  function reset() {
    splitTool.classList.remove("target");
    intro.classList.remove("cut", "gone");
    seek(0, "00:00:00");
    display.querySelectorAll(".clickable").forEach(function (el) { el.classList.remove("clickable"); });
  }

  function aim(el) {
    var box = display.getBoundingClientRect();
    var r = el.getBoundingClientRect();
    var x = r.left - box.left + Math.min(r.width * 0.35, 40);
    var y = r.top - box.top + r.height * 0.55;
    pointer.style.left = x + "px";
    pointer.style.top = y + "px";
    // Keep the instruction on screen: it hangs left of the pointer near the
    // right edge, and above it near the bottom.
    var flip = x > box.width * 0.55;
    pointer.classList.toggle("flip-x", flip);
    tip.style.maxWidth = Math.min(250, flip ? x - 4 : box.width - x - 30) + "px";
    pointer.classList.toggle("flip-y", y > box.height * 0.6);
  }

  function show(i) {
    var step = steps[i];
    display.classList.remove("is-listening");
    stepLabel.textContent = "step " + (i + 1) + " of " + steps.length;
    say.textContent = step.say;
    tipStep.textContent = (i + 1) + " / " + steps.length;
    tipSay.textContent = step.say;
    display.classList.add("busy");
    pointer.classList.remove("away");
    dots.forEach(function (d, n) { d.classList.toggle("on", n <= i); });
    display.querySelectorAll(".clickable").forEach(function (el) { el.classList.remove("clickable"); });
    step.enter();
    step.hit().forEach(function (el) { el.classList.add("clickable"); });
    aim(step.target());
  }

  function schedule(fn, ms) { clearTimeout(timer); timer = setTimeout(fn, ms); }

  function tick() {
    if (index < steps.length) {
      show(index);
      index += 1;
      if (!driven) schedule(tick, index === steps.length ? 3600 : 2600);
      else if (index === steps.length) schedule(function () { driven = false; tick(); }, 5200);
    } else {
      pointer.classList.add("away");
      display.classList.remove("busy");
      schedule(function () {
        reset();
        index = 0;
        schedule(tick, 900);
      }, 1400);
    }
  }

  // Clicking the highlighted target moves on, like the real walkthrough.
  display.addEventListener("click", function (event) {
    var el = event.target.closest(".clickable");
    if (!el || listening) return;
    driven = true;
    tick();
  });

  // Hold Control + Option to ask. Release to hear the answer.
  function startListening() {
    if (listening) return;
    listening = true;
    driven = true;
    clearTimeout(timer);
    reset();
    display.classList.add("is-listening", "busy");
    pointer.classList.remove("away");
    stepLabel.textContent = "listening";
    say.textContent = "“How do I cut the boring intro out of this?”";
    tipStep.textContent = "listening";
    tipSay.textContent = say.textContent;
    aim(display.querySelector(".viewer"));
    dots.forEach(function (d) { d.classList.remove("on"); });
    keys.forEach(function (k) { k.classList.add("down"); });
    if (hint) hint.classList.add("used");
  }
  function stopListening() {
    if (!listening) return;
    listening = false;
    keys.forEach(function (k) { k.classList.remove("down"); });
    stepLabel.textContent = "thinking";
    tipStep.textContent = "thinking";
    index = 0;
    schedule(tick, 700);
  }
  function wantsAsk(event) { return event.ctrlKey && event.altKey; }
  document.addEventListener("keydown", function (event) {
    if (wantsAsk(event) && !reduce) startListening();
  });
  document.addEventListener("keyup", function (event) {
    if (listening && !wantsAsk(event)) stopListening();
  });
  window.addEventListener("blur", stopListening);
  // Touch and mouse: press and hold the key caps instead.
  keys.forEach(function (k) {
    k.addEventListener("pointerdown", function (event) { event.preventDefault(); if (!reduce) startListening(); });
  });
  document.addEventListener("pointerup", stopListening);
  document.addEventListener("pointercancel", stopListening);

  if (reduce) {
    steps[0].enter();
    show(1);
    window.addEventListener("resize", function () { aim(steps[1].target()); });
    return;
  }

  function start() {
    if (running) return;
    running = true;
    // The visitor is driving: scrolling back into view must not take over.
    if (listening || driven) return;
    schedule(tick, 900);
  }
  function stop() {
    running = false;
    if (!driven) clearTimeout(timer);
  }

  if ("IntersectionObserver" in window) {
    new IntersectionObserver(function (entries) {
      entries.forEach(function (e) { if (e.isIntersecting) start(); else if (!listening) stop(); });
    }, { threshold: 0.3 }).observe(display);
  } else {
    start();
  }
  window.addEventListener("resize", function () {
    var current = steps[Math.max(0, index - 1)];
    if (current) aim(current.target());
  });
})();
