/* Hero demo: the notch opens into HeyMate and walks the pointer through a
   three-step task in the spreadsheet below it. Pointer positions come from
   the real elements, so the layout can change without retuning numbers.
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
  var chartTool = display.querySelector("[data-tool=chart]");
  var cells = display.querySelectorAll("[data-col=b]");
  var chart = display.querySelector(".chart");

  var steps = [
    {
      say: "First, select the sales numbers in column B.",
      tip: "Drag from here",
      target: function () { return cells[0]; },
      enter: function () { cells.forEach(function (c) { c.classList.add("sel"); }); }
    },
    {
      say: "Now click Chart in the toolbar.",
      tip: "Chart",
      target: function () { return chartTool; },
      enter: function () { chartTool.classList.add("target"); }
    },
    {
      say: "That's your chart. Want me to show you how to add a title?",
      tip: "Your chart",
      target: function () { return chart; },
      enter: function () { chartTool.classList.remove("target"); chart.classList.add("show"); }
    }
  ];

  function reset() {
    cells.forEach(function (c) { c.classList.remove("sel"); });
    chartTool.classList.remove("target");
    chart.classList.remove("show");
  }

  function aim(el) {
    var box = display.getBoundingClientRect();
    var r = el.getBoundingClientRect();
    pointer.style.left = (r.left - box.left + Math.min(r.width * 0.35, 40)) + "px";
    pointer.style.top = (r.top - box.top + r.height * 0.55) + "px";
  }

  function show(index) {
    var step = steps[index];
    stepLabel.textContent = "step " + (index + 1) + " of " + steps.length;
    say.textContent = step.say;
    tip.textContent = step.tip;
    dots.forEach(function (d, i) { d.classList.toggle("on", i <= index); });
    step.enter();
    aim(step.target());
  }

  var reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  if (reduce) {
    notch.classList.add("open");
    steps[0].enter();
    show(1);
    window.addEventListener("resize", function () { aim(steps[1].target()); });
    return;
  }

  var index = 0;
  var timer = null;
  var running = false;

  function tick() {
    if (index < steps.length) {
      show(index);
      index += 1;
      timer = setTimeout(tick, index === steps.length ? 3600 : 2600);
    } else {
      notch.classList.remove("open");
      timer = setTimeout(function () {
        reset();
        index = 0;
        notch.classList.add("open");
        timer = setTimeout(tick, 900);
      }, 1400);
    }
  }

  function start() {
    if (running) return;
    running = true;
    notch.classList.add("open");
    timer = setTimeout(tick, 900);
  }
  function stop() {
    running = false;
    clearTimeout(timer);
  }

  if ("IntersectionObserver" in window) {
    new IntersectionObserver(function (entries) {
      entries.forEach(function (e) { if (e.isIntersecting) start(); else stop(); });
    }, { threshold: 0.3 }).observe(display);
  } else {
    start();
  }
  window.addEventListener("resize", function () {
    var current = steps[Math.max(0, index - 1)];
    if (current) aim(current.target());
  });
})();
