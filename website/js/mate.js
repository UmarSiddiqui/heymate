// Milo lives along the bottom of the screen. He wanders left and right with a
// waddling step, stops to look around, point, or hop, blinks, waves when you
// hover, says hi when clicked, jumps when you scroll fast, cheers at the
// finale, and ducks out of the way of the footer. Reduced motion keeps him
// standing still in his corner.
(function () {
  var mate = document.querySelector("[data-mate]");
  if (!mate) return;
  var btn = mate.querySelector(".mate-btn");
  var step = mate.querySelector(".mate-step");
  var bubble = mate.querySelector(".mate-bubble");
  var still = window.matchMedia("(prefers-reduced-motion: reduce)");
  var wide = window.matchMedia("(min-width: 1300px)");
  var lines = ["Hey! I'm Milo.", "Hold ⌃⌥ and ask me anything.", "I live in your notch.", "Wanna see a trick?"];
  var said = 0;

  // x is Milo's offset from his home corner, always <= 0 (leftward).
  var x = 0, target = 0, facing = 1, phase = 0, hopT = -1;
  var mode = "idle"; // idle | walk | pose | talk
  var hovered = false, away = false, last = 0, nextAt = 0, poseUntil = 0;
  var lastScrollY = window.scrollY, lastScrollT = 0, hopCooldown = 0;

  function frame(name) { if (mate.getAttribute("data-frame") !== name) mate.setAttribute("data-frame", name); }
  function rand(a, b) { return a + Math.random() * (b - a); }

  // How far left Milo may roam: a band at the bottom right on wide screens,
  // most of the edge on narrow ones (where only his head shows), leaving room
  // for his speech bubble.
  function range() {
    var w = window.innerWidth;
    return wide.matches ? Math.min(w * 0.4, 520) : Math.max(0, w - 260);
  }

  function plan(now) {
    if (still.matches) return;
    var r = range(), roll = Math.random();
    if (x < -40 && roll < 0.35) { walkTo(0); return; }
    if (roll < 0.7) {
      var t = -rand(0, r);
      if (Math.abs(t - x) < 120) t = x < -r / 2 ? 0 : -r * rand(0.5, 1);
      walkTo(t);
    } else if (roll < 0.85) {
      pose("think", now, 1600);
    } else {
      pose("celebrate", now, 700); hop(now);
    }
  }

  function walkTo(t) { target = Math.max(-range(), Math.min(0, t)); mode = "walk"; mate.classList.add("walking"); frame("idle"); }
  function pose(name, now, ms) { mode = "pose"; poseUntil = now + ms; frame(name); }
  function hop(now) { if (!still.matches) hopT = now; }
  function rest(now) {
    mode = "idle"; mate.classList.remove("walking"); frame("idle");
    nextAt = now + rand(3500, 8000);
  }

  function greet(text, now) {
    mode = "talk"; poseUntil = now + 2600;
    mate.classList.remove("walking");
    bubble.textContent = text;
    frame(text === "Say hey!" ? "celebrate" : "wave");
    if (text === "Say hey!") hop(now);
    mate.classList.add("talking", "awake");
  }

  function tick(now) {
    var dt = Math.min(0.05, last ? (now - last) / 1000 : 0);
    last = now;
    var lift = 0, tilt = 0, squash = 1;

    if (!away && !document.hidden) {
      if (mode === "walk") {
        var d = target - x, dir = d < 0 ? -1 : 1;
        facing = dir;
        var move = Math.min(Math.abs(d), 70 * dt);
        x += dir * move;
        phase += dt * 5.2; // steps per second, give or take
        var s = Math.sin(phase * Math.PI);
        lift = Math.abs(s) * 5;
        tilt = s * 6 + dir * 3;
        if (Math.abs(target - x) < 0.5) { x = target; rest(now); }
      } else if (mode === "pose" || mode === "talk") {
        if (now > poseUntil) {
          if (mode === "talk") mate.classList.remove("talking", "awake");
          rest(now);
        }
      } else if (mode === "idle" && !hovered) {
        if (now > nextAt) plan(now);
      }
    }

    if (hopT >= 0) {
      var p = (now - hopT) / 650;
      if (p >= 1) hopT = -1;
      else {
        // anticipate, jump, land
        if (p < 0.15) squash = 1 - p * 0.5;
        else if (p < 0.85) lift = Math.sin(((p - 0.15) / 0.7) * Math.PI) * 26;
        else squash = 1 - (1 - p) * 0.4;
      }
    }

    mate.style.setProperty("--x", x.toFixed(1) + "px");
    step.style.transform = "translateY(" + (-lift).toFixed(1) + "px) rotate(" + tilt.toFixed(2) + "deg) scale(" + facing + "," + squash.toFixed(3) + ")";
    requestAnimationFrame(tick);
  }

  function blink() {
    setTimeout(function () {
      if (!still.matches && !document.hidden && mate.getAttribute("data-frame") === "idle") {
        frame("blink");
        setTimeout(function () { if (mate.getAttribute("data-frame") === "blink") frame("idle"); }, 150);
      }
      blink();
    }, rand(2600, 6200));
  }

  btn.addEventListener("click", function () { greet(lines[said++ % lines.length], performance.now()); });
  btn.addEventListener("mouseenter", function () {
    hovered = true;
    if (mode === "walk" || mode === "idle") { mode = "idle"; mate.classList.remove("walking"); frame("wave"); }
  });
  btn.addEventListener("mouseleave", function () {
    hovered = false;
    if (mode === "idle") rest(performance.now());
  });

  // A fast scroll makes him jump.
  window.addEventListener("scroll", function () {
    var now = performance.now(), y = window.scrollY;
    var v = Math.abs(y - lastScrollY) / Math.max(1, now - lastScrollT) * 1000;
    lastScrollY = y; lastScrollT = now;
    if (!still.matches && v > 3000 && now > hopCooldown && mode !== "talk") {
      hopCooldown = now + 4000;
      hop(now);
    }
  }, { passive: true });

  if ("IntersectionObserver" in window) {
    var footer = document.querySelector(".footer");
    if (footer) {
      new IntersectionObserver(function (entries) {
        away = entries[0].isIntersecting;
        mate.classList.toggle("away", away);
      }).observe(footer);
    }
    var finale = document.querySelector(".finale h2");
    if (finale) {
      var cheered = false;
      new IntersectionObserver(function (entries) {
        if (entries[0].isIntersecting && !cheered) { cheered = true; greet("Say hey!", performance.now()); }
      }, { threshold: 1 }).observe(finale);
    }
  }

  window.addEventListener("resize", function () {
    var r = range();
    if (x < -r) { x = -r; target = Math.max(target, -r); }
  });

  frame("idle");
  nextAt = performance.now() + 2500;
  requestAnimationFrame(tick);
  blink();
})();
