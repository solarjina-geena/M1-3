// ⑦ 최종검사 탭: 최종검사 일보 판독에서 '비고란 재검사'를 따로 뺀 항목을 미리보기 아래에 보여 주고, 고쳐서 한 건씩 저장한다. 2026-11-07 사용자 요청
// (예전: 비고를 따로 캡처해 재검사 칸에 다시 올리는 방식 → 이제 같은 판독에서 바로)
// 저장 = 기존 재검사 저장(/api/reinspection → m13_reinspection_save): inspection_run(재검) + inspection_lot(CA LOT FK, 못 정하면 미연결) + 본검사 연결 + 불량.
// 검사 내용(현미경 검사·와이어 데미지·리드핀 찍힘 등 한 가지)은 특이사항으로 비고 원문 앞에 [검사내용] 으로 남기고 source.inspection_content 에도 둔다.
(() => {
  const e = v => (typeof esc === 'function' ? esc(v) : String(v ?? ''));
  const opt = (v, cur, t) => `<option value="${e(v)}" ${String(cur ?? '') === String(v) ? 'selected' : ''}>${e(t ?? v)}</option>`;
  let list = [], file = '';

  function lotRow(l, i, j) {
    const cands = l.ca_candidates || [];
    return `<tr data-ri="${i}" data-lj="${j}"><td><input class="ri_mark" value="${e(l.mark)}" style="width:70px"></td>
      <td><input class="ri_box" type="number" min="0" value="${e(l.box_count ?? '')}" style="width:60px"></td>
      <td><input class="ri_ea" type="number" min="0" value="${e(l.qty_ea ?? '')}" style="width:80px"></td>
      <td><input class="ri_ca" list="ri_ca_${i}_${j}" value="${e(l.ca_lot_code || '')}" placeholder="${l.lot_date ? '비우면 ' + e(l.lot_date.slice(2).replace(/-/g, '')) + 'D1 (CA 일보 미확인 LOT)' : '못 읽음 → 비우면 미연결'}" style="width:110px${l.ca_lot_code ? '' : ';background:#fff3cd'}">
        <datalist id="ri_ca_${i}_${j}">${cands.map(c => `<option value="${e(c)}">`).join('')}</datalist><br><small class="muted">${e(l.how || '')}</small></td>
      <td><select class="ri_prior">${opt('ALL', l.prior_run_id, `본검사 전부${l.prior_runs ? ' (' + l.prior_runs + '건)' : ''}`)}${opt('NONE', l.prior_run_id, '연결 안 함')}</select></td>
      <td><button class="ghost small" type="button" data-rdel="${i}.${j}">빼기</button></td></tr>`;
  }
  function card(r, i) {
    return `<div class="card" style="margin:8px 0;padding:10px;border:1px solid #f0c36d;background:#fffdf5" data-rcard="${i}">
      <div style="display:flex;flex-wrap:wrap;gap:8px 14px;align-items:center;font-size:12px">
        <b>재검사 ${i + 1}</b>
        <label>모델 <select class="ri_model">${opt('', r.model, '고르세요')}${['IV', 'OV', 'HSV'].map(m => opt(m, r.model)).join('')}</select></label>
        <label>재검일 <input class="ri_date" type="date" value="${e(r.inspection_date || '')}"></label>
        <label>특이사항(검사 내용) <input class="ri_content" value="${e(r.inspection_content || '')}" placeholder="현미경 검사 / 와이어 데미지 / 리드핀 찍힘" style="width:170px"></label>
        <label>방법 <select class="ri_method">${opt('VISUAL_MANUAL', r.method, '육안 재검')}${opt('MICROSCOPE', r.method, '현미경 검사')}</select></label>
        <label>검사 수량(EA) <input class="ri_qty" type="number" min="0" value="${e(r.qty_ea ?? '')}" style="width:90px"></label>
        <label>검사자 <small class="muted">(저장 시 가림)</small> <input class="ri_insp" value="${e(r.inspector_raw || r.inspector_masked || '')}" style="width:80px"></label>
      </div>
      <table style="margin-top:6px"><tr><th>LOT 마킹</th><th>BOX</th><th>EA</th><th>CA 제품 LOT (FK)</th><th>본검사 연결</th><th></th></tr>${(r.lots || []).map((l, j) => lotRow(l, i, j)).join('')}</table>
      <button class="ghost small" type="button" data-radd="${i}">＋ LOT 줄</button>
      <div style="margin-top:6px;font-size:12px"><b>재검에서 나온 불량</b> ${(r.defects || []).map((d, j) => `<span data-rdf="${i}.${j}"><input class="ri_dname" value="${e(d.name)}" style="width:120px"> <input class="ri_dqty" type="number" min="0" value="${e(d.qty ?? '')}" style="width:60px">EA</span>`).join(' · ') || '<span class="muted">비고에 불량 수량 없음</span>'}
        <button class="ghost small" type="button" data-rdadd="${i}">＋ 불량</button></div>
      <label style="display:block;margin-top:6px;font-size:12px">비고 원문 <textarea class="ri_raw" rows="2" maxlength="900" style="width:100%">${e(r.remark_raw || '')}</textarea></label>
      <div style="display:flex;gap:8px;align-items:center;margin-top:6px"><button class="primary" type="button" data-rsave="${i}">이 재검사 저장</button><span class="ri_st muted">${r.saved ? '저장됨' : '저장 전'}</span></div></div>`;
  }
  function read(i) {
    const c = document.querySelector(`[data-rcard="${i}"]`), r = list[i], q = s => c.querySelector(s);
    r.model = q('.ri_model').value || null; r.inspection_date = q('.ri_date').value; r.inspection_content = q('.ri_content').value.trim();
    r.method = q('.ri_method').value; r.qty_ea = q('.ri_qty').value === '' ? null : +q('.ri_qty').value; r.inspector_masked = q('.ri_insp').value.trim(); r.remark_raw = q('.ri_raw').value;
    c.querySelectorAll('tr[data-lj]').forEach(tr => { const l = r.lots[+tr.dataset.lj]; l.mark = tr.querySelector('.ri_mark').value.trim().toUpperCase(); l.box_count = tr.querySelector('.ri_box').value === '' ? null : +tr.querySelector('.ri_box').value;
      l.qty_ea = tr.querySelector('.ri_ea').value === '' ? null : +tr.querySelector('.ri_ea').value; l.ca_lot_code = tr.querySelector('.ri_ca').value.trim().toUpperCase() || null; l.prior_run_id = tr.querySelector('.ri_prior').value });
    c.querySelectorAll('[data-rdf]').forEach(sp => { const d = r.defects[+sp.dataset.rdf.split('.')[1]]; d.name = sp.querySelector('.ri_dname').value.trim(); d.qty = sp.querySelector('.ri_dqty').value === '' ? null : +sp.querySelector('.ri_dqty').value });
  }
  function render() {
    const box = document.getElementById('reInline'); if (!box) return;
    box.innerHTML = list.length ? `<h4 style="margin:14px 0 4px">재검사 — 비고란에서 뺀 항목 ${list.length}건 <small class="muted">(같은 판독에서 뺐습니다. 고친 뒤 한 건씩 저장 · CA LOT 칸이 비어도 마킹코드로 날짜를 알면 그 날 CA LOT(없으면 'CA 작업일보 미확인' LOT)에 FK, 못 읽은 마킹만 미연결)</small></h4>` + list.map(card).join('') : '';
    box.querySelectorAll('[data-rsave]').forEach(b => b.onclick = () => save(+b.dataset.rsave));
    box.querySelectorAll('[data-radd]').forEach(b => b.onclick = () => { const i = +b.dataset.radd; read(i); list[i].lots.push({ mark: '', box_count: null, qty_ea: null, ca_lot_code: null, prior_run_id: 'NONE' }); render() });
    box.querySelectorAll('[data-rdel]').forEach(b => b.onclick = () => { const [i, j] = b.dataset.rdel.split('.').map(Number); read(i); list[i].lots.splice(j, 1); render() });
    box.querySelectorAll('[data-rdadd]').forEach(b => b.onclick = () => { const i = +b.dataset.rdadd; read(i); list[i].defects.push({ name: '', qty: null }); render() });
    box.querySelectorAll('.ri_box').forEach(inp => inp.addEventListener('input', () => { const ea = inp.closest('tr').querySelector('.ri_ea'); if (inp.value !== '' && !ea.dataset.touched) ea.value = +inp.value * 480 }));
    box.querySelectorAll('.ri_ea').forEach(inp => inp.addEventListener('input', () => inp.dataset.touched = '1'));
  }
  async function save(i) {
    read(i); const r = list[i], st = document.querySelector(`[data-rcard="${i}"] .ri_st`);
    const lots = r.lots.filter(l => l.mark || l.ca_lot_code);
    if (!r.model) { st.textContent = '모델을 고르세요'; st.className = 'ri_st err'; return }
    if (!r.inspection_date) { st.textContent = '재검일을 넣으세요'; st.className = 'ri_st err'; return }
    if (!lots.length) { st.textContent = 'LOT 을 한 줄 이상 넣으세요'; st.className = 'ri_st err'; return }
    if (r.inspector_masked && !/\*/.test(r.inspector_masked) && r.inspector_masked.length > 1) r.inspector_masked = r.inspector_masked[0] + '*'.repeat(Math.max(1, r.inspector_masked.length - 2)) + r.inspector_masked.slice(-1);
    const note = [r.inspection_content ? `[검사내용] ${r.inspection_content}` : '', r.inspector_masked ? `검사자 ${r.inspector_masked}` : '', r.remark_raw || ''].filter(Boolean).join(' · ').slice(0, 1000);
    const body = { model: r.model, inspection_date: r.inspection_date, method: r.method, qty_ea: r.qty_ea, raw_note: note, replace: false,
      lots: lots.map(l => ({ lot_code: l.ca_lot_code || '', lot_code_raw: l.mark || null, lot_date: l.ca_lot_code ? null : (l.lot_date || null), box_count: l.box_count, qty_ea: l.qty_ea, prior_run_id: l.ca_lot_code ? (l.prior_run_id || 'ALL') : 'NONE' })),
      findings: r.defects.filter(d => d.name).map(d => ({ name_raw: d.name, qty: d.qty })),
      source: { via: '최종검사 일보 판독 비고(⑦ 탭)', file, inspection_content: r.inspection_content || null, inspector_masked: r.inspector_masked || null, ai_read: true } };
    st.textContent = '저장 중…'; st.className = 'ri_st muted';
    try {
      const x = await api('/api/reinspection', { method: 'POST', authed: true, headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
      r.saved = true; st.textContent = `저장됨 · 재검 LOT ${x.lots ?? lots.length}줄${x.unresolved ? ` · 미연결 ${x.unresolved}` : ''}`; st.className = 'ri_st ok';
      document.getElementById('r_listGo')?.click();
    } catch (err) { st.textContent = '실패 · ' + err.message; st.className = 'ri_st err' }
  }
  window.showInlineReinsp = (items, fname) => { list = (items || []).map(x => ({ ...x, lots: (x.lots || []).map(l => ({ ...l })), defects: (x.defects || []).map(d => ({ ...d })) })); file = fname || ''; render() };
})();
