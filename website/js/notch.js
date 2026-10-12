/* Hero demo: the notch opens into HeyMate and walks the pointer through a
   three-step task in the spreadsheet below it. It plays by itself, and it
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
  var wave = display.querySelector(".notch-wave");
  var pointer = display.querySelector(".pointer");
  var tip = display.querySelector(".pointer-tip");
  var chartTool = display.querySelector("[data-tool=chart]");
  var cells = display.querySelectorAll("[data-col=b]");
  var chart = display.querySelector(".chart");
  var keys = document.querySelectorAll("[data-key]");
  var hint = document.querySelector("[data-try-hint]");

  var steps = [
    {
      say: "First, select the sales numbers in column B.",
      tip: "Click here",
      target: function () { return cells[0]; },
      hit: function () { return cells; },
      enter: function () { cells.forEach(function (c) { c.classList.add("sel"); }); }
    },
    {
      say: "Now click Chart in the toolbar.",
      tip: "Chart",
      target: function () { return chartTool; },
      hit: function () { return [chartTool]; },
      enter: function () { chartTool.classList.add("target"); }
    },
    {
      say: "That's your chart. Want me to show you how to add a title?",
      tip: "Your chart",
      target: function () { return chart; },
      hit: function () { return []; },
      enter: function () { chartTool.classList.remove("target"); chart.classList.add("show"); }
    }
  ];

  var reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  var index = 0;          // next step to show
  var timer = null;
  var running = false;
  var listening = false;
  var driven = false;     // the visitor took over: no autoplay until it ends

  function reset() {
    cells.forEach(function (c) { c.classList.remove("sel"); });
    chartTool.classList.remove("target");
    chart.classList.remove("show");
    display.querySelectorAll(".clickable").forEach(function (el) { el.classList.remove("clickable"); });
  }

  function aim(el) {
    var box = display.getBoundingClientRect();
    var r = el.getBoundingClientRect();
    pointer.style.left = (r.left - box.left + Math.min(r.width * 0.35, 40)) + "px";
    pointer.style.top = (r.top - box.top + r.height * 0.55) + "px";
  }

  function show(i) {
    var step = steps[i];
    display.classList.remove("is-listening");
    stepLabel.textContent = "step " + (i + 1) + " of " + steps.length;
    say.textContent = step.say;
    tip.textContent = step.tip;
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
      notch.classList.remove("open");
      schedule(function () {
        reset();
        index = 0;
        notch.classList.add("open");
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
    notch.classList.add("open");
    display.classList.add("is-listening");
    stepLabel.textContent = "listening";
    say.textContent = "“Walk me through making a chart.”";
    dots.forEach(function (d) { d.classList.remove("on"); });
    keys.forEach(function (k) { k.classList.add("down"); });
    if (hint) hint.classList.add("used");
  }
  function stopListening() {
    if (!listening) return;
    listening = false;
    keys.forEach(function (k) { k.classList.remove("down"); });
    stepLabel.textContent = "thinking";
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
    notch.classList.add("open");
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
    notch.classList.add("open");
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
  void wave;
})();
