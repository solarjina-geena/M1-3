// 관리 화면 입력 목록 공통(위치도·재검사·사출조건 체크시트) — 2026-11-06 사용자 결정: 입력 최신순 30건 + 더 보기, 기간으로 거르기.
// 목록은 탭을 열거나 새로고침할 때 DB 에서 다시 읽는다(새로고침해도 사라지지 않음). 저장 전 미리보기만 브라우저 메모리에 있다.
//   m13List.show(key, box, rows, { dateKey, timeKey, dateLabel, head, row, empty, after, gapBy })
//   - gapBy: 기간을 고르면 그 열(예: model_code)별로 기록 없는 날짜를 보여 준다(작업일보 목록)
//   - 기간이 비면: 입력 시각(timeKey) 최신순 30건, '더 보기'로 30건씩
//   - 기간(from~to, dateKey 기준)을 고르면: 그 기간 전부를 날짜 최신순으로
//   - 15분 안에 입력한 줄은 초록 배경 + '방금'
(() => {
  const PAGE = 30, NEW_MS = 15 * 60 * 1000, st = {};
  const css = document.createElement('style');
  css.textContent = '.m13-lv-bar{display:flex;flex-wrap:wrap;gap:8px;align-items:center;margin:6px 0;font-size:12px}.m13-lv-bar input[type=date]{width:auto;padding:3px 6px}'
    + '.lv-gap{margin:4px 0 8px;padding:6px 8px;border:1px dashed var(--border,#cfd6dd);border-radius:8px;font-size:12px;line-height:1.7}.lv-miss{display:inline-block;margin-right:6px;color:#c62828;font-weight:600}.lv-miss.we{color:#999;font-weight:400}'
    + 'tr.m13-new td{background:var(--ok-bg,#eef9ee)}.m13-badge{display:inline-block;font-size:10px;padding:0 5px;border-radius:8px;background:#2e7d32;color:#fff;margin-left:4px;vertical-align:1px}';
  document.head.appendChild(css);
  const esc2 = v => String(v ?? '').replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));

  // (2026-11-20 사용자 의견) 날짜순 정렬 선택 · 기간 안 빠진 날짜 표시 · 날짜 창이 서로의 날짜를 기준으로(시작 ≤ 끝) · ◀ ▶ 로 같은 길이만큼 앞뒤 구간 이동
  const DAY = 86400000;
  const iso = d => new Date(d).toISOString().slice(0, 10);
  const addDays = (ymd, n) => iso(Date.parse(ymd + 'T00:00:00Z') + n * DAY);
  const md = ymd => `${+ymd.slice(5, 7)}/${+ymd.slice(8, 10)}`;
  const WD = '일월화수목금토';
  function gaps(s, o, rows) {
    if (!o.gapBy && o.gapBy !== '') return '';
    if (!s.from || !s.to) return '<div class="muted lv-gap">빠진 날짜를 보려면 기간(시작~끝)을 모두 고르세요.</div>';
    const n = Math.round((Date.parse(s.to) - Date.parse(s.from)) / DAY) + 1;
    if (n < 1 || n > 120) return '<div class="muted lv-gap">빠진 날짜는 120일 이내 기간에서만 보여 줍니다.</div>';
    const days = Array.from({ length: n }, (_, i) => addDays(s.from, i));
    const groups = new Map();
    for (const r of rows) { const g = o.gapBy ? String(r[o.gapBy] ?? '—') : '전체'; if (!groups.has(g)) groups.set(g, new Set()); groups.get(g).add(String(r[o.dateKey] || '').slice(0, 10)) }
    if (!groups.size) return '';
    const fmtDay = d => { const w = new Date(d + 'T00:00:00Z').getUTCDay(); return `<span class="lv-miss${w === 0 || w === 6 ? ' we' : ''}">${md(d)}(${WD[w]})</span>` };
    const lines = [...groups].sort((a, b) => a[0].localeCompare(b[0])).map(([g, set]) => {
      const miss = days.filter(d => !set.has(d));
      return `<div><b>${esc2(g)}</b> · ${miss.length ? `빠진 날 ${miss.length}일: ${miss.map(fmtDay).join(' ')}` : '<span class="ok">빠진 날 없음</span>'}</div>`;
    }).join('');
    return `<div class="lv-gap"><div class="muted">기간 안에서 기록이 없는 날짜${o.gapBy ? '(모델별)' : ''} — 회색 = 토·일요일(쉬는 날일 수 있음)</div>${lines}</div>`;
  }

  function draw(key) {
    const s = st[key], o = s.o, box = s.box;
    const dk = r => String(r[o.dateKey] || ''), tk = r => String(r[o.timeKey] || '');
    const byDateDesc = (a, b) => dk(b).localeCompare(dk(a)) || tk(b).localeCompare(tk(a));
    const byDateAsc = (a, b) => dk(a).localeCompare(dk(b)) || tk(a).localeCompare(tk(b));
    const ranged = !!(s.from || s.to);
    let rows = s.rows.slice(), shown;
    if (ranged) rows = rows.filter(r => (!s.from || dk(r) >= s.from) && (!s.to || dk(r) <= s.to));
    const sort = s.sort || (ranged ? 'dateDesc' : 'input');
    rows.sort(sort === 'dateAsc' ? byDateAsc : sort === 'dateDesc' ? byDateDesc : (a, b) => tk(b).localeCompare(tk(a)));
    shown = ranged ? rows : rows.slice(0, s.n);
    const now = Date.now();
    const body = shown.map(r => {
      let h = o.row(r);
      const t = Date.parse(tk(r));
      if (t && now - t < NEW_MS) h = h.replace(/^\s*<tr/, '<tr class="m13-new"').replace(/<\/td>/, '<span class="m13-badge">방금</span></td>');
      return h;
    }).join('');
    const total = s.rows.length, dl = esc2(o.dateLabel || '날짜');
    const sortName = { input: '입력 최신순', dateDesc: `${dl} 최신순`, dateAsc: `${dl} 오래된 순` }[sort];
    box.innerHTML = `<div class="m13-lv-bar"><span>${dl} 기간</span>`
      + `<button class="ghost small lv-prev" type="button" title="같은 길이만큼 앞 구간" ${s.from && s.to ? '' : 'disabled'}>◀</button>`
      + `<input type="date" class="lv-from" value="${s.from}" ${s.to ? `max="${s.to}"` : ''}> ~ <input type="date" class="lv-to" value="${s.to}" ${s.from ? `min="${s.from}"` : ''}>`
      + `<button class="ghost small lv-next" type="button" title="같은 길이만큼 뒤 구간" ${s.from && s.to ? '' : 'disabled'}>▶</button>`
      + `${ranged ? '<button class="ghost small lv-clear" type="button">기간 지우기</button>' : ''}`
      + `<label style="display:inline-flex;gap:4px;align-items:center">정렬 <select class="lv-sort" style="width:auto;padding:2px 4px;font-size:12px">`
      + `<option value="input" ${sort === 'input' ? 'selected' : ''}>입력 최신순</option><option value="dateDesc" ${sort === 'dateDesc' ? 'selected' : ''}>${dl} 최신순</option><option value="dateAsc" ${sort === 'dateAsc' ? 'selected' : ''}>${dl} 오래된 순</option></select></label>`
      + `<span class="muted">${ranged ? `기간 안 ${shown.length}건 (전체 ${total}건)` : `전체 ${total}건 중 ${shown.length}건`} · ${sortName}</span></div>`
      + (ranged ? gaps(s, o, rows) : '')
      + (shown.length ? `<table><tr>${o.head}</tr>${body}</table>` : `<div class="muted">${esc2(ranged ? '이 기간에 입력된 것이 없습니다.' : (o.empty || '입력된 것이 없습니다.'))}</div>`)
      + (!ranged && rows.length > shown.length ? `<button class="ghost small lv-more" type="button" style="margin-top:6px">더 보기 (+${Math.min(PAGE, rows.length - shown.length)}건 · 남은 ${rows.length - shown.length}건)</button>` : '');
    const fromEl = box.querySelector('.lv-from'), toEl = box.querySelector('.lv-to');
    // 시작만 고르면 끝도 같은 날로 채워 두고(끝 날짜 창이 그 달부터 열림), 시작이 끝보다 늦으면 끝을 시작에 맞춘다(반대도 같음)
    fromEl.onchange = () => { s.from = fromEl.value; if (s.from && (!s.to || s.to < s.from)) s.to = s.from; draw(key) };
    toEl.onchange = () => { s.to = toEl.value; if (s.to && (!s.from || s.from > s.to)) s.from = s.to; draw(key) };
    const shift = dir => { const n = Math.round((Date.parse(s.to) - Date.parse(s.from)) / DAY) + 1; s.from = addDays(s.from, dir * n); s.to = addDays(s.to, dir * n); draw(key) };
    const pv = box.querySelector('.lv-prev'), nx = box.querySelector('.lv-next');
    if (pv) pv.onclick = () => shift(-1); if (nx) nx.onclick = () => shift(1);
    box.querySelector('.lv-sort').onchange = ev => { s.sort = ev.target.value; draw(key) };
    const c = box.querySelector('.lv-clear'); if (c) c.onclick = () => { s.from = s.to = ''; s.sort = ''; draw(key) };
    const m = box.querySelector('.lv-more'); if (m) m.onclick = () => { s.n += PAGE; draw(key) };
    if (o.after) o.after(box);
  }

  // 입력 시각: DB 는 UTC → 이 PC 시각(한국)으로 'MM-DD HH:mm'
  window.m13Time = ts => { const d = new Date(ts); if (!ts || isNaN(d)) return ''; const z = n => String(n).padStart(2, '0'); return `${z(d.getMonth() + 1)}-${z(d.getDate())} ${z(d.getHours())}:${z(d.getMinutes())}` };
  window.m13List = {
    show(key, box, rows, o) {
      const s = st[key] || (st[key] = { n: PAGE, from: '', to: '' });
      s.rows = Array.isArray(rows) ? rows : []; s.o = o; s.box = box; draw(key);
    },
  };
})();
