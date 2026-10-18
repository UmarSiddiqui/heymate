// The app's cast, live: Blobatars breathe, blink and follow the pointer with
// Alain's blobatar 2.7.0, the same looks the app ships. Milo and Nova use the
// app's portrait gaze layers: the face stays put and the irises move inside
// fixed eye masks. Reduced motion and touch screens keep everyone still.
import { Blobatar } from "./vendor/blobatar/blobatar.js";
import { gaze } from "./vendor/blobatar/gaze.js";

// Mirrors BlobatarCharacter.configuration(token:mateID:) in the app.
var LOOKS = {
  Tide: { hue: 190, shape: 0.32 },
  Lilac: { hue: 290, shape: 0.1 },
  Peach: { hue: 35, shape: 0.51 },
  Cloud: { hue: 220, shape: 0.82 },
  Sun: { hue: 80, shape: 0.96 },
  Mint: { hue: 155, shape: 0.74 }
};

document.querySelectorAll("[data-blob]").forEach(function (host) {
  var label = host.getAttribute("data-blob");
  var look = LOOKS[label];
  if (!look) return;
  var size = Number(host.getAttribute("data-size")) || 48;
  var svg = Blobatar({
    name: "HeyMate Blobatar " + label, size: size, hue: look.hue, tone: 0.25,
    traits: { shape: look.shape }, animate: "always"
  });
  host.textContent = "";
  host.appendChild(svg);
  gaze(svg, { target: "pointer" });
  host.addEventListener("click", function () {
    host.classList.remove("boop");
    void host.offsetWidth;
    host.classList.add("boop");
  });
});

// MiloGazeEyeGeometry.portrait: eye centres and sizes on the 550 × 600 render.
var EYES = [{ x: 0.3386, y: 0.5461 }, { x: 0.6495, y: 0.5463 }];
var EYE_W = 0.2697, EYE_H = 0.2962;
var portraits = [];
var still = matchMedia("(prefers-reduced-motion: reduce)");
var fine = matchMedia("(hover: hover) and (pointer: fine)");

document.querySelectorAll("[data-portrait]").forEach(function (host) {
  var who = host.getAttribute("data-portrait");
  host.textContent = "";
  var base = new Image();
  base.src = "assets/img/mate/" + who + "-head.webp";
  base.alt = "";
  base.className = "portrait-base";
  host.appendChild(base);
  var irises = [];
  EYES.forEach(function (eye) {
    var clip = document.createElement("span");
    clip.className = "portrait-eye";
    clip.style.clipPath = "ellipse(" + (EYE_W * 50) + "% " + (EYE_H * 50) + "% at " + (eye.x * 100) + "% " + (eye.y * 100) + "%)";
    var img = new Image();
    img.src = "assets/img/mate/" + who + "-eyes.webp";
    img.alt = "";
    clip.appendChild(img);
    host.appendChild(clip);
    irises.push(img);
  });
  portraits.push({ host: host, irises: irises, x: 0, y: 0 });
});

var px = null, py = null, last = 0, frame = 0;
function live() { return fine.matches && !still.matches; }
function tick(now) {
  frame = 0;
  var dt = last ? Math.min(now - last, 150) : 1000 / 60;
  last = now;
  var amount = 1 - Math.exp(-dt / 75), moving = false;
  portraits.forEach(function (p) {
    var box = p.host.getBoundingClientRect();
    var tx = 0, ty = 0;
    if (px !== null && live()) {
      var dx = (px - (box.left + box.width / 2)) / Math.max(box.width, 120);
      var dy = (py - (box.top + box.height / 2)) / Math.max(box.height, 120);
      var length = Math.max(1, Math.hypot(dx, dy));
      var reach = Math.min(6, box.width * 0.045);
      tx = dx / length * reach;
      ty = dy / length * reach;
    }
    p.x += (tx - p.x) * amount;
    p.y += (ty - p.y) * amount;
    if (Math.abs(tx - p.x) > 0.02 || Math.abs(ty - p.y) > 0.02) moving = true;
    var t = "translate(" + p.x.toFixed(2) + "px," + p.y.toFixed(2) + "px)";
    p.irises.forEach(function (img) { img.style.transform = t; });
  });
  if (moving) frame = requestAnimationFrame(tick);
  else last = 0;
}
function wake() { if (!frame && portraits.length) frame = requestAnimationFrame(tick); }
addEventListener("pointermove", function (e) { px = e.clientX; py = e.clientY; wake(); }, { passive: true });
document.documentElement.addEventListener("pointerleave", function () { px = py = null; wake(); });
addEventListener("scroll", wake, { passive: true });
still.addEventListener("change", wake);
