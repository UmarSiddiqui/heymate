/* Homepage notch and companion. No microphone, screen, or AI-provider access. */
(function () {
  "use strict";
  var $ = function (s) { return document.querySelector(s); };
  var $$ = function (s) { return Array.from(document.querySelectorAll(s)); };
  var reduce = matchMedia("(prefers-reduced-motion: reduce)");
  var fine = matchMedia("(hover: hover) and (pointer: fine)");
  var compact = matchMedia("(max-width: 820px)");
  var activeMate = "Milo";
  var guide = $("#buddy-guide"), caption = guide.querySelector(".buddy-caption");
  var glyph = guide.querySelector(".buddy-glyph"), arrow = guide.querySelector(".buddy-arrow");
  var followTilt = 0, restTimer = 0;
  var buddyButton = $("#buddy-toggle"), buddyEnabled = true;
  var notch = $("#mini-notch"), notchPanel = $("#mini-notch-panel"), notchToggle = $("#notch-toggle");
  var docking = false, dockAnimation = null;
  var notchOpen = false, notchPinned = false, hoverTimer = 0, leaveTimer = 0, notchFrame = 0, notchState = { width: 185, height: 32, cardness: 0, opacity: 0 };
  var surface = $(".mini-notch-surface"), surfacePath = surface.querySelector("path");
  var tabIndicator = $(".mini-tab-indicator"), transientAnimations = new Set();
  var notchClosedWidth = notchToggle.offsetWidth, notchLayout = { width: 760, height: 224 };
  var captionWidth = 260, captionHeight = 100;
  function clamp(value, low, high) { return Math.max(low, Math.min(high, value)); }
  function mix(a, b, t) { return a + (b - a) * t; }
  // CNNotchMotion.swift: opening response .62 / damping .72; fold .26 / .92.
  function spring(time, response, damping) {
    var omega = 2 * Math.PI / response, damped = omega * Math.sqrt(1 - damping * damping);
    return 1 - Math.exp(-damping * omega * time) * (Math.cos(damped * time) + damping * omega / damped * Math.sin(damped * time));
  }
  function animateEntry(node, duration, distance) {
    if (reduce.matches || document.hidden) return null;
    if (node._entryAnimation) node._entryAnimation.cancel();
    var animation = node.animate([
      { opacity: 0, transform: "translateY(" + distance + "px)" },
      { opacity: 1, transform: "translateY(0)" }
    ], { duration: duration, easing: "cubic-bezier(.2,.8,.2,1)" });
    node._entryAnimation = animation;
    transientAnimations.add(animation);
    animation.finished.then(function () { transientAnimations.delete(animation); }, function () { transientAnimations.delete(animation); });
    return animation;
  }
  // The Home surface expands along the top edge, matching the real app.
  // Keep content at its final size while the black housing grows around it.
  function silhouette(width, height, cardness) {
    var c = clamp(cardness, 0, 1);
    var topRadius = Math.min(12 * c, width / 2, height / 2);
    var bottomRadius = Math.min(mix(11, 30, c), width / 2, height / 2);
    return "M" + topRadius + ",0 H" + (width - topRadius) +
      " Q" + width + ",0 " + width + "," + topRadius +
      " V" + (height - bottomRadius) + " Q" + width + "," + height + " " + (width - bottomRadius) + "," + height +
      " H" + bottomRadius + " Q0," + height + " 0," + (height - bottomRadius) +
      " V" + topRadius + " Q0,0 " + topRadius + ",0 Z";
  }
  function renderNotch(state) {
    notchState = state;
    var width = Math.max(1, state.width), height = Math.max(1, state.height);
    surface.style.width = width + "px"; surface.style.height = height + "px";
    surface.setAttribute("viewBox", "0 0 " + width + " " + height);
    surfacePath.setAttribute("d", silhouette(width, height, state.cardness));
    notchPanel.style.opacity = clamp(state.opacity, 0, 1);
    notchPanel.style.clipPath = "inset(0px " + Math.max(0, (notchLayout.width - width) / 2) + "px " + Math.max(0, notchLayout.height - height) + "px)";
  }
  function morphNotch(open, immediate, resizing) {
    cancelAnimationFrame(notchFrame); notchFrame = 0;
    var from = Object.assign({}, notchState);
    notchClosedWidth = notchToggle.offsetWidth;
    if (!notchPanel.hidden) notchLayout = { width: notchPanel.offsetWidth, height: notchPanel.offsetHeight };
    var to = { width: open ? notchLayout.width : notchClosedWidth, height: open ? notchLayout.height : 32, cardness: open ? 1 : 0, opacity: open ? 1 : 0 };
    if (immediate || reduce.matches || document.hidden) {
      renderNotch(to); if (!open) notchPanel.hidden = true; return;
    }
    var response = resizing ? .38 : open ? .62 : .26, damping = resizing ? .88 : open ? .72 : .92;
    var duration = resizing ? 440 : open ? 920 : 330, start = performance.now();
    function tick(now) {
      var linear = clamp((now - start) / duration, 0, 1), eased = spring((now - start) / 1000, response, damping);
      var opacity = resizing ? 1 : open ? mix(from.opacity, 1, clamp((linear - .15) / .45, 0, 1)) : from.opacity * (1 - clamp(linear / .35, 0, 1));
      renderNotch({ width: mix(from.width, to.width, clamp(eased, 0, 1)), height: mix(from.height, to.height, eased), cardness: mix(from.cardness, to.cardness, clamp(eased, 0, 1)), opacity: opacity });
      if (linear < 1) notchFrame = requestAnimationFrame(tick);
      else { notchFrame = 0; renderNotch(to); if (!notchOpen) notchPanel.hidden = true; }
    }
    notchFrame = requestAnimationFrame(tick);
  }
  function positionTabIndicator(tab, animate) {
    var next = { left: tab.offsetLeft, width: tab.offsetWidth };
    var before = tabIndicator.getBoundingClientRect(), parent = tab.parentElement.getBoundingClientRect();
    var from = { left: before.left - parent.left, width: before.width };
    if (tabIndicator._motion) tabIndicator._motion.cancel();
    tabIndicator.style.transform = "translateX(" + next.left + "px)"; tabIndicator.style.width = next.width + "px";
    if (animate && !reduce.matches && before.width > 0) {
      var frames = [];
      for (var i = 0; i <= 24; i++) { var t = i / 24, p = i === 24 ? 1 : spring(t * .38, .26, .9); frames.push({ transform: "translateX(" + mix(from.left, next.left, p) + "px)", width: mix(from.width, next.width, p) + "px", offset: t }); }
      tabIndicator._motion = tabIndicator.animate(frames, { duration: 380, easing: "linear" });
    }
  }
  var context = "hey, i’m heymate. a second pair of eyes, minus the chair. have a look around.";
  var pendingContext = context, contextTimer = 0, typeTimer = 0, tipReady = true;
  var words = document.createElement("span"), message = document.createElement("span");
  var measure = document.createElement("span"), dots = document.createElement("span");
  var caret = document.createElement("span");
  words.className = "buddy-words"; message.className = "buddy-message";
  measure.className = "buddy-measure"; dots.className = "buddy-thinking";
  caret.className = "buddy-caret";
  for (var dot = 0; dot < 3; dot++) dots.appendChild(document.createElement("i"));
  message.append(words, caret);
  caption.replaceChildren(measure, message, dots);
  var x = Math.min(innerWidth - 270, innerWidth / 2 + 90), y = 55;
  var px = x, py = y, frame = 0, pointerSeen = false, quietTimer, scrollTimer;
  function setNotch(open, restoreFocus, hover) {
    clearTimeout(hoverTimer); clearTimeout(leaveTimer);
    if (open === notchOpen && !notchFrame) { if (restoreFocus) notchToggle.focus({ preventScroll: true }); return; }
    notchPinned = open && !hover;
    notchOpen = open;
    notchToggle.setAttribute("aria-expanded", String(open));
    notchPanel.inert = !open;
    notch.classList.toggle("notch-open", open);
    if (open) {
      notchPanel.hidden = false;
      guide.classList.add("quiet");
      var selected = notch.querySelector('[role="tab"][aria-selected="true"]');
      positionTabIndicator(selected, false);
      if (!hover) selected.focus({ preventScroll: true });
    } else if (restoreFocus) notchToggle.focus({ preventScroll: true });
    morphNotch(open, false, false);
  }
  // Same hover intent and exit grace as NotchCompanionController.swift.
  notch.addEventListener("pointerenter", function (e) {
    clearTimeout(leaveTimer);
    if (e.pointerType === "touch" || !fine.matches || notchOpen || notchFrame) return;
    hoverTimer = setTimeout(function () { setNotch(true, false, true); }, 180);
  });
  notch.addEventListener("pointerleave", function () {
    clearTimeout(hoverTimer);
    if (notchOpen && !notchPinned) leaveTimer = setTimeout(function () { setNotch(false, false); }, 220);
  });
  notchToggle.addEventListener("click", function () { setNotch(!notchOpen, false); });
  $(".mini-notch-collapse").addEventListener("click", function () { setNotch(false, true); });
  document.addEventListener("click", function (e) { if (notchOpen && !notch.contains(e.target)) setNotch(false, false); });
  $$("[data-notch-link]").forEach(function (link) { link.addEventListener("click", function () { setNotch(false, false); }); });
  var notchTabs = $$("[data-notch-tab]");
  function selectNotchTab(tab) {
    if (tab.getAttribute("aria-selected") === "true") return;
    var bottom = $(".mini-notch-bottom"), before = bottom.getBoundingClientRect();
    notchTabs.forEach(function (button) {
      var selected = button === tab;
      button.setAttribute("aria-selected", String(selected)); button.tabIndex = selected ? 0 : -1;
      $("#notch-" + button.dataset.notchTab + "-panel").hidden = !selected;
    });
    positionTabIndicator(tab, true);
    animateEntry($("#notch-" + tab.dataset.notchTab + "-panel"), 160, 0);
    if (bottom._shiftAnimation) bottom._shiftAnimation.cancel();
    var delta = before.top - bottom.getBoundingClientRect().top;
    if (!reduce.matches && delta) {
      var shift = bottom.animate([{ transform: "translateY(" + delta + "px)" }, { transform: "translateY(0)" }], { duration: 320, easing: "cubic-bezier(.2,.8,.2,1)" });
      bottom._shiftAnimation = shift;
      transientAnimations.add(shift); shift.finished.then(function () { transientAnimations.delete(shift); }, function () { transientAnimations.delete(shift); });
    }
    if (notchOpen) morphNotch(true, false, true);
  }
  notchTabs.forEach(function (tab, index) {
    tab.addEventListener("click", function () { selectNotchTab(tab); });
    tab.addEventListener("keydown", function (e) {
      var next = e.key === "Home" ? 0 : e.key === "End" ? notchTabs.length - 1 : e.key === "ArrowRight" ? (index + 1) % notchTabs.length : e.key === "ArrowLeft" ? (index + notchTabs.length - 1) % notchTabs.length : null;
      if (next !== null) { e.preventDefault(); selectNotchTab(notchTabs[next]); notchTabs[next].focus(); }
    });
  });
  function openTour() {
    setNotch(false, false);
    var film = $("#tour video");
    $("#tour").scrollIntoView({ behavior: reduce.matches ? "instant" : "smooth", block: "center" });
    film.focus({ preventScroll: true });
    guide.classList.add("quiet");
  }
  $$("[data-open-tour]").forEach(function (button) { button.addEventListener("click", openTour); });
  $$("[data-select-mate]").forEach(function (button) {
    button.addEventListener("click", function () {
      activeMate = button.dataset.selectMate;
      $$("[data-select-mate]").forEach(function (other) {
        var selected = other.dataset.selectMate === activeMate;
        other.classList.toggle("selected", selected);
        if (other.hasAttribute("aria-pressed")) other.setAttribute("aria-pressed", String(selected));
      });
      setContext(activeMate.toLowerCase() + " it is. give your mates their own jobs and personalities in the mac app.");
    });
  });
  document.addEventListener("keydown", function (event) {
    if (event.key === "Escape" && notchOpen) setNotch(false, true);
  });
  window.addEventListener("blur", function () { guide.classList.add("quiet"); });
  var finder = $("[data-finder]"), integrationGroups = $$(".directory > section");
  finder.addEventListener("input", function () {
    var query = finder.value.trim().toLocaleLowerCase(), matches = 0;
    integrationGroups.forEach(function (group) {
      var groupMatches = 0;
      group.querySelectorAll(".tiles > li").forEach(function (item) {
        var match = item.textContent.toLocaleLowerCase().includes(query);
        item.hidden = !match;
        if (match) groupMatches++;
      });
      group.hidden = groupMatches === 0;
      matches += groupMatches;
    });
    $("[data-finder-miss]").hidden = matches > 0;
  });
  function paint() {
    frame = 0;
    if (!buddyEnabled || docking || !fine.matches || reduce.matches || document.hidden) return;
    // CompanionCursorView follows at 60Hz without positional easing. Its
    // position is the glyph center, 35pt right and 25pt below the system pointer.
    var dx = px - x, dy = py - y, moved = Math.hypot(dx, dy) >= .5;
    if (moved) { x = px; y = py; armRest(); }
    // Same banking rule as updateFollowTilt(horizontalStep:).
    var targetTilt = moved ? Math.max(-8, Math.min(8, dx * .5)) : 0;
    followTilt += (targetTilt - followTilt) * .2;
    if (Math.abs(followTilt) < .05 && targetTilt === 0) followTilt = 0;
    arrow.style.setProperty("--buddy-tilt", followTilt.toFixed(2) + "deg");
    var gx = Math.max(4, Math.min(innerWidth - guide.offsetWidth - 4, x)), gy = Math.max(4, Math.min(innerHeight - guide.offsetHeight - 4, y));
    placeBuddy(gx, gy);
    if (moved || followTilt !== 0) frame = requestAnimationFrame(paint);
  }
  function armRest() {
    clearTimeout(restTimer);
    glyph.classList.remove("breathing");
    restTimer = setTimeout(function () {
      if (buddyEnabled && fine.matches && !reduce.matches && !document.hidden && !guide.classList.contains("away")) glyph.classList.add("breathing");
    }, 3000);
  }
  function placeBuddy(gx, gy) {
    // Only the arrow follows the pointer. Caption bounds must never constrain
    // that position: flip and clamp the caption independently instead.
    guide.style.transform = "translate(" + gx.toFixed(1) + "px," + gy.toFixed(1) + "px)";
    var width = captionWidth, height = captionHeight;
    var left = gx + guide.offsetWidth + 7;
    if (left + width > innerWidth - 10) left = gx - width - 10;
    left = Math.max(10, Math.min(innerWidth - width - 10, left));
    var top = gy + guide.offsetHeight - 7;
    if (top + height > innerHeight - 10) top = gy - height - 8;
    top = Math.max(10, Math.min(innerHeight - height - 10, top));
    caption.style.left = (left - gx).toFixed(1) + "px";
    caption.style.top = (top - gy).toFixed(1) + "px";
    caption.classList.toggle("caption-left", left < gx);
  }
  function wake() { if (!frame) frame = requestAnimationFrame(paint); }
  function refreshCaptionPosition() {
    var box = guide.getBoundingClientRect();
    placeBuddy(box.left, box.top);
  }
  function finishSpeech() {
    clearTimeout(typeTimer);
    words.textContent = context;
    caption.dataset.state = "done";
    refreshCaptionPosition();
  }
  function speak(text) {
    clearTimeout(typeTimer);
    context = text;
    measure.textContent = text;
    words.textContent = "";
    if (reduce.matches || !buddyEnabled || !fine.matches || document.hidden) { finishSpeech(); return; }
    caption.dataset.state = "thinking";
    refreshCaptionPosition();
    var letters = Array.from(text), at = 0;
    function typeNext() {
      caption.dataset.state = "typing";
      // Small batches feel conversational without making visitors wait for a paragraph.
      var count = Math.min(letters.length - at, 1 + (at % 3 === 0 ? 1 : 0));
      at += count;
      words.textContent = letters.slice(0, at).join("");
      if (at === letters.length) { finishSpeech(); return; }
      var last = letters[at - 1];
      typeTimer = setTimeout(typeNext, /[.!?]/.test(last) ? 170 : /[,;:]/.test(last) ? 85 : 24);
    }
    typeTimer = setTimeout(typeNext, 230);
  }
  function setContext(text) {
    // The caption only appears over spots that have something to say, and only
    // once the pointer settles there. Everywhere else just the arrow shows.
    if (!text) {
      pendingContext = null; tipReady = false;
      clearTimeout(contextTimer); contextTimer = 0;
      guide.classList.add("quiet");
      return;
    }
    if (text !== pendingContext) {
      pendingContext = text;
      clearTimeout(contextTimer);
      contextTimer = 0;
      tipReady = false;
      guide.classList.add("quiet");
      contextTimer = setTimeout(function () {
        contextTimer = 0; tipReady = true; speak(pendingContext);
        if (buddyEnabled && !notchOpen && !docking) guide.classList.remove("quiet");
      }, 450);
    }
    if (tipReady && buddyEnabled && !notchOpen && !docking) guide.classList.remove("quiet");
  }
  function updateBuddy() { guide.hidden = (!buddyEnabled && !docking) || !fine.matches; if (guide.hidden || reduce.matches) { clearTimeout(restTimer); glyph.classList.remove("breathing"); followTilt = 0; arrow.style.setProperty("--buddy-tilt", "0deg"); } if (!guide.hidden && !notchOpen && !docking && tipReady) guide.classList.remove("quiet"); if (reduce.matches) { placeBuddy(18, Math.max(85,innerHeight - 190)); } else wake(); }
  document.addEventListener("pointermove", function (e) {
    if (e.pointerType === "touch") return;
    guide.classList.remove("away");
    pointerSeen = true; px = e.clientX + 35 - 8; py = e.clientY + 25 - 8;
    var target = e.target.closest("[data-guide]");
    if (buddyEnabled && !docking) setContext(contextFor(e.target));
    // Keep native controls clear of the companion’s caption.
    guide.classList.toggle("quiet", !!e.target.closest(".mini-notch") || (!!e.target.closest("input,button,video") && !target) || !tipReady);
    clearTimeout(quietTimer); quietTimer = setTimeout(function () { guide.classList.add("quiet"); }, 6500);
    wake();
  }, { passive: true });
  document.documentElement.addEventListener("pointerleave", function () { guide.classList.add("away"); clearTimeout(restTimer); glyph.classList.remove("breathing"); });
  function updateDock() {
    var r = $("#tour").getBoundingClientRect();
    var f = $(".home-footer").getBoundingClientRect();
    $(".desktop-mates").classList.toggle("dock-hidden", compact.matches && (r.top < innerHeight && r.bottom > 0 || f.top < innerHeight));
  }
  function contextFor(node) {
    var target = node && node.closest("[data-guide]");
    var section = node && node.closest("[data-context]");
    // Only small, specific spots speak; big sections stay quiet.
    if (target) return target.dataset.guide;
    return section && section.matches("article") ? section.dataset.context : null;
  }
  window.addEventListener("scroll", function () {
    updateDock();
    if (!buddyEnabled) return;
    guide.classList.add("quiet");
    clearTimeout(scrollTimer);
    scrollTimer = setTimeout(function () {
      // Resolve the actual element under the pointer after scrolling settles.
      // Viewport-center guesses could overwrite a more specific hover message.
      if (!buddyEnabled || !pointerSeen) return;
      var node = document.elementFromPoint(px - 27, py - 17);
      setContext(contextFor(node));
      if (node && node.closest(".mini-notch")) guide.classList.add("quiet");
    }, 120);
  }, { passive: true });
  function setBuddyEnabled(enabled, animate) {
    var before = guide.getBoundingClientRect();
    if (dockAnimation) { dockAnimation.cancel(); dockAnimation = null; }
    notch.classList.remove("buddy-docking");
    buddyEnabled = enabled;
    docking = false;
    buddyButton.setAttribute("aria-pressed", String(!enabled));
    $("[data-park-label]").textContent = enabled ? "Park buddy" : "Recall buddy";
    buddyButton.dataset.guide = enabled ? "park me here when you need the space. recall brings me back. even helpful siblings need a chair." : "there i am, parked right here. recall me when you want a hand again.";
    notch.classList.toggle("buddy-parked", !enabled);
    clearTimeout(restTimer); glyph.classList.remove("breathing");
    clearTimeout(contextTimer); contextTimer = 0;
    if (pendingContext) context = pendingContext; measure.textContent = context; finishSpeech();
    guide.classList.add("quiet");
    try { sessionStorage.setItem("heymate.buddy", String(enabled)); } catch (_) {}
    var dock = $(".park-orbit").getBoundingClientRect();
    var destination = { x: dock.left + dock.width / 2 - guide.offsetWidth / 2, y: dock.top + dock.height / 2 - guide.offsetHeight / 2 };
    if (animate && fine.matches && !reduce.matches && !document.hidden) {
      docking = true;
      notch.classList.add("buddy-docking");
      guide.hidden = false;
      var from = enabled ? destination : { x: before.x, y: before.y };
      var to = enabled ? { x: px, y: py } : destination;
      var distance = Math.hypot(to.x - from.x, to.y - from.y);
      var lift = Math.min(distance * .2, distance <= 320 ? 40 : distance <= 900 ? 80 : 120);
      var peakScale = distance <= 320 ? 1.15 : distance <= 900 ? 1.3 : 1.4;
      var control = { x: (from.x + to.x) / 2, y: (from.y + to.y) / 2 - lift };
      var duration = clamp(distance / 800, .6, 1.4) * 1000;
      var frames = [], angles = [], previousHeading = -35;
      for (var i = 0; i <= 60; i++) {
        var linear = i / 60, t = linear * linear * (3 - 2 * linear), u = 1 - t;
        var fx = u * u * from.x + 2 * u * t * control.x + t * t * to.x;
        var fy = u * u * from.y + 2 * u * t * control.y + t * t * to.y;
        if (distance > 900 && linear < .12) {
          var ox = control.x - from.x, oy = control.y - from.y, length = Math.max(Math.hypot(ox, oy), .001);
          var pull = 14 * Math.sin(linear / .12 * Math.PI); fx -= ox / length * pull; fy -= oy / length * pull;
        }
        var dx = 2 * u * (control.x - from.x) + 2 * t * (to.x - control.x);
        var dy = 2 * u * (control.y - from.y) + 2 * t * (to.y - control.y);
        var heading = Math.atan2(dy, dx) * 180 / Math.PI + 90;
        while (heading - previousHeading > 180) heading -= 360;
        while (heading - previousHeading < -180) heading += 360;
        // Let the arrow leave and land in its familiar resting pose.
        var blend = Math.min(1, linear / .12, (1 - linear) / .16);
        var rotation = mix(-35, heading, Math.max(0, blend));
        previousHeading = heading;
        frames.push({ transform: "translate(" + fx + "px," + fy + "px)", opacity: 1, offset: linear });
        angles.push({ transform: "rotate(" + rotation + "deg) scale(" + (1 + Math.sin(linear * Math.PI) * (peakScale - 1)) + ")", offset: linear });
      }
      var flight = guide.animate(frames, { duration: duration, easing: "linear", fill: "forwards" });
      var headingFlight = arrow.animate(angles, { duration: duration, easing: "linear", fill: "forwards" });
      dockAnimation = flight;
      flight.finished.then(function () {
        if (dockAnimation !== flight) return;
        docking = false; dockAnimation = null;
        notch.classList.remove("buddy-docking");
        x = to.x; y = to.y; placeBuddy(x, y);
        headingFlight.cancel(); flight.cancel(); updateBuddy();
      }, function () { headingFlight.cancel(); });
    } else updateBuddy();
  }
  buddyButton.addEventListener("click", function () { setBuddyEnabled(!buddyEnabled, true); });
  try { if (sessionStorage.getItem("heymate.buddy") === "false") setBuddyEnabled(false, false); } catch (_) {}
  compact.addEventListener("change", updateDock);
  fine.addEventListener("change", function () { if (!fine.matches) finishSpeech(); updateBuddy(); });
  function settleMotion() {
    clearTimeout(hoverTimer); clearTimeout(leaveTimer);
    morphNotch(notchOpen, true, false);
    transientAnimations.forEach(function (animation) { animation.cancel(); }); transientAnimations.clear();
    if (tabIndicator._motion) tabIndicator._motion.cancel();
    if (dockAnimation) { dockAnimation.cancel(); dockAnimation = null; docking = false; }
    notch.classList.remove("buddy-docking");
    updateBuddy();
  }
  reduce.addEventListener("change", function () { if (reduce.matches) { settleMotion(); clearTimeout(contextTimer); contextTimer = 0; if (pendingContext) context = pendingContext; measure.textContent = context; finishSpeech(); } updateBuddy(); });
  window.addEventListener("resize", function () {
    if (!pointerSeen) px = innerWidth / 2 + 90;
    updateDock(); updateBuddy(); morphNotch(notchOpen, true, false);
    if (notchOpen) positionTabIndicator(notch.querySelector('[role="tab"][aria-selected="true"]'), false);
  });
  document.addEventListener("visibilitychange", function () { if (document.hidden) { settleMotion(); clearTimeout(restTimer); glyph.classList.remove("breathing"); if (frame) cancelAnimationFrame(frame); frame = 0; clearTimeout(contextTimer); contextTimer = 0; if (pendingContext) context = pendingContext; measure.textContent = context; finishSpeech(); } else updateBuddy(); });
  var captionObserver = new ResizeObserver(function (entries) {
    var rect = entries[0].borderBoxSize;
    if (rect && rect[0]) { captionWidth = rect[0].inlineSize; captionHeight = rect[0].blockSize; }
    else { var bounds = caption.getBoundingClientRect(); captionWidth = bounds.width; captionHeight = bounds.height; }
    refreshCaptionPosition();
  });
  captionObserver.observe(caption);
  notchPanel.inert = true;
  renderNotch({ width: notchToggle.offsetWidth, height: 32, cardness: 0, opacity: 0 });
  updateDock();
  speak(context);
  updateBuddy();
  armRest();
  setTimeout(function () { guide.classList.add("quiet"); }, 7000);
})();
