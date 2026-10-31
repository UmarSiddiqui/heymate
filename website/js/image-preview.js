(function () {
  var triggers = document.querySelectorAll('.product-expand');
  if (!triggers.length) return;

  var dialog = document.createElement('dialog');
  dialog.className = 'image-preview';
  dialog.setAttribute('aria-label', 'Expanded product screenshot');
  var close = document.createElement('button');
  close.type = 'button';
  close.className = 'image-preview-close';
  close.textContent = 'Close ×';
  var image = document.createElement('img');
  var caption = document.createElement('p');
  caption.id = 'image-preview-caption';
  dialog.setAttribute('aria-describedby', caption.id);
  dialog.append(close, image, caption);
  document.body.appendChild(dialog);

  var opener;
  triggers.forEach(function (button) {
    button.addEventListener('click', function () {
      opener = button;
      var thumbnail = button.querySelector('img');
      image.src = button.dataset.imageSrc;
      image.alt = thumbnail.alt;
      caption.textContent = thumbnail.alt;
      dialog.showModal();
      document.documentElement.classList.add('image-preview-open');
      close.focus();
    });
  });
  close.addEventListener('click', function () { dialog.close(); });
  dialog.addEventListener('click', function (event) {
    if (event.target !== dialog) return;
    var bounds = dialog.getBoundingClientRect();
    if (event.clientX < bounds.left || event.clientX > bounds.right || event.clientY < bounds.top || event.clientY > bounds.bottom) dialog.close();
  });
  dialog.addEventListener('close', function () {
    document.documentElement.classList.remove('image-preview-open');
    if (opener) opener.focus({ preventScroll: true });
  });
}());
