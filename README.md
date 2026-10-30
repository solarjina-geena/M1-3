# M1-3 — 개인과제(M1-2) + 팀과제(M3-1) 통합

iMEB3 작업일보 데이터를 Firestore(M1-2 개인과제)에서 팀과제 Supabase `mqi` 스키마로 옮기고,
대시보드·AI 에이전트가 `mqi`를 읽도록 발전시키는 작업 폴더입니다.

## 바탕이 되는 두 프로젝트
| 프로젝트 | 위치 | 내용 |
|---|---|---|
| M1-2 개인과제 | `../M1-2` (GitHub solarjina-geena/M1-2) | FastAPI + Firestore + 대시보드/챗봇. 원소재~최종검사 LOT 추적 |
| M3-1 팀과제 | GitHub neoinkyu/M3-1 (최신 브랜치 `feat/ocr-guided-review-prototype`) | Streamlit OCR 검토 → Supabase `mqi`(52 테이블) |
| mqi 엑셀 초안 | `../M3-1/m3-1` | 원본판독 엑셀 → mqi 양식 변환 초안, `repository.py` 데이터 계층 |

## Supabase 프로젝트
| 용도 | 조직 | 프로젝트 | ref | 권한 |
|---|---|---|---|---|
| 개인 작업용 | CODYSSEY-M3-1 GEENA | IMEB3 DB | `idlckjmmoysklfssotyk` | 읽기·쓰기·스키마 적용 |
| 팀과제 | (팀 조직) | mqi-m3-1-dev | `clyjvqffabxpizkhydux` | 읽기만 |

앱이 보는 프로젝트는 `backend/.env.personal` / `.env.team`의 `SUPABASE_URL`·키로만 정해진다.

## 원칙
- Supabase `mqi`의 테이블·컬럼·제약조건은 바꾸지 않는다. 기존 구조에 맞춰 행만 넣는다 (`AGENTS.md`).
- DB 쓰기는 DB 담당(이*규)의 승인 후에만 한다. 그 전에는 읽기와 엑셀·CSV 초안으로 검증한다.
- 실제 제조 기록(`*.xlsx`, `*.csv`, 원본 PDF/사진)은 GitHub에 올리지 않는다.
- LOT 연결은 사람이 확인하기 전까지 `CANDIDATE`로 넣는다.

## 진행 기록
- 2026-10-29: 폴더 생성. M1-2·M3-1 분석 완료. Supabase에는 실제 iMEB3 데이터가 8/6~8/8 3일치만 있음을 확인.
- 2026-10-29: 개인 Supabase 프로젝트 `IMEB3 DB`(ref idlckjmmoysklfssotyk) 생성. 팀 기준 마이그레이션 `20261009000100_full_50_tables.sql`을 수정 없이 적용 → 테이블 50+1, FK 152, CHECK 229 (팀과 동일 확인).
- 2026-10-29: Firestore 720문서 → mqi 변환기(`tools/firestore_to_mqi.py`) 작성. INSERT 4,097행, LOT 사슬 CA 57개 중 수지까지 완전 7개. 적재 SQL은 `outputs/`(git 제외).
- 2026-10-29: 개인 DB에 조회 뷰(`public.m13_*`)와 쓰기 RPC(`m13_journal_save`, `m13_link_confirm`) 적용. 백엔드(FastAPI)·대시보드(`frontend/index.html`)·입력관리(`frontend/manage.html`) 작성.

- 2026-10-29: LOT 사슬 규칙 보완. 변환기(`tools/firestore_to_mqi.py`)에 BA 인서트 날짜→스티칭 LOT 직접 매칭, BA 보빈 날짜→같은 보빈의 스티칭 일보 모두 매칭(15일 범위), 스티칭 보빈 날짜→사출 LOT, 8·9월 양식 필드 20여 종, 수지 `resin_lots_raw` 처리를 추가. BA→사출 직접 연결 45행은 VOID. 개인 DB에 차이분 적용(`outputs/firestore_mqi_delta*_20261029.sql`), 사슬 뷰 `m13_lot_chain_gaps` v2(CA LOT 당 1행, '참조만 있음' 구분). 완전 사슬 CA LOT 8 → 22 / 57. 조견표 규칙(Z+월+일)으로 최종검사 LOT 매핑 319 → 355, 09-30 CA 리워크는 `rework_record` 로. 뷰에 BA·CA 수량 차이(`ba_ca_gap`). 대조 기록은 `docs/사슬_*_20261029.md`.

- 2026-10-29(저녁): 최종검사 규칙 반영. 검사자 `worker`(가린 이름) 22명, 1차(신입·지원)/2차(전담 4명=실제 수량) 차수, 재검·미성형 검사 유형, `inspection_run_link` 43건. 리워크 `rework_record` 4건. LOT 흐름표 뷰 `m13_lot_flow`. 기록: `docs/검사규칙_및_LOT흐름표_20261029.md`, `docs/BA_CA_수량차이_원문확인_20261029.md`.
- 2026-10-29(밤): 자재 LOT 가지 보강. 변환기에 리드핀·와이어·케이스 필드 20여 종과 자재 홈 공정 규칙(BB 수지/BS 리드핀/BA 와이어/CA 케이스) 추가, 개인 DB 에 delta7 적용(material_usage 427 ACTIVE, 완전 사슬 25/57). OCR 프롬프트 공정별 필수 항목 체크리스트, `JournalPayload` 필드 확장, RPC `m13_journal_save` v2, 대시보드 추적 그래프에 자재 칩. 기록: `docs/사슬_연결_적용결과_20261029.md` 7차.

- 2026-10-30(밤): OCR 정답률 측정기 `tools/accuracy/`(정답지 xls/xlsx → 칸, DB 뷰 `public.m13_accuracy_cells`, 팀 기준서 v1.0 판정식). 확인 전 초안: 생산수량·불량수량 59.0%(534칸). 결과·칸 목록은 로컬 docs/정답률, outputs/accuracy.
- 2026-10-30(밤): 8월 조립작업일보 엑셀 전사본 적재. `tools/assembly_xls_to_docs.py`(IV/OV·HSV 2호기/스티칭 시트, 모델은 ITEM 줄로 구분). CSV 에 모델 확정 문서가 있는 날은 제외하고 OV/HSV 보류 구간 18장만 적재(차이분 319행). CA LOT 57→74, 완전 사슬 41→49. CSV vs 전사본 수량 대조표를 로컬 docs 에 기록.
- 2026-10-30(저녁): 8월 사출작업일보 엑셀 전사본(`imeb3사출작업일보_8월_.xls`, 18장) 적재. `tools/injection_xls_to_docs.py` 로 통합 CSV 양식 문서(주/야 23건)를 만들어 변환기에 함께 입력, 차이분 120행 적용. 완전 사슬 CA LOT 25 → 41 / 57.
- 2026-10-30: 배포 준비. Supabase Auth 이메일 로그인(팀 Streamlit 앱 `auth.py` 규칙을 FastAPI 로 이식, `MQI_ALLOWED_EMAILS` 허용 목록), 대시보드에 "관리자 입력 🔒" 탭(팀 OCR 검토·적재 앱 연결 + 보조 입력 manage.html), AI 생성 표시, `render.yaml`, `tools/auth_admin.py`. 기록: `docs/배포_준비_20261030.md`.

> `docs/` 의 작업 기록(사슬_*, 검사규칙, BA_CA 수량차이, 배포_준비)은 실제 제조 기록을 담고 있어 **로컬 전용**(git 제외)이다. 공개 저장소에는 `docs/M3-1_과제보고서.md` 만 올린다.

## 실행
1. `backend/.env.example` → `backend/.env.personal` 복사 후 `SUPABASE_SERVICE_ROLE_KEY`, `SUPABASE_PUBLISHABLE_KEY`, `ANTHROPIC_API_KEY`, `MQI_ALLOWED_EMAILS` 채우기
2. `대시보드_실행.bat` 더블클릭 → http://127.0.0.1:8800
3. 메인 대시보드는 로그인 없이 조회. "관리자 입력 🔒" 탭만 Supabase Auth 이메일 로그인(계정은 `py tools/auth_admin.py create <email>`).

## 배포 (Render)
- 대시보드: https://m1-3-imeb3-dashboard.onrender.com (2026-10-30, 개인 IMEB3 DB 기준. 무료 플랜이라 첫 접속은 30~60초 대기)
- 상태 확인: https://m1-3-imeb3-dashboard.onrender.com/api/health
- `render.yaml` Blueprint 로 배포한다. 절차와 환경변수는 로컬 `docs/배포_준비_20261030.md`.
3. 입력·관리: http://127.0.0.1:8800/manage.html (직접 입력 / 엑셀·CSV / 이미지 / 사슬 보완 / 연결 확인)

## 구조
| 경로 | 내용 |
|---|---|
| `backend/app/config.py` | `.env.personal` / `.env.team` 선택 (`M13_ENV`). 팀 DB는 자동 읽기전용 |
| `backend/app/db/supabase_client.py` | PostgREST 얇은 클라이언트 (REST 조회 + RPC 쓰기) |
| `backend/app/repository/` | 데이터 계층 인터페이스와 Supabase 구현. 화면·에이전트는 이것만 사용 |
| `backend/app/ingest/journal_payload.py` | 작업일보 1장 형식(JournalPayload). 투입 LOT·원자재 LOT = 사슬 |
| `backend/app/ingest/excel_csv.py`, `image.py` | 엑셀·CSV 행 → 작업일보, 사진 → Claude 가 읽어 작업일보 (미리보기 전용) |
| `backend/app/agent/claude_agent.py` | AI 창. Anthropic SDK, 도구 5개(팀 챗봇 규약 이름), 숫자는 DB 조회만 |
| `supabase/migrations/` | 팀 기준 SQL(수정 없음) + 개인 전용 권한·뷰·RPC |
| `tools/firestore_to_mqi.py` | Firestore CSV → mqi 적재 SQL + 보고서 |
