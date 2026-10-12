/* Two small hands-on moments: drafting an agent from a sentence, and asking
   "does it work with…?" of the integrations list. Example data only. */
(function () {
  var reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  // ---- Agent drafting demo ----
  var drafter = document.querySelector("[data-drafter]");
  if (drafter) {
    var drafts = {
      inbox: {
        text: "Draft replies to customer email every morning",
        face: "signalpointer", name: "Inbox Ivy", role: "Drafts replies to customer email each morning",
        habits: ["Read new customer email before 9", "Save drafts in Gmail, never send them", "Lead with anything urgent or angry"],
        asks: ["Sending any email", "Offering refunds or discounts"]
      },
      radar: {
        text: "Watch competitors' prices and tell me what changed",
        face: "instrumentlens", name: "Market Radar", role: "Checks competitor pricing pages every Monday",
        habits: ["Keep a baseline file in output/", "Report only what changed since last week", "Link the page behind every number"],
        asks: ["Signing up for anything", "Contacting a competitor"]
      },
      tutor: {
        text: "Teach me Figma, one step at a time",
        face: "signalcomet", name: "Frame Coach", role: "Teaches Figma on screen, one step at a time",
        habits: ["Point at the exact control before explaining it", "Wait until you've tried each step", "Use your own file, not a sample"],
        asks: ["Deleting or overwriting layers"]
      }
    };
    var textEl = drafter.querySelector("[data-draft-text]");
    var card = drafter.querySelector("[data-draft-card]");
    var face = drafter.querySelector("[data-draft-face]");
    var nameEl = drafter.querySelector("[data-draft-name]");
    var roleEl = drafter.querySelector("[data-draft-role]");
    var habitsEl = drafter.querySelector("[data-draft-habits]");
    var asksEl = drafter.querySelector("[data-draft-asks]");
    var chips = drafter.querySelectorAll("[data-draft]");
    var run = 0;

    function fill(list, items) {
      list.innerHTML = "";
      items.forEach(function (item, i) {
        var li = document.createElement("li");
        li.textContent = item;
        li.style.transitionDelay = reduce ? "0ms" : (120 + i * 110) + "ms";
        list.appendChild(li);
      });
    }

    function draft(key) {
      var d = drafts[key];
      var mine = ++run;
      chips.forEach(function (c) { c.setAttribute("aria-pressed", c.getAttribute("data-draft") === key ? "true" : "false"); });
      card.hidden = true;
      card.classList.remove("in");
      drafter.classList.add("typing");
      var shown = 0;
      function type() {
        if (mine !== run) return;
        shown = reduce ? d.text.length : Math.min(d.text.length, shown + 2);
        textEl.textContent = d.text.slice(0, shown);
        if (shown < d.text.length) { setTimeout(type, 24); return; }
        drafter.classList.remove("typing");
        drafter.classList.add("drafting");
        setTimeout(function () {
          if (mine !== run) return;
          drafter.classList.remove("drafting");
          face.src = "assets/img/faces/v3/" + d.face + ".webp";
          nameEl.textContent = d.name;
          roleEl.textContent = d.role;
          fill(habitsEl, d.habits);
          fill(asksEl, d.asks);
          card.hidden = false;
          requestAnimationFrame(function () { requestAnimationFrame(function () { card.classList.add("in"); }); });
        }, reduce ? 0 : 900);
      }
      type();
    }

    chips.forEach(function (c) {
      c.setAttribute("aria-pressed", "false");
      c.addEventListener("click", function () { draft(c.getAttribute("data-draft")); });
    });

    // Draft the first one when the section comes into view, once.
    if ("IntersectionObserver" in window) {
      var io = new IntersectionObserver(function (entries) {
        if (entries[0].isIntersecting) { io.disconnect(); if (run === 0) draft("radar"); }
      }, { threshold: 0.5 });
      io.observe(drafter);
    } else {
      draft("radar");
    }
  }

  // ---- Integrations finder ----
  var finder = document.querySelector("[data-finder]");
  if (finder) {
    var items = document.querySelectorAll(".directory .tiles li");
    var miss = document.querySelector("[data-finder-miss]");
    var directory = document.querySelector(".directory");
    finder.addEventListener("input", function () {
      var q = finder.value.trim().toLowerCase();
      var hits = 0;
      items.forEach(function (li) {
        var match = !q || li.textContent.toLowerCase().indexOf(q) !== -1;
        li.classList.toggle("dim", !match);
        li.classList.toggle("hit", !!q && match);
        if (q && match) hits += 1;
      });
      directory.classList.toggle("searching", !!q);
      miss.hidden = !(q && hits === 0);
    });
  }
})();
