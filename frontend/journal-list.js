// 관리 화면 ③ 사출 · ④ BS · ⑤ 조립 · ⑦ 최종검사 탭 아래 '저장된 작업일보' 목록 — 2026-11-07 팀장 요청
// 모든 입력 화면 공통 규칙: 새로고침해도 DB 에서 다시 읽어 최근 입력순 30건(+더 보기·기간 거르기), 같은 날·모델·LOT 중복 표시, 삭제(VOID, 사유 필수).
// 수정 = 같은 일보를 다시 판독해 '고치기' 후 '기존 기록 바꾸기'로 저장(이전 기록은 VOID). 탭을 바꾸면 그 탭의 판독 화면과 목록으로 바뀐다.
(() => {
  const e = v => (typeof esc === 'function' ? esc(v) : String(v ?? ''));
  const PROC = { INJECTION: 'IMEB3_INJECTION', STITCHING: 'IMEB3_STITCHING', ASSEMBLY: 'IMEB3_WINDING,IMEB3_CA_PRESS', MIXED: 'IMEB3_INJECTION,IMEB3_WINDING,IMEB3_CA_PRESS' };
  const PN = { IMEB3_INJECTION: '사출', IMEB3_STITCHING: '스티칭(BS)', IMEB3_WINDING: '권선(BA)', IMEB3_CA_PRESS: '압입(CA)' };
  const KO = { INJECTION: '사출', STITCHING: 'BS', ASSEMBLY: '조립(BA·CA)', MIXED: '사출·조립', FINAL_INSPECTION: '최종검사 본검사' };
  function box() {
    let b = document.getElementById('jlist');
    if (!b) {
      const out = document.getElementById('imgOut'); if (!out) return null;
      const card = out.closest('.card') || out.parentElement;
      b = document.createElement('div'); b.className = 'card'; b.id = 'jlistCard'; b.style.marginTop = '12px';
      b.innerHTML = '<h3 style="display:flex;gap:10px;align-items:center"><span id="jlistTitle">저장된 작업일보</span><button class="ghost small" type="button" id="jlistReload">목록 새로고침</button></h3><div class="sub">DB 에 저장된 기록입니다(새로고침해도 그대로). 최근 입력순 30건 · 기간으로 거르기 · <b>중복</b> = 같은 날·모델·공정·LOT 이 두 번 이상. 잘못 저장했으면 <b>삭제</b>(사유 필수, 하위 기록까지 함께 무효 처리). 수정은 같은 일보를 다시 판독해 고친 뒤 \'기존 기록 바꾸기\'로 저장하세요.</div><div id="jlist"></div>';
      card.after(b); document.getElementById('jlistReload').onclick = () => load(); b = document.getElementById('jlist');
    }
    return b;
  }
  async function load(kind) {
    kind = kind || window.journalKind; const b = box(); if (!b || !KO[kind]) return;
    const t = document.getElementById('jlistTitle'); if (t) t.textContent = `저장된 ${KO[kind]} 작업일보`;
    b.innerHTML = '<span class="muted">불러오는 중…</span>';
    const fin = kind === 'FINAL_INSPECTION';
    let rows = [];
    try { rows = await api(fin ? '/api/final-entries' : '/api/journal-entries?process=' + encodeURIComponent(PROC[kind]), { authed: true }) }
    catch (err) { b.innerHTML = `<div class="err">${e(err.message)} (로그인이 필요할 수 있습니다)</div>`; return }
    if (window.journalKind !== kind) return;
    const src = r => r.file ? `<small class="muted">${e(r.file)}${r.page ? ' · ' + e(r.page) + '쪽' : ''}</small>` : '<small class="muted">—</small>';
    const dup = r => Number(r.same_count) > 1 ? ' <span class="m13-badge" style="background:#c62828">중복 ' + r.same_count + '</span>' : '';
    const edits = r => Number(r.human_edits) ? ` <small class="muted">고침 ${r.human_edits}</small>` : '';
    const fmt = n => n == null ? '—' : Number(n).toLocaleString();
    const opts = fin ? {
      dateKey: 'inspection_date', timeKey: 'recorded_at', dateLabel: '검사일', empty: '저장된 최종검사 본검사가 없습니다.',
      head: '<th>검사일</th><th>모델</th><th>차수</th><th>검사자</th><th>검사 LOT</th><th>검사 수량</th><th>불량</th><th>출처</th><th>입력 시각</th><th></th>',
      row: r => `<tr><td>${e(r.inspection_date)}${dup(r)}</td><td>${e(r.model_code)}</td><td>${e(r.inspection_class)}</td><td>${e(r.inspector || '—')}</td><td style="text-align:left;max-width:220px">${e(r.lots || '—')}</td><td>${fmt(r.inspected_qty_ea)}</td><td>${fmt(r.defects)}</td><td>${src(r)}${edits(r)}</td><td class="muted">${e(typeof m13Time === 'function' ? m13Time(r.recorded_at) : r.recorded_at)}</td><td><button class="ghost small" type="button" data-jv="${e(r.run_id)}" data-jl="${e(r.model_code + ' ' + r.inspection_date + ' ' + (r.inspector || ''))}">삭제</button></td></tr>`
    } : {
      dateKey: 'work_date', timeKey: 'recorded_at', dateLabel: '작업일', empty: `저장된 ${KO[kind]} 작업일보가 없습니다.`,
      head: '<th>작업일</th><th>모델</th><th>공정</th><th>LOT</th><th>생산 수량</th><th>불량</th><th>출처</th><th>입력 시각</th><th></th>',
      row: r => `<tr><td>${e(r.work_date)}${dup(r)}</td><td>${e(r.model_code)}</td><td>${e(PN[r.process_code] || r.process_code)}</td><td>${e(r.lot_code || '—')}</td><td>${fmt(r.qty)}</td><td>${fmt(r.defects)}</td><td>${src(r)}${edits(r)}</td><td class="muted">${e(typeof m13Time === 'function' ? m13Time(r.recorded_at) : r.recorded_at)}</td><td><button class="ghost small" type="button" data-jv="${e(r.run_id)}" data-jl="${e(r.model_code + ' ' + (PN[r.process_code] || '') + ' ' + r.work_date + ' ' + (r.lot_code || ''))}">삭제</button></td></tr>`
    };
    opts.after = el => el.querySelectorAll('[data-jv]').forEach(btn => btn.onclick = async () => {
      const note = prompt(`이 기록을 삭제(무효 처리)할까요?\n${btn.dataset.jl}\n\n삭제 사유를 5자 이상 적어 주세요(예: 다른 제품 일보를 잘못 판독, 같은 일보 중복 저장)`);
      if (note == null) return; if (note.trim().length < 5) { alert('사유를 5자 이상 적어 주세요'); return }
      btn.disabled = true; btn.textContent = '삭제 중…';
      try { await api(fin ? '/api/final/void' : '/api/journal/void', { method: 'POST', authed: true, headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ run_id: btn.dataset.jv, note: note.trim() }) }); load(kind) }
      catch (err) { btn.disabled = false; btn.textContent = '삭제'; alert('삭제 실패 · ' + err.message) }
    });
    m13List.show('journal_' + kind, b, rows, opts);
  }
  window.loadJournalList = load;
  // 저장이 끝나면 목록 다시
  const orig = window.saveAll;
  if (typeof orig === 'function') window.saveAll = async (...a) => { const r = await orig(...a); try { load() } catch (_) {} return r };
  // 탭을 열 때·처음 열 때
  document.querySelectorAll('#tabs [data-kind]').forEach(b => b.addEventListener('click', () => setTimeout(() => load(b.dataset.kind), 0)));
  setTimeout(() => { if (document.querySelector('#tabs button.on[data-kind]')) load() }, 600);
})();
