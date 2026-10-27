(() => {
  'use strict';
  const rows = [...document.querySelectorAll('.bar-row')];
  const filter = document.getElementById('review-filter');
  const search = document.getElementById('review-search');
  const feedback = document.getElementById('review-feedback');
  let lastIssue = null;
  const compact = value => value.toLowerCase().replace(/\s+/g, '');
  function applyFilters() {
    const query = compact(search.value);
    let visible = 0;
    for (const row of rows) {
      row.hidden = !(compact(row.dataset.search).includes(query) &&
        (filter.value !== 'issues' || row.dataset.issue === '1'));
      visible += Number(!row.hidden);
    }
    for (const card of document.querySelectorAll('.system-card')) {
      const children = [...card.querySelectorAll('.bar-row')];
      if (children.length) card.hidden = children.every(row => row.hidden);
    }
    document.getElementById('visible-count').textContent = `显示 ${visible} / ${rows.length} 小节`;
    document.getElementById('filter-empty').hidden = visible > 0 || rows.length === 0;
    document.getElementById('next-issue').disabled = !rows.some(row => !row.hidden && row.dataset.issue === '1');
  }
  filter.addEventListener('change', () => { feedback.textContent = ''; applyFilters(); });
  search.addEventListener('input', () => { feedback.textContent = ''; applyFilters(); });
  document.getElementById('reset-filter').addEventListener('click', () => { filter.value = 'all'; search.value = ''; applyFilters(); search.focus(); });
  document.getElementById('next-issue').addEventListener('click', () => {
    const pending = rows.filter(row => !row.hidden && row.dataset.issue === '1');
    if (!pending.length) return;
    const row = pending[(pending.indexOf(lastIssue) + 1) % pending.length];
    rows.forEach(r => r.classList.remove('is-focused')); row.classList.add('is-focused'); lastIssue = row;
    row.scrollIntoView({block:'center', behavior:matchMedia('(prefers-reduced-motion: reduce)').matches ? 'auto' : 'smooth'});
    feedback.textContent = `已定位：${row.dataset.label}。可在 Guitar Pro 中修改。`;
    row.focus({preventScroll:true});
  });
  const dialog = document.getElementById('image-dialog'), image = document.getElementById('large-image');
  const stage = document.getElementById('image-stage');
  let zoom = 100, opener;
  function setZoom(value) {
    zoom = Math.max(10, value); image.style.width = zoom + '%';
    document.getElementById('zoom-value').textContent = Math.round(zoom) + '%';
    document.getElementById('zoom-out').disabled = zoom <= 10;
    document.getElementById('zoom-in').disabled = zoom >= 400;
  }
  for (const button of document.querySelectorAll('[data-preview]')) button.addEventListener('click', () => {
    opener = button; image.src = button.dataset.preview; image.alt = button.dataset.previewLabel || '谱图对照';
    document.getElementById('image-title').textContent = image.alt; dialog.showModal(); setZoom(100);
    stage.scrollTop = stage.scrollLeft = 0;
  });
  document.getElementById('zoom-in').addEventListener('click', () => setZoom(Math.min(400, zoom + 50)));
  document.getElementById('zoom-out').addEventListener('click', () => setZoom(zoom - 50));
  document.getElementById('zoom-fit').addEventListener('click', () => { setZoom(100); stage.scrollTop = stage.scrollLeft = 0; });
  document.getElementById('zoom-original').addEventListener('click', () => {
    if (!image.naturalWidth) return;
    const style = getComputedStyle(stage);
    const width = stage.clientWidth - parseFloat(style.paddingLeft) - parseFloat(style.paddingRight);
    setZoom(image.naturalWidth / Math.max(1, width) * 100);
  });
  document.getElementById('close-image').addEventListener('click', () => dialog.close());
  dialog.addEventListener('close', () => opener?.focus({preventScroll:true}));
  applyFilters();
})();
