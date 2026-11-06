// 관리 화면 작업일보 미리보기(사진 Claude 읽기·엑셀/CSV)를 표에서 바로 고치기 — 2026-11-06 사용자 요청
// 줄마다 '고치기'를 누르면 아래에 편집칸이 열리고, 고친 값은 그 줄의 저장 대상(payload)에 바로 반영된다('OK 항목 모두 저장' 그대로 사용).
// AI 가 UNCERTAIN·UNREADABLE·BLANK·'?' 로 남긴 칸은 노란색으로 표시한다. 사람 이름(검사자·작업자)은 서버가 가려서 저장한다.
(() => {
  const UNSURE = /UNCERTAIN|UNREADABLE|불확실|판독\s*불가|\?/i, BLANKISH = /^\s*BLANK\s*$/i;
  const flag = v => v != null && (UNSURE.test(String(v)) || BLANKISH.test(String(v)));
  const e = s => (typeof esc === 'function' ? esc(s) : String(s ?? ''));
  const procOpts = cur => Object.entries(PROC).map(([k, v]) => `<option value="${k}" ${k === cur ? 'selected' : ''}>${v}</option>`).join('');
  const matOpts = cur => Object.entries(MATS).map(([k, v]) => `<option value="${k}" ${k === cur ? 'selected' : ''}>${v}</option>`).join('') + (cur && !MATS[cur] ? `<option selected value="${e(cur)}">${e(cur)}</option>` : '');
  const sel = (path, cur, opts) => `<select data-p="${path}">${opts.map(([v, t]) => `<option value="${v}" ${String(cur ?? '') === String(v) ? 'selected' : ''}>${t}</option>`).join('')}</select>`;
  const inp = (path, v, ph = '', w = '', type = 'text') => `<input type="${type}" data-p="${path}" value="${e(v ?? '')}" placeholder="${e(ph)}" style="${w ? 'width:' + w + ';' : ''}${flag(v) ? 'background:#fff3cd;border-color:#e7ad00' : ''}">`;
  const NUM = /(qty|minutes|boxes|sequence|inspection_round)$/;

  function getItem(k) { return (window.pendingItems || [])[k] }
  function setPath(obj, path, val) {
    const ks = path.split('.'); let o = obj;
    for (let i = 0; i < ks.length - 1; i++) o = o[ks[i]];
    const last = ks.at(-1);
    if (NUM.test(last)) val = val === '' ? null : Number(val);
    else if (val === '') val = null;
    o[last] = val;
  }

  function editorHtml(k, p) {
    const fin = p.process === 'IMEB3_FINAL_INSPECTION';
    const list = (name, title, rows, cols, add) => `<div class="je-list"><b>${title}</b>${rows.map((r, i) => `<div class="je-row">${cols(r, `${name}.${i}`)}<button class="ghost small" type="button" data-je-del="${name}.${i}">빼기</button></div>`).join('') || '<div class="muted">없음</div>'}<button class="ghost small" type="button" data-je-add="${name}">＋ ${add}</button></div>`;
    p.inputs = p.inputs || []; p.materials = p.materials || []; p.defects = p.defects || []; p.lots = p.lots || []; p.workers_raw = p.workers_raw || [];
    return `<div class="je" data-k="${k}">
      <div class="je-grid">
        <label>모델 ${sel('model', p.model, [['IV', 'IV'], ['OV', 'OV'], ['HSV', 'HSV']])}</label>
        <label>공정 <select data-p="process">${procOpts(p.process)}</select></label>
        <label>교대 ${sel('shift', p.shift, [['D', '주간 D'], ['N', '야간 N']])}</label>
        <label>순번 ${inp('sequence', p.sequence, '1', '60px', 'number')}</label>
        <label>${fin ? '검사량' : '생산량'} ${inp('gross_output_qty', p.gross_output_qty, '', '110px', 'number')}</label>
        <label>작업시간(분) ${inp('work_minutes', p.work_minutes, '', '90px', 'number')}</label>
        ${fin ? `<label>검사 구분 ${sel('inspection_type', p.inspection_type || 'FINAL', [['FINAL', '본검사'], ['REINSPECTION', '재검(중복 검사)']])}</label><label>차수 ${sel('inspection_round', p.inspection_round, [['', '—'], ['1', '1차'], ['2', '2차']])}</label><label>검사자(가려서 저장) ${inp('inspector_raw', p.inspector_raw, '', '110px')}</label>` : ''}
      </div>
      <label class="je-wide">수량 원문 ${inp('raw_quantity_text', p.raw_quantity_text, '', '100%')}</label>
      <label class="je-wide">비고 원문 ${inp('remarks_raw', p.remarks_raw, '', '100%')}</label>
      ${fin && !p.lots.length ? `<div class="warn" style="margin:6px 0">일보에 LOT 기록이 없습니다 — 그대로 저장하면 <b>(LOT 기록 누락)</b> 줄로 남고 '확인 필요'에 올라갑니다. 나중에 CA LOT 을 넣으면 연결됩니다.${p.inspection_type === 'REINSPECTION' ? ' 재검은 최종검사 검사량 합계에 넣지 않고 따로 집계됩니다.' : ''}</div>` : ''}
      ${fin ? list('lots', '검사 LOT (마킹=BOX)', p.lots, (r, b) => `${inp(b + '.raw', r.raw, 'ZH4=2BOX', '130px')} 마킹 ${inp(b + '.marking_code', r.marking_code, 'ZH4', '70px')} BOX ${inp(b + '.boxes', r.boxes, '', '60px', 'number')}`, '검사 LOT')
        : list('inputs', '투입 LOT (상위 공정) ★사슬', p.inputs, (r, b) => `<select data-p="${b}.process">${procOpts(r.process)}</select> ${sel(b + '.component', r.component, [['', '—'], ['BOBBIN', '보빈'], ['INSERT', '인서트']])} 날짜 ${inp(b + '.lot_date', r.lot_date, '2026-09-03', '120px')} 원문 ${inp(b + '.raw', r.raw, '9.3', '110px')}`, '투입 LOT')
        + list('materials', '원자재 LOT ★사슬', p.materials, (r, b) => `<select data-p="${b}.material">${matOpts(r.material)}</select> 날짜 ${inp(b + '.lot_date', r.lot_date, '2026-08-28', '120px')} 원문 ${inp(b + '.raw', r.raw, '8.28', '120px')} 수량 ${inp(b + '.qty', r.qty, '', '70px', 'number')} ${inp(b + '.unit', r.unit, 'kg', '45px')} 위치 ${inp(b + '.spindle', r.spindle, '1-1', '55px')}`, '원자재')
        + list('workers_raw', '작업자 (가려서 저장)', p.workers_raw, (r, b) => `${inp(b + '.name', r.name, '이름', '110px')} ${sel(b + '.role', r.role, [['', '작업자'], ['SETUP', '셋업'], ['SUPERVISOR', '반장·조장'], ['OTHER', '기타']])}`, '작업자')}
      ${list('defects', '불량', p.defects, (r, b) => `${inp(b + '.name', r.name, '불량명', '170px')} 수량 ${inp(b + '.qty', r.qty, '', '70px', 'number')} 원문 ${inp(b + '.raw', r.raw, '', '110px')}`, '불량')}
      <div style="display:flex;gap:8px;align-items:center;margin-top:6px"><button class="primary" type="button" data-je-close="${k}">고친 내용 반영하고 닫기</button><span class="muted">노란 칸 = AI 가 불확실·빈칸으로 남긴 곳. 저장은 아래 'OK 항목 모두 저장'</span></div>
    </div>`;
  }

  function summary(k) {
    const it = getItem(k), p = it.payload, tr = document.querySelector(`tr[data-i="${k}"]`); if (!tr) return;
    const off = tr.querySelector('.st-cell') ? [...tr.children].indexOf(tr.querySelector('.st-cell')) : 0, td = i => tr.children[off + i];
    const cell = (i, html, raw) => { const c = td(i); if (!c) return; c.innerHTML = html; c.style.background = flag(raw) ? '#fff3cd' : ''; };
    cell(1, e(p.model)); cell(2, e(PROC[p.process] || p.process));
    cell(4, e(p.gross_output_qty ?? '—'), p.gross_output_qty);
    cell(5, (p.inputs || []).map(x => e((PROC[x.process] || x.process || '') + ' ' + (x.lot_date || x.raw || ''))).join('<br>'), (p.inputs || []).map(x => x.raw + ' ' + x.lot_date).join(' '));
    cell(6, (p.materials || []).map(m => e((MATS[m.material] || m.material) + ' ' + (m.lot_date || m.raw || ''))).join('<br>'), (p.materials || []).map(m => m.raw).join(' '));
    cell(7, (p.defects || []).map(d => e(d.name + ' ' + (d.qty ?? d.raw ?? ''))).join('<br>'), (p.defects || []).map(d => d.raw).join(' '));
    cell(8, (p.lots || []).map(l => e(l.raw)).join('<br>'), (p.lots || []).map(l => l.raw).join(' '));
  }
  window.journalEditMarkUnsure = () => (window.pendingItems || []).forEach((it, k) => { if (it && it.ok) summary(k) });

  function open(k) {
    const tr = document.querySelector(`tr[data-i="${k}"]`); if (!tr) return;
    const nx = tr.nextElementSibling; if (nx && nx.classList.contains('je-tr')) { nx.remove(); return }
    const row = document.createElement('tr'); row.className = 'je-tr';
    row.innerHTML = `<td colspan="${tr.children.length}" style="background:#f7fbff;text-align:left">${editorHtml(k, getItem(k).payload)}</td>`;
    tr.after(row);
  }
  function redraw(k) { const tr = document.querySelector(`tr[data-i="${k}"]`), nx = tr?.nextElementSibling; if (nx && nx.classList.contains('je-tr')) { nx.remove(); open(k) } }

  document.addEventListener('input', ev => {
    const t = ev.target, box = t.closest && t.closest('.je'); if (!box || !t.dataset.p) return;
    const k = +box.dataset.k, it = getItem(k); if (!it) return;
    setPath(it.payload, t.dataset.p, t.value);
    if (t.dataset.p === 'inspection_type') { if (t.value === 'REINSPECTION' && !it.payload.inspection_round) it.payload.inspection_round = 2; redraw(k); }
    t.style.background = flag(t.value) ? '#fff3cd' : '#eaf7ea'; t.style.borderColor = flag(t.value) ? '#e7ad00' : '#5cb85c';
    const st = document.querySelector(`tr[data-i="${k}"] .st-cell`); if (st && !st.dataset.edited) { st.dataset.edited = '1'; st.insertAdjacentHTML('beforeend', '<br><small class="warn">수정됨(저장 전)</small>') }
  });
  document.addEventListener('change', ev => { const t = ev.target; if (t.tagName === 'SELECT' && t.closest && t.closest('.je')) t.dispatchEvent(new Event('input', { bubbles: true })) });
  document.addEventListener('click', ev => {
    const t = ev.target; if (!t.dataset) return;
    if (t.dataset.ed != null) { open(+t.dataset.ed); return }
    const box = t.closest && t.closest('.je'); if (!box) return; const k = +box.dataset.k, p = getItem(k).payload;
    if (t.dataset.jeAdd) { const blank = { inputs: { process: null, component: null, lot_date: null, raw: null }, materials: { material: 'IMEB3_RESIN', lot_date: null, raw: null, qty: null, unit: null, spindle: null }, defects: { name: '', qty: null, raw: null }, lots: { raw: '', marking_code: null, boxes: null }, workers_raw: { name: '', role: null } }[t.dataset.jeAdd]; p[t.dataset.jeAdd].push(blank); redraw(k); return }
    if (t.dataset.jeDel) { const [name, i] = t.dataset.jeDel.split('.'); p[name].splice(+i, 1); redraw(k); return }
    if (t.dataset.jeClose != null) { summary(k); const nx = document.querySelector(`tr[data-i="${k}"]`)?.nextElementSibling; if (nx && nx.classList.contains('je-tr')) nx.remove() }
  });
  const css = document.createElement('style');
  css.textContent = `.je{font-size:12px}.je-grid{display:flex;flex-wrap:wrap;gap:8px 14px;margin-bottom:6px}.je label{display:inline-flex;gap:4px;align-items:center;font-weight:400}.je-wide{display:flex!important;margin:4px 0}.je-wide input{flex:1}
  .je-list{margin:8px 0;padding:6px 8px;border:1px dashed #cfd6dd;border-radius:8px}.je-list>b{display:block;margin-bottom:4px}.je-row{display:flex;flex-wrap:wrap;gap:4px;align-items:center;margin:3px 0}.je input,.je select{padding:3px 5px;font-size:12px;width:auto}`;
  document.head.appendChild(css);
})();
