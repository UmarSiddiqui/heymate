(function () {
  var player = document.getElementById('visual-answer-player');
  if (!player) return;
  var examples = {
    biryani: { name: 'Chicken biryani · 2D explainer', label: 'HeyMate drawing a chicken biryani explanation over the desktop' },
    camera: { name: 'Raspberry Pi camera · Connection diagram', label: 'HeyMate drawing a Raspberry Pi camera connection diagram over the desktop' },
    board: { name: 'Raspberry Pi · 3D explanation', label: 'HeyMate showing a labelled 3D circuit board over the desktop' }
  };
  var buttons = document.querySelectorAll('[data-visual-example]');
  var active = 'biryani';
  var played = new Set();
  var visible = false;
  var reduce = window.matchMedia('(prefers-reduced-motion: reduce)');
  player.muted = true;
  player.loop = false;

  function start(explicit) {
    if (document.hidden || (!explicit && (!visible || reduce.matches || played.has(active)))) return;
    var key = active;
    var attempt = player.play();
    if (attempt && attempt.then) attempt.then(function () { played.add(key); }, function () {
      // Native controls remain available when autoplay is blocked.
    });
  }

  buttons.forEach(function (button) {
    button.addEventListener('click', function () {
      if (button.getAttribute('aria-pressed') === 'true') return;
      var key = button.dataset.visualExample;
      var example = examples[key];
      if (!example) return;
      player.pause();
      active = key;
      player.poster = 'assets/video/visual-answers/' + key + '.png';
      player.src = 'assets/video/visual-answers/' + key + '.mp4?v=short-1';
      player.setAttribute('aria-label', example.label);
      document.getElementById('visual-example-name').textContent = example.name;
      buttons.forEach(function (other) {
        other.setAttribute('aria-pressed', String(other === button));
      });
      player.load();
      start(true);
    });
  });

  // One automatic play per example; returning to the section never restarts it.
  if ('IntersectionObserver' in window) {
    new IntersectionObserver(function (entries) {
      visible = entries[0].isIntersecting && entries[0].intersectionRatio >= .35;
      if (visible) start(false);
      else player.pause();
    }, { threshold: [0, .35] }).observe(player);
  }
  document.addEventListener('visibilitychange', function () {
    if (document.hidden) player.pause();
  });
}());
