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
      row: r => `<tr><td>${e(r.work_date)}${dup(r)}</td><td>${e(r.model_code)}</td><td>${e(PN[r.process_code] || r.process_code)}</td><td>${e(r.lot_code || '—')}</td><td>${fmt(r.qty)}</td><td>${fmt(r.defects)}</td><td>${src(r)}${edits(r)}</td><td class="muted">${e(typeof m13Time === 'function' ? m13Time(r.recorded_at) : r.recorded_at)}</td><td><button class="ghost small" type="button" data-jv="${e(r.run_id)}" data-jl="${e(r.model_code + ' ' + (PN[r.process_code] || '') + ' ' + r.work_date + ' ' + (r.lot_code || ''))}">삭제</button>${/WINDING|CA_PRESS/.test(r.process_code || '') ? `<button class="ghost small" type="button" style="margin-top:3px" title="리워크 일보 도입(10/16) 전에 조립 일보 양식에 적은 리워크 — 그날 권선·압입을 하루 전체 리워크로" data-jrw="${e(r.run_id)}" data-jl="${e(r.model_code + ' ' + r.work_date + ' 권선·압입')}">리워크로 바꾸기</button>` : ''}</td></tr>`
    };
    const afterVoid = el => el.querySelectorAll('[data-jrw]').forEach(btn => btn.onclick = async () => {
      const note = prompt(`${btn.dataset.jl} 를 '하루 전체 리워크'로 바꿀까요?
(리워크 일보 도입 전, 조립 일보에 적은 리워크)

- 생산량·LOT 흐름·불량 그래프에서 빠지고 대시보드 리워크 탭에 나타납니다
- 리워크 탭 목록의 '조립 일보로 되돌리기'로 언제든 되돌릴 수 있습니다

메모(선택, 예: 비고에 리워크 작업수량 1950 기재):`, '');
      if (note === null) return;
      btn.disabled = true; btn.textContent = '바꾸는 중…';
      try { const r = await api('/api/journal/to-rework', { method: 'POST', authed: true, headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ process_run_id: btn.dataset.jrw, note: note.trim() }) }); alert(`리워크로 바꿨습니다 · ${r.changed}건(권선·압입)`); load(kind) }
      catch (err) { btn.disabled = false; btn.textContent = '리워크로 바꾸기'; alert('바꾸기 실패 · ' + err.message) }
    });
    const prevAfter = el => afterVoid(el);
    opts.after = el => { prevAfter(el); el.querySelectorAll('[data-jv]').forEach(btn => btn.onclick = async () => {
      const note = prompt(`이 기록을 삭제(무효 처리)할까요?\n${btn.dataset.jl}\n\n삭제 사유를 5자 이상 적어 주세요(예: 다른 제품 일보를 잘못 판독, 같은 일보 중복 저장)`);
      if (note == null) return; if (note.trim().length < 5) { alert('사유를 5자 이상 적어 주세요'); return }
      btn.disabled = true; btn.textContent = '삭제 중…';
      try { await api(fin ? '/api/final/void' : '/api/journal/void', { method: 'POST', authed: true, headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ run_id: btn.dataset.jv, note: note.trim() }) }); load(kind) }
      catch (err) { btn.disabled = false; btn.textContent = '삭제'; alert('삭제 실패 · ' + err.message) }
    }) };
    m13List.show('journal_' + kind, b, rows, opts);
    if (fin) loadReinsp(); else document.getElementById('jreCard')?.remove();
  }
  // (2026-11-07 팀장) 최종검사 탭 아래 '저장된 재검사' — 검사자·LOT 범위·LOT 별 수량·불량, 삭제(VOID)
  async function loadReinsp() {
    let r = document.getElementById('jreList');
    if (!r) {
      const host = document.getElementById('jlistCard'); if (!host) return;
      const c = document.createElement('div'); c.className = 'card'; c.id = 'jreCard'; c.style.marginTop = '12px';
      c.innerHTML = '<h3>저장된 재검사 (일보 비고·재검 줄)</h3><div class="sub">재검 1건 = 검사자 1명이 다시 본 LOT 묶음. LOT 범위와 LOT 별 수량(BOX×480·낱개)을 함께 보여 줍니다. 잘못 넣은 재검은 삭제(사유 필수).</div><div id="jreList"></div>';
      host.after(c); r = document.getElementById('jreList');
    }
    if (window.journalKind !== 'FINAL_INSPECTION') { document.getElementById('jreCard')?.remove(); return }
    let rows = [];
    try { rows = await api('/api/reinspections?limit=500', { authed: true }) } catch (err) { r.innerHTML = `<div class="err">${e(err.message)}</div>`; return }
    const fmt = n => n == null ? '—' : Number(n).toLocaleString();
    const lotsTxt = x => (x.lots || []).map(l => `${e(l.lot_code_raw || '?')}${l.ca_lot_code ? ' <small class="muted">(' + e(l.ca_lot_code) + ')</small>' : ' <small class="warn">(미연결)</small>'} ${l.lot_qty != null ? fmt(l.lot_qty) : '<small class="muted">수량 —</small>'}`).join('<br>');
    const range = x => { const cs = (x.lots || []).map(l => l.ca_lot_code).filter(Boolean).sort(); return cs.length ? (cs.length > 1 ? `${cs[0]} ~ ${cs.at(-1)}` : cs[0]) + ` · ${(x.lots || []).length}개 LOT` : '—' };
    m13List.show('journal_reinsp', r, rows, {
      dateKey: 'inspection_date', timeKey: 'recorded_at', dateLabel: '재검일', empty: '저장된 재검사가 없습니다.',
      head: '<th>재검일</th><th>모델</th><th>검사자</th><th>방법</th><th>LOT 범위</th><th>LOT 별 수량</th><th>합계</th><th>불량</th><th>출처</th><th>입력 시각</th><th></th>',
      row: x => `<tr><td>${e(x.inspection_date)}</td><td>${e(x.model_code)}</td><td>${e(x.source?.inspector_masked || '—')}</td><td>${x.inspection_method === 'MICROSCOPE' ? '현미경' : '육안'}${x.source?.inspection_content ? '<br><small class="muted">' + e(x.source.inspection_content) + '</small>' : ''}</td>
        <td style="white-space:nowrap">${range(x)}</td><td style="white-space:nowrap">${lotsTxt(x)}</td><td>${fmt(x.inspected_qty_ea)}</td>
        <td style="white-space:nowrap">${(x.findings || []).map(f => e((f.defect || '') + ' ' + fmt(f.qty))).join('<br>') || '—'}</td>
        <td><small class="muted">${e(x.source?.file || '')}${x.source?.page ? ' · ' + e(x.source.page) + '쪽' : ''}</small></td><td class="muted">${e(typeof m13Time === 'function' ? m13Time(x.recorded_at) : x.recorded_at)}</td>
        <td><button class="ghost small" type="button" data-rev="${e(x.run_id)}" data-rel="${e(x.model_code + ' ' + x.inspection_date + ' ' + (x.source?.inspector_masked || ''))}">삭제</button></td></tr>`,
      after: el => el.querySelectorAll('[data-rev]').forEach(btn => btn.onclick = async () => {
        const note = prompt(`이 재검사를 삭제(무효 처리)할까요?\n${btn.dataset.rel}\n\n삭제 사유를 5자 이상 적어 주세요`); if (note == null) return;
        if (note.trim().length < 5) { alert('사유를 5자 이상 적어 주세요'); return }
        btn.disabled = true;
        try { await api('/api/reinspection/void', { method: 'POST', authed: true, headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ run_id: btn.dataset.rev, note: note.trim() }) }); loadReinsp() }
        catch (err) { btn.disabled = false; alert('삭제 실패 · ' + err.message) }
      }),
    });
  }

  window.loadJournalList = load;
  // 저장이 끝나면 목록 다시
  const orig = window.saveAll;
  if (typeof orig === 'function') window.saveAll = async (...a) => { const r = await orig(...a); try { load() } catch (_) {} return r };
  // 탭을 열 때·처음 열 때
  document.querySelectorAll('#tabs [data-kind]').forEach(b => b.addEventListener('click', () => setTimeout(() => load(b.dataset.kind), 0)));
  setTimeout(() => { if (document.querySelector('#tabs button.on[data-kind]')) load() }, 600);
})();
