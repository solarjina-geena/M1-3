// M1-3 사람 판단 기록 — 대시보드 왼쪽 '확인 필요' 탭의 판단 카드와 '확인·판단 이력' 탭.
// 저장: POST /api/judgment (RPC m13_judgment_save, 팀 표에 기록·감사 이력). 로그인은 관리 화면과 같은 sessionStorage 'm13auth'.
// 근거 이미지: 브라우저에서 SHA-256 해시만 계산해 보낸다(업로드·API 호출 없음, 원본 보관 안 함).
(() => {
  const API = (window.API_BASE_URL || '').replace(/\/$/, '');
  const $ = s => document.querySelector(s);
  const esc = v => String(v ?? '—').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const DEC = {
    READ_VALUE: { VERIFIED: '확인', CORRECTED: '정정', REJECTED: '반려' },
    INSPECTION_LOT: { CONFIRMED: 'CA LOT 연결', UNRESOLVED: '미연결 유지', VOID: '삭제(VOID)' },
    EVENT: { VERIFIED: '확인', REJECTED: '반려', VOID: '삭제(VOID)' },
    POSITION: { VERIFIED: '확인', CORRECTED: '정정', NEEDS_REVIEW: '재측정 요청' },
  };
  const KIND = { READ_VALUE: '판독값', INSPECTION_LOT: '검사 LOT', EVENT: '생산 이벤트', POSITION: '초품 위치도' };
  const BASIS = { EXTRACTION_ERROR: '판독 오류', SOURCE_TYPO: '원본 오기', FORMAT_ERROR: '형식 오류', INCONSISTENT_SOURCE: '원본끼리 불일치', OTHER: '기타' };
  const DETAIL = {
    field_code: '항목', raw_value: '원문', extracted_value: '판독값', sheet: '시트', cell: '칸', review_note: '이전 메모',
    lot_code_raw: '원문 LOT', box_count: 'BOX', quantity_raw: '수량 원문', round_no: '차수', normalization: '판독 상태',
    event_type: '유형', description: '설명', duration_minutes: '시간(분)', start_at: '시작', source_file: '원본 파일', source_page: '쪽',
    spec_pos: 'SPEC ⌀', control_pos: '관리기준 ⌀', run_linked: 'CA 실행 연결',
  };

  // ---- 로그인 세션 (manage.html 과 같은 저장소)
  const authGet = () => { try { return JSON.parse(sessionStorage.getItem('m13auth') || 'null') } catch (e) { return null } };
  const authSet = j => sessionStorage.setItem('m13auth', JSON.stringify({ access_token: j.access_token, refresh_token: j.refresh_token, expires_at: j.expires_at, email: j.user?.email || authGet()?.email }));
  const tok = () => authGet()?.access_token || sessionStorage.getItem('m13token') || '';
  async function refresh() {
    const a = authGet(); if (!a?.refresh_token) return false;
    const r = await fetch(API + '/api/auth/refresh', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ refresh_token: a.refresh_token }) });
    if (!r.ok) { sessionStorage.removeItem('m13auth'); return false }
    authSet(await r.json()); return true;
  }
  async function post(path, body, retry = true) {
    const r = await fetch(API + path, { method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: 'Bearer ' + tok() }, body: JSON.stringify(body) });
    if (r.status === 401 && retry && await refresh()) return post(path, body, false);
    const j = await r.json().catch(() => ({}));
    if (!r.ok) { const e = new Error(typeof j.detail === 'string' ? j.detail : `HTTP ${r.status}`); e.status = r.status; throw e }
    return j;
  }

  // ---- 상태
  let queue = [], selected = new Set(), openId = null, suggestion = null, images = [], filter = '';

  function css() {
    const s = document.createElement('style');
    s.textContent = `
#reviewTab:not(.hidden),#verifiedTab:not(.hidden){max-height:none;flex:1 1 auto;min-height:0;overflow:auto}
.jq-head{display:flex;gap:6px;align-items:center;margin-bottom:6px;font-size:12px}
.jq-head input{flex:1;min-width:0;padding:4px 6px;border:1px solid var(--line);border-radius:6px;font-size:12px}
.jq-row{display:flex;gap:6px;align-items:flex-start}
.jq-row input[type=checkbox]{margin-top:3px}
.jq-row .jq-main{flex:1;min-width:0;cursor:pointer}
.jq-tag{display:inline-block;font-size:11px;padding:0 5px;border-radius:9px;background:#eef1f4;color:var(--muted);margin-right:4px}
.jq-card{border:1px solid var(--blue);border-radius:8px;padding:8px;margin-top:6px;background:#f7fbff}
.jq-card dl{display:grid;grid-template-columns:auto 1fr;gap:2px 8px;margin:4px 0;font-size:11px}
.jq-card dt{color:var(--muted)} .jq-card dd{margin:0;overflow-wrap:anywhere}
.jq-dec{display:flex;flex-wrap:wrap;gap:4px;margin:6px 0}
.jq-dec button{padding:4px 8px;border:1px solid var(--line);border-radius:6px;background:#fff;cursor:pointer;font-size:12px}
.jq-dec button.on{background:var(--dark);color:#fff;border-color:var(--dark)}
.jq-card label{display:block;font-size:11px;color:var(--muted);margin-top:5px}
.jq-card input[type=text],.jq-card select,.jq-card textarea{width:100%;padding:4px 6px;border:1px solid var(--line);border-radius:6px;font:inherit;font-size:12px}
.jq-ai{margin-top:6px;padding:6px;border-radius:6px;background:#fff8e1;font-size:11px}
.jq-msg{font-size:11px;margin-top:4px} .jq-msg.err{color:var(--red)} .jq-msg.ok{color:#2e7d32}
.jq-actions{display:flex;gap:4px;margin-top:6px;flex-wrap:wrap}
.jq-actions button{padding:5px 9px;border-radius:6px;border:1px solid var(--line);background:#fff;cursor:pointer;font-size:12px}
.jq-actions button.primary{background:var(--blue);color:#fff;border-color:var(--blue)}
.jq-login{display:grid;gap:4px;margin-top:6px}
.jl-ai{font-size:10px;padding:0 4px;border-radius:8px;margin-left:4px}
.jl-ai.y{background:#e8f5e9;color:#2e7d32} .jl-ai.n{background:#ffebee;color:#c62828}`;
    document.head.appendChild(s);
  }

  // ---- 확인 필요 목록
  async function loadQueue() {
    try { queue = await (await fetch(API + '/api/review-queue')).json() } catch (e) { queue = [] }
    const b = $('#judgeBadge'); if (b) b.textContent = queue.length;
    renderQueue();
  }
  function visible() {
    const f = filter.trim().toUpperCase();
    return f ? queue.filter(q => [q.lot_code, q.model_code, q.stage_label, q.title, q.item_date].join(' ').toUpperCase().includes(f)) : queue;
  }
  function renderQueue() {
    const box = $('#judgeQueue'); if (!box) return;
    const rows = visible();
    const sel = [...selected].filter(id => queue.some(q => q.item_id === id));
    box.innerHTML = `<div class="review-item"><div class="jq-head"><b>사람 판단 필요 ${queue.length}건</b><input id="jqFilter" placeholder="LOT·모델·공정 거르기" value="${esc(filter === '' ? '' : filter)}"></div>
      <small>판독값 확인 · 판독 불가 검사 LOT · 생산 이벤트 · 초품 위치도 경계/불량. 판단은 팀 표에 남고 LOT 에 연결됩니다.${sel.length > 1 ? ` <b>선택 ${sel.length}건 일괄 판단</b>` : ''}</small></div>`
      + (rows.length ? rows.slice(0, 60).map(q => `<div class="review-item" data-id="${esc(q.item_id)}"><div class="jq-row">
          <input type="checkbox" data-sel="${esc(q.item_id)}" ${selected.has(q.item_id) ? 'checked' : ''} title="같은 종류끼리 20건까지 일괄 판단">
          <div class="jq-main" data-open="${esc(q.item_id)}"><span class="jq-tag">${esc(q.stage_label)}</span><span class="jq-tag">${esc(KIND[q.kind])}</span><b>${esc(q.model_code || '')} ${esc(q.item_date || '')}</b>${q.lot_code ? ` · LOT ${esc(q.lot_code)}` : ''}<br><small>${esc(q.title)}</small></div></div>
          ${openId === q.item_id ? card(q) : ''}</div>`).join('') + (rows.length > 60 ? `<div class="review-item"><small>외 ${rows.length - 60}건 — 위 칸에 LOT·모델로 거르세요</small></div>` : '')
        : '<div class="review-item"><small>판단할 항목 없음</small></div>');
    const fi = $('#jqFilter'); if (fi) fi.oninput = e => { filter = e.target.value; const pos = e.target.selectionStart; renderQueue(); const n = $('#jqFilter'); n.focus(); n.setSelectionRange(pos, pos) };
    box.querySelectorAll('[data-sel]').forEach(c => c.onchange = () => {
      const q = queue.find(x => x.item_id === c.dataset.sel);
      const first = queue.find(x => selected.has(x.item_id));
      if (c.checked && first && first.kind !== q.kind) { c.checked = false; alert('일괄 판단은 같은 종류끼리만 고를 수 있습니다'); return }
      if (c.checked && selected.size >= 20) { c.checked = false; alert('일괄 판단은 20건까지'); return }
      c.checked ? selected.add(q.item_id) : selected.delete(q.item_id); renderQueue();
    });
    box.querySelectorAll('[data-open]').forEach(d => d.onclick = () => { const id = d.dataset.open; openId = openId === id ? null : id; suggestion = null; images = []; renderQueue() });
    if (openId) bindCard(queue.find(q => q.item_id === openId));
  }

  const VALUE_KO = { UNCERTAIN_RAW_CODE: '원문 판독 불확실', UNRESOLVED: '미해결', OTHER: '기타', STOP: '정지', RESTART: '재가동', SETUP_CHANGE: '셋업 변경',
    MAINTENANCE: '수리·보전', MATERIAL_CHANGE: '자재 교체', PRIMARY: '주 근거', CROSS_CHECK: '대조 근거', lot_code_raw: 'LOT 코드' };
  function detailList(q) {
    const d = q.detail || {};
    const items = Object.entries(d).filter(([k, v]) => v !== null && v !== '' && k !== 'points' && DETAIL[k]).map(([k, v]) => `<dt>${esc(DETAIL[k])}</dt><dd>${esc(typeof v === 'boolean' ? (v ? '예' : '아니오') : (VALUE_KO[v] || v))}</dd>`);
    if (Array.isArray(d.points)) items.push(`<dt>벗어난 점</dt><dd>${d.points.map(p => `${p.side === 'L' ? '좌' : '우'}${p.no} ⌀${p.pos_xy} ${p.status}`).map(esc).join(', ')}</dd>`);
    return `<dl>${items.join('')}</dl>`;
  }
  function card(q) {
    const dec = DEC[q.kind];
    const n = [...selected].filter(id => id !== q.item_id && queue.some(x => x.item_id === id)).length;
    return `<div class="jq-card" id="jqCard">
      ${detailList(q)}
      <div class="jq-dec">${Object.entries(dec).map(([k, v]) => `<button data-dec="${k}">${esc(v)}</button>`).join('')}</div>
      <div id="jqExtra"></div>
      <label>판단 근거 메모 (5~500자, 실명·연락처 금지) <span id="jqCount">0/500</span></label>
      <textarea id="jqNote" rows="2" maxlength="500" placeholder="예: 원본 사진 하단 야간 행 LOT 이 N1 로 적혀 있음"></textarea>
      <label>근거 이미지 (3개까지 · 해시만 저장, 원본은 올리지 않음)</label>
      <input type="file" id="jqImg" accept="image/*,application/pdf" multiple><div id="jqImgList" class="jq-msg"></div>
      <div id="jqAi"></div>
      <div id="jqLogin"></div>
      <div class="jq-actions"><button id="jqSuggest">AI 제안 받기</button><button id="jqSave" class="primary">판단 저장${n ? ` (+선택 ${n}건)` : ''}</button><button id="jqClose">닫기</button></div>
      <div id="jqMsg" class="jq-msg"></div></div>`;
  }
  function bindCard(q) {
    if (!q) return;
    let decision = null;
    const extra = () => {
      const x = $('#jqExtra'); let h = '';
      if (decision === 'CORRECTED' && q.kind === 'POSITION') h += `<label>정정값 (좌우|시료|축|값, 예 L|1|X|2.105)</label><input type="text" id="jqVal" placeholder="L|1|X|2.105">`;
      else if (decision === 'CORRECTED') h += `<label>정정값 (원문 칸은 그대로 남음)</label><input type="text" id="jqVal" value="${esc(q.current_value || '')}">`;
      if (q.kind === 'EVENT' && decision === 'VERIFIED') h += `<label>설명 정정 (선택 — 비우면 그대로)</label><input type="text" id="jqVal" placeholder="${esc(q.current_value || '')}">`;
      if (q.kind === 'INSPECTION_LOT' && decision === 'CONFIRMED') h += `<label>CA 제품 LOT 코드 (원본에서 직접 읽은 값만 · 추정 금지)</label><input type="text" id="jqLot" placeholder="예 260903D1">`;
      if (decision === 'CORRECTED' || decision === 'REJECTED') h += `<label>사유 (필수)</label><select id="jqBasis"><option value="">고르세요</option>${Object.entries(BASIS).map(([k, v]) => `<option value="${k}">${esc(v)}</option>`).join('')}</select>`;
      else if (decision) h += `<label>사유 (선택)</label><select id="jqBasis"><option value="">—</option>${Object.entries(BASIS).map(([k, v]) => `<option value="${k}">${esc(v)}</option>`).join('')}</select>`;
      x.innerHTML = h;
    };
    document.querySelectorAll('#jqCard [data-dec]').forEach(b => b.onclick = () => { decision = b.dataset.dec; document.querySelectorAll('#jqCard [data-dec]').forEach(x => x.classList.toggle('on', x === b)); extra() });
    $('#jqNote').oninput = e => $('#jqCount').textContent = `${e.target.value.length}/500`;
    $('#jqClose').onclick = () => { openId = null; renderQueue() };
    $('#jqImg').onchange = async e => {
      const files = [...e.target.files]; const msg = $('#jqImgList');
      if (files.length + images.length > 3) { msg.className = 'jq-msg err'; msg.textContent = '근거 이미지는 3개까지입니다'; e.target.value = ''; return }
      for (const f of files) {
        const pdf = f.type === 'application/pdf';
        if (f.size > (pdf ? 20 : 5) * 1024 * 1024) { msg.className = 'jq-msg err'; msg.textContent = `${f.name}: ${pdf ? 'PDF 20MB' : '이미지 5MB'} 이하만`; continue }
        const hash = [...new Uint8Array(await crypto.subtle.digest('SHA-256', await f.arrayBuffer()))].map(b => b.toString(16).padStart(2, '0')).join('');
        if (!images.some(i => i.sha256 === hash)) images.push({ sha256: hash, name: f.name.slice(0, 80) });
      }
      e.target.value = '';
      msg.className = 'jq-msg'; msg.innerHTML = images.map(i => `${esc(i.name)} · ${i.sha256.slice(0, 12)}…`).join('<br>');
    };
    $('#jqSuggest').onclick = async () => {
      const box = $('#jqAi'); box.innerHTML = '<div class="jq-ai">AI 제안을 만드는 중…</div>';
      try {
        suggestion = await post('/api/judgment/suggest', { item_id: q.item_id });
        box.innerHTML = `<div class="jq-ai"><b>AI 제안 — 사람이 결정합니다</b> (AI(Claude) 생성)<br>제안: <b>${esc(suggestion.decision_label || '없음')}</b><br>${esc(suggestion.reason)}`
          + (suggestion.similar?.length ? `<br><small>비슷한 지난 판단: ${suggestion.similar.slice(0, 3).map(s => `${s.item_date || ''} ${s.lot_code || ''} → ${s.decision_label}`).map(esc).join(' / ')}</small>` : '<br><small>비슷한 지난 판단 없음</small>') + '</div>';
      } catch (e) { suggestion = null; box.innerHTML = `<div class="jq-ai">${e.status === 401 ? '로그인 후 쓸 수 있습니다' : esc(e.message)}</div>`; if (e.status === 401) loginForm() }
    };
    $('#jqSave').onclick = async () => {
      const msg = $('#jqMsg'); msg.className = 'jq-msg err';
      const note = $('#jqNote').value.trim();
      if (!decision) { msg.textContent = '결정 버튼을 먼저 고르세요'; return }
      if (note.length < 5) { msg.textContent = '메모를 5자 이상 적어 주세요'; return }
      const val = $('#jqVal')?.value.trim() || null, basis = $('#jqBasis')?.value || null, lot = $('#jqLot')?.value.trim().toUpperCase() || null;
      if (decision === 'CORRECTED' && !val) { msg.textContent = '정정값을 적어 주세요'; return }
      if ((decision === 'CORRECTED' || decision === 'REJECTED') && !basis) { msg.textContent = '사유를 골라 주세요'; return }
      if (q.kind === 'POSITION' && decision === 'CORRECTED') {
        const m = /^([LR])\|(\d+)\|([XY])\|(-?\d+(?:\.\d{1,3})?)$/i.exec(val || '');
        if (!m) { msg.textContent = '정정값 형식: 좌우|시료|축|값 (소수 3자리까지)'; return }
      }
      if (q.kind === 'INSPECTION_LOT' && decision === 'CONFIRMED' && !/^\d{6}[DN]\d+$/.test(lot || '')) { msg.textContent = 'LOT 코드 형식: YYMMDD+D/N+순번 (예 260903D1)'; return }
      const ids = [q.item_id, ...[...selected].filter(id => id !== q.item_id && queue.some(x => x.item_id === id))];
      const body = { item_ids: ids, decision, note, value: val, lot_code: lot, basis_code: basis, images,
        ai_suggestion: suggestion?.decision ? { decision: suggestion.decision, reason: suggestion.reason, model: suggestion.model } : null };
      msg.className = 'jq-msg'; msg.textContent = '저장 중…';
      try {
        const r = await post('/api/judgment', body);
        const bad = r.results.filter(x => !x.ok);
        msg.className = bad.length ? 'jq-msg err' : 'jq-msg ok';
        msg.textContent = `저장 ${r.saved}건` + (bad.length ? ` · 실패 ${bad.length}건: ${bad[0].error}` : '');
        if (r.saved) { selected.clear(); setTimeout(() => { openId = null; loadQueue(); loadLog() }, bad.length ? 2500 : 800) }
      } catch (e) {
        msg.className = 'jq-msg err'; msg.textContent = e.status === 401 ? '로그인이 필요합니다' : e.message;
        if (e.status === 401) loginForm();
      }
    };
  }
  function loginForm() {
    const box = $('#jqLogin'); if (!box || box.innerHTML) return;
    box.innerHTML = `<div class="jq-login"><small>판단 저장·AI 제안은 팀원 로그인 후 쓸 수 있습니다</small><input type="text" id="jqEmail" placeholder="이메일" autocomplete="username"><input type="password" id="jqPw" placeholder="비밀번호" autocomplete="current-password"><button id="jqLoginBtn">로그인</button></div>`;
    $('#jqLoginBtn').onclick = async () => {
      const r = await fetch(API + '/api/auth/login', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ email: $('#jqEmail').value.trim(), password: $('#jqPw').value }) });
      const j = await r.json().catch(() => ({}));
      if (!r.ok) { $('#jqMsg').className = 'jq-msg err'; $('#jqMsg').textContent = j.detail || '로그인 실패'; return }
      authSet(j); box.innerHTML = ''; $('#jqMsg').className = 'jq-msg ok'; $('#jqMsg').textContent = '로그인됨 — 다시 저장을 누르세요';
    };
  }

  // ---- 확인·판단 이력
  async function loadLog() {
    const box = $('#judgeLog'); if (!box) return;
    let rows = [];
    try { rows = await (await fetch(API + '/api/judgments?limit=100')).json() } catch (e) { }
    const withAi = rows.filter(r => r.ai_agreed !== null && r.ai_agreed !== undefined), agree = withAi.filter(r => r.ai_agreed).length;
    box.innerHTML = `<div class="review-item"><b>사람 판단 ${rows.length}건</b><small> · AI 제안과 일치 ${withAi.length ? `${agree}/${withAi.length} (${Math.round(agree * 100 / withAi.length)}%)` : '— (제안 받은 판단 없음)'}</small></div>`
      + rows.slice(0, 30).map(r => `<div class="review-item"><span class="jq-tag">${esc(r.stage_label)}</span><b>${esc(r.decision_label)}</b> · ${esc(r.title)}
        ${r.ai_agreed === true ? '<span class="jl-ai y">AI 일치</span>' : r.ai_agreed === false ? '<span class="jl-ai n">AI 다름</span>' : ''}
        <br><small>${esc((r.changed_at || '').slice(0, 16).replace('T', ' '))} · ${esc(r.model_code || '')} ${r.lot_code ? 'LOT ' + esc(r.lot_code) : ''}${r.value ? ' · 값 ' + esc(r.value) : ''}${r.basis ? ' · ' + esc(BASIS[r.basis] || r.basis) : ''}</small>
        <br><small>${esc(r.note)}${Array.isArray(r.images) && r.images.length ? ` · 근거 이미지 ${r.images.length}개` : ''}</small></div>`).join('');
  }

  function init() {
    if (!$('#judgeQueue')) return;
    css(); loadQueue(); loadLog();
  }
  document.readyState === 'loading' ? document.addEventListener('DOMContentLoaded', init) : init();
})();
