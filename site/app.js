// The strip in the hero behaves like SlideScroll's own layout: columns keep
// their width, the strip scrolls just far enough to show the focused one, and
// columns past either edge park there with a sliver showing. The first column
// is pinned: it holds the left edge and the rest scroll past it.
(() => {
  const screen = document.querySelector('[data-strip]');
  if (!screen) return;
  const wins = [...screen.querySelectorAll('.win')];
  const PRESETS = [1 / 4, 1 / 3, 1 / 2, 2 / 3, 3 / 4];
  const GAP = 12;
  const PEEK = 8;
  const widths = [1 / 4, 1 / 2, 1 / 3, 2 / 3, 1 / 3, 1 / 2];
  const pinned = 0;
  const parts = [...document.querySelectorAll('[data-part]')];
  const notes = [...document.querySelectorAll('[data-note]')];
  const menuApp = document.querySelector('[data-menu-app]');
  let focused = 1;
  let scroll = 0;

  const room = () => screen.clientWidth;
  // Like SlideScroll's preset_width: two halves plus three gaps fill the screen.
  const px = (f) => f * (room() - GAP) - GAP;
  // Where the scrolling part of the strip starts: just past the pinned column.
  const left = () => GAP + px(widths[pinned]);
  // A column's x on the strip, before scrolling, counting only scrolling columns.
  const stripX = (i) => {
    let x = GAP;
    for (let j = 0; j < i; j++) if (j !== pinned) x += px(widths[j]) + GAP;
    return x;
  };

  function ensureVisible() {
    if (focused === pinned) return;
    const view = room() - left();
    const x = stripX(focused);
    const w = px(widths[focused]);
    if (x + w + GAP > scroll + view) scroll = x + w + GAP - view;
    if (x - GAP < scroll) scroll = x - GAP;
  }

  function layout() {
    ensureVisible();
    const r = room();
    const l = left();
    wins.forEach((win, i) => {
      const w = px(widths[i]);
      let x;
      let hidden = 0;
      if (i === pinned) x = GAP;
      else {
        x = l + stripX(i) - scroll;
        if (x > r - PEEK) x = r - PEEK;
        else if (x + w < l + PEEK) x = l + PEEK - w;
        // A column sliding past the pinned one is cut off at its edge, the
        // way the screen's edge cuts off the columns on the right.
        hidden = Math.max(0, l + GAP - x);
      }
      win.style.width = `${w}px`;
      win.style.transform = `translateX(${x}px)`;
      win.style.clipPath = `inset(-60px -60px -60px ${hidden}px)`;
      win.classList.toggle('is-focused', i === focused);
    });
    const kind = wins[focused].dataset.kind;
    parts.forEach((b) => b.setAttribute('aria-pressed', String(b.dataset.part === kind)));
    notes.forEach((n) => (n.hidden = n.dataset.note !== kind));
    if (menuApp) menuApp.textContent = wins[focused].querySelector('.tab[aria-selected="true"]')?.textContent ?? wins[focused].dataset.app;
  }

  function focus(i) {
    focused = Math.max(0, Math.min(wins.length - 1, i));
    layout();
  }

  function cycle() {
    const w = widths[focused];
    widths[focused] = PRESETS.find((p) => p > w + 0.01) ?? PRESETS[0];
    layout();
  }

  screen.classList.add('is-live');
  layout();
  new ResizeObserver(layout).observe(screen);

  document.querySelectorAll('[data-move]').forEach((b) => b.addEventListener('click', () => focus(focused + Number(b.dataset.move))));
  document.querySelector('[data-cycle]')?.addEventListener('click', cycle);
  parts.forEach((b) => b.addEventListener('click', () => {
    const i = wins.findIndex((w) => w.dataset.kind === b.dataset.part);
    // Jump only if the focused window isn't already that kind of part.
    if (wins[focused].dataset.kind !== b.dataset.part) focus(i);
  }));
  screen.addEventListener('keydown', (e) => {
    if (e.key === 'ArrowLeft') focus(focused - 1);
    else if (e.key === 'ArrowRight') focus(focused + 1);
    else if (e.key === 'r' || e.key === 'R') cycle();
    else return;
    e.preventDefault();
  });
  wins.forEach((win, i) => win.addEventListener('click', () => focus(i)));

  // The tabbed column: a tab shows its window and hides the others.
  screen.querySelectorAll('.win--tabs').forEach((win) => {
    const tabs = [...win.querySelectorAll('[data-tab]')];
    tabs.forEach((tab) => tab.addEventListener('click', () => {
      tabs.forEach((t) => t.setAttribute('aria-selected', String(t === tab)));
      win.querySelectorAll('[data-tab-panel]').forEach((p) => (p.hidden = p.dataset.tabPanel !== tab.dataset.tab));
      win.dataset.app = tab.textContent;
      focus(wins.indexOf(win));
    }));
  });
})();

// The Settings tabs: arrow keys move between them, as in a real tab list.
document.querySelectorAll('[data-switch]').forEach((root) => {
  const tabs = [...root.querySelectorAll('[role="tab"]')];
  const select = (tab) => {
    tabs.forEach((t) => {
      const on = t === tab;
      t.setAttribute('aria-selected', String(on));
      t.tabIndex = on ? 0 : -1;
      document.getElementById(t.getAttribute('aria-controls')).hidden = !on;
    });
  };
  tabs.forEach((tab, i) => {
    tab.addEventListener('click', () => select(tab));
    tab.addEventListener('keydown', (e) => {
      const next = e.key === 'ArrowRight' ? 1 : e.key === 'ArrowLeft' ? -1 : 0;
      if (!next) return;
      e.preventDefault();
      const t = tabs[(i + next + tabs.length) % tabs.length];
      select(t);
      t.focus();
    });
  });
});

// The demo video: YouTube loads only once it's played, so visiting the page
// sends nothing to YouTube. Without JavaScript the poster links to the video.
document.querySelectorAll('[data-youtube]').forEach((link) => {
  link.addEventListener('click', (e) => {
    e.preventDefault();
    const frame = document.createElement('iframe');
    frame.src = `https://www.youtube-nocookie.com/embed/${link.dataset.youtube}?autoplay=1&rel=0&playsinline=1`;
    frame.title = 'SlideScroll demo video';
    frame.allow = 'autoplay; encrypted-media; picture-in-picture; fullscreen';
    frame.allowFullscreen = true;
    link.replaceWith(frame);
  });
});

// Copy the install command.
document.querySelectorAll('[data-command]').forEach((box) => {
  const button = box.querySelector('[data-copy]');
  const label = box.querySelector('[data-copy-label]');
  const text = box.querySelector('code').textContent.trim();
  if (!navigator.clipboard) {
    button.hidden = true;
    return;
  }
  button.addEventListener('click', async () => {
    try {
      await navigator.clipboard.writeText(text);
      label.textContent = 'Copied';
      button.classList.add('is-done');
    } catch {
      label.textContent = 'Press ⌘C';
    }
    setTimeout(() => {
      label.textContent = 'Copy';
      button.classList.remove('is-done');
    }, 2000);
  });
});

// Point the download buttons at the latest release's disk image. The
// links already go to 0.3.0, so this only matters after a newer release.
fetch('https://api.github.com/repos/majnioui/SlideScroll/releases/latest')
  .then((r) => (r.ok ? r.json() : null))
  .then((release) => {
    const dmg = release?.assets?.find((a) => a.name.endsWith('.dmg'));
    if (dmg) document.querySelectorAll('[data-dmg]').forEach((a) => (a.href = dmg.browser_download_url));
  })
  .catch(() => {});
