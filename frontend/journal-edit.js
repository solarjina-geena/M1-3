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
  const inp = (path, v, ph = '', w = '', type = 'text', hot = false) => `<input type="${type}" data-p="${path}" value="${e(v ?? '')}" placeholder="${e(ph)}" style="${w ? 'width:' + w + ';' : ''}${hot || flag(v) ? 'background:var(--flag-bg);border-color:#e7ad00' : ''}">`;
  const NUM = /(qty|minutes|boxes|sequence|inspection_round)$/;
  // 차수 한 칸: 1차검사 = FINAL·1차 / 본검사 = FINAL·2차 / 재검사 = REINSPECTION (2026-11-07 사용자)
  const clsOf = p => p.inspection_type === 'REINSPECTION' ? 'RE' : (String(p.inspection_round) === '1' ? 'FIRST' : 'MAIN');

  function getItem(k) { return (window.pendingItems || [])[k] }
  // 고친 칸 기록: 처음 값(AI·파일이 읽은 값)을 기억해 두고, 바뀐 칸을 payload.source.human_edits 로 저장(사람 판독 확정 칸)
  const getPath = (obj, path) => path.split('.').reduce((o, k) => (o == null ? undefined : o[k]), obj);
  function track(it, path, before) {
    it._orig = it._orig || {};
    if (!(path in it._orig)) it._orig[path] = before == null ? null : String(before);
    const p = it.payload, src = (p.source = p.source || {}), cur = getPath(p, path), now = cur == null ? null : String(cur);
    const others = (src.human_edits || []).filter(e => e.path !== path);
    src.human_edits = it._orig[path] === now ? others : [...others, { path, ai: it._orig[path], value: now }];
    it.edited = src.human_edits.length; window.journalEditCount && window.journalEditCount();
  }
  function setPath(obj, path, val) {
    const ks = path.split('.'); let o = obj;
    for (let i = 0; i < ks.length - 1; i++) o = o[ks[i]];
    const last = ks.at(-1);
    if (NUM.test(last)) val = val === '' ? null : Number(val);
    else if (val === '') val = null;
    o[last] = val;
  }

  const ASM_SIB = k => { const n = (typeof siblings === 'function') ? siblings(k).length : 0; return n ? '<div class="je-sib muted" style="margin:2px 0 4px">작업자·비고는 같은 장의 짝 줄(권선 BA·압입 CA)에도 같이 반영됩니다</div>' : '' };
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
        <label title="일보에 불량 합계 칸이 있을 때 적힌 숫자. 불량 칸 합과 맞춰 봅니다">불량 합계(적힌 값) ${inp('defect_qty', p.defect_qty, '', '80px', 'number')}</label>
        ${fin ? `<label>차수 <select data-cls="1">${[['FIRST', '1차검사 (훈련·신입·지원, 합계 제외)'], ['MAIN', '본검사 (2차, 합계)'], ['RE', '재검사 (불량 이슈 재선별, 따로 집계)']].map(([v, t]) => `<option value="${v}" ${clsOf(p) === v ? 'selected' : ''}>${t}</option>`).join('')}</select></label><label>검사자 <small class="muted">(저장 시 가림)</small> ${inp('inspector_raw', p.inspector_raw, '', '110px')}</label>${clsOf(p) === 'RE' ? `<label>검사 내용(특이사항) ${inp('inspection_content', p.inspection_content, '현미경 검사 / 와이어 데미지 / 리드핀 찍힘', '200px')}</label>` : ''}` : ''}
      </div>
      <label class="je-wide">수량 원문 ${inp('raw_quantity_text', p.raw_quantity_text, '', '100%')}</label>
      <label class="je-wide">비고 원문 ${inp('remarks_raw', p.remarks_raw, '', '100%')}</label>${ASM_SIB(k)}
      ${fin && !p.lots.length ? `<div class="warn" style="margin:6px 0">일보에 LOT 기록이 없습니다 — 그대로 저장하면 <b>(LOT 기록 누락)</b> 줄로 남고 '확인 필요'에 올라갑니다. 나중에 CA LOT 을 넣으면 연결됩니다.${p.inspection_type === 'REINSPECTION' ? ' 재검은 최종검사 검사량 합계에 넣지 않고 따로 집계됩니다.' : ''}</div>` : ''}
      ${fin ? list('lots', '검사 LOT (마킹=BOX)', p.lots, (r, b) => `${inp(b + '.raw', r.raw, 'ZH4=2BOX', '130px')} 마킹 ${inp(b + '.marking_code', r.marking_code, 'ZH4', '70px')} BOX ${inp(b + '.boxes', r.boxes, '', '60px', 'number')}`, '검사 LOT')
        : list('inputs', '투입 LOT (상위 공정) ★사슬', p.inputs, (r, b) => `<select data-p="${b}.process">${procOpts(r.process)}</select> ${sel(b + '.component', r.component, [['', '—'], ['BOBBIN', '보빈'], ['INSERT', '인서트']])} 날짜 ${inp(b + '.lot_date', r.lot_date, '2026-09-03', '120px')} 원문 ${inp(b + '.raw', r.raw, '9.3', '110px')}`, '투입 LOT')
        + list('materials', '원자재 LOT ★사슬', p.materials, (r, b) => `<select data-p="${b}.material">${matOpts(r.material)}</select> 날짜 ${inp(b + '.lot_date', r.lot_date, '2026-08-28', '120px')} 원문 ${inp(b + '.raw', r.raw, '8.28', '120px')} 수량 ${inp(b + '.qty', r.qty, '', '70px', 'number')} ${inp(b + '.unit', r.unit, 'kg', '45px')} 위치 ${inp(b + '.spindle', r.spindle, '1-1', '55px')}`, '원자재')
        + list('workers_raw', '작업자 (가려서 저장)', p.workers_raw, (r, b) => `${inp(b + '.name', r.name, '이름', '110px')} ${sel(b + '.role', r.role, [['', '작업자'], ['SETUP', '셋업'], ['SUPERVISOR', '반장·조장'], ['OTHER', '기타']])}`, '작업자')}
      ${list('defects', '불량', p.defects, (r, b) => `${inp(b + '.name', r.name, '불량명', '170px')} 수량 ${inp(b + '.qty', r.qty, '', '70px', 'number', r.qty_alt != null && r.qty_alt !== '')}${altChip(b, r)} 원문 ${inp(b + '.raw', r.raw, '', '110px')}`, '불량')}
      <div class="je-dsum">${dsumHtml(p)}</div>
      <div style="display:flex;gap:8px;align-items:center;margin-top:6px"><button class="primary" type="button" data-je-close="${k}">고친 내용 반영하고 닫기</button><span class="muted">노란 칸 = AI 가 불확실·빈칸으로 남긴 곳. 고친 칸은 'AI 값 → 사람 값'으로 DB 출처 기록에 남습니다. 저장은 화면 아래 고정된 '모두 저장' 줄</span></div>
    </div>`;
  }

  function summary(k) {
    const it = getItem(k), p = it.payload, tr = document.querySelector(`tr[data-i="${k}"]`); if (!tr) return;
    const off = tr.querySelector('.st-cell') ? [...tr.children].indexOf(tr.querySelector('.st-cell')) : 0, td = i => tr.children[off + i];
    const cell = (i, html, raw) => { const c = td(i); if (!c) return; c.innerHTML = html; c.style.background = flag(raw) ? 'var(--flag-bg)' : ''; };
    cell(1, e(p.model)); cell(2, e(PROC[p.process] || p.process));
    cell(4, e(p.gross_output_qty ?? '—'), p.gross_output_qty);
    cell(5, (p.inputs || []).map(x => e((PROC[x.process] || x.process || '') + ' ' + (x.lot_date || x.raw || ''))).join('<br>'), (p.inputs || []).map(x => x.raw + ' ' + x.lot_date).join(' '));
    cell(6, window.matCell ? window.matCell((p.materials || []).map(m => (MATS[m.material] || m.material) + ' ' + (m.lot_date || m.raw || ''))) : (p.materials || []).map(m => e((MATS[m.material] || m.material) + ' ' + (m.lot_date || m.raw || ''))).join('<br>'), (p.materials || []).map(m => m.raw).join(' '));
    cell(7, window.defCell ? window.defCell(p.defects || []) : (p.defects || []).map(d => `<span style="white-space:nowrap">${e(d.name + ' ' + (d.qty ?? d.raw ?? ''))}</span>`).join('<br>'), (p.defects || []).map(d => d.raw).join(' '));
    cell(8, (p.lots || []).map(l => e(l.raw)).join('<br>'), (p.lots || []).map(l => l.raw).join(' '));
    const fw = tr.querySelector('.fin-who'); if (fw) fw.innerHTML = window.finWhoHtml ? window.finWhoHtml(p) : e(p.inspector_raw || '—');
  }
  window.journalEditMarkUnsure = () => { (window.pendingItems || []).forEach((it, k) => { if (it && it.ok) summary(k) }); nameMarkRows(); checkMarkRows() };

  // ── 불량 수량 확인(2026-11-20 사용자 의견: 불량 수량이 가장 많이 틀림) ──
  // · AI 가 숫자를 두 가지로 본 칸(qty_alt)은 노란색 + '다른 후보 N · 바꾸기'
  // · 일보에 적힌 불량 합계(defect_qty)와 불량 칸 합이 다르면 알림(어느 칸이 틀렸는지 찾게). 자동으로 고치지 않는다.
  const numOr = v => (v === '' || v == null || isNaN(Number(v))) ? null : Number(v);
  const altChip = (b, r) => r.qty_alt != null && r.qty_alt !== '' ? ` <span class="je-alt">다른 후보 <b>${e(r.qty_alt)}</b> <button class="ghost small" type="button" data-je-alt="${b}">바꾸기</button></span>` : '';
  function dsum(p) {
    const ds = (p.defects || []).map(d => numOr(d.qty)).filter(x => x != null), sum = ds.reduce((a, x) => a + x, 0), tot = numOr(p.defect_qty);
    const alts = (p.defects || []).filter(d => d.qty_alt != null && d.qty_alt !== '').length;
    // (2026-11-20) 초기불량을 빼고 적은 합계(현장 관습)도 맞는 것으로 보고, 저장 때 초기불량 포함 합계로 자동 반영
    const init = (p.defects || []).filter(d => /초기\s*불량/.test(d.name || '')).map(d => numOr(d.qty)).filter(x => x != null).reduce((a, x) => a + x, 0);
    const custom = tot != null && init > 0 && tot !== sum && tot === sum - init;
    return { sum, tot, alts, init, custom, bad: tot != null && tot !== sum && !custom };
  }
  function dsumHtml(p) {
    const c = dsum(p);
    const head = `불량 칸 합 <b>${c.sum.toLocaleString()}</b>`;
    if (c.tot == null) return `<span class="muted">${head} · 일보에 불량 합계 칸이 있으면 위 '불량 합계(적힌 값)'에 넣어 맞춰 보세요</span>`;
    if (c.custom) return `<span class="ok">✔ 적힌 합계 ${c.tot.toLocaleString()} = 초기불량 ${c.init.toLocaleString()} 을 뺀 칸 합(현장 관습) → 저장할 때 초기불량을 넣은 <b>${c.sum.toLocaleString()}</b> 로 반영합니다</span>`;
    return c.bad ? `<span class="je-dbad">⚠ ${head} ≠ 적힌 합계 <b>${c.tot.toLocaleString()}</b> (차이 ${(c.tot - c.sum).toLocaleString()}) — 원본에서 불량 칸 숫자를 다시 확인하세요</span>`
      : `<span class="ok">✔ ${head} = 적힌 합계 ${c.tot.toLocaleString()}</span>`;
  }
  function checkMarkRows() {
    (window.pendingItems || []).forEach((it, k) => {
      if (!it || !it.ok) return; const tr = document.querySelector(`tr[data-i="${k}"]`), st = tr && tr.querySelector('.st-cell'); if (!st) return;
      st.querySelector('.je-dqb')?.remove();
      const c = dsum(it.payload), msg = [c.bad ? `불량 합계 안 맞음(칸 합 ${c.sum} · 적힌 ${c.tot})` : '', c.alts ? `숫자 후보 2개인 칸 ${c.alts}` : ''].filter(Boolean).join(' · ');
      if (msg) st.insertAdjacentHTML('beforeend', `<br><small class="je-dqb warn">불량 확인 · ${e(msg)}</small>`);
    });
  }

  // ── 이름 길잡이(2026-11-20 사용자 의견: 작업자·검사자 이름이 자주 틀림) ──
  // 그 공정에 저장된 이름(가운데 글자를 가린 이름)과 사람이 고친 기록(읽은 이름 → 실제 이름)을 서버에서 받아,
  // 고치기 칸의 이름 옆에 '명단에 있음 / 자주 헷갈림 → 바꾸기 / 처음 보는 이름'을 보여 주고, 명단에서 골라 넣을 수 있게 한다.
  // 실명은 DB 에 없으므로 비교는 가린 이름(성·끝 글자)끼리. 자동으로 바꾸지는 않는다(사람이 단추로 고름).
  const NG = window.__nameGuide = window.__nameGuide || {};
  const kindNow = () => window.journalKind || 'MIXED';
  const maskJs = raw => { if (raw == null) return ''; let t = String(raw).trim(); if (!t) return '';
    t = t.replace(/[가-힣]{2,4}/g, n => n.length > 2 ? n[0] + '*'.repeat(n.length - 2) + n.at(-1) : n[0] + '*');
    return t.replace(/[A-Za-z]{2,}/g, w => w.length > 2 ? w[0] + '*'.repeat(w.length - 2) + w.at(-1) : w[0] + '*').slice(0, 60) };
  async function loadNames(kind) {
    kind = kind || kindNow(); if (NG[kind] && NG[kind] !== 'loading') return NG[kind];
    if (NG[kind] === 'loading') return null; NG[kind] = 'loading';
    try { NG[kind] = await api('/api/worker-names?kind=' + encodeURIComponent(kind), { authed: true }) } catch (_) { delete NG[kind]; return null }
    nameMarkRows(); return NG[kind];
  }
  function nameCheck(raw) {
    const g = NG[kindNow()]; if (!g || g === 'loading' || !raw || flag(raw)) return null;
    const m = maskJs(raw), hit = (g.names || []).find(x => x.name === m), fx = (g.fixes || []).filter(f => f.ai === m && f.n >= 2);
    if (fx.length) return { st: 'fix', m, to: fx[0].value, n: fx[0].n, known: !!(hit && !hit.rare) };
    if (hit && !hit.rare) return { st: 'ok', m, runs: hit.runs };
    if (hit) return { st: 'rare', m, runs: hit.runs };
    return { st: 'new', m };
  }
  function chipHtml(path, raw) {
    const c = nameCheck(raw); if (!c) return '';
    if (c.st === 'ok') return `<span class="je-nm ok">✔ 명단에 있음(${c.runs}번)</span>`;
    if (c.st === 'fix') return `<span class="je-nm fx">자주 헷갈린 이름: ${e(c.m)} → ${e(c.to)} (${c.n}번 고침)${c.known ? ' · 두 사람 모두 명단에 있으니 원본 확인' : ''} <button class="ghost small" type="button" data-je-nm="${path}" data-v="${e(c.to)}">바꾸기: ${e(c.to)}</button></span>`;
    if (c.st === 'rare') return `<span class="je-nm nw">거의 안 나온 이름(${c.runs}번) — 원본 확인</span>`;
    return `<span class="je-nm nw">처음 보는 이름 — 원본 확인(새 작업자면 그대로)</span>`;
  }
  const NAME_P = /^(workers_raw\.\d+\.name|inspector_raw)$/;
  function nameDecorate(root) {
    const g = NG[kindNow()];
    if (!g || g === 'loading') { loadNames().then(x => x && root.isConnected && nameDecorate(root)); return }
    let dl = document.getElementById('je-names');
    if (!dl) { dl = document.createElement('datalist'); dl.id = 'je-names'; document.body.appendChild(dl) }
    dl.innerHTML = (g.names || []).filter(x => !x.rare).map(x => `<option value="${e(x.name)}">${x.runs}번</option>`).join('');
    root.querySelectorAll('input[data-p]').forEach(i => {
      if (!NAME_P.test(i.dataset.p)) return;
      i.setAttribute('list', 'je-names'); i.title = '명단(가린 이름)에서 고를 수 있습니다';
      let sp = i.nextElementSibling; if (!sp || !sp.classList.contains('je-nmw')) { sp = document.createElement('span'); sp.className = 'je-nmw'; i.after(sp) }
      sp.innerHTML = chipHtml(i.dataset.p, i.value);
    });
  }
  function nameMarkRows() {
    const g = NG[kindNow()]; if (!g || g === 'loading') { if (!g) loadNames(); return }
    (window.pendingItems || []).forEach((it, k) => {
      if (!it || !it.ok) return; const p = it.payload, tr = document.querySelector(`tr[data-i="${k}"]`); if (!tr) return;
      const st = tr.querySelector('.st-cell'); if (!st) return; st.querySelector('.je-nmb')?.remove();
      const bad = [p.inspector_raw, ...(p.workers_raw || []).map(w => w && w.name)].filter(Boolean).map(n => nameCheck(n)).filter(c => c && c.st !== 'ok');
      if (!bad.length) return;
      const t = bad.map(c => c.st === 'fix' ? `${c.m} → ${c.to}?` : c.m + (c.st === 'new' ? ' 처음 보는 이름' : ' 거의 안 나옴')).join(', ');
      st.insertAdjacentHTML('beforeend', `<br><small class="je-nmb warn" title="${e(t)}">이름 확인 ${bad.length} · ${e(t)}</small>`);
    });
  }
  document.querySelectorAll('#tabs [data-kind]').forEach(b => b.addEventListener('click', () => setTimeout(() => loadNames(b.dataset.kind), 0)));
  setTimeout(() => loadNames(), 800);

  // (2026-11-20 사용자 의견) 지금 고치는 줄이 어디인지: 그 줄을 파란 테두리로 표시하고, 편집칸 맨 위에 '몇 번째 줄 · 날짜 · 모델 · 공정 · 쪽'을 보여 준다.
  // 다른 줄의 편집칸은 자동으로 닫아 한 번에 한 줄만 열리게 한다(고친 값은 이미 저장 대상에 반영돼 있으므로 사라지지 않음).
  function headHtml(k, p) {
    const its = window.pendingItems || [];
    const pg = p.source?.page ? ` · 원본 ${e(p.source.page)}쪽` : '';
    return `<div class="je-head">✏ 지금 고치는 줄: <b>표의 ${k + 1}번째 줄</b> <small>(전체 ${its.length}줄)</small> · ${e(p.work_date || '날짜 없음')} ${e(p.shift || '')} · ${e(p.model || '')} · ${e(PROC[p.process] || p.process || '')}${pg}${p.inspector_raw ? ' · 검사자 ' + e(p.inspector_raw) : ''}</div>`;
  }
  function closeRow(tr) { if (!tr) return; const nx = tr.nextElementSibling; if (nx && nx.classList.contains('je-tr')) nx.remove(); tr.classList.remove('je-cur') }
  function open(k, keep) {
    const tr = document.querySelector(`tr[data-i="${k}"]`); if (!tr) return;
    const nx = tr.nextElementSibling; if (nx && nx.classList.contains('je-tr')) { if (keep) nx.remove(); else { summary(k); closeRow(tr); return } }
    if (!keep) document.querySelectorAll('tr.je-cur').forEach(o => { if (o !== tr) { const j = +o.dataset.i; summary(j); closeRow(o) } });
    const row = document.createElement('tr'); row.className = 'je-tr';
    row.innerHTML = `<td colspan="${tr.children.length}" style="background:var(--edit-bg);text-align:left">${headHtml(k, getItem(k).payload)}${editorHtml(k, getItem(k).payload)}</td>`;
    tr.after(row); tr.classList.add('je-cur'); nameDecorate(row);
    if (!keep) tr.scrollIntoView({ block: 'start', behavior: 'smooth' });
  }
  function redraw(k) { const tr = document.querySelector(`tr[data-i="${k}"]`), nx = tr?.nextElementSibling; if (nx && nx.classList.contains('je-tr')) open(k, true) }
  // (2026-11-07 팀장) 조립 일보 한 장 = 권선(BA)·압입(CA) 두 줄: 작업자·비고는 같은 장이므로 한 번만 고치면 짝 줄에도 같이 반영
  const ASM = ['IMEB3_WINDING', 'IMEB3_CA_PRESS'];
  const SHARED = /^(workers_raw|remarks_raw)(\.|$)/;
  function siblings(k) {
    const a = getItem(k)?.payload; if (!a || !ASM.includes(a.process)) return [];
    const pg = a.source?.page, f = a.source?.file || a.source?.filename;
    return (window.pendingItems || []).map((it, j) => [it, j]).filter(([it, j]) => j !== k && it && it.ok && it.payload && ASM.includes(it.payload.process)
      && it.payload.process !== a.process && it.payload.work_date === a.work_date && it.payload.model === a.model
      && String(it.payload.source?.page ?? '') === String(pg ?? '') && String(it.payload.source?.file || it.payload.source?.filename || '') === String(f || '')).map(([, j]) => j);
  }
  function syncShared(k) {
    const src = getItem(k).payload, sibs = siblings(k); if (!sibs.length) return 0;
    for (const j of sibs) {
      const it = getItem(j), p = it.payload;
      const bw = JSON.stringify(p.workers_raw || []), br = p.remarks_raw;
      p.workers_raw = JSON.parse(JSON.stringify(src.workers_raw || [])); p.remarks_raw = src.remarks_raw ?? null;
      if (JSON.stringify(p.workers_raw) !== bw) track(it, 'workers_raw(같은 장 반영)', bw);
      if ((p.remarks_raw ?? null) !== (br ?? null)) track(it, 'remarks_raw', br);
      const st = document.querySelector(`tr[data-i="${j}"] .st-cell`); if (st && !st.dataset.edited) { st.dataset.edited = '1'; st.insertAdjacentHTML('beforeend', '<br><small class="warn">수정됨(같은 장 반영)</small>') }
      redraw(j);
    }
    const note = document.querySelector(`.je[data-k="${k}"] .je-sib`); if (note) note.textContent = `작업자·비고는 같은 장의 ${sibs.map(j => getItem(j).payload.process === 'IMEB3_WINDING' ? '권선(BA)' : '압입(CA)').join('·')} 줄에도 같이 반영됩니다`;
    return sibs.length;
  }

  document.addEventListener('input', ev => {
    const t = ev.target, box = t.closest && t.closest('.je'); if (!box) return;
    if (t.dataset.cls) {
      const k = +box.dataset.k, it = getItem(k); if (!it) return; const p = it.payload, bt = p.inspection_type, br = p.inspection_round;
      p.inspection_type = t.value === 'RE' ? 'REINSPECTION' : 'FINAL'; p.inspection_round = t.value === 'FIRST' ? 1 : 2;
      track(it, 'inspection_type', bt); track(it, 'inspection_round', br); t.style.background = '#eaf7ea'; redraw(k);
      const st = document.querySelector(`tr[data-i="${k}"] .st-cell`); if (st && !st.dataset.edited) { st.dataset.edited = '1'; st.insertAdjacentHTML('beforeend', '<br><small class="warn">수정됨(저장 전)</small>') }
      return;
    }
    if (!t.dataset.p) return;
    const k = +box.dataset.k, it = getItem(k); if (!it) return;
    const before = getPath(it.payload, t.dataset.p);
    setPath(it.payload, t.dataset.p, t.value);
    track(it, t.dataset.p, before);
    if (SHARED.test(t.dataset.p)) syncShared(k);
    if (/^(defects\.\d+\.qty|defect_qty)$/.test(t.dataset.p)) { const ds = box.querySelector('.je-dsum'); if (ds) ds.innerHTML = dsumHtml(it.payload); checkMarkRows() }
    if (NAME_P.test(t.dataset.p)) { const sp = t.nextElementSibling; if (sp && sp.classList.contains('je-nmw')) sp.innerHTML = chipHtml(t.dataset.p, t.value); nameMarkRows() }
    if (t.dataset.p === 'inspection_type') { if (t.value === 'REINSPECTION' && !it.payload.inspection_round) it.payload.inspection_round = 2; redraw(k); }
    t.style.background = flag(t.value) ? 'var(--flag-bg)' : 'var(--ok-bg)'; t.style.borderColor = flag(t.value) ? '#e7ad00' : '#5cb85c';
    const st = document.querySelector(`tr[data-i="${k}"] .st-cell`); if (st && !st.dataset.edited) { st.dataset.edited = '1'; st.insertAdjacentHTML('beforeend', '<br><small class="warn">수정됨(저장 전)</small>') }
  });
  document.addEventListener('change', ev => { const t = ev.target; if (t.tagName === 'SELECT' && t.closest && t.closest('.je')) t.dispatchEvent(new Event('input', { bubbles: true })) });
  document.addEventListener('click', ev => {
    const t = ev.target; if (!t.dataset) return;
    if (t.dataset.ed != null) { open(+t.dataset.ed); return }
    if (t.dataset.jeNm) { const i = t.closest('.je')?.querySelector(`input[data-p="${t.dataset.jeNm}"]`); if (i) { i.value = t.dataset.v; i.dispatchEvent(new Event('input', { bubbles: true })) } return }
    const box = t.closest && t.closest('.je'); if (!box) return; const k = +box.dataset.k, p = getItem(k).payload;
    if (t.dataset.jeAlt) { const r = getPath(p, t.dataset.jeAlt), it = getItem(k); if (!r) return; const before = r.qty; r.qty = numOr(r.qty_alt); r.qty_alt = before; track(it, t.dataset.jeAlt + '.qty', before); checkMarkRows(); redraw(k); return }
    if (t.dataset.jeAdd) { const blank = { inputs: { process: null, component: null, lot_date: null, raw: null }, materials: { material: 'IMEB3_RESIN', lot_date: null, raw: null, qty: null, unit: null, spindle: null }, defects: { name: '', qty: null, raw: null }, lots: { raw: '', marking_code: null, boxes: null }, workers_raw: { name: '', role: null } }[t.dataset.jeAdd]; p[t.dataset.jeAdd].push(blank); track(getItem(k), t.dataset.jeAdd + '.' + (p[t.dataset.jeAdd].length - 1) + '(추가)', null); if (t.dataset.jeAdd === 'workers_raw') syncShared(k); redraw(k); return }
    if (t.dataset.jeDel) { const [name, i] = t.dataset.jeDel.split('.'); const gone = JSON.stringify(p[name][+i] || {}).slice(0, 180); p[name].splice(+i, 1); const it = getItem(k); it._orig = it._orig || {}; it._orig[name + '.' + i + '(빼기)'] = gone; (p.source = p.source || {}).human_edits = [...(p.source.human_edits || []), { path: name + '.' + i + '(빼기)', ai: gone, value: null }]; it.edited = p.source.human_edits.length; window.journalEditCount && window.journalEditCount(); if (name === 'workers_raw') syncShared(k); redraw(k); return }
    if (t.dataset.jeClose != null) { summary(k); const tr = document.querySelector(`tr[data-i="${k}"]`); closeRow(tr); if (tr) { tr.scrollIntoView({ block: 'center', behavior: 'smooth' }); tr.style.transition = 'background .8s'; tr.style.background = '#eaf7ea'; setTimeout(() => tr.style.background = '', 1200) } }
  });
  const css = document.createElement('style');
  css.textContent = `.je{font-size:12px}.je-grid{display:flex;flex-wrap:wrap;gap:8px 14px;margin-bottom:6px}.je label{display:inline-flex;gap:4px;align-items:center;font-weight:400}.je-wide{display:flex!important;margin:4px 0}.je-wide input{flex:1}
  .je-list{margin:8px 0;padding:6px 8px;border:1px dashed #cfd6dd;border-radius:8px}.je-list>b{display:block;margin-bottom:4px}.je-row{display:flex;flex-wrap:wrap;gap:4px;align-items:center;margin:3px 0}.je input,.je select{padding:3px 5px;font-size:12px;width:auto}
  tr.je-cur>td{background:var(--cur-bg,#e3f0ff)!important;border-top:2px solid #1e6fd9;border-bottom:2px solid #1e6fd9}tr.je-cur>td:first-child{border-left:5px solid #1e6fd9}
  tr.je-tr>td{border-left:5px solid #1e6fd9;border-bottom:2px solid #1e6fd9}:root{--cur-bg:#e3f0ff}[data-theme=dark]{--cur-bg:#16263d}.je-alt{font-size:11px;padding:1px 6px;border-radius:8px;background:var(--flag-bg)}.je-dsum{margin:-2px 0 6px;font-size:12px}.je-dbad{color:#c62828;font-weight:600}.je-nmw{display:inline-flex;align-items:center}.je-nm{font-size:11px;margin-left:4px;padding:1px 6px;border-radius:8px}.je-nm.ok{color:#2e7d32}.je-nm.fx{background:var(--flag-bg);color:inherit}.je-nm.nw{color:#b26a00}.je-head{position:sticky;top:0;z-index:5;margin:-2px 0 8px;padding:6px 10px;background:#1e6fd9;color:#fff;border-radius:6px;font-size:13px}`;
  document.head.appendChild(css);
})();
