-- 개인 프로젝트 전용 (IMEB3 DB). 기록용 — 2026-11-20 SQL 편집기로 이미 적용한 원본 대조 정정(행 값만, 구조 변경 없음).
-- 20261110-1.pdf 5쪽(최종검사, IV, 검사자 이*진) LOT 마킹 판독 오류를 사용자가 원본을 보고 정정.
--   1열 3,840 EA: ZKG 6BOX(→ 261107D1) ⇒ ZKE 5BOX(→ 261105D1 CA)   · ZKI 3BOX 그대로 → 5+3 = 8 BOX = 3,840 EA 일치
--   2열 3,600 EA: ZKG 4BOX+240EA(→ 261107D1) ⇒ ZKE 4BOX+240EA(→ 261105D1 CA) · ZKH 3BOX(→ 261108D1) ⇒ ZKF 3BOX(→ 261106D1 CA)
-- 고치기 전 값은 inspection_lot.remark.corrected 와 감사 이력(mqi_audit.row_change)에 남아 있다.
-- 이 정정으로 아무도 가리키지 않게 된 자리표시 LOT 261107D1·261108D1(IV) 은 아래에서 무효(VOID) 처리(사용자 지시).
-- mqi 쓰기 보호(write_guard)가 SERIALIZABLE 트랜잭션을 요구한다.

BEGIN ISOLATION LEVEL SERIALIZABLE;
SELECT set_config('mqi.actor_ref', 'm1-3-app', true),
       set_config('mqi.change_reason', '[최종검사] 원본 대조 정정 20261110-1.pdf 5쪽 1열: ZKG 6BOX → ZKE 5BOX(사용자 원본 확인 2026-11-20, 검사수량 3,840=8BOX 와 일치)', true);
UPDATE mqi.inspection_lot
   SET lot_code_raw = 'ZKE 5BOX', recorded_quantity_raw = 'ZKE 5BOX', recorded_box_count = 5,
       production_lot_id = '9d6d173e-252e-4581-bddf-a36da4cb6061',
       remark = (coalesce(public.m13_try_jsonb(remark), '{}'::jsonb) || jsonb_build_object('marking_code', 'ZKE',
                 'corrected', jsonb_build_object('before', 'ZKG 6BOX → 261107D1', 'by', '사용자 원본 확인', 'at', '2026-11-20')))::text
 WHERE inspection_lot_id = 'be24f7c8-1cc2-4a51-886c-44248231e3de' AND lot_code_raw = 'ZKG 6BOX' AND record_state = 'ACTIVE';
COMMIT;

BEGIN ISOLATION LEVEL SERIALIZABLE;
SELECT set_config('mqi.actor_ref', 'm1-3-app', true),
       set_config('mqi.change_reason', '[최종검사] 원본 대조 정정 20261110-1.pdf 5쪽 2열: ZKG 4BOX+240EA → ZKE 4BOX+240EA, ZKH 3BOX → ZKF 3BOX(사용자 원본 확인 2026-11-20)', true);
UPDATE mqi.inspection_lot
   SET lot_code_raw = 'ZKE 4BOX+240EA', recorded_quantity_raw = 'ZKE 4BOX+240EA',
       production_lot_id = '9d6d173e-252e-4581-bddf-a36da4cb6061',
       remark = (coalesce(public.m13_try_jsonb(remark), '{}'::jsonb) || jsonb_build_object('marking_code', 'ZKE',
                 'corrected', jsonb_build_object('before', 'ZKG 4BOX+240EA → 261107D1', 'by', '사용자 원본 확인', 'at', '2026-11-20')))::text
 WHERE inspection_lot_id = '825003d7-181d-47dc-844a-e38e23c9269a' AND lot_code_raw = 'ZKG 4BOX+240EA' AND record_state = 'ACTIVE';
UPDATE mqi.inspection_lot
   SET lot_code_raw = 'ZKF 3BOX', recorded_quantity_raw = 'ZKF 3BOX',
       production_lot_id = '93b184c9-7cc3-49da-b466-1349b1844033',
       remark = (coalesce(public.m13_try_jsonb(remark), '{}'::jsonb) || jsonb_build_object('marking_code', 'ZKF',
                 'corrected', jsonb_build_object('before', 'ZKH 3BOX → 261108D1', 'by', '사용자 원본 확인', 'at', '2026-11-20')))::text
 WHERE inspection_lot_id = '497d8898-33a1-4804-badf-e728567af0fa' AND lot_code_raw = 'ZKH 3BOX' AND record_state = 'ACTIVE';
COMMIT;

-- (2026-11-20 사용자 지시) 정정 뒤 참조가 없어진 자리표시 LOT 2개 무효(VOID). 행은 지우지 않음, 되돌리려면 record_state='ACTIVE'.
BEGIN ISOLATION LEVEL SERIALIZABLE;
SELECT set_config('mqi.actor_ref', 'm1-3-app', true),
       set_config('mqi.change_reason', '[최종검사] 무효(VOID): 마킹 판독 오류(ZKG·ZKH)로 생긴 자리표시 CA LOT, 원본 대조 정정 뒤 참조 0 (사용자 지시 2026-11-20)', true);
UPDATE mqi.production_lot
   SET record_state = 'VOID',
       remark = (coalesce(public.m13_try_jsonb(remark), '{}'::jsonb) || jsonb_build_object('voided', jsonb_build_object('reason', '20261110-1.pdf 5쪽 마킹 판독 오류(ZKG·ZKH)로 생긴 자리표시 LOT, 정정 뒤 참조 없음', 'at', '2026-11-20')))::text
 WHERE lot_id IN ('5c2417bd-3d4e-48f6-9e80-4e8f0a87f1c1', '64b1c823-8bdc-44a4-879a-cc5d0f356b8e') AND record_state = 'ACTIVE'
   AND NOT EXISTS (SELECT 1 FROM mqi.inspection_lot il WHERE il.production_lot_id = production_lot.lot_id AND il.record_state = 'ACTIVE')
   AND NOT EXISTS (SELECT 1 FROM mqi.process_run_lot prl WHERE prl.production_lot_id = production_lot.lot_id AND prl.record_state = 'ACTIVE');
COMMIT;
