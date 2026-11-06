// 관리 화면 '판독 기록' 탭 — 문서 종류별 Claude 호출 비교(횟수·토큰·판독 시간·모델), 결과보고서 표용. 2026-11-07
// 기록은 판독할 때마다 서버가 DB(extraction_run 사슬, 뷰 m13_ai_calls)에 자동으로 남긴다. 엑셀 판독(사출조건·보빈 위치도)은 토큰 0, 시간만.
(() => {
  const $ = s => document.querySelector(s);
  const e = v => (typeof esc === 'function' ? esc(v) : String(v ?? ''));
  const n = v => v == null ? '—' : Number(v).toLocaleString();
  let last = null;

  async function load() {
    const box = $('#ac_out'); box.innerHTML = '<div class="muted">불러오는 중…</div>';
    try { last = await api('/api/admin/ai-calls', { authed: true }) } catch (err) { box.innerHTML = `<div class="err">${e(err.message)}</div>`; return }
    const S = last.summary;
    box.innerHTML = `<h4 style="margin:6px 0">문서 종류별 비교 (전체 ${last.total}회)</h4>
      <table><tr><th>문서</th><th>방식</th><th>모델</th><th>횟수</th><th>성공</th><th>평균 입력 토큰</th><th>평균 출력 토큰</th><th>평균 합계 토큰</th><th>평균 판독 시간(초)</th><th>최소~최대(초)</th><th>평균 읽은 항목</th><th>누적 입력/출력 토큰</th></tr>
      ${S.map(g => `<tr><td><b>${e(g.kind_label)}</b></td><td>${g.method === 'VISION_LLM' ? 'Claude 이미지' : '엑셀 칸 판독'}</td><td>${e(g.model || '—')}</td><td>${g.calls}</td><td>${g.ok}</td>
        <td>${n(g.avg_input_tokens)}</td><td>${n(g.avg_output_tokens)}</td><td><b>${n(g.avg_total_tokens)}</b></td><td><b>${g.avg_seconds ?? '—'}</b></td><td>${g.min_seconds ?? '—'} ~ ${g.max_seconds ?? '—'}</td><td>${g.avg_items ?? '—'}</td><td>${n(g.sum_input_tokens)} / ${n(g.sum_output_tokens)}</td></tr>`).join('') || '<tr><td colspan="12" class="muted">아직 기록이 없습니다 — 작업일보·재검사·사출조건·보빈 위치도를 판독하면 쌓입니다.</td></tr>'}</table>
      <div style="margin:6px 0"><button class="ghost small" id="ac_copy" type="button">보고서용 표 복사(엑셀·한글 붙여넣기)</button> <span id="ac_copied" class="muted"></span></div>
      <h4 style="margin:12px 0 6px">판독 1회씩</h4><div id="ac_rows"></div>`;
    m13List.show('aicalls', $('#ac_rows'), last.rows.map(r => ({ ...r, day: String(r.started_at || '').slice(0, 10) })), {
      dateKey: 'day', timeKey: 'started_at', dateLabel: '판독일', empty: '기록 없음',
      head: '<th>시각</th><th>문서</th><th>모델</th><th>상태</th><th>입력 토큰</th><th>출력 토큰</th><th>시간(초)</th><th>항목</th><th>파일</th>',
      row: r => `<tr><td class="muted">${e(m13Time(r.started_at))}</td><td>${e(r.kind_label)}</td><td>${e(r.model || '엑셀')}</td><td class="${r.status === 'COMPLETED' ? 'ok' : 'err'}">${r.status === 'COMPLETED' ? '성공' : '실패'}${r.error ? `<br><small>${e(r.error.slice(0, 60))}</small>` : ''}</td><td>${n(r.input_tokens)}</td><td>${n(r.output_tokens)}</td><td>${r.seconds != null ? Number(r.seconds).toFixed(1) : '—'}</td><td>${r.items ?? r.blocks ?? '—'}</td><td class="muted" style="max-width:240px;overflow-wrap:anywhere">${e(r.file || '')}</td></tr>`,
    });
    $('#ac_copy').onclick = async () => {
      const head = ['문서', '방식', '모델', '횟수', '성공', '평균 입력 토큰', '평균 출력 토큰', '평균 합계 토큰', '평균 판독 시간(초)', '최소 시간(초)', '최대 시간(초)', '평균 읽은 항목'];
      const lines = [head.join('\t'), ...S.map(g => [g.kind_label, g.method === 'VISION_LLM' ? 'Claude 이미지' : '엑셀 칸 판독', g.model || '', g.calls, g.ok, g.avg_input_tokens ?? '', g.avg_output_tokens ?? '', g.avg_total_tokens ?? '', g.avg_seconds ?? '', g.min_seconds ?? '', g.max_seconds ?? '', g.avg_items ?? ''].join('\t'))];
      try { await navigator.clipboard.writeText(lines.join('\n')); $('#ac_copied').textContent = '복사됨 — 엑셀이나 한글 표에 붙여넣으세요' } catch (_) { $('#ac_copied').textContent = '복사 실패(브라우저 권한)' }
    };
  }

  function init() {
    if (!$('#v-aicalls')) return;
    $('#ac_go').onclick = load;
    document.querySelector('#tabs [data-v="aicalls"]')?.addEventListener('click', load);
    setTimeout(() => { if (document.querySelector('#v-aicalls')?.classList.contains('on') && !last) load() }, 500);
  }
  document.readyState === 'loading' ? document.addEventListener('DOMContentLoaded', init) : init();
})();
