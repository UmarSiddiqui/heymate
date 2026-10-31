(function () {
  var button = document.querySelector('.apps-motion');
  if (!button) return;
  button.addEventListener('click', function () {
    var paused = button.closest('.t-apps').classList.toggle('apps-paused');
    button.setAttribute('aria-pressed', String(paused));
    button.setAttribute('aria-label', paused ? 'Resume scrolling app logos' : 'Pause scrolling app logos');
    button.textContent = paused ? 'Resume' : 'Pause';
  });
}());
