(() => {
  const get = (id) => document.getElementById(`demo-${id}`);
  const demo = document.getElementById('browser-demo');
  const start = get('start');
  const reset = get('reset');
  const step = get('step');
  const instruction = get('instruction');
  const question = get('question');
  const folder = get('folder');
  const drafts = get('drafts');
  const fileList = get('file-list');
  const initialOrder = Array.from(fileList.children);
  const sort = get('sort');
  const latest = get('latest');
  const opened = get('opened');
  const result = get('result');
  const location = get('location');
  const next = get('next');
  let target = null;

  function pointTo(button, number, message) {
    clearPointer();
    target = button;
    target.setAttribute('data-demo-target', '');
    target.setAttribute('aria-describedby', 'demo-instruction');
    step.hidden = false;
    step.textContent = `Step ${number} of 3`;
    instruction.textContent = message;
    target.focus();
  }

  function clearPointer() {
    target?.removeAttribute('data-demo-target');
    target?.removeAttribute('aria-describedby');
    target = null;
  }

  start.addEventListener('click', () => {
    start.hidden = true;
    reset.hidden = false;
    question.hidden = false;
    folder.disabled = false;
    pointTo(folder, 1, 'Open Drafts. That’s where the project files are saved.');
  });

  folder.addEventListener('click', () => {
    folder.hidden = true;
    drafts.hidden = false;
    location.textContent = 'Project Files / Drafts';
    pointTo(sort, 2, 'Sort by date modified to bring the newest draft to the top.');
  });

  sort.addEventListener('click', () => {
    const newestFirst = [...initialOrder].sort((a, b) =>
      b.dataset.modified.localeCompare(a.dataset.modified)
    );
    fileList.append(...newestFirst);
    sort.textContent = 'Newest first';
    sort.disabled = true;
    pointTo(latest, 3, 'Open Launch notes v3. It was modified most recently.');
  });

  fileList.addEventListener('click', (event) => {
    const file = event.target.closest('.demo-file');
    if (!file) return;
    if (!sort.disabled) {
      instruction.textContent = 'Sort by date modified first, so you can check which draft is newest.';
      sort.focus();
      return;
    }
    if (file !== latest) {
      instruction.textContent = 'That draft is older. Open Launch notes v3 at the top of the list.';
      latest.focus();
      return;
    }

    clearPointer();
    step.textContent = 'Walkthrough complete';
    instruction.textContent = 'You found the latest draft. HeyMate waits while you do each step.';
    drafts.hidden = true;
    opened.hidden = false;
    next.hidden = false;
    result.focus();
  });

  reset.addEventListener('click', () => {
    clearPointer();
    fileList.append(...initialOrder);
    sort.disabled = false;
    sort.textContent = 'Sort by date modified';
    location.textContent = 'Project Files';
    instruction.textContent = 'Ask a sample question to start.';
    step.hidden = true;
    question.hidden = true;
    reset.hidden = true;
    next.hidden = true;
    folder.disabled = true;
    folder.hidden = false;
    drafts.hidden = true;
    opened.hidden = true;
    start.hidden = false;
    start.focus();
  });

  demo.hidden = false;
})();
