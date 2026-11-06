// 관리 화면 입력 목록 공통(위치도·재검사·사출조건 체크시트) — 2026-11-06 사용자 결정: 입력 최신순 30건 + 더 보기, 기간으로 거르기.
// 목록은 탭을 열거나 새로고침할 때 DB 에서 다시 읽는다(새로고침해도 사라지지 않음). 저장 전 미리보기만 브라우저 메모리에 있다.
//   m13List.show(key, box, rows, { dateKey, timeKey, dateLabel, head, row, empty, after })
//   - 기간이 비면: 입력 시각(timeKey) 최신순 30건, '더 보기'로 30건씩
//   - 기간(from~to, dateKey 기준)을 고르면: 그 기간 전부를 날짜 최신순으로
//   - 15분 안에 입력한 줄은 초록 배경 + '방금'
(() => {
  const PAGE = 30, NEW_MS = 15 * 60 * 1000, st = {};
  const css = document.createElement('style');
  css.textContent = '.m13-lv-bar{display:flex;flex-wrap:wrap;gap:8px;align-items:center;margin:6px 0;font-size:12px}.m13-lv-bar input[type=date]{width:auto;padding:3px 6px}'
    + 'tr.m13-new td{background:#eef9ee}.m13-badge{display:inline-block;font-size:10px;padding:0 5px;border-radius:8px;background:#2e7d32;color:#fff;margin-left:4px;vertical-align:1px}';
  document.head.appendChild(css);
  const esc2 = v => String(v ?? '').replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));

  function draw(key) {
    const s = st[key], o = s.o, box = s.box;
    const dk = r => String(r[o.dateKey] || ''), tk = r => String(r[o.timeKey] || '');
    let rows = s.rows.slice(), shown;
    if (s.from || s.to) {
      rows = rows.filter(r => (!s.from || dk(r) >= s.from) && (!s.to || dk(r) <= s.to)).sort((a, b) => dk(b).localeCompare(dk(a)) || tk(b).localeCompare(tk(a)));
      shown = rows;
    } else {
      rows.sort((a, b) => tk(b).localeCompare(tk(a)));
      shown = rows.slice(0, s.n);
    }
    const now = Date.now();
    const body = shown.map(r => {
      let h = o.row(r);
      const t = Date.parse(tk(r));
      if (t && now - t < NEW_MS) h = h.replace(/^\s*<tr/, '<tr class="m13-new"').replace(/<\/td>/, '<span class="m13-badge">방금</span></td>');
      return h;
    }).join('');
    const total = s.rows.length;
    box.innerHTML = `<div class="m13-lv-bar"><span>${esc2(o.dateLabel || '날짜')} 기간</span><input type="date" class="lv-from" value="${s.from}"> ~ <input type="date" class="lv-to" value="${s.to}">`
      + `${s.from || s.to ? '<button class="ghost small lv-clear" type="button">기간 지우기</button>' : ''}`
      + `<span class="muted">${s.from || s.to ? `기간 안 ${shown.length}건 (전체 ${total}건) · ${esc2(o.dateLabel || '날짜')} 최신순` : `전체 ${total}건 중 ${shown.length}건 · 입력 최신순`}</span></div>`
      + (shown.length ? `<table><tr>${o.head}</tr>${body}</table>` : `<div class="muted">${esc2(s.from || s.to ? '이 기간에 입력된 것이 없습니다.' : (o.empty || '입력된 것이 없습니다.'))}</div>`)
      + (!(s.from || s.to) && rows.length > shown.length ? `<button class="ghost small lv-more" type="button" style="margin-top:6px">더 보기 (+${Math.min(PAGE, rows.length - shown.length)}건 · 남은 ${rows.length - shown.length}건)</button>` : '');
    const set = () => { s.from = box.querySelector('.lv-from').value; s.to = box.querySelector('.lv-to').value; draw(key) };
    box.querySelector('.lv-from').onchange = set; box.querySelector('.lv-to').onchange = set;
    const c = box.querySelector('.lv-clear'); if (c) c.onclick = () => { s.from = s.to = ''; draw(key) };
    const m = box.querySelector('.lv-more'); if (m) m.onclick = () => { s.n += PAGE; draw(key) };
    if (o.after) o.after(box);
  }

  // 입력 시각: DB 는 UTC → 이 PC 시각(한국)으로 'MM-DD HH:mm'
  window.m13Time = ts => { const d = new Date(ts); if (!ts || isNaN(d)) return ''; const z = n => String(n).padStart(2, '0'); return `${z(d.getMonth() + 1)}-${z(d.getDate())} ${z(d.getHours())}:${z(d.getMinutes())}` };
  window.m13List = {
    show(key, box, rows, o) {
      const s = st[key] || (st[key] = { n: PAGE, from: '', to: '' });
      s.rows = rows || []; s.o = o; s.box = box; draw(key);
    },
  };
})();
