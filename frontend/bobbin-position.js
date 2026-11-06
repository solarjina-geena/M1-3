// 관리 화면 '보빈 위치도' 탭 — 사출 보빈 초품 위치도 월별 엑셀(모델별 시트, 캐비티 16 × 좌우)을 올려 블록별 저장. 2026-11-06
// 1블록 = 초품 1회 = BB LOT(날짜 + ㈜/(야) → D1/N1). 같은 모델 사출 실행이 1건이면 FK 연결, 아니면 미연결(추정 안 함).
// 판정은 저장 후 DB 기준(BOBBIN-POSITION-A1-3)이 계산한다. 미리보기 판정은 같은 규칙(정상 ≤0.35 · 경계 ≤0.40 · 불량)으로 화면에서만.
(() => {
  const $ = s => document.querySelector(s);
  const e = v => (typeof esc === 'function' ? esc(v) : String(v ?? ''));
  const NOM = { x: 2.1, y: 12.0 }, SPEC = 0.35, CTRL = 0.40;
  let prev = null;
  const judge = (x, y) => { if (x == null || y == null) return null; const dx = x - NOM.x, dy = y - NOM.y, v = Math.max(2 * Math.abs(dx), 2 * Math.abs(dy), 2 * Math.hypot(dx, dy)); return { xy: 2 * Math.hypot(dx, dy), st: v <= SPEC ? '정상' : v <= CTRL ? '경계' : '불량' } };
  const C = { 정상: 'ok', 경계: 'warn', 불량: 'err' };

  function blockSummary(b) {
    const n = { 정상: 0, 경계: 0, 불량: 0 }; let diff = 0, mx = 0;
    for (const r of b.rows) for (const [x, y, s] of [[r.lx, r.ly, r.src_l], [r.rx, r.ry, r.src_r]]) {
      const j = judge(x == null ? null : +x, y == null ? null : +y); if (!j) continue; n[j.st]++; mx = Math.max(mx, j.xy);
      if (s && s !== (j.st === '정상' ? 'OK' : 'NG')) diff++;
    }
    const bad = [];
    for (const r of b.rows) for (const [sd, x, y] of [['좌', r.lx, r.ly], ['우', r.rx, r.ry]]) { const j = judge(x == null ? null : +x, y == null ? null : +y); if (j && j.st !== '정상') bad.push({ sd, no: r.no, st: j.st, v: j.xy }) }
    return { n, diff, mx, bad };
  }
  function lotOf(b) { return b.date ? b.date.slice(2).replace(/-/g, '') + (b.shift || '?') + '1' : '?' }

  function render() {
    const box = $('#bp_out'); if (!prev) { box.innerHTML = ''; return }
    const bs = prev.blocks;
    box.innerHTML = `<div class="muted">${e(prev.file)} · 값이 든 블록 ${bs.length}개 (빈 양식은 건너뜀) · 복사본 ${bs.filter(b => b.copy_of).length}개는 기본 해제 · 판정: 정상 ≤${SPEC} · 경계 ≤${CTRL} · 불량 (원천 OK/NG 와 다른 칸 = ≠)</div>
      <table><tr><th><input type="checkbox" id="bp_all" style="width:auto"></th><th>모델</th><th>제목 날짜</th><th>BB LOT</th><th>캐비티</th><th>정상</th><th>경계</th><th>불량</th><th>최대 위치도</th><th>불량·경계 캐비티</th><th>원천과 다른 칸</th><th>특이사항</th><th>상태</th></tr>
      ${bs.map(b => { const s = blockSummary(b), ok = !b.problem && !b.copy_of; return `<tr${b.copy_of ? ' style="opacity:.6"' : ''}>
        <td>${b.problem ? '' : `<input type="checkbox" class="bp_blk" value="${e(b.key)}" ${ok && !b.exists ? 'checked' : ''} style="width:auto">`}</td>
        <td><b>${e(b.model)}</b><br><small class="muted">${e(b.key)}</small></td><td>${e(b.label)}</td>
        <td>${e(lotOf(b))}${b.shift ? '' : '<br><small class="warn">주/야 없음 → 그날 사출 1건일 때만 연결</small>'}</td><td>${b.rows.length}</td>
        <td class="ok">${s.n.정상}</td><td class="warn">${s.n.경계 || ''}</td><td class="err">${s.n.불량 || ''}</td><td>${s.mx.toFixed(3)}</td><td style="text-align:left;white-space:nowrap">${s.bad.length ? s.bad.map(x => `<span class="${C[x.st]}">${x.sd} ${String.fromCharCode(64 + x.no)}</span>`).join(' ') : '<span class="muted">—</span>'}</td><td class="${s.diff ? 'err' : 'muted'}">${s.diff || '—'}</td>
        <td><input class="bp_note" data-key="${e(b.key)}" maxlength="500" placeholder="선택" style="width:140px"></td>
        <td>${b.problem ? `<span class="err">${e(b.problem)}</span>` : b.copy_of ? `<span class="warn">복사본(= ${e(b.copy_of)}과 값 같음)</span>` : b.exists ? '<span class="warn">이미 저장됨</span>' : b.same_day_blocks > 1 ? '<span class="warn">같은 날·주야 블록 여러 개</span>' : '<span class="ok">새 블록</span>'}</td></tr>` }).join('')}</table>`;
    $('#bp_all').onchange = ev => document.querySelectorAll('.bp_blk').forEach(c => c.checked = ev.target.checked);
  }

  function preview() {
    const f = $('#bp_file').files[0];
    if (!f) { setStatus('bobbin', '엑셀 파일을 먼저 고르세요', 'warn'); return }
    job('bobbin', '보빈 위치도 읽기', async signal => {
      const fd = new FormData(); fd.append('file', f);
      prev = await api('/api/bobbin-position/preview', { method: 'POST', authed: true, body: fd, signal });
      render();
      const m = {}; prev.blocks.forEach(b => m[b.model] = (m[b.model] || 0) + 1);
      return `미리보기 · 블록 ${prev.blocks.length}개 (${Object.entries(m).map(([k, v]) => k + ' ' + v).join(' · ')}) — 저장할 블록을 고르고 'DB에 저장'`;
    }, { limit: 120 }).catch(() => { });
  }

  function previewText() {
    const text = $('#bp_text').value;
    if (!text.trim()) { setStatus('bobbin', '엑셀에서 블록을 복사해 붙여넣으세요', 'warn'); return }
    job('bobbin', '붙여넣기 읽기', async signal => {
      prev = await api('/api/bobbin-position/preview-text', { method: 'POST', authed: true, signal, headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ text, model: $('#bp_model').value || null, date: $('#bp_date').value || null, shift: $('#bp_shift').value || null }) });
      render();
      if (!prev.blocks.length) return '읽을 수 있는 블록이 없습니다 — 제목 줄부터 복사하거나, NO·좌X·좌Y·위치도·판정·우X·우Y… 줄을 복사하세요';
      return `미리보기 · 블록 ${prev.blocks.length}개 — 확인 후 'DB에 저장'`;
    }, { limit: 60 }).catch(() => { });
  }

  // 방금 저장한 블록으로 대시보드를 연다: 모델이 하나면 그 모델, 날짜가 하나면 하루 보기, 여러 날이면 기간 보기
  function bbLink(r) {
    const ok = r.results.filter(x => x.ok).map(x => prev.blocks.find(b => b.key === x.key)).filter(Boolean);
    const ms = [...new Set(ok.map(b => b.model))], ds = [...new Set(ok.map(b => b.date))].sort();
    let u = 'index.html?proc=INJECTION&view=bobbin' + (ms.length === 1 ? '&model=' + ms[0] : '');
    if (ds.length === 1) u += '&date=' + ds[0]; else if (ds.length > 1) u += `&mode=range&from=${ds[0]}&to=${ds.at(-1)}`;
    return u;
  }

  function save() {
    if (!prev) { setStatus('bobbin', '먼저 미리보기를 하세요', 'warn'); return }
    const keys = [...document.querySelectorAll('.bp_blk:checked')].map(c => c.value);
    if (!keys.length) { setStatus('bobbin', '저장할 블록을 고르세요', 'warn'); return }
    const notes = {}; document.querySelectorAll('.bp_note').forEach(i => { if (i.value.trim()) notes[i.dataset.key] = i.value.trim() });
    if (!confirm(`보빈 초품 위치도 ${keys.length}블록을 저장할까요?`)) return;
    job('bobbin', 'DB 저장', async signal => {
      const r = await api('/api/bobbin-position', { method: 'POST', authed: true, signal, headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ sha256: prev.sha256, keys, replace: $('#bp_replace').checked, notes }) });
      $('#bp_res').innerHTML = `<ul>${r.results.map(x => x.ok ? `<li class="ok">${e(x.key)} → BB LOT ${e(x.bb_lot)} · 측정값 ${x.measurements}개 · ${x.process_run_id ? '사출 실행 연결' : `<span class="warn">미연결(그 LOT 사출 실행 ${x.runs}건)</span>`}</li>` : `<li class="err">${e(x.key)} 실패 · ${e(x.error)}</li>`).join('')}</ul>
        <a class="primary small" href="${bbLink(r)}" target="m13dash" style="display:inline-block;margin-top:4px;padding:6px 12px;border-radius:8px;text-decoration:none">방금 저장한 보빈 위치도 보기 ↗</a>`;
      prev.blocks.forEach(b => { if (r.results.some(x => x.ok && x.key === b.key)) b.exists = true }); render(); loadList();
      const bad = r.results.filter(x => !x.ok).length;
      return `저장 ${r.saved}블록${bad ? ` · 실패 ${bad}블록(목록에 사유)` : ''}`;
    }, { limit: 120 }).catch(() => { });
  }

  async function loadList() {
    const m = $('#bp_listModel').value; let rows = [];
    try { rows = await api('/api/bobbin-position-entries' + (m ? '?model=' + m : '')) } catch (err) { $('#bp_list').innerHTML = `<div class="err">${e(err.message)}</div>`; return }
    m13List.show('bobbin', $('#bp_list'), rows, {
      dateKey: 'check_date', timeKey: 'recorded_at', dateLabel: '측정일', empty: '입력된 보빈 위치도가 없습니다.',
      head: '<th>측정일</th><th>모델</th><th>주야</th><th>BB LOT</th><th>캐비티·좌우</th><th>정상</th><th>경계</th><th>불량</th><th>최대 위치도</th><th>사출 실행</th><th>특이사항</th><th>입력 시각</th><th></th>',
      row: r => `<tr><td>${e(r.check_date)}</td><td>${e(r.model_code)}</td><td>${r.shift === 'D' ? '주간' : r.shift === 'N' ? '야간' : '<span class="warn">미기재</span>'}</td><td>${e(r.bb_lot_code || '')}</td><td>${r.points}</td><td class="ok">${r.ok_cnt}</td><td class="warn">${r.warn_cnt || ''}</td><td class="err">${r.ng_cnt || ''}</td><td>${r.max_pos != null ? Number(r.max_pos).toFixed(3) : '—'}</td><td>${r.run_linked ? '연결' : '<span class="muted">미연결</span>'}</td><td class="muted">${e(r.note || '')}</td><td class="muted">${e(m13Time(r.recorded_at))}</td>
        <td style="white-space:nowrap"><a class="ghost small" href="index.html?proc=INJECTION&view=bobbin&model=${e(r.model_code)}&date=${e(r.check_date)}" target="m13dash">보기</a> <button class="ghost small" type="button" data-bpv="${e(r.check_id)}" data-bpl="${e(r.model_code + ' ' + r.check_date + ' ' + (r.shift || ''))}">삭제</button></td></tr>`,
      after: box => box.querySelectorAll('[data-bpv]').forEach(b => b.onclick = () => {
        const note = prompt(b.dataset.bpl + ' 보빈 위치도를 삭제(VOID)할까요?\n사유를 5자 이상 적어 주세요'); if (note === null) return;
        job('bobbin', '삭제', async () => { const r = await api('/api/bobbin-position/void', { method: 'POST', authed: true, headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ check_id: b.dataset.bpv, note }) }); loadList(); return `삭제(VOID) · ${b.dataset.bpl} · 측정값 ${r.voided_measurements}개` }).catch(() => { });
      }),
    });
  }

  function init() {
    if (!$('#v-bobbin')) return;
    $('#bp_go').onclick = preview; $('#bp_goText').onclick = previewText; $('#bp_save').onclick = save; $('#bp_listGo').onclick = loadList; $('#bp_listModel').onchange = loadList;
    $('#bp_file').onchange = () => { prev = null; render(); $('#bp_res').innerHTML = ''; const f = $('#bp_file').files[0]; if (f) setStatus('bobbin', `파일 선택됨 · ${f.name} · '미리보기'를 누르세요`, 'info') };
    document.querySelector('#tabs [data-v="bobbin"]')?.addEventListener('click', loadList);
  }
  document.readyState === 'loading' ? document.addEventListener('DOMContentLoaded', init) : init();
})();
