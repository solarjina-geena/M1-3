-- Generated from database/migrations/202610090001_full_50_tables.sql; do not edit this baseline by hand.
-- CLI owns the migration transaction; standalone source retains BEGIN/COMMIT.
-- M3-1 v1: 50 domain/source tables + 1 audit infrastructure table. No factory seed data.

-- Fresh database only. PostgreSQL >= 15. Owner/migration credential, never anon.

SET LOCAL lock_timeout = '5s';

CREATE SCHEMA mqi;

CREATE SCHEMA mqi_audit;

REVOKE ALL ON SCHEMA mqi, mqi_audit FROM PUBLIC;

CREATE TABLE mqi.product (
    product_id UUID DEFAULT gen_random_uuid() NOT NULL,
    product_code VARCHAR(50),
    product_name VARCHAR(100) NOT NULL,
    is_active BOOLEAN DEFAULT TRUE NOT NULL,
    recorded_at TIMESTAMPTZ DEFAULT clock_timestamp() NOT NULL,
    updated_at TIMESTAMPTZ DEFAULT clock_timestamp() NOT NULL,
    row_version BIGINT DEFAULT 1 NOT NULL,
    record_state VARCHAR(10) DEFAULT 'ACTIVE' NOT NULL,
    CONSTRAINT pk_product_ PRIMARY KEY (product_id),
    CONSTRAINT uq_product_product_code UNIQUE (product_code),
    CONSTRAINT ck_product_row_version_positive CHECK (row_version > 0),
    CONSTRAINT ck_product_record_state_code CHECK (record_state IN ('ACTIVE', 'VOID'))
);

COMMENT ON TABLE mqi.product IS '제품군';

COMMENT ON COLUMN mqi.product.product_id IS 'PK';

COMMENT ON COLUMN mqi.product.product_code IS '제품군 식별코드';

COMMENT ON COLUMN mqi.product.product_name IS '제품군 이름';

COMMENT ON COLUMN mqi.product.is_active IS '사용 여부';

COMMENT ON COLUMN mqi.product.recorded_at IS 'DB 최초 저장 시각; 실제 제조/관측 시각과 다름';

COMMENT ON COLUMN mqi.product.updated_at IS 'DB 최종 변경 시각';

COMMENT ON COLUMN mqi.product.row_version IS '시스템 변경 버전; 원본 개정번호 아님';

COMMENT ON COLUMN mqi.product.record_state IS 'ACTIVE / VOID; VOID는 보존된 무효 기록, 참조 삭제 안 함';

CREATE TABLE mqi.product_model (
    model_id UUID DEFAULT gen_random_uuid() NOT NULL,
    product_id UUID NOT NULL,
    model_code VARCHAR(50) NOT NULL,
    model_name VARCHAR(100),
    is_active BOOLEAN DEFAULT TRUE NOT NULL,
    recorded_at TIMESTAMPTZ DEFAULT clock_timestamp() NOT NULL,
    updated_at TIMESTAMPTZ DEFAULT clock_timestamp() NOT NULL,
    row_version BIGINT DEFAULT 1 NOT NULL,
    record_state VARCHAR(10) DEFAULT 'ACTIVE' NOT NULL,
    CONSTRAINT pk_product_model_ PRIMARY KEY (model_id),
    CONSTRAINT uq_product_model_product_id_model_code UNIQUE (product_id, model_code),
    CONSTRAINT ck_product_model_row_version_positive CHECK (row_version > 0),
    CONSTRAINT ck_product_model_record_state_code CHECK (record_state IN ('ACTIVE', 'VOID'))
);

COMMENT ON TABLE mqi.product_model IS '제품 모델';

COMMENT ON COLUMN mqi.product_model.model_id IS 'PK';

COMMENT ON COLUMN mqi.product_model.product_id IS 'FK → product';

COMMENT ON COLUMN mqi.product_model.model_code IS '모델 코드';

COMMENT ON COLUMN mqi.product_model.model_name IS '모델 이름';

COMMENT ON COLUMN mqi.product_model.is_active IS '사용 여부';

COMMENT ON COLUMN mqi.product_model.recorded_at IS 'DB 최초 저장 시각; 실제 제조/관측 시각과 다름';

COMMENT ON COLUMN mqi.product_model.updated_at IS 'DB 최종 변경 시각';

COMMENT ON COLUMN mqi.product_model.row_version IS '시스템 변경 버전; 원본 개정번호 아님';

COMMENT ON COLUMN mqi.product_model.record_state IS 'ACTIVE / VOID; VOID는 보존된 무효 기록, 참조 삭제 안 함';

CREATE TABLE mqi.process (
    process_id UUID DEFAULT gen_random_uuid() NOT NULL,
    process_code VARCHAR(50) NOT NULL,
    process_name VARCHAR(100) NOT NULL,
    is_active BOOLEAN DEFAULT TRUE NOT NULL,
    recorded_at TIMESTAMPTZ DEFAULT clock_timestamp() NOT NULL,
    updated_at TIMESTAMPTZ DEFAULT clock_timestamp() NOT NULL,
    row_version BIGINT DEFAULT 1 NOT NULL,
    record_state VARCHAR(10) DEFAULT 'ACTIVE' NOT NULL,
    CONSTRAINT pk_process_ PRIMARY KEY (process_id),
    CONSTRAINT uq_process_process_code UNIQUE (process_code),
    CONSTRAINT ck_process_row_version_positive CHECK (row_version > 0),
    CONSTRAINT ck_process_record_state_code CHECK (record_state IN ('ACTIVE', 'VOID'))
);

COMMENT ON TABLE mqi.process IS '제조공정';

COMMENT ON COLUMN mqi.process.process_id IS 'PK';

COMMENT ON COLUMN mqi.process.process_code IS '공정 코드';

COMMENT ON COLUMN mqi.process.process_name IS '공정 이름';

COMMENT ON COLUMN mqi.process.is_active IS '사용 여부';

COMMENT ON COLUMN mqi.process.recorded_at IS 'DB 최초 저장 시각; 실제 제조/관측 시각과 다름';

COMMENT ON COLUMN mqi.process.updated_at IS 'DB 최종 변경 시각';

COMMENT ON COLUMN mqi.process.row_version IS '시스템 변경 버전; 원본 개정번호 아님';

COMMENT ON COLUMN mqi.process.record_state IS 'ACTIVE / VOID; VOID는 보존된 무효 기록, 참조 삭제 안 함';

CREATE TABLE mqi.production_line (
    line_id UUID DEFAULT gen_random_uuid() NOT NULL,
    line_code VARCHAR(50) NOT NULL,
    line_name VARCHAR(100) NOT NULL,
    is_active BOOLEAN DEFAULT TRUE NOT NULL,
    recorded_at TIMESTAMPTZ DEFAULT clock_timestamp() NOT NULL,
    updated_at TIMESTAMPTZ DEFAULT clock_timestamp() NOT NULL,
    row_version BIGINT DEFAULT 1 NOT NULL,
    record_state VARCHAR(10) DEFAULT 'ACTIVE' NOT NULL,
    CONSTRAINT pk_production_line_ PRIMARY KEY (line_id),
    CONSTRAINT uq_production_line_line_code UNIQUE (line_code),
    CONSTRAINT ck_production_line_row_version_positive CHECK (row_version > 0),
    CONSTRAINT ck_production_line_record_state_code CHECK (record_state IN ('ACTIVE', 'VOID'))
);

COMMENT ON TABLE mqi.production_line IS '생산라인';

COMMENT ON COLUMN mqi.production_line.line_id IS 'PK';

COMMENT ON COLUMN mqi.production_line.line_code IS '라인 식별코드';

COMMENT ON COLUMN mqi.production_line.line_name IS '라인 이름';

COMMENT ON COLUMN mqi.production_line.is_active IS '사용 여부';

COMMENT ON COLUMN mqi.production_line.recorded_at IS 'DB 최초 저장 시각; 실제 제조/관측 시각과 다름';

COMMENT ON COLUMN mqi.production_line.updated_at IS 'DB 최종 변경 시각';

COMMENT ON COLUMN mqi.production_line.row_version IS '시스템 변경 버전; 원본 개정번호 아님';

COMMENT ON COLUMN mqi.production_line.record_state IS 'ACTIVE / VOID; VOID는 보존된 무효 기록, 참조 삭제 안 함';

CREATE TABLE mqi.production_lot (
    lot_id UUID DEFAULT gen_random_uuid() NOT NULL,
    model_id UUID NOT NULL,
    lot_date DATE,
    lot_code_raw VARCHAR(100),
    verification_status VARCHAR(30) NOT NULL,
    remark TEXT,
    recorded_at TIMESTAMPTZ DEFAULT clock_timestamp() NOT NULL,
    updated_at TIMESTAMPTZ DEFAULT clock_timestamp() NOT NULL,
    row_version BIGINT DEFAULT 1 NOT NULL,
    record_state VARCHAR(10) DEFAULT 'ACTIVE' NOT NULL,
    CONSTRAINT pk_production_lot_ PRIMARY KEY (lot_id),
    CONSTRAINT uq_production_lot_lot_id_model_id UNIQUE (lot_id, model_id),
    CONSTRAINT ck_production_lot_row_version_positive CHECK (row_version > 0),
    CONSTRAINT ck_production_lot_record_state_code CHECK (record_state IN ('ACTIVE', 'VOID')),
    CONSTRAINT ck_production_lot_verification_status_code CHECK (verification_status IN ('UNVERIFIED', 'CONFIRMED', 'NEEDS_REVIEW', 'REJECTED'))
);

COMMENT ON TABLE mqi.production_lot IS '생산 LOT';

COMMENT ON COLUMN mqi.production_lot.lot_id IS 'PK';

COMMENT ON COLUMN mqi.production_lot.model_id IS 'FK → product_model';

COMMENT ON COLUMN mqi.production_lot.lot_date IS '확인된 생산 LOT 일자';

COMMENT ON COLUMN mqi.production_lot.lot_code_raw IS '원본에 기록된 LOT 표시';

COMMENT ON COLUMN mqi.production_lot.verification_status IS 'LOT 정보 검증상태';

COMMENT ON COLUMN mqi.production_lot.remark IS '추가 설명';

COMMENT ON COLUMN mqi.production_lot.recorded_at IS 'DB 최초 저장 시각; 실제 제조/관측 시각과 다름';

COMMENT ON COLUMN mqi.production_lot.updated_at IS 'DB 최종 변경 시각';

COMMENT ON COLUMN mqi.production_lot.row_version IS '시스템 변경 버전; 원본 개정번호 아님';

COMMENT ON COLUMN mqi.production_lot.record_state IS 'ACTIVE / VOID; VOID는 보존된 무효 기록, 참조 삭제 안 함';

CREATE TABLE mqi.production_run (
    run_id UUID DEFAULT gen_random_uuid() NOT NULL,
    model_id UUID NOT NULL,
    line_id UUID,
    work_date DATE,
    shift VARCHAR(10),
    run_sequence INTEGER,
    start_at TIMESTAMPTZ,
    end_at TIMESTAMPTZ,
    run_type VARCHAR(30),
    restart_reason TEXT,
    remark TEXT,
    recorded_at TIMESTAMPTZ DEFAULT clock_timestamp() NOT NULL,
    updated_at TIMESTAMPTZ DEFAULT clock_timestamp() NOT NULL,
    row_version BIGINT DEFAULT 1 NOT NULL,
    record_state VARCHAR(10) DEFAULT 'ACTIVE' NOT NULL,
    CONSTRAINT pk_production_run_ PRIMARY KEY (run_id),
    CONSTRAINT uq_production_run_run_id_model_id UNIQUE (run_id, model_id),
    CONSTRAINT ck_production_run_row_version_positive CHECK (row_version > 0),
    CONSTRAINT ck_production_run_record_state_code CHECK (record_state IN ('ACTIVE', 'VOID')),
    CONSTRAINT ck_production_run_run_sequence_positive CHECK (run_sequence > 0),
    CONSTRAINT ck_production_run_end_at_order CHECK (end_at > start_at)
);

COMMENT ON TABLE mqi.production_run IS '생산 작업구간';

COMMENT ON COLUMN mqi.production_run.run_id IS 'PK';

COMMENT ON COLUMN mqi.production_run.model_id IS 'FK → product_model';

COMMENT ON COLUMN mqi.production_run.line_id IS 'FK → production_line';

COMMENT ON COLUMN mqi.production_run.work_date IS '확인된 작업 기준일';

COMMENT ON COLUMN mqi.production_run.shift IS 'D / N 등 근무구분';

COMMENT ON COLUMN mqi.production_run.run_sequence IS '동일 기준일 내 작업구간 순번';

COMMENT ON COLUMN mqi.production_run.start_at IS '작업 시작시각';

COMMENT ON COLUMN mqi.production_run.end_at IS '작업 종료시각';

COMMENT ON COLUMN mqi.production_run.run_type IS '작업유형';

COMMENT ON COLUMN mqi.production_run.restart_reason IS '재가동 또는 작업구간 분리 사유';

COMMENT ON COLUMN mqi.production_run.remark IS '비고';

COMMENT ON COLUMN mqi.production_run.recorded_at IS 'DB 최초 저장 시각; 실제 제조/관측 시각과 다름';

COMMENT ON COLUMN mqi.production_run.updated_at IS 'DB 최종 변경 시각';

COMMENT ON COLUMN mqi.production_run.row_version IS '시스템 변경 버전; 원본 개정번호 아님';

COMMENT ON COLUMN mqi.production_run.record_state IS 'ACTIVE / VOID; VOID는 보존된 무효 기록, 참조 삭제 안 함';

CREATE TABLE mqi.process_run (
    process_run_id UUID DEFAULT gen_random_uuid() NOT NULL,
    run_id UUID NOT NULL,
    process_id UUID NOT NULL,
    work_date DATE,
    sequence_no INTEGER,
    work_type VARCHAR(30),
    start_at TIMESTAMPTZ,
    end_at TIMESTAMPTZ,
    remark TEXT,
    model_id UUID NOT NULL,
    recorded_at TIMESTAMPTZ DEFAULT clock_timestamp() NOT NULL,
    updated_at TIMESTAMPTZ DEFAULT clock_timestamp() NOT NULL,
    row_version BIGINT DEFAULT 1 NOT NULL,
    record_state VARCHAR(10) DEFAULT 'ACTIVE' NOT NULL,
    CONSTRAINT pk_process_run_ PRIMARY KEY (process_run_id),
    CONSTRAINT uq_process_run_process_run_id_model_id UNIQUE (process_run_id, model_id),
    CONSTRAINT ck_process_run_row_version_positive CHECK (row_version > 0),
    CONSTRAINT ck_process_run_record_state_code CHECK (record_state IN ('ACTIVE', 'VOID')),
    CONSTRAINT ck_process_run_sequence_no_positive CHECK (sequence_no > 0),
    CONSTRAINT ck_process_run_end_at_order CHECK (end_at > start_at)
);

COMMENT ON TABLE mqi.process_run IS '공정 실행이력';

COMMENT ON COLUMN mqi.process_run.process_run_id IS 'PK';

COMMENT ON COLUMN mqi.process_run.run_id IS 'FK → production_run';

COMMENT ON COLUMN mqi.process_run.process_id IS 'FK → process';

COMMENT ON COLUMN mqi.process_run.work_date IS '확인된 공정 작업 기준일';

COMMENT ON COLUMN mqi.process_run.sequence_no IS '공정 실행 순번';

COMMENT ON COLUMN mqi.process_run.work_type IS '작업 종류';

COMMENT ON COLUMN mqi.process_run.start_at IS '공정 시작시각';

COMMENT ON COLUMN mqi.process_run.end_at IS '공정 종료시각';

COMMENT ON COLUMN mqi.process_run.remark IS '비고';

COMMENT ON COLUMN mqi.process_run.model_id IS '상위 FK의 모델 식별자 복사; 서버 검증/자동 채움, 업무 추정 아님';

COMMENT ON COLUMN mqi.process_run.recorded_at IS 'DB 최초 저장 시각; 실제 제조/관측 시각과 다름';

COMMENT ON COLUMN mqi.process_run.updated_at IS 'DB 최종 변경 시각';

COMMENT ON COLUMN mqi.process_run.row_version IS '시스템 변경 버전; 원본 개정번호 아님';

COMMENT ON COLUMN mqi.process_run.record_state IS 'ACTIVE / VOID; VOID는 보존된 무효 기록, 참조 삭제 안 함';

CREATE TABLE mqi.process_run_result (
    process_run_result_id UUID DEFAULT gen_random_uuid() NOT NULL,
    process_run_id UUID NOT NULL,
    recorded_good_qty INTEGER,
    process_defect_qty INTEGER,
    gross_output_qty INTEGER,
    work_minutes INTEGER,
    raw_quantity_text TEXT,
    remark TEXT,
    recorded_at TIMESTAMPTZ DEFAULT clock_timestamp() NOT NULL,
    updated_at TIMESTAMPTZ DEFAULT clock_timestamp() NOT NULL,
    row_version BIGINT DEFAULT 1 NOT NULL,
    record_state VARCHAR(10) DEFAULT 'ACTIVE' NOT NULL,
    CONSTRAINT pk_process_run_result_ PRIMARY KEY (process_run_result_id),
    CONSTRAINT uq_process_run_result_process_run_id UNIQUE (process_run_id),
    CONSTRAINT ck_process_run_result_row_version_positive CHECK (row_version > 0),
    CONSTRAINT ck_process_run_result_record_state_code CHECK (record_state IN ('ACTIVE', 'VOID')),
    CONSTRAINT ck_process_run_result_recorded_good_qty_nonnegative CHECK (recorded_good_qty >= 0),
    CONSTRAINT ck_process_run_result_process_defect_qty_nonnegative CHECK (process_defect_qty >= 0),
    CONSTRAINT ck_process_run_result_gross_output_qty_nonnegative CHECK (gross_output_qty >= 0),
    CONSTRAINT ck_process_run_result_work_minutes_nonnegative CHECK (work_minutes >= 0)
);

COMMENT ON TABLE mqi.process_run_result IS '공정별 생산실적';

COMMENT ON COLUMN mqi.process_run_result.process_run_result_id IS 'PK';

COMMENT ON COLUMN mqi.process_run_result.process_run_id IS 'FK → process_run';

COMMENT ON COLUMN mqi.process_run_result.recorded_good_qty IS '원본 기준 공정 양품수량';

COMMENT ON COLUMN mqi.process_run_result.process_defect_qty IS '해당 공정의 확인된 불량수량';

COMMENT ON COLUMN mqi.process_run_result.gross_output_qty IS '별도로 확인된 총 산출수량';

COMMENT ON COLUMN mqi.process_run_result.work_minutes IS '확인된 실제 작업시간(분)';

COMMENT ON COLUMN mqi.process_run_result.raw_quantity_text IS '원본 수량 표현';

COMMENT ON COLUMN mqi.process_run_result.remark IS '비고';

COMMENT ON COLUMN mqi.process_run_result.recorded_at IS 'DB 최초 저장 시각; 실제 제조/관측 시각과 다름';

COMMENT ON COLUMN mqi.process_run_result.updated_at IS 'DB 최종 변경 시각';

COMMENT ON COLUMN mqi.process_run_result.row_version IS '시스템 변경 버전; 원본 개정번호 아님';

COMMENT ON COLUMN mqi.process_run_result.record_state IS 'ACTIVE / VOID; VOID는 보존된 무효 기록, 참조 삭제 안 함';

CREATE TABLE mqi.process_run_lot (
    process_run_lot_id UUID DEFAULT gen_random_uuid() NOT NULL,
    process_run_id UUID NOT NULL,
    production_lot_id UUID NOT NULL,
    lot_role VARCHAR(20) NOT NULL,
    recorded_quantity INTEGER,
    quantity_unit VARCHAR(20),
    raw_quantity_text TEXT,
    linkage_status VARCHAR(30) NOT NULL,
    evidence_note TEXT,
    model_id UUID NOT NULL,
    recorded_at TIMESTAMPTZ DEFAULT clock_timestamp() NOT NULL,
    updated_at TIMESTAMPTZ DEFAULT clock_timestamp() NOT NULL,
    row_version BIGINT DEFAULT 1 NOT NULL,
    record_state VARCHAR(10) DEFAULT 'ACTIVE' NOT NULL,
    CONSTRAINT pk_process_run_lot_ PRIMARY KEY (process_run_lot_id),
    CONSTRAINT ck_process_run_lot_row_version_positive CHECK (row_version > 0),
    CONSTRAINT ck_process_run_lot_record_state_code CHECK (record_state IN ('ACTIVE', 'VOID')),
    CONSTRAINT ck_process_run_lot_recorded_quantity_nonnegative CHECK (recorded_quantity >= 0),
    CONSTRAINT ck_process_run_lot_linkage_status_code CHECK (linkage_status IN ('CONFIRMED', 'CANDIDATE')),
    CONSTRAINT ck_process_run_lot_lot_role_code CHECK (lot_role IN ('INPUT', 'OUTPUT'))
);

COMMENT ON TABLE mqi.process_run_lot IS '공정별 LOT 연결';

COMMENT ON COLUMN mqi.process_run_lot.process_run_lot_id IS 'PK';

COMMENT ON COLUMN mqi.process_run_lot.process_run_id IS 'FK → process_run';

COMMENT ON COLUMN mqi.process_run_lot.production_lot_id IS 'FK → production_lot';

COMMENT ON COLUMN mqi.process_run_lot.lot_role IS 'INPUT / OUTPUT';

COMMENT ON COLUMN mqi.process_run_lot.recorded_quantity IS '원본에서 확인된 수량';

COMMENT ON COLUMN mqi.process_run_lot.quantity_unit IS '원본에서 확인된 수량단위';

COMMENT ON COLUMN mqi.process_run_lot.raw_quantity_text IS '원본 수량 표현';

COMMENT ON COLUMN mqi.process_run_lot.linkage_status IS 'CONFIRMED / CANDIDATE';

COMMENT ON COLUMN mqi.process_run_lot.evidence_note IS '연결 근거';

COMMENT ON COLUMN mqi.process_run_lot.model_id IS '상위 FK의 모델 식별자 복사; 서버 검증/자동 채움, 업무 추정 아님';

COMMENT ON COLUMN mqi.process_run_lot.recorded_at IS 'DB 최초 저장 시각; 실제 제조/관측 시각과 다름';

COMMENT ON COLUMN mqi.process_run_lot.updated_at IS 'DB 최종 변경 시각';

COMMENT ON COLUMN mqi.process_run_lot.row_version IS '시스템 변경 버전; 원본 개정번호 아님';

COMMENT ON COLUMN mqi.process_run_lot.record_state IS 'ACTIVE / VOID; VOID는 보존된 무효 기록, 참조 삭제 안 함';

CREATE TABLE mqi.equipment (
    equipment_id UUID DEFAULT gen_random_uuid() NOT NULL,
    equipment_code VARCHAR(100) NOT NULL,
    equipment_name VARCHAR(150),
    equipment_type VARCHAR(50) NOT NULL,
    line_id UUID,
    is_active BOOLEAN DEFAULT TRUE NOT NULL,
    remark TEXT,
    recorded_at TIMESTAMPTZ DEFAULT clock_timestamp() NOT NULL,
    updated_at TIMESTAMPTZ DEFAULT clock_timestamp() NOT NULL,
    row_version BIGINT DEFAULT 1 NOT NULL,
    record_state VARCHAR(10) DEFAULT 'ACTIVE' NOT NULL,
    CONSTRAINT pk_equipment_ PRIMARY KEY (equipment_id),
    CONSTRAINT uq_equipment_equipment_code UNIQUE (equipment_code),
    CONSTRAINT ck_equipment_row_version_positive CHECK (row_version > 0),
    CONSTRAINT ck_equipment_record_state_code CHECK (record_state IN ('ACTIVE', 'VOID')),
    CONSTRAINT ck_equipment_equipment_type_code CHECK (equipment_type IN ('INJECTION_MACHINE', 'TEMPERATURE_CONTROLLER', 'STITCHING_MACHINE', 'WINDING_MACHINE', 'ASSEMBLY_MACHINE', 'INSPECTION_EQUIPMENT', 'OTHER'))
);

COMMENT ON TABLE mqi.equipment IS '설비 마스터';

COMMENT ON COLUMN mqi.equipment.equipment_id IS 'PK';

COMMENT ON COLUMN mqi.equipment.equipment_code IS '설비 식별코드';

COMMENT ON COLUMN mqi.equipment.equipment_name IS '설비명';

COMMENT ON COLUMN mqi.equipment.equipment_type IS '설비 유형';

COMMENT ON COLUMN mqi.equipment.line_id IS '현재 기본 배치 생산라인 FK';

COMMENT ON COLUMN mqi.equipment.is_active IS '사용 여부';

COMMENT ON COLUMN mqi.equipment.remark IS '비고';

COMMENT ON COLUMN mqi.equipment.recorded_at IS 'DB 최초 저장 시각; 실제 제조/관측 시각과 다름';

COMMENT ON COLUMN mqi.equipment.updated_at IS 'DB 최종 변경 시각';

COMMENT ON COLUMN mqi.equipment.row_version IS '시스템 변경 버전; 원본 개정번호 아님';

COMMENT ON COLUMN mqi.equipment.record_state IS 'ACTIVE / VOID; VOID는 보존된 무효 기록, 참조 삭제 안 함';

CREATE TABLE mqi.equipment_position (
    position_id UUID DEFAULT gen_random_uuid() NOT NULL,
    equipment_id UUID NOT NULL,
    position_code VARCHAR(50) NOT NULL,
    position_type VARCHAR(30) NOT NULL,
    position_name VARCHAR(100),
    is_active BOOLEAN DEFAULT TRUE NOT NULL,
    remark TEXT,
    recorded_at TIMESTAMPTZ DEFAULT clock_timestamp() NOT NULL,
    updated_at TIMESTAMPTZ DEFAULT clock_timestamp() NOT NULL,
    row_version BIGINT DEFAULT 1 NOT NULL,
    record_state VARCHAR(10) DEFAULT 'ACTIVE' NOT NULL,
    CONSTRAINT pk_equipment_position_ PRIMARY KEY (position_id),
    CONSTRAINT uq_equipment_position_equipment_id_position_code UNIQUE (equipment_id, position_code),
    CONSTRAINT uq_equipment_position_position_id_equipment_id UNIQUE (position_id, equipment_id),
    CONSTRAINT ck_equipment_position_row_version_positive CHECK (row_version > 0),
    CONSTRAINT ck_equipment_position_record_state_code CHECK (record_state IN ('ACTIVE', 'VOID')),
    CONSTRAINT ck_equipment_position_position_type_code CHECK (position_type IN ('CHANNEL', 'AXIS', 'ZONE', 'CAVITY', 'OTHER'))
);

COMMENT ON TABLE mqi.equipment_position IS '설비의 축·채널·위치';

COMMENT ON COLUMN mqi.equipment_position.position_id IS 'PK';

COMMENT ON COLUMN mqi.equipment_position.equipment_id IS 'FK → equipment';

COMMENT ON COLUMN mqi.equipment_position.position_code IS '위치 식별코드';

COMMENT ON COLUMN mqi.equipment_position.position_type IS '위치 유형';

COMMENT ON COLUMN mqi.equipment_position.position_name IS '표시명';

COMMENT ON COLUMN mqi.equipment_position.is_active IS '사용 여부';

COMMENT ON COLUMN mqi.equipment_position.remark IS '비고';

COMMENT ON COLUMN mqi.equipment_position.recorded_at IS 'DB 최초 저장 시각; 실제 제조/관측 시각과 다름';

COMMENT ON COLUMN mqi.equipment_position.updated_at IS 'DB 최종 변경 시각';

COMMENT ON COLUMN mqi.equipment_position.row_version IS '시스템 변경 버전; 원본 개정번호 아님';

COMMENT ON COLUMN mqi.equipment_position.record_state IS 'ACTIVE / VOID; VOID는 보존된 무효 기록, 참조 삭제 안 함';

CREATE TABLE mqi.equipment_connection (
    equipment_connection_id UUID DEFAULT gen_random_uuid() NOT NULL,
    host_equipment_id UUID NOT NULL,
    connected_equipment_id UUID NOT NULL,
    connection_type VARCHAR(50) NOT NULL,
    effective_from TIMESTAMPTZ,
    effective_to TIMESTAMPTZ,
    verification_status VARCHAR(30) NOT NULL,
    remark TEXT,
    recorded_at TIMESTAMPTZ DEFAULT clock_timestamp() NOT NULL,
    updated_at TIMESTAMPTZ DEFAULT clock_timestamp() NOT NULL,
    row_version BIGINT DEFAULT 1 NOT NULL,
    record_state VARCHAR(10) DEFAULT 'ACTIVE' NOT NULL,
    CONSTRAINT pk_equipment_connection_ PRIMARY KEY (equipment_connection_id),
    CONSTRAINT ck_equipment_connection_row_version_positive CHECK (row_version > 0),
    CONSTRAINT ck_equipment_connection_record_state_code CHECK (record_state IN ('ACTIVE', 'VOID')),
    CONSTRAINT ck_equipment_connection_verification_status_code CHECK (verification_status IN ('UNVERIFIED', 'CONFIRMED', 'NEEDS_REVIEW', 'REJECTED')),
    CONSTRAINT ck_equipment_connection_effective_to_order CHECK (effective_to >= effective_from),
    CONSTRAINT ck_equipment_connection_no_self_reference CHECK (host_equipment_id <> connected_equipment_id)
);

COMMENT ON TABLE mqi.equipment_connection IS '설비 간 연결관계';

COMMENT ON COLUMN mqi.equipment_connection.equipment_connection_id IS 'PK';

COMMENT ON COLUMN mqi.equipment_connection.host_equipment_id IS '주설비 FK';

COMMENT ON COLUMN mqi.equipment_connection.connected_equipment_id IS '연결 설비 FK';

COMMENT ON COLUMN mqi.equipment_connection.connection_type IS '연결 유형';

COMMENT ON COLUMN mqi.equipment_connection.effective_from IS '연결 시작시각';

COMMENT ON COLUMN mqi.equipment_connection.effective_to IS '연결 종료시각';

COMMENT ON COLUMN mqi.equipment_connection.verification_status IS '연결정보 검증상태';

COMMENT ON COLUMN mqi.equipment_connection.remark IS '비고';

COMMENT ON COLUMN mqi.equipment_connection.recorded_at IS 'DB 최초 저장 시각; 실제 제조/관측 시각과 다름';

COMMENT ON COLUMN mqi.equipment_connection.updated_at IS 'DB 최종 변경 시각';

COMMENT ON COLUMN mqi.equipment_connection.row_version IS '시스템 변경 버전; 원본 개정번호 아님';

COMMENT ON COLUMN mqi.equipment_connection.record_state IS 'ACTIVE / VOID; VOID는 보존된 무효 기록, 참조 삭제 안 함';

CREATE TABLE mqi.process_equipment_usage (
    equipment_usage_id UUID DEFAULT gen_random_uuid() NOT NULL,
    process_run_id UUID NOT NULL,
    equipment_id UUID NOT NULL,
    equipment_role VARCHAR(30) NOT NULL,
    usage_start_at TIMESTAMPTZ,
    usage_end_at TIMESTAMPTZ,
    linkage_status VARCHAR(30) NOT NULL,
    remark TEXT,
    recorded_at TIMESTAMPTZ DEFAULT clock_timestamp() NOT NULL,
    updated_at TIMESTAMPTZ DEFAULT clock_timestamp() NOT NULL,
    row_version BIGINT DEFAULT 1 NOT NULL,
    record_state VARCHAR(10) DEFAULT 'ACTIVE' NOT NULL,
    CONSTRAINT pk_process_equipment_usage_ PRIMARY KEY (equipment_usage_id),
    CONSTRAINT ck_process_equipment_usage_row_version_positive CHECK (row_version > 0),
    CONSTRAINT ck_process_equipment_usage_record_state_code CHECK (record_state IN ('ACTIVE', 'VOID')),
    CONSTRAINT ck_process_equipment_usage_linkage_status_code CHECK (linkage_status IN ('CONFIRMED', 'CANDIDATE')),
    CONSTRAINT ck_process_equipment_usage_usage_end_at_order CHECK (usage_end_at > usage_start_at),
    CONSTRAINT ck_process_equipment_usage_equipment_role_code CHECK (equipment_role IN ('PRIMARY', 'AUXILIARY', 'CONTROLLER', 'OTHER'))
);

COMMENT ON TABLE mqi.process_equipment_usage IS '공정별 설비 사용이력';

COMMENT ON COLUMN mqi.process_equipment_usage.equipment_usage_id IS 'PK';

COMMENT ON COLUMN mqi.process_equipment_usage.process_run_id IS 'FK → process_run';

COMMENT ON COLUMN mqi.process_equipment_usage.equipment_id IS 'FK → equipment';

COMMENT ON COLUMN mqi.process_equipment_usage.equipment_role IS '설비의 역할';

COMMENT ON COLUMN mqi.process_equipment_usage.usage_start_at IS '사용 시작시각';

COMMENT ON COLUMN mqi.process_equipment_usage.usage_end_at IS '사용 종료시각';

COMMENT ON COLUMN mqi.process_equipment_usage.linkage_status IS '연결 검증상태';

COMMENT ON COLUMN mqi.process_equipment_usage.remark IS '비고';

COMMENT ON COLUMN mqi.process_equipment_usage.recorded_at IS 'DB 최초 저장 시각; 실제 제조/관측 시각과 다름';

COMMENT ON COLUMN mqi.process_equipment_usage.updated_at IS 'DB 최종 변경 시각';

COMMENT ON COLUMN mqi.process_equipment_usage.row_version IS '시스템 변경 버전; 원본 개정번호 아님';

COMMENT ON COLUMN mqi.process_equipment_usage.record_state IS 'ACTIVE / VOID; VOID는 보존된 무효 기록, 참조 삭제 안 함';

CREATE TABLE mqi.parameter_definition (
    parameter_id UUID DEFAULT gen_random_uuid() NOT NULL,
    process_id UUID,
    parameter_code VARCHAR(100) NOT NULL,
    parameter_name VARCHAR(150) NOT NULL,
    value_kind VARCHAR(20) NOT NULL,
    unit VARCHAR(30),
    position_scope VARCHAR(20) NOT NULL,
    is_active BOOLEAN DEFAULT TRUE NOT NULL,
    description TEXT,
    recorded_at TIMESTAMPTZ DEFAULT clock_timestamp() NOT NULL,
    updated_at TIMESTAMPTZ DEFAULT clock_timestamp() NOT NULL,
    row_version BIGINT DEFAULT 1 NOT NULL,
    record_state VARCHAR(10) DEFAULT 'ACTIVE' NOT NULL,
    CONSTRAINT pk_parameter_definition_ PRIMARY KEY (parameter_id),
    CONSTRAINT ck_parameter_definition_row_version_positive CHECK (row_version > 0),
    CONSTRAINT ck_parameter_definition_record_state_code CHECK (record_state IN ('ACTIVE', 'VOID')),
    CONSTRAINT ck_parameter_definition_value_kind_code CHECK (value_kind IN ('NUMBER', 'CODE', 'TEXT')),
    CONSTRAINT ck_parameter_definition_position_scope_code CHECK (position_scope IN ('EQUIPMENT', 'POSITION', 'BOTH'))
);

COMMENT ON TABLE mqi.parameter_definition IS '작업조건 항목 정의';

COMMENT ON COLUMN mqi.parameter_definition.parameter_id IS 'PK';

COMMENT ON COLUMN mqi.parameter_definition.process_id IS '적용 공정 FK';

COMMENT ON COLUMN mqi.parameter_definition.parameter_code IS '항목 코드';

COMMENT ON COLUMN mqi.parameter_definition.parameter_name IS '항목명';

COMMENT ON COLUMN mqi.parameter_definition.value_kind IS '값의 유형';

COMMENT ON COLUMN mqi.parameter_definition.unit IS '측정 단위';

COMMENT ON COLUMN mqi.parameter_definition.position_scope IS '위치 적용 범위';

COMMENT ON COLUMN mqi.parameter_definition.is_active IS '사용 여부';

COMMENT ON COLUMN mqi.parameter_definition.description IS '항목 설명';

COMMENT ON COLUMN mqi.parameter_definition.recorded_at IS 'DB 최초 저장 시각; 실제 제조/관측 시각과 다름';

COMMENT ON COLUMN mqi.parameter_definition.updated_at IS 'DB 최종 변경 시각';

COMMENT ON COLUMN mqi.parameter_definition.row_version IS '시스템 변경 버전; 원본 개정번호 아님';

COMMENT ON COLUMN mqi.parameter_definition.record_state IS 'ACTIVE / VOID; VOID는 보존된 무효 기록, 참조 삭제 안 함';

CREATE TABLE mqi.process_setup_spec (
    spec_id UUID DEFAULT gen_random_uuid() NOT NULL,
    model_id UUID NOT NULL,
    process_id UUID NOT NULL,
    equipment_id UUID,
    spec_revision VARCHAR(50),
    effective_from DATE,
    effective_to DATE,
    verification_status VARCHAR(30) NOT NULL,
    remark TEXT,
    recorded_at TIMESTAMPTZ DEFAULT clock_timestamp() NOT NULL,
    updated_at TIMESTAMPTZ DEFAULT clock_timestamp() NOT NULL,
    row_version BIGINT DEFAULT 1 NOT NULL,
    record_state VARCHAR(10) DEFAULT 'ACTIVE' NOT NULL,
    CONSTRAINT pk_process_setup_spec_ PRIMARY KEY (spec_id),
    CONSTRAINT ck_process_setup_spec_row_version_positive CHECK (row_version > 0),
    CONSTRAINT ck_process_setup_spec_record_state_code CHECK (record_state IN ('ACTIVE', 'VOID')),
    CONSTRAINT ck_process_setup_spec_verification_status_code CHECK (verification_status IN ('UNVERIFIED', 'CONFIRMED', 'NEEDS_REVIEW', 'REJECTED')),
    CONSTRAINT ck_process_setup_spec_effective_to_order CHECK (effective_to >= effective_from)
);

COMMENT ON TABLE mqi.process_setup_spec IS '모델별 표준 작업조건 버전';

COMMENT ON COLUMN mqi.process_setup_spec.spec_id IS 'PK';

COMMENT ON COLUMN mqi.process_setup_spec.model_id IS 'FK → product_model';

COMMENT ON COLUMN mqi.process_setup_spec.process_id IS 'FK → process';

COMMENT ON COLUMN mqi.process_setup_spec.equipment_id IS '특정 설비 전용 기준인 경우 FK';

COMMENT ON COLUMN mqi.process_setup_spec.spec_revision IS '기준 개정번호';

COMMENT ON COLUMN mqi.process_setup_spec.effective_from IS '적용 시작일';

COMMENT ON COLUMN mqi.process_setup_spec.effective_to IS '적용 종료일';

COMMENT ON COLUMN mqi.process_setup_spec.verification_status IS '기준 검증상태';

COMMENT ON COLUMN mqi.process_setup_spec.remark IS '비고';

COMMENT ON COLUMN mqi.process_setup_spec.recorded_at IS 'DB 최초 저장 시각; 실제 제조/관측 시각과 다름';

COMMENT ON COLUMN mqi.process_setup_spec.updated_at IS 'DB 최종 변경 시각';

COMMENT ON COLUMN mqi.process_setup_spec.row_version IS '시스템 변경 버전; 원본 개정번호 아님';

COMMENT ON COLUMN mqi.process_setup_spec.record_state IS 'ACTIVE / VOID; VOID는 보존된 무효 기록, 참조 삭제 안 함';

CREATE TABLE mqi.process_setup_spec_item (
    spec_item_id UUID DEFAULT gen_random_uuid() NOT NULL,
    spec_id UUID NOT NULL,
    parameter_id UUID NOT NULL,
    position_id UUID,
    target_numeric NUMERIC,
    target_text TEXT,
    min_numeric NUMERIC,
    max_numeric NUMERIC,
    remark TEXT,
    recorded_at TIMESTAMPTZ DEFAULT clock_timestamp() NOT NULL,
    updated_at TIMESTAMPTZ DEFAULT clock_timestamp() NOT NULL,
    row_version BIGINT DEFAULT 1 NOT NULL,
    record_state VARCHAR(10) DEFAULT 'ACTIVE' NOT NULL,
    CONSTRAINT pk_process_setup_spec_item_ PRIMARY KEY (spec_item_id),
    CONSTRAINT ck_process_setup_spec_item_row_version_positive CHECK (row_version > 0),
    CONSTRAINT ck_process_setup_spec_item_record_state_code CHECK (record_state IN ('ACTIVE', 'VOID')),
    CONSTRAINT ck_process_setup_spec_item_target_numeric_finite CHECK (target_numeric NOT IN ('NaN'::numeric, 'Infinity'::numeric, '-Infinity'::numeric)),
    CONSTRAINT ck_process_setup_spec_item_min_numeric_finite CHECK (min_numeric NOT IN ('NaN'::numeric, 'Infinity'::numeric, '-Infinity'::numeric)),
    CONSTRAINT ck_process_setup_spec_item_max_numeric_finite CHECK (max_numeric NOT IN ('NaN'::numeric, 'Infinity'::numeric, '-Infinity'::numeric)),
    CONSTRAINT ck_process_setup_spec_item_range_order CHECK (max_numeric >= min_numeric),
    CONSTRAINT ck_process_setup_spec_item_one_value_type CHECK (num_nonnulls(target_numeric,target_text) <= 1)
);

COMMENT ON TABLE mqi.process_setup_spec_item IS '기준조건 세부항목';

COMMENT ON COLUMN mqi.process_setup_spec_item.spec_item_id IS 'PK';

COMMENT ON COLUMN mqi.process_setup_spec_item.spec_id IS 'FK → process_setup_spec';

COMMENT ON COLUMN mqi.process_setup_spec_item.parameter_id IS 'FK → parameter_definition';

COMMENT ON COLUMN mqi.process_setup_spec_item.position_id IS '특정 설비 위치에 적용 시 FK';

COMMENT ON COLUMN mqi.process_setup_spec_item.target_numeric IS '수치형 기준값';

COMMENT ON COLUMN mqi.process_setup_spec_item.target_text IS '코드 또는 문자 기준값';

COMMENT ON COLUMN mqi.process_setup_spec_item.min_numeric IS '하한값';

COMMENT ON COLUMN mqi.process_setup_spec_item.max_numeric IS '상한값';

COMMENT ON COLUMN mqi.process_setup_spec_item.remark IS '비고';

COMMENT ON COLUMN mqi.process_setup_spec_item.recorded_at IS 'DB 최초 저장 시각; 실제 제조/관측 시각과 다름';

COMMENT ON COLUMN mqi.process_setup_spec_item.updated_at IS 'DB 최종 변경 시각';

COMMENT ON COLUMN mqi.process_setup_spec_item.row_version IS '시스템 변경 버전; 원본 개정번호 아님';

COMMENT ON COLUMN mqi.process_setup_spec_item.record_state IS 'ACTIVE / VOID; VOID는 보존된 무효 기록, 참조 삭제 안 함';

CREATE TABLE mqi.parameter_observation (
    observation_id UUID DEFAULT gen_random_uuid() NOT NULL,
    process_run_id UUID,
    equipment_id UUID NOT NULL,
    position_id UUID,
    parameter_id UUID NOT NULL,
    observed_at TIMESTAMPTZ,
    value_numeric NUMERIC,
    value_text TEXT,
    raw_value_text TEXT,
    observation_method VARCHAR(30),
    validation_status VARCHAR(30) NOT NULL,
    remark TEXT,
    recorded_at TIMESTAMPTZ DEFAULT clock_timestamp() NOT NULL,
    updated_at TIMESTAMPTZ DEFAULT clock_timestamp() NOT NULL,
    row_version BIGINT DEFAULT 1 NOT NULL,
    record_state VARCHAR(10) DEFAULT 'ACTIVE' NOT NULL,
    CONSTRAINT pk_parameter_observation_ PRIMARY KEY (observation_id),
    CONSTRAINT ck_parameter_observation_row_version_positive CHECK (row_version > 0),
    CONSTRAINT ck_parameter_observation_record_state_code CHECK (record_state IN ('ACTIVE', 'VOID')),
    CONSTRAINT ck_parameter_observation_value_numeric_finite CHECK (value_numeric NOT IN ('NaN'::numeric, 'Infinity'::numeric, '-Infinity'::numeric)),
    CONSTRAINT ck_parameter_observation_validation_status_code CHECK (validation_status IN ('UNVERIFIED', 'VERIFIED', 'NEEDS_REVIEW', 'REJECTED', 'CONFIRMED_TYPO')),
    CONSTRAINT ck_parameter_observation_observation_method_code CHECK (observation_method IN ('HMI_DISPLAY', 'EQUIPMENT_PHOTO', 'WORK_JOURNAL', 'MANUAL_MEASUREMENT', 'OTHER')),
    CONSTRAINT ck_parameter_observation_one_value_type CHECK (num_nonnulls(value_numeric,value_text) <= 1)
);

COMMENT ON TABLE mqi.parameter_observation IS '실제 작업조건 관측값';

COMMENT ON COLUMN mqi.parameter_observation.observation_id IS 'PK';

COMMENT ON COLUMN mqi.parameter_observation.process_run_id IS '연결된 공정 실행 FK';

COMMENT ON COLUMN mqi.parameter_observation.equipment_id IS '관측 대상 설비 FK';

COMMENT ON COLUMN mqi.parameter_observation.position_id IS '설비의 채널·축·위치 FK';

COMMENT ON COLUMN mqi.parameter_observation.parameter_id IS '작업조건 항목 FK';

COMMENT ON COLUMN mqi.parameter_observation.observed_at IS '실제 관측시각';

COMMENT ON COLUMN mqi.parameter_observation.value_numeric IS '수치형 관측값';

COMMENT ON COLUMN mqi.parameter_observation.value_text IS '코드·문자형 관측값';

COMMENT ON COLUMN mqi.parameter_observation.raw_value_text IS '원본 기재값';

COMMENT ON COLUMN mqi.parameter_observation.observation_method IS '관측 방법';

COMMENT ON COLUMN mqi.parameter_observation.validation_status IS '검증상태';

COMMENT ON COLUMN mqi.parameter_observation.remark IS '비고';

COMMENT ON COLUMN mqi.parameter_observation.recorded_at IS 'DB 최초 저장 시각; 실제 제조/관측 시각과 다름';

COMMENT ON COLUMN mqi.parameter_observation.updated_at IS 'DB 최종 변경 시각';

COMMENT ON COLUMN mqi.parameter_observation.row_version IS '시스템 변경 버전; 원본 개정번호 아님';

COMMENT ON COLUMN mqi.parameter_observation.record_state IS 'ACTIVE / VOID; VOID는 보존된 무효 기록, 참조 삭제 안 함';

CREATE TABLE mqi.material (
    material_id UUID DEFAULT gen_random_uuid() NOT NULL,
    material_code VARCHAR(100),
    material_name VARCHAR(150) NOT NULL,
    material_category VARCHAR(50),
    specification TEXT,
    default_unit VARCHAR(20),
    is_active BOOLEAN DEFAULT TRUE NOT NULL,
    remark TEXT,
    recorded_at TIMESTAMPTZ DEFAULT clock_timestamp() NOT NULL,
    updated_at TIMESTAMPTZ DEFAULT clock_timestamp() NOT NULL,
    row_version BIGINT DEFAULT 1 NOT NULL,
    record_state VARCHAR(10) DEFAULT 'ACTIVE' NOT NULL,
    CONSTRAINT pk_material_ PRIMARY KEY (material_id),
    CONSTRAINT uq_material_material_code UNIQUE (material_code),
    CONSTRAINT ck_material_row_version_positive CHECK (row_version > 0),
    CONSTRAINT ck_material_record_state_code CHECK (record_state IN ('ACTIVE', 'VOID'))
);

COMMENT ON TABLE mqi.material IS '원자재 품목';

COMMENT ON COLUMN mqi.material.material_id IS 'PK';

COMMENT ON COLUMN mqi.material.material_code IS '원자재 품목코드';

COMMENT ON COLUMN mqi.material.material_name IS '원자재 품목명';

COMMENT ON COLUMN mqi.material.material_category IS '원자재 분류';

COMMENT ON COLUMN mqi.material.specification IS '규격';

COMMENT ON COLUMN mqi.material.default_unit IS '기본 수량단위';

COMMENT ON COLUMN mqi.material.is_active IS '사용 여부';

COMMENT ON COLUMN mqi.material.remark IS '비고';

COMMENT ON COLUMN mqi.material.recorded_at IS 'DB 최초 저장 시각; 실제 제조/관측 시각과 다름';

COMMENT ON COLUMN mqi.material.updated_at IS 'DB 최종 변경 시각';

COMMENT ON COLUMN mqi.material.row_version IS '시스템 변경 버전; 원본 개정번호 아님';

COMMENT ON COLUMN mqi.material.record_state IS 'ACTIVE / VOID; VOID는 보존된 무효 기록, 참조 삭제 안 함';

CREATE TABLE mqi.material_lot (
    material_lot_id UUID DEFAULT gen_random_uuid() NOT NULL,
    material_id UUID NOT NULL,
    supplier_lot_code VARCHAR(100),
    internal_lot_code VARCHAR(100),
    received_date DATE,
    manufactured_date DATE,
    verification_status VARCHAR(30) NOT NULL,
    remark TEXT,
    recorded_at TIMESTAMPTZ DEFAULT clock_timestamp() NOT NULL,
    updated_at TIMESTAMPTZ DEFAULT clock_timestamp() NOT NULL,
    row_version BIGINT DEFAULT 1 NOT NULL,
    record_state VARCHAR(10) DEFAULT 'ACTIVE' NOT NULL,
    CONSTRAINT pk_material_lot_ PRIMARY KEY (material_lot_id),
    CONSTRAINT uq_material_lot_material_lot_id_material_id UNIQUE (material_lot_id, material_id),
    CONSTRAINT ck_material_lot_row_version_positive CHECK (row_version > 0),
    CONSTRAINT ck_material_lot_record_state_code CHECK (record_state IN ('ACTIVE', 'VOID')),
    CONSTRAINT ck_material_lot_verification_status_code CHECK (verification_status IN ('UNVERIFIED', 'CONFIRMED', 'NEEDS_REVIEW', 'REJECTED'))
);

COMMENT ON TABLE mqi.material_lot IS '원자재 LOT';

COMMENT ON COLUMN mqi.material_lot.material_lot_id IS 'PK';

COMMENT ON COLUMN mqi.material_lot.material_id IS 'FK → material';

COMMENT ON COLUMN mqi.material_lot.supplier_lot_code IS '공급업체 LOT 코드';

COMMENT ON COLUMN mqi.material_lot.internal_lot_code IS '사내 LOT 관리코드';

COMMENT ON COLUMN mqi.material_lot.received_date IS '입고일';

COMMENT ON COLUMN mqi.material_lot.manufactured_date IS '원자재 제조일';

COMMENT ON COLUMN mqi.material_lot.verification_status IS 'LOT 검증상태';

COMMENT ON COLUMN mqi.material_lot.remark IS '비고';

COMMENT ON COLUMN mqi.material_lot.recorded_at IS 'DB 최초 저장 시각; 실제 제조/관측 시각과 다름';

COMMENT ON COLUMN mqi.material_lot.updated_at IS 'DB 최종 변경 시각';

COMMENT ON COLUMN mqi.material_lot.row_version IS '시스템 변경 버전; 원본 개정번호 아님';

COMMENT ON COLUMN mqi.material_lot.record_state IS 'ACTIVE / VOID; VOID는 보존된 무효 기록, 참조 삭제 안 함';

CREATE TABLE mqi.material_usage (
    material_usage_id UUID DEFAULT gen_random_uuid() NOT NULL,
    process_run_id UUID NOT NULL,
    material_id UUID NOT NULL,
    material_lot_id UUID,
    recorded_lot_code_raw VARCHAR(100),
    used_quantity NUMERIC,
    quantity_unit VARCHAR(20),
    usage_role VARCHAR(30),
    linkage_status VARCHAR(30) NOT NULL,
    remark TEXT,
    recorded_at TIMESTAMPTZ DEFAULT clock_timestamp() NOT NULL,
    updated_at TIMESTAMPTZ DEFAULT clock_timestamp() NOT NULL,
    row_version BIGINT DEFAULT 1 NOT NULL,
    record_state VARCHAR(10) DEFAULT 'ACTIVE' NOT NULL,
    CONSTRAINT pk_material_usage_ PRIMARY KEY (material_usage_id),
    CONSTRAINT ck_material_usage_row_version_positive CHECK (row_version > 0),
    CONSTRAINT ck_material_usage_record_state_code CHECK (record_state IN ('ACTIVE', 'VOID')),
    CONSTRAINT ck_material_usage_used_quantity_finite CHECK (used_quantity NOT IN ('NaN'::numeric, 'Infinity'::numeric, '-Infinity'::numeric)),
    CONSTRAINT ck_material_usage_used_quantity_nonnegative CHECK (used_quantity >= 0),
    CONSTRAINT ck_material_usage_linkage_status_code CHECK (linkage_status IN ('CONFIRMED', 'CANDIDATE'))
);

COMMENT ON TABLE mqi.material_usage IS '공정별 원자재 사용이력';

COMMENT ON COLUMN mqi.material_usage.material_usage_id IS 'PK';

COMMENT ON COLUMN mqi.material_usage.process_run_id IS 'FK → process_run';

COMMENT ON COLUMN mqi.material_usage.material_id IS 'FK → material';

COMMENT ON COLUMN mqi.material_usage.material_lot_id IS 'FK → material_lot';

COMMENT ON COLUMN mqi.material_usage.recorded_lot_code_raw IS '원본에 기록된 LOT 코드';

COMMENT ON COLUMN mqi.material_usage.used_quantity IS '확인된 사용수량';

COMMENT ON COLUMN mqi.material_usage.quantity_unit IS '사용수량의 단위';

COMMENT ON COLUMN mqi.material_usage.usage_role IS '원자재 사용 역할';

COMMENT ON COLUMN mqi.material_usage.linkage_status IS '사용관계 검증상태';

COMMENT ON COLUMN mqi.material_usage.remark IS '비고';

COMMENT ON COLUMN mqi.material_usage.recorded_at IS 'DB 최초 저장 시각; 실제 제조/관측 시각과 다름';

COMMENT ON COLUMN mqi.material_usage.updated_at IS 'DB 최종 변경 시각';

COMMENT ON COLUMN mqi.material_usage.row_version IS '시스템 변경 버전; 원본 개정번호 아님';

COMMENT ON COLUMN mqi.material_usage.record_state IS 'ACTIVE / VOID; VOID는 보존된 무효 기록, 참조 삭제 안 함';

CREATE TABLE mqi.worker (
    worker_id UUID DEFAULT gen_random_uuid() NOT NULL,
    worker_code VARCHAR(100),
    worker_display_name VARCHAR(100),
    is_active BOOLEAN DEFAULT TRUE NOT NULL,
    remark TEXT,
    recorded_at TIMESTAMPTZ DEFAULT clock_timestamp() NOT NULL,
    updated_at TIMESTAMPTZ DEFAULT clock_timestamp() NOT NULL,
    row_version BIGINT DEFAULT 1 NOT NULL,
    record_state VARCHAR(10) DEFAULT 'ACTIVE' NOT NULL,
    CONSTRAINT pk_worker_ PRIMARY KEY (worker_id),
    CONSTRAINT uq_worker_worker_code UNIQUE (worker_code),
    CONSTRAINT ck_worker_row_version_positive CHECK (row_version > 0),
    CONSTRAINT ck_worker_record_state_code CHECK (record_state IN ('ACTIVE', 'VOID'))
);

COMMENT ON TABLE mqi.worker IS '작업자 마스터';

COMMENT ON COLUMN mqi.worker.worker_id IS 'PK';

COMMENT ON COLUMN mqi.worker.worker_code IS '사내 작업자 식별코드';

COMMENT ON COLUMN mqi.worker.worker_display_name IS '업무상 필요한 표시명';

COMMENT ON COLUMN mqi.worker.is_active IS '사용 여부';

COMMENT ON COLUMN mqi.worker.remark IS '비고';

COMMENT ON COLUMN mqi.worker.recorded_at IS 'DB 최초 저장 시각; 실제 제조/관측 시각과 다름';

COMMENT ON COLUMN mqi.worker.updated_at IS 'DB 최종 변경 시각';

COMMENT ON COLUMN mqi.worker.row_version IS '시스템 변경 버전; 원본 개정번호 아님';

COMMENT ON COLUMN mqi.worker.record_state IS 'ACTIVE / VOID; VOID는 보존된 무효 기록, 참조 삭제 안 함';

CREATE TABLE mqi.worker_assignment (
    assignment_id UUID DEFAULT gen_random_uuid() NOT NULL,
    worker_id UUID NOT NULL,
    production_run_id UUID,
    process_run_id UUID,
    worker_role VARCHAR(50),
    assigned_from TIMESTAMPTZ,
    assigned_to TIMESTAMPTZ,
    linkage_status VARCHAR(30) NOT NULL,
    remark TEXT,
    recorded_at TIMESTAMPTZ DEFAULT clock_timestamp() NOT NULL,
    updated_at TIMESTAMPTZ DEFAULT clock_timestamp() NOT NULL,
    row_version BIGINT DEFAULT 1 NOT NULL,
    record_state VARCHAR(10) DEFAULT 'ACTIVE' NOT NULL,
    CONSTRAINT pk_worker_assignment_ PRIMARY KEY (assignment_id),
    CONSTRAINT ck_worker_assignment_row_version_positive CHECK (row_version > 0),
    CONSTRAINT ck_worker_assignment_record_state_code CHECK (record_state IN ('ACTIVE', 'VOID')),
    CONSTRAINT ck_worker_assignment_linkage_status_code CHECK (linkage_status IN ('CONFIRMED', 'CANDIDATE')),
    CONSTRAINT ck_worker_assignment_assigned_to_order CHECK (assigned_to > assigned_from),
    CONSTRAINT ck_worker_assignment_worker_role_code CHECK (worker_role IN ('OPERATOR', 'SETUP', 'SUPERVISOR', 'QUALITY_CHECKER', 'OTHER')),
    CONSTRAINT ck_worker_assignment_exactly_one_target CHECK (num_nonnulls(production_run_id, process_run_id) = 1)
);

COMMENT ON TABLE mqi.worker_assignment IS '작업자 배정이력';

COMMENT ON COLUMN mqi.worker_assignment.assignment_id IS 'PK';

COMMENT ON COLUMN mqi.worker_assignment.worker_id IS 'FK → worker';

COMMENT ON COLUMN mqi.worker_assignment.production_run_id IS 'FK → production_run';

COMMENT ON COLUMN mqi.worker_assignment.process_run_id IS 'FK → process_run';

COMMENT ON COLUMN mqi.worker_assignment.worker_role IS '작업자의 역할';

COMMENT ON COLUMN mqi.worker_assignment.assigned_from IS '배정 시작시각';

COMMENT ON COLUMN mqi.worker_assignment.assigned_to IS '배정 종료시각';

COMMENT ON COLUMN mqi.worker_assignment.linkage_status IS '배정관계 검증상태';

COMMENT ON COLUMN mqi.worker_assignment.remark IS '비고';

COMMENT ON COLUMN mqi.worker_assignment.recorded_at IS 'DB 최초 저장 시각; 실제 제조/관측 시각과 다름';

COMMENT ON COLUMN mqi.worker_assignment.updated_at IS 'DB 최종 변경 시각';

COMMENT ON COLUMN mqi.worker_assignment.row_version IS '시스템 변경 버전; 원본 개정번호 아님';

COMMENT ON COLUMN mqi.worker_assignment.record_state IS 'ACTIVE / VOID; VOID는 보존된 무효 기록, 참조 삭제 안 함';

CREATE TABLE mqi.production_event (
    event_id UUID DEFAULT gen_random_uuid() NOT NULL,
    production_run_id UUID,
    process_run_id UUID,
    equipment_id UUID,
    event_type VARCHAR(50) NOT NULL,
    event_date DATE,
    event_start_at TIMESTAMPTZ,
    event_end_at TIMESTAMPTZ,
    duration_minutes INTEGER,
    event_description TEXT,
    validation_status VARCHAR(30) NOT NULL,
    remark TEXT,
    recorded_at TIMESTAMPTZ DEFAULT clock_timestamp() NOT NULL,
    updated_at TIMESTAMPTZ DEFAULT clock_timestamp() NOT NULL,
    row_version BIGINT DEFAULT 1 NOT NULL,
    record_state VARCHAR(10) DEFAULT 'ACTIVE' NOT NULL,
    CONSTRAINT pk_production_event_ PRIMARY KEY (event_id),
    CONSTRAINT ck_production_event_row_version_positive CHECK (row_version > 0),
    CONSTRAINT ck_production_event_record_state_code CHECK (record_state IN ('ACTIVE', 'VOID')),
    CONSTRAINT ck_production_event_duration_minutes_nonnegative CHECK (duration_minutes >= 0),
    CONSTRAINT ck_production_event_validation_status_code CHECK (validation_status IN ('UNVERIFIED', 'VERIFIED', 'NEEDS_REVIEW', 'REJECTED')),
    CONSTRAINT ck_production_event_event_end_at_order CHECK (event_end_at > event_start_at),
    CONSTRAINT ck_production_event_event_type_code CHECK (event_type IN ('STOP', 'RESTART', 'SETUP_CHANGE', 'MAINTENANCE', 'MATERIAL_CHANGE', 'OTHER')),
    CONSTRAINT ck_production_event_exactly_one_target CHECK (num_nonnulls(production_run_id, process_run_id) = 1)
);

COMMENT ON TABLE mqi.production_event IS '생산공정 이벤트';

COMMENT ON COLUMN mqi.production_event.event_id IS 'PK';

COMMENT ON COLUMN mqi.production_event.production_run_id IS 'FK → production_run';

COMMENT ON COLUMN mqi.production_event.process_run_id IS 'FK → process_run';

COMMENT ON COLUMN mqi.production_event.equipment_id IS '관련 설비 FK';

COMMENT ON COLUMN mqi.production_event.event_type IS '이벤트 유형';

COMMENT ON COLUMN mqi.production_event.event_date IS '확인된 이벤트 발생일';

COMMENT ON COLUMN mqi.production_event.event_start_at IS '이벤트 시작시각';

COMMENT ON COLUMN mqi.production_event.event_end_at IS '이벤트 종료시각';

COMMENT ON COLUMN mqi.production_event.duration_minutes IS '원본에서 확인된 지속시간';

COMMENT ON COLUMN mqi.production_event.event_description IS '원본 이벤트 내용';

COMMENT ON COLUMN mqi.production_event.validation_status IS '검증상태';

COMMENT ON COLUMN mqi.production_event.remark IS '비고';

COMMENT ON COLUMN mqi.production_event.recorded_at IS 'DB 최초 저장 시각; 실제 제조/관측 시각과 다름';

COMMENT ON COLUMN mqi.production_event.updated_at IS 'DB 최종 변경 시각';

COMMENT ON COLUMN mqi.production_event.row_version IS '시스템 변경 버전; 원본 개정번호 아님';

COMMENT ON COLUMN mqi.production_event.record_state IS 'ACTIVE / VOID; VOID는 보존된 무효 기록, 참조 삭제 안 함';

CREATE TABLE mqi.quality_check (
    quality_check_id UUID DEFAULT gen_random_uuid() NOT NULL,
    model_id UUID NOT NULL,
    process_run_id UUID,
    checker_id UUID,
    check_date DATE,
    checked_at TIMESTAMPTZ,
    check_type VARCHAR(50) NOT NULL,
    sample_reference VARCHAR(100),
    check_sequence INTEGER,
    validation_status VARCHAR(30) NOT NULL,
    remark TEXT,
    recorded_at TIMESTAMPTZ DEFAULT clock_timestamp() NOT NULL,
    updated_at TIMESTAMPTZ DEFAULT clock_timestamp() NOT NULL,
    row_version BIGINT DEFAULT 1 NOT NULL,
    record_state VARCHAR(10) DEFAULT 'ACTIVE' NOT NULL,
    CONSTRAINT pk_quality_check_ PRIMARY KEY (quality_check_id),
    CONSTRAINT ck_quality_check_row_version_positive CHECK (row_version > 0),
    CONSTRAINT ck_quality_check_record_state_code CHECK (record_state IN ('ACTIVE', 'VOID')),
    CONSTRAINT ck_quality_check_check_sequence_positive CHECK (check_sequence > 0),
    CONSTRAINT ck_quality_check_validation_status_code CHECK (validation_status IN ('UNVERIFIED', 'VERIFIED', 'NEEDS_REVIEW', 'REJECTED')),
    CONSTRAINT ck_quality_check_check_type_code CHECK (check_type IN ('MASTER_SAMPLE', 'IN_PROCESS_SAMPLE', 'OTHER'))
);

COMMENT ON TABLE mqi.quality_check IS '품질 측정 실행';

COMMENT ON COLUMN mqi.quality_check.quality_check_id IS 'PK';

COMMENT ON COLUMN mqi.quality_check.model_id IS 'FK → product_model';

COMMENT ON COLUMN mqi.quality_check.process_run_id IS 'FK → process_run';

COMMENT ON COLUMN mqi.quality_check.checker_id IS 'FK → worker';

COMMENT ON COLUMN mqi.quality_check.check_date IS '측정 기준일';

COMMENT ON COLUMN mqi.quality_check.checked_at IS '실제 측정시각';

COMMENT ON COLUMN mqi.quality_check.check_type IS '측정 유형';

COMMENT ON COLUMN mqi.quality_check.sample_reference IS '샘플 식별정보';

COMMENT ON COLUMN mqi.quality_check.check_sequence IS '동일 조건 내 측정 순번';

COMMENT ON COLUMN mqi.quality_check.validation_status IS '검증상태';

COMMENT ON COLUMN mqi.quality_check.remark IS '비고';

COMMENT ON COLUMN mqi.quality_check.recorded_at IS 'DB 최초 저장 시각; 실제 제조/관측 시각과 다름';

COMMENT ON COLUMN mqi.quality_check.updated_at IS 'DB 최종 변경 시각';

COMMENT ON COLUMN mqi.quality_check.row_version IS '시스템 변경 버전; 원본 개정번호 아님';

COMMENT ON COLUMN mqi.quality_check.record_state IS 'ACTIVE / VOID; VOID는 보존된 무효 기록, 참조 삭제 안 함';

CREATE TABLE mqi.measurement (
    measurement_id UUID DEFAULT gen_random_uuid() NOT NULL,
    quality_check_id UUID NOT NULL,
    measurement_item_code VARCHAR(100) NOT NULL,
    measurement_item_name VARCHAR(150),
    measurement_point_code VARCHAR(100),
    sample_index INTEGER,
    measurement_index INTEGER,
    measured_value NUMERIC,
    measurement_unit VARCHAR(30),
    raw_value_text TEXT,
    measured_at TIMESTAMPTZ,
    validation_status VARCHAR(30) NOT NULL,
    remark TEXT,
    recorded_at TIMESTAMPTZ DEFAULT clock_timestamp() NOT NULL,
    updated_at TIMESTAMPTZ DEFAULT clock_timestamp() NOT NULL,
    row_version BIGINT DEFAULT 1 NOT NULL,
    record_state VARCHAR(10) DEFAULT 'ACTIVE' NOT NULL,
    CONSTRAINT pk_measurement_ PRIMARY KEY (measurement_id),
    CONSTRAINT ck_measurement_row_version_positive CHECK (row_version > 0),
    CONSTRAINT ck_measurement_record_state_code CHECK (record_state IN ('ACTIVE', 'VOID')),
    CONSTRAINT ck_measurement_sample_index_positive CHECK (sample_index > 0),
    CONSTRAINT ck_measurement_measurement_index_positive CHECK (measurement_index > 0),
    CONSTRAINT ck_measurement_measured_value_finite CHECK (measured_value NOT IN ('NaN'::numeric, 'Infinity'::numeric, '-Infinity'::numeric)),
    CONSTRAINT ck_measurement_validation_status_code CHECK (validation_status IN ('UNVERIFIED', 'VERIFIED', 'NEEDS_REVIEW', 'REJECTED'))
);

COMMENT ON TABLE mqi.measurement IS '품질 측정값';

COMMENT ON COLUMN mqi.measurement.measurement_id IS 'PK';

COMMENT ON COLUMN mqi.measurement.quality_check_id IS 'FK → quality_check';

COMMENT ON COLUMN mqi.measurement.measurement_item_code IS '측정항목 코드';

COMMENT ON COLUMN mqi.measurement.measurement_item_name IS '측정항목 이름';

COMMENT ON COLUMN mqi.measurement.measurement_point_code IS '측정 지점 식별정보';

COMMENT ON COLUMN mqi.measurement.sample_index IS '샘플 구분 순번';

COMMENT ON COLUMN mqi.measurement.measurement_index IS '측정 순번';

COMMENT ON COLUMN mqi.measurement.measured_value IS '측정 수치';

COMMENT ON COLUMN mqi.measurement.measurement_unit IS '측정 단위';

COMMENT ON COLUMN mqi.measurement.raw_value_text IS '원본 측정값 표기';

COMMENT ON COLUMN mqi.measurement.measured_at IS '측정시각';

COMMENT ON COLUMN mqi.measurement.validation_status IS '검증상태';

COMMENT ON COLUMN mqi.measurement.remark IS '비고';

COMMENT ON COLUMN mqi.measurement.recorded_at IS 'DB 최초 저장 시각; 실제 제조/관측 시각과 다름';

COMMENT ON COLUMN mqi.measurement.updated_at IS 'DB 최종 변경 시각';

COMMENT ON COLUMN mqi.measurement.row_version IS '시스템 변경 버전; 원본 개정번호 아님';

COMMENT ON COLUMN mqi.measurement.record_state IS 'ACTIVE / VOID; VOID는 보존된 무효 기록, 참조 삭제 안 함';

CREATE TABLE mqi.inspection_run (
    inspection_run_id UUID DEFAULT gen_random_uuid() NOT NULL,
    model_id UUID NOT NULL,
    process_run_id UUID,
    inspector_id UUID,
    inspection_date DATE,
    started_at TIMESTAMPTZ,
    ended_at TIMESTAMPTZ,
    inspection_type VARCHAR(30) NOT NULL,
    inspection_stage VARCHAR(50) NOT NULL,
    inspection_round_no INTEGER,
    inspection_method VARCHAR(30),
    inspection_scope VARCHAR(30),
    target_defect_type_id UUID,
    inspected_qty_ea INTEGER,
    raw_inspection_label VARCHAR(150),
    validation_status VARCHAR(30) NOT NULL,
    remark TEXT,
    recorded_at TIMESTAMPTZ DEFAULT clock_timestamp() NOT NULL,
    updated_at TIMESTAMPTZ DEFAULT clock_timestamp() NOT NULL,
    row_version BIGINT DEFAULT 1 NOT NULL,
    record_state VARCHAR(10) DEFAULT 'ACTIVE' NOT NULL,
    CONSTRAINT pk_inspection_run_ PRIMARY KEY (inspection_run_id),
    CONSTRAINT uq_inspection_run_inspection_run_id_model_id UNIQUE (inspection_run_id, model_id),
    CONSTRAINT ck_inspection_run_row_version_positive CHECK (row_version > 0),
    CONSTRAINT ck_inspection_run_record_state_code CHECK (record_state IN ('ACTIVE', 'VOID')),
    CONSTRAINT ck_inspection_run_inspection_round_no_positive CHECK (inspection_round_no > 0),
    CONSTRAINT ck_inspection_run_inspected_qty_ea_nonnegative CHECK (inspected_qty_ea >= 0),
    CONSTRAINT ck_inspection_run_validation_status_code CHECK (validation_status IN ('UNVERIFIED', 'VERIFIED', 'NEEDS_REVIEW', 'REJECTED')),
    CONSTRAINT ck_inspection_run_ended_at_order CHECK (ended_at > started_at),
    CONSTRAINT ck_inspection_run_inspection_type_code CHECK (inspection_type IN ('IN_PROCESS', 'FINAL', 'REINSPECTION')),
    CONSTRAINT ck_inspection_run_inspection_stage_code CHECK (inspection_stage IN ('VISION_1', 'VISION_2', 'VISION_3', 'WELD', 'FINAL', 'OTHER')),
    CONSTRAINT ck_inspection_run_inspection_method_code CHECK (inspection_method IN ('EQUIPMENT_AUTO', 'VISUAL_MANUAL', 'MICROSCOPE', 'OTHER')),
    CONSTRAINT ck_inspection_run_inspection_scope_code CHECK (inspection_scope IN ('ROUTINE', 'TARGETED', 'OTHER'))
);

COMMENT ON TABLE mqi.inspection_run IS '검사 실행이력';

COMMENT ON COLUMN mqi.inspection_run.inspection_run_id IS 'PK';

COMMENT ON COLUMN mqi.inspection_run.model_id IS 'FK → product_model';

COMMENT ON COLUMN mqi.inspection_run.process_run_id IS '검사 대상 공정 실행 FK';

COMMENT ON COLUMN mqi.inspection_run.inspector_id IS '확인된 검사 담당자 FK → worker';

COMMENT ON COLUMN mqi.inspection_run.inspection_date IS '검사 기준일';

COMMENT ON COLUMN mqi.inspection_run.started_at IS '검사 시작시각';

COMMENT ON COLUMN mqi.inspection_run.ended_at IS '검사 종료시각';

COMMENT ON COLUMN mqi.inspection_run.inspection_type IS '검사 유형';

COMMENT ON COLUMN mqi.inspection_run.inspection_stage IS '검사 단계';

COMMENT ON COLUMN mqi.inspection_run.inspection_round_no IS '동일 대상에 대한 검사 차수';

COMMENT ON COLUMN mqi.inspection_run.inspection_method IS '검사 방법';

COMMENT ON COLUMN mqi.inspection_run.inspection_scope IS '검사 범위';

COMMENT ON COLUMN mqi.inspection_run.target_defect_type_id IS '집중 검사 대상 불량 유형 FK';

COMMENT ON COLUMN mqi.inspection_run.inspected_qty_ea IS '명시적으로 확인된 검사수량(EA)';

COMMENT ON COLUMN mqi.inspection_run.raw_inspection_label IS '원본 검사명';

COMMENT ON COLUMN mqi.inspection_run.validation_status IS '기록 검증상태';

COMMENT ON COLUMN mqi.inspection_run.remark IS '비고';

COMMENT ON COLUMN mqi.inspection_run.recorded_at IS 'DB 최초 저장 시각; 실제 제조/관측 시각과 다름';

COMMENT ON COLUMN mqi.inspection_run.updated_at IS 'DB 최종 변경 시각';

COMMENT ON COLUMN mqi.inspection_run.row_version IS '시스템 변경 버전; 원본 개정번호 아님';

COMMENT ON COLUMN mqi.inspection_run.record_state IS 'ACTIVE / VOID; VOID는 보존된 무효 기록, 참조 삭제 안 함';

CREATE TABLE mqi.inspection_lot (
    inspection_lot_id UUID DEFAULT gen_random_uuid() NOT NULL,
    inspection_run_id UUID NOT NULL,
    production_lot_id UUID,
    lot_code_raw VARCHAR(100),
    recorded_box_count INTEGER,
    inspected_qty_ea INTEGER,
    recorded_quantity_raw TEXT,
    lot_linkage_status VARCHAR(30) NOT NULL,
    remark TEXT,
    model_id UUID NOT NULL,
    recorded_at TIMESTAMPTZ DEFAULT clock_timestamp() NOT NULL,
    updated_at TIMESTAMPTZ DEFAULT clock_timestamp() NOT NULL,
    row_version BIGINT DEFAULT 1 NOT NULL,
    record_state VARCHAR(10) DEFAULT 'ACTIVE' NOT NULL,
    CONSTRAINT pk_inspection_lot_ PRIMARY KEY (inspection_lot_id),
    CONSTRAINT uq_inspection_lot_inspection_lot_id_inspection_run_id UNIQUE (inspection_lot_id, inspection_run_id),
    CONSTRAINT ck_inspection_lot_row_version_positive CHECK (row_version > 0),
    CONSTRAINT ck_inspection_lot_record_state_code CHECK (record_state IN ('ACTIVE', 'VOID')),
    CONSTRAINT ck_inspection_lot_recorded_box_count_nonnegative CHECK (recorded_box_count >= 0),
    CONSTRAINT ck_inspection_lot_inspected_qty_ea_nonnegative CHECK (inspected_qty_ea >= 0),
    CONSTRAINT ck_inspection_lot_lot_linkage_status_code CHECK (lot_linkage_status IN ('UNRESOLVED', 'CANDIDATE', 'CONFIRMED')),
    CONSTRAINT ck_inspection_lot_lot_state CHECK ((production_lot_id IS NULL AND lot_linkage_status = 'UNRESOLVED') OR (production_lot_id IS NOT NULL AND lot_linkage_status IN ('CANDIDATE','CONFIRMED')))
);

COMMENT ON TABLE mqi.inspection_lot IS '검사 대상 LOT 및 수량';

COMMENT ON COLUMN mqi.inspection_lot.inspection_lot_id IS 'PK';

COMMENT ON COLUMN mqi.inspection_lot.inspection_run_id IS 'FK → inspection_run';

COMMENT ON COLUMN mqi.inspection_lot.production_lot_id IS '확인된 생산 LOT FK';

COMMENT ON COLUMN mqi.inspection_lot.lot_code_raw IS '원본 LOT 표시';

COMMENT ON COLUMN mqi.inspection_lot.recorded_box_count IS '원본에 기록된 박스수량';

COMMENT ON COLUMN mqi.inspection_lot.inspected_qty_ea IS '실제 확인된 검사수량(EA)';

COMMENT ON COLUMN mqi.inspection_lot.recorded_quantity_raw IS '원본 수량 표현';

COMMENT ON COLUMN mqi.inspection_lot.lot_linkage_status IS 'LOT 식별 검증상태';

COMMENT ON COLUMN mqi.inspection_lot.remark IS '비고';

COMMENT ON COLUMN mqi.inspection_lot.model_id IS '상위 FK의 모델 식별자 복사; 서버 검증/자동 채움, 업무 추정 아님';

COMMENT ON COLUMN mqi.inspection_lot.recorded_at IS 'DB 최초 저장 시각; 실제 제조/관측 시각과 다름';

COMMENT ON COLUMN mqi.inspection_lot.updated_at IS 'DB 최종 변경 시각';

COMMENT ON COLUMN mqi.inspection_lot.row_version IS '시스템 변경 버전; 원본 개정번호 아님';

COMMENT ON COLUMN mqi.inspection_lot.record_state IS 'ACTIVE / VOID; VOID는 보존된 무효 기록, 참조 삭제 안 함';

CREATE TABLE mqi.inspection_run_link (
    inspection_run_link_id UUID DEFAULT gen_random_uuid() NOT NULL,
    prior_inspection_run_id UUID NOT NULL,
    followup_inspection_run_id UUID NOT NULL,
    relation_type VARCHAR(50) NOT NULL,
    linkage_status VARCHAR(30) NOT NULL,
    evidence_note TEXT,
    remark TEXT,
    model_id UUID NOT NULL,
    recorded_at TIMESTAMPTZ DEFAULT clock_timestamp() NOT NULL,
    updated_at TIMESTAMPTZ DEFAULT clock_timestamp() NOT NULL,
    row_version BIGINT DEFAULT 1 NOT NULL,
    record_state VARCHAR(10) DEFAULT 'ACTIVE' NOT NULL,
    CONSTRAINT pk_inspection_run_link_ PRIMARY KEY (inspection_run_link_id),
    CONSTRAINT uq_inspection_run_link_prior_inspection_run_id_follo_edfe12a2ae UNIQUE (prior_inspection_run_id, followup_inspection_run_id, relation_type),
    CONSTRAINT ck_inspection_run_link_row_version_positive CHECK (row_version > 0),
    CONSTRAINT ck_inspection_run_link_record_state_code CHECK (record_state IN ('ACTIVE', 'VOID')),
    CONSTRAINT ck_inspection_run_link_linkage_status_code CHECK (linkage_status IN ('CONFIRMED', 'CANDIDATE')),
    CONSTRAINT ck_inspection_run_link_relation_type_code CHECK (relation_type IN ('TRAINING_CONFIRMATION', 'RECHECK_OF_REJECTS', 'TARGETED_REINSPECTION', 'OTHER')),
    CONSTRAINT ck_inspection_run_link_no_self_reference CHECK (prior_inspection_run_id <> followup_inspection_run_id)
);

COMMENT ON TABLE mqi.inspection_run_link IS '검사 실행 간 관계';

COMMENT ON COLUMN mqi.inspection_run_link.inspection_run_link_id IS 'PK';

COMMENT ON COLUMN mqi.inspection_run_link.prior_inspection_run_id IS '앞선 검사 실행 FK';

COMMENT ON COLUMN mqi.inspection_run_link.followup_inspection_run_id IS '후속 검사 실행 FK';

COMMENT ON COLUMN mqi.inspection_run_link.relation_type IS '검사 간 관계 유형';

COMMENT ON COLUMN mqi.inspection_run_link.linkage_status IS '관계 검증상태';

COMMENT ON COLUMN mqi.inspection_run_link.evidence_note IS '연결 근거';

COMMENT ON COLUMN mqi.inspection_run_link.remark IS '비고';

COMMENT ON COLUMN mqi.inspection_run_link.model_id IS '상위 FK의 모델 식별자 복사; 서버 검증/자동 채움, 업무 추정 아님';

COMMENT ON COLUMN mqi.inspection_run_link.recorded_at IS 'DB 최초 저장 시각; 실제 제조/관측 시각과 다름';

COMMENT ON COLUMN mqi.inspection_run_link.updated_at IS 'DB 최종 변경 시각';

COMMENT ON COLUMN mqi.inspection_run_link.row_version IS '시스템 변경 버전; 원본 개정번호 아님';

COMMENT ON COLUMN mqi.inspection_run_link.record_state IS 'ACTIVE / VOID; VOID는 보존된 무효 기록, 참조 삭제 안 함';

CREATE TABLE mqi.defect_type (
    defect_type_id UUID DEFAULT gen_random_uuid() NOT NULL,
    defect_code VARCHAR(100) NOT NULL,
    defect_name VARCHAR(150) NOT NULL,
    defect_category VARCHAR(100),
    description TEXT,
    is_active BOOLEAN DEFAULT TRUE NOT NULL,
    recorded_at TIMESTAMPTZ DEFAULT clock_timestamp() NOT NULL,
    updated_at TIMESTAMPTZ DEFAULT clock_timestamp() NOT NULL,
    row_version BIGINT DEFAULT 1 NOT NULL,
    record_state VARCHAR(10) DEFAULT 'ACTIVE' NOT NULL,
    CONSTRAINT pk_defect_type_ PRIMARY KEY (defect_type_id),
    CONSTRAINT uq_defect_type_defect_code UNIQUE (defect_code),
    CONSTRAINT ck_defect_type_row_version_positive CHECK (row_version > 0),
    CONSTRAINT ck_defect_type_record_state_code CHECK (record_state IN ('ACTIVE', 'VOID'))
);

COMMENT ON TABLE mqi.defect_type IS '불량 유형 마스터';

COMMENT ON COLUMN mqi.defect_type.defect_type_id IS 'PK';

COMMENT ON COLUMN mqi.defect_type.defect_code IS '표준화된 불량 유형 코드';

COMMENT ON COLUMN mqi.defect_type.defect_name IS '불량 유형명';

COMMENT ON COLUMN mqi.defect_type.defect_category IS '상위 불량 분류';

COMMENT ON COLUMN mqi.defect_type.description IS '정의 및 판정 설명';

COMMENT ON COLUMN mqi.defect_type.is_active IS '사용 여부';

COMMENT ON COLUMN mqi.defect_type.recorded_at IS 'DB 최초 저장 시각; 실제 제조/관측 시각과 다름';

COMMENT ON COLUMN mqi.defect_type.updated_at IS 'DB 최종 변경 시각';

COMMENT ON COLUMN mqi.defect_type.row_version IS '시스템 변경 버전; 원본 개정번호 아님';

COMMENT ON COLUMN mqi.defect_type.record_state IS 'ACTIVE / VOID; VOID는 보존된 무효 기록, 참조 삭제 안 함';

CREATE TABLE mqi.quality_finding (
    quality_finding_id UUID DEFAULT gen_random_uuid() NOT NULL,
    inspection_run_id UUID,
    inspection_lot_id UUID,
    process_run_id UUID,
    defect_type_id UUID,
    parent_finding_id UUID,
    finding_class VARCHAR(30) NOT NULL,
    quantity INTEGER,
    quantity_unit VARCHAR(20),
    raw_quantity_text TEXT,
    raw_defect_name TEXT,
    validation_status VARCHAR(30) NOT NULL,
    remark TEXT,
    model_id UUID NOT NULL,
    recorded_at TIMESTAMPTZ DEFAULT clock_timestamp() NOT NULL,
    updated_at TIMESTAMPTZ DEFAULT clock_timestamp() NOT NULL,
    row_version BIGINT DEFAULT 1 NOT NULL,
    record_state VARCHAR(10) DEFAULT 'ACTIVE' NOT NULL,
    CONSTRAINT pk_quality_finding_ PRIMARY KEY (quality_finding_id),
    CONSTRAINT uq_quality_finding_quality_finding_id_model_id UNIQUE (quality_finding_id, model_id),
    CONSTRAINT ck_quality_finding_row_version_positive CHECK (row_version > 0),
    CONSTRAINT ck_quality_finding_record_state_code CHECK (record_state IN ('ACTIVE', 'VOID')),
    CONSTRAINT ck_quality_finding_quantity_nonnegative CHECK (quantity >= 0),
    CONSTRAINT ck_quality_finding_validation_status_code CHECK (validation_status IN ('UNVERIFIED', 'VERIFIED', 'NEEDS_REVIEW', 'REJECTED')),
    CONSTRAINT ck_quality_finding_finding_class_code CHECK (finding_class IN ('EQUIPMENT_REJECT', 'FALSE_REJECT', 'TRUE_DEFECT', 'FINAL_DEFECT', 'PROCESS_DEFECT')),
    CONSTRAINT ck_quality_finding_exactly_one_target CHECK (num_nonnulls(inspection_run_id, process_run_id) = 1),
    CONSTRAINT ck_quality_finding_no_self_reference CHECK (parent_finding_id <> quality_finding_id),
    CONSTRAINT ck_quality_finding_lot_requires_inspection CHECK (inspection_lot_id IS NULL OR inspection_run_id IS NOT NULL),
    CONSTRAINT ck_quality_finding_finding_context CHECK ((finding_class = 'PROCESS_DEFECT') = (process_run_id IS NOT NULL))
);

COMMENT ON TABLE mqi.quality_finding IS '품질 이상 및 판정 결과';

COMMENT ON COLUMN mqi.quality_finding.quality_finding_id IS 'PK';

COMMENT ON COLUMN mqi.quality_finding.inspection_run_id IS '검사 실행 FK';

COMMENT ON COLUMN mqi.quality_finding.inspection_lot_id IS '불량이 귀속된 검사 대상 LOT FK → inspection_lot';

COMMENT ON COLUMN mqi.quality_finding.process_run_id IS '직접 공정 불량 기록인 경우 FK';

COMMENT ON COLUMN mqi.quality_finding.defect_type_id IS '불량 유형 FK';

COMMENT ON COLUMN mqi.quality_finding.parent_finding_id IS '확인된 선행 품질 기록 FK';

COMMENT ON COLUMN mqi.quality_finding.finding_class IS '품질 발견·판정 유형';

COMMENT ON COLUMN mqi.quality_finding.quantity IS '해당 유형의 확인된 수량';

COMMENT ON COLUMN mqi.quality_finding.quantity_unit IS '수량단위';

COMMENT ON COLUMN mqi.quality_finding.raw_quantity_text IS '원본 수량 표기';

COMMENT ON COLUMN mqi.quality_finding.raw_defect_name IS '원본 불량명';

COMMENT ON COLUMN mqi.quality_finding.validation_status IS '추출 및 검증상태';

COMMENT ON COLUMN mqi.quality_finding.remark IS '비고';

COMMENT ON COLUMN mqi.quality_finding.model_id IS '공정 또는 검사 모델 식별자; 부모 Finding과 복합 FK로 일치 보장';

COMMENT ON COLUMN mqi.quality_finding.recorded_at IS 'DB 최초 저장 시각; 실제 제조/관측 시각과 다름';

COMMENT ON COLUMN mqi.quality_finding.updated_at IS 'DB 최종 변경 시각';

COMMENT ON COLUMN mqi.quality_finding.row_version IS '시스템 변경 버전; 원본 개정번호 아님';

COMMENT ON COLUMN mqi.quality_finding.record_state IS 'ACTIVE / VOID; VOID는 보존된 무효 기록, 참조 삭제 안 함';

CREATE TABLE mqi.lot_code_scheme (
    scheme_id UUID DEFAULT gen_random_uuid() NOT NULL,
    scheme_code VARCHAR(100) NOT NULL,
    scheme_name VARCHAR(150) NOT NULL,
    scheme_version VARCHAR(50),
    effective_from DATE,
    effective_to DATE,
    source_description TEXT,
    verification_status VARCHAR(30) NOT NULL,
    remark TEXT,
    recorded_at TIMESTAMPTZ DEFAULT clock_timestamp() NOT NULL,
    updated_at TIMESTAMPTZ DEFAULT clock_timestamp() NOT NULL,
    row_version BIGINT DEFAULT 1 NOT NULL,
    record_state VARCHAR(10) DEFAULT 'ACTIVE' NOT NULL,
    CONSTRAINT pk_lot_code_scheme_ PRIMARY KEY (scheme_id),
    CONSTRAINT uq_lot_code_scheme_scheme_code UNIQUE (scheme_code),
    CONSTRAINT ck_lot_code_scheme_row_version_positive CHECK (row_version > 0),
    CONSTRAINT ck_lot_code_scheme_record_state_code CHECK (record_state IN ('ACTIVE', 'VOID')),
    CONSTRAINT ck_lot_code_scheme_verification_status_code CHECK (verification_status IN ('UNVERIFIED', 'CONFIRMED', 'NEEDS_REVIEW', 'REJECTED')),
    CONSTRAINT ck_lot_code_scheme_effective_to_order CHECK (effective_to >= effective_from)
);

COMMENT ON TABLE mqi.lot_code_scheme IS 'LOT 코드 변환체계';

COMMENT ON COLUMN mqi.lot_code_scheme.scheme_id IS 'PK';

COMMENT ON COLUMN mqi.lot_code_scheme.scheme_code IS '변환체계 식별코드';

COMMENT ON COLUMN mqi.lot_code_scheme.scheme_name IS '변환체계 이름';

COMMENT ON COLUMN mqi.lot_code_scheme.scheme_version IS '조견표 또는 규칙 버전';

COMMENT ON COLUMN mqi.lot_code_scheme.effective_from IS '적용 시작일';

COMMENT ON COLUMN mqi.lot_code_scheme.effective_to IS '적용 종료일';

COMMENT ON COLUMN mqi.lot_code_scheme.source_description IS '변환규칙 근거자료';

COMMENT ON COLUMN mqi.lot_code_scheme.verification_status IS '규칙 검증상태';

COMMENT ON COLUMN mqi.lot_code_scheme.remark IS '비고';

COMMENT ON COLUMN mqi.lot_code_scheme.recorded_at IS 'DB 최초 저장 시각; 실제 제조/관측 시각과 다름';

COMMENT ON COLUMN mqi.lot_code_scheme.updated_at IS 'DB 최종 변경 시각';

COMMENT ON COLUMN mqi.lot_code_scheme.row_version IS '시스템 변경 버전; 원본 개정번호 아님';

COMMENT ON COLUMN mqi.lot_code_scheme.record_state IS 'ACTIVE / VOID; VOID는 보존된 무효 기록, 참조 삭제 안 함';

CREATE TABLE mqi.lot_code_mapping (
    mapping_id UUID DEFAULT gen_random_uuid() NOT NULL,
    scheme_id UUID NOT NULL,
    marking_code VARCHAR(30) NOT NULL,
    lot_date DATE NOT NULL,
    validation_status VARCHAR(30) NOT NULL,
    remark TEXT,
    recorded_at TIMESTAMPTZ DEFAULT clock_timestamp() NOT NULL,
    updated_at TIMESTAMPTZ DEFAULT clock_timestamp() NOT NULL,
    row_version BIGINT DEFAULT 1 NOT NULL,
    record_state VARCHAR(10) DEFAULT 'ACTIVE' NOT NULL,
    CONSTRAINT pk_lot_code_mapping_ PRIMARY KEY (mapping_id),
    CONSTRAINT ck_lot_code_mapping_row_version_positive CHECK (row_version > 0),
    CONSTRAINT ck_lot_code_mapping_record_state_code CHECK (record_state IN ('ACTIVE', 'VOID')),
    CONSTRAINT ck_lot_code_mapping_validation_status_code CHECK (validation_status IN ('UNVERIFIED', 'VERIFIED', 'NEEDS_REVIEW', 'REJECTED'))
);

COMMENT ON TABLE mqi.lot_code_mapping IS 'LOT 코드와 날짜 대응';

COMMENT ON COLUMN mqi.lot_code_mapping.mapping_id IS 'PK';

COMMENT ON COLUMN mqi.lot_code_mapping.scheme_id IS 'FK → lot_code_scheme';

COMMENT ON COLUMN mqi.lot_code_mapping.marking_code IS '변환 대상 LOT 코드';

COMMENT ON COLUMN mqi.lot_code_mapping.lot_date IS '코드에 대응하는 날짜';

COMMENT ON COLUMN mqi.lot_code_mapping.validation_status IS '변환 검증상태';

COMMENT ON COLUMN mqi.lot_code_mapping.remark IS '비고';

COMMENT ON COLUMN mqi.lot_code_mapping.recorded_at IS 'DB 최초 저장 시각; 실제 제조/관측 시각과 다름';

COMMENT ON COLUMN mqi.lot_code_mapping.updated_at IS 'DB 최종 변경 시각';

COMMENT ON COLUMN mqi.lot_code_mapping.row_version IS '시스템 변경 버전; 원본 개정번호 아님';

COMMENT ON COLUMN mqi.lot_code_mapping.record_state IS 'ACTIVE / VOID; VOID는 보존된 무효 기록, 참조 삭제 안 함';

CREATE TABLE mqi.rework_record (
    rework_id UUID DEFAULT gen_random_uuid() NOT NULL,
    model_id UUID NOT NULL,
    rework_type VARCHAR(50) NOT NULL,
    work_date DATE,
    marked_lot_code_raw VARCHAR(100),
    lot_code_mapping_id UUID,
    marked_lot_date DATE,
    serial_start_raw VARCHAR(100),
    serial_end_raw VARCHAR(100),
    serial_start_num BIGINT,
    serial_end_num BIGINT,
    recorded_qty INTEGER,
    recorded_qty_basis VARCHAR(50),
    input_qty INTEGER,
    completed_qty INTEGER,
    work_minutes INTEGER,
    validation_status VARCHAR(30) NOT NULL,
    raw_note TEXT,
    remark TEXT,
    recorded_at TIMESTAMPTZ DEFAULT clock_timestamp() NOT NULL,
    updated_at TIMESTAMPTZ DEFAULT clock_timestamp() NOT NULL,
    row_version BIGINT DEFAULT 1 NOT NULL,
    record_state VARCHAR(10) DEFAULT 'ACTIVE' NOT NULL,
    CONSTRAINT pk_rework_record_ PRIMARY KEY (rework_id),
    CONSTRAINT uq_rework_record_rework_id_model_id UNIQUE (rework_id, model_id),
    CONSTRAINT ck_rework_record_row_version_positive CHECK (row_version > 0),
    CONSTRAINT ck_rework_record_record_state_code CHECK (record_state IN ('ACTIVE', 'VOID')),
    CONSTRAINT ck_rework_record_recorded_qty_nonnegative CHECK (recorded_qty >= 0),
    CONSTRAINT ck_rework_record_input_qty_nonnegative CHECK (input_qty >= 0),
    CONSTRAINT ck_rework_record_completed_qty_nonnegative CHECK (completed_qty >= 0),
    CONSTRAINT ck_rework_record_work_minutes_nonnegative CHECK (work_minutes >= 0),
    CONSTRAINT ck_rework_record_validation_status_code CHECK (validation_status IN ('UNVERIFIED', 'VERIFIED', 'NEEDS_REVIEW', 'REJECTED')),
    CONSTRAINT ck_rework_record_rework_type_code CHECK (rework_type IN ('CA_REMARKING', 'BA_VISION_RECOVERY', 'OTHER')),
    CONSTRAINT ck_rework_record_recorded_qty_basis_code CHECK (recorded_qty_basis IN ('SERIAL_DIFFERENCE', 'DIRECT_COUNT', 'OTHER', 'UNKNOWN')),
    CONSTRAINT ck_rework_record_serial_order CHECK (serial_end_num >= serial_start_num),
    CONSTRAINT ck_rework_record_serial_start_raw_required CHECK (serial_start_num IS NULL OR serial_start_raw IS NOT NULL),
    CONSTRAINT ck_rework_record_serial_end_raw_required CHECK (serial_end_num IS NULL OR serial_end_raw IS NOT NULL)
);

COMMENT ON TABLE mqi.rework_record IS '리워크 작업실적';

COMMENT ON COLUMN mqi.rework_record.rework_id IS 'PK';

COMMENT ON COLUMN mqi.rework_record.model_id IS 'FK → product_model';

COMMENT ON COLUMN mqi.rework_record.rework_type IS '리워크 작업유형';

COMMENT ON COLUMN mqi.rework_record.work_date IS '실제 확인된 리워크 작업일';

COMMENT ON COLUMN mqi.rework_record.marked_lot_code_raw IS '리워크 기록상의 제품 마킹 LOT 코드';

COMMENT ON COLUMN mqi.rework_record.lot_code_mapping_id IS '확인된 LOT 코드 변환 FK';

COMMENT ON COLUMN mqi.rework_record.marked_lot_date IS '마킹코드에 대응하는 날짜';

COMMENT ON COLUMN mqi.rework_record.serial_start_raw IS '원본 SERIAL 시작값';

COMMENT ON COLUMN mqi.rework_record.serial_end_raw IS '원본 SERIAL 종료값';

COMMENT ON COLUMN mqi.rework_record.serial_start_num IS '숫자로 검증된 SERIAL 시작값';

COMMENT ON COLUMN mqi.rework_record.serial_end_num IS '숫자로 검증된 SERIAL 종료값';

COMMENT ON COLUMN mqi.rework_record.recorded_qty IS '리워크 관리자료에 기재된 수량';

COMMENT ON COLUMN mqi.rework_record.recorded_qty_basis IS '원본 기록수량의 산정 방식';

COMMENT ON COLUMN mqi.rework_record.input_qty IS '실제 확인된 리워크 투입수량';

COMMENT ON COLUMN mqi.rework_record.completed_qty IS '실제 확인된 리워크 완료수량';

COMMENT ON COLUMN mqi.rework_record.work_minutes IS '확인된 작업시간';

COMMENT ON COLUMN mqi.rework_record.validation_status IS '기록 검증상태';

COMMENT ON COLUMN mqi.rework_record.raw_note IS '원본 비고';

COMMENT ON COLUMN mqi.rework_record.remark IS '검증 및 추가 설명';

COMMENT ON COLUMN mqi.rework_record.recorded_at IS 'DB 최초 저장 시각; 실제 제조/관측 시각과 다름';

COMMENT ON COLUMN mqi.rework_record.updated_at IS 'DB 최종 변경 시각';

COMMENT ON COLUMN mqi.rework_record.row_version IS '시스템 변경 버전; 원본 개정번호 아님';

COMMENT ON COLUMN mqi.rework_record.record_state IS 'ACTIVE / VOID; VOID는 보존된 무효 기록, 참조 삭제 안 함';

CREATE TABLE mqi.rework_origin_link (
    rework_origin_link_id UUID DEFAULT gen_random_uuid() NOT NULL,
    rework_id UUID NOT NULL,
    original_lot_id UUID NOT NULL,
    original_process_run_id UUID,
    linkage_status VARCHAR(30) NOT NULL,
    linkage_method VARCHAR(50),
    evidence_note TEXT,
    verified_at TIMESTAMPTZ,
    remark TEXT,
    model_id UUID NOT NULL,
    recorded_at TIMESTAMPTZ DEFAULT clock_timestamp() NOT NULL,
    updated_at TIMESTAMPTZ DEFAULT clock_timestamp() NOT NULL,
    row_version BIGINT DEFAULT 1 NOT NULL,
    record_state VARCHAR(10) DEFAULT 'ACTIVE' NOT NULL,
    CONSTRAINT pk_rework_origin_link_ PRIMARY KEY (rework_origin_link_id),
    CONSTRAINT ck_rework_origin_link_row_version_positive CHECK (row_version > 0),
    CONSTRAINT ck_rework_origin_link_record_state_code CHECK (record_state IN ('ACTIVE', 'VOID')),
    CONSTRAINT ck_rework_origin_link_linkage_status_code CHECK (linkage_status IN ('CONFIRMED', 'CANDIDATE')),
    CONSTRAINT ck_rework_origin_link_linkage_method_code CHECK (linkage_method IN ('DIRECT_RECORD', 'SERIAL_TRACE', 'WORK_JOURNAL_MATCH', 'DATE_BASED_CANDIDATE', 'OTHER')),
    CONSTRAINT ck_rework_origin_link_date_hint_not_confirmed CHECK (linkage_method IS DISTINCT FROM 'DATE_BASED_CANDIDATE' OR linkage_status = 'CANDIDATE')
);

COMMENT ON TABLE mqi.rework_origin_link IS '최초 생산 LOT 연결';

COMMENT ON COLUMN mqi.rework_origin_link.rework_origin_link_id IS 'PK';

COMMENT ON COLUMN mqi.rework_origin_link.rework_id IS 'FK → rework_record';

COMMENT ON COLUMN mqi.rework_origin_link.original_lot_id IS 'FK → production_lot';

COMMENT ON COLUMN mqi.rework_origin_link.original_process_run_id IS '확인된 최초 공정 실행 FK';

COMMENT ON COLUMN mqi.rework_origin_link.linkage_status IS 'LOT 연결 검증상태';

COMMENT ON COLUMN mqi.rework_origin_link.linkage_method IS '연결 근거 또는 추적방법';

COMMENT ON COLUMN mqi.rework_origin_link.evidence_note IS '상세 연결근거';

COMMENT ON COLUMN mqi.rework_origin_link.verified_at IS '최종 확인시각';

COMMENT ON COLUMN mqi.rework_origin_link.remark IS '비고';

COMMENT ON COLUMN mqi.rework_origin_link.model_id IS '상위 FK의 모델 식별자 복사; 서버 검증/자동 채움, 업무 추정 아님';

COMMENT ON COLUMN mqi.rework_origin_link.recorded_at IS 'DB 최초 저장 시각; 실제 제조/관측 시각과 다름';

COMMENT ON COLUMN mqi.rework_origin_link.updated_at IS 'DB 최종 변경 시각';

COMMENT ON COLUMN mqi.rework_origin_link.row_version IS '시스템 변경 버전; 원본 개정번호 아님';

COMMENT ON COLUMN mqi.rework_origin_link.record_state IS 'ACTIVE / VOID; VOID는 보존된 무효 기록, 참조 삭제 안 함';

CREATE TABLE mqi.traceability_card (
    traceability_card_id UUID DEFAULT gen_random_uuid() NOT NULL,
    model_id UUID NOT NULL,
    card_reference_raw VARCHAR(100),
    box_no_raw VARCHAR(100),
    marked_lot_code_raw VARCHAR(100),
    serial_start_raw VARCHAR(100),
    serial_end_raw VARCHAR(100),
    box_capacity INTEGER,
    actual_box_qty INTEGER,
    card_date DATE,
    validation_status VARCHAR(30) NOT NULL,
    raw_note TEXT,
    remark TEXT,
    recorded_at TIMESTAMPTZ DEFAULT clock_timestamp() NOT NULL,
    updated_at TIMESTAMPTZ DEFAULT clock_timestamp() NOT NULL,
    row_version BIGINT DEFAULT 1 NOT NULL,
    record_state VARCHAR(10) DEFAULT 'ACTIVE' NOT NULL,
    CONSTRAINT pk_traceability_card_ PRIMARY KEY (traceability_card_id),
    CONSTRAINT ck_traceability_card_row_version_positive CHECK (row_version > 0),
    CONSTRAINT ck_traceability_card_record_state_code CHECK (record_state IN ('ACTIVE', 'VOID')),
    CONSTRAINT ck_traceability_card_box_capacity_positive CHECK (box_capacity > 0),
    CONSTRAINT ck_traceability_card_actual_box_qty_nonnegative CHECK (actual_box_qty >= 0),
    CONSTRAINT ck_traceability_card_validation_status_code CHECK (validation_status IN ('UNVERIFIED', 'VERIFIED', 'NEEDS_REVIEW', 'REJECTED'))
);

COMMENT ON TABLE mqi.traceability_card IS '조립카드';

COMMENT ON COLUMN mqi.traceability_card.traceability_card_id IS 'PK';

COMMENT ON COLUMN mqi.traceability_card.model_id IS 'FK → product_model';

COMMENT ON COLUMN mqi.traceability_card.card_reference_raw IS '원본 카드 식별정보';

COMMENT ON COLUMN mqi.traceability_card.box_no_raw IS '원본 BOX 번호';

COMMENT ON COLUMN mqi.traceability_card.marked_lot_code_raw IS '카드에 기재된 LOT 코드';

COMMENT ON COLUMN mqi.traceability_card.serial_start_raw IS '원본 SERIAL 시작값';

COMMENT ON COLUMN mqi.traceability_card.serial_end_raw IS '원본 SERIAL 종료값';

COMMENT ON COLUMN mqi.traceability_card.box_capacity IS '확인된 BOX 기준수량';

COMMENT ON COLUMN mqi.traceability_card.actual_box_qty IS '실제 확인된 BOX 내 제품수량';

COMMENT ON COLUMN mqi.traceability_card.card_date IS '카드에 확인된 날짜';

COMMENT ON COLUMN mqi.traceability_card.validation_status IS '카드 정보 검증상태';

COMMENT ON COLUMN mqi.traceability_card.raw_note IS '원본 비고';

COMMENT ON COLUMN mqi.traceability_card.remark IS '추가 설명';

COMMENT ON COLUMN mqi.traceability_card.recorded_at IS 'DB 최초 저장 시각; 실제 제조/관측 시각과 다름';

COMMENT ON COLUMN mqi.traceability_card.updated_at IS 'DB 최종 변경 시각';

COMMENT ON COLUMN mqi.traceability_card.row_version IS '시스템 변경 버전; 원본 개정번호 아님';

COMMENT ON COLUMN mqi.traceability_card.record_state IS 'ACTIVE / VOID; VOID는 보존된 무효 기록, 참조 삭제 안 함';

CREATE TABLE mqi.source_ingest (
    ingest_id UUID DEFAULT gen_random_uuid() NOT NULL,
    source_name VARCHAR(150),
    ingest_method VARCHAR(30) NOT NULL,
    started_at TIMESTAMPTZ NOT NULL,
    completed_at TIMESTAMPTZ,
    ingest_status VARCHAR(30) NOT NULL,
    importer_ref VARCHAR(100),
    remark TEXT,
    recorded_at TIMESTAMPTZ DEFAULT clock_timestamp() NOT NULL,
    updated_at TIMESTAMPTZ DEFAULT clock_timestamp() NOT NULL,
    row_version BIGINT DEFAULT 1 NOT NULL,
    record_state VARCHAR(10) DEFAULT 'ACTIVE' NOT NULL,
    CONSTRAINT pk_source_ingest_ PRIMARY KEY (ingest_id),
    CONSTRAINT ck_source_ingest_row_version_positive CHECK (row_version > 0),
    CONSTRAINT ck_source_ingest_record_state_code CHECK (record_state IN ('ACTIVE', 'VOID')),
    CONSTRAINT ck_source_ingest_completed_at_order CHECK (completed_at >= started_at),
    CONSTRAINT ck_source_ingest_ingest_method_code CHECK (ingest_method IN ('FILE_UPLOAD', 'BATCH_IMPORT', 'API_COLLECTION', 'MANUAL_IMPORT')),
    CONSTRAINT ck_source_ingest_ingest_status_code CHECK (ingest_status IN ('RUNNING', 'COMPLETED', 'PARTIAL', 'FAILED'))
);

COMMENT ON TABLE mqi.source_ingest IS '자료 수집 실행이력';

COMMENT ON COLUMN mqi.source_ingest.ingest_id IS 'PK';

COMMENT ON COLUMN mqi.source_ingest.source_name IS '자료 출처 또는 수집명';

COMMENT ON COLUMN mqi.source_ingest.ingest_method IS '수집 방법';

COMMENT ON COLUMN mqi.source_ingest.started_at IS '수집 시작시각';

COMMENT ON COLUMN mqi.source_ingest.completed_at IS '수집 완료시각';

COMMENT ON COLUMN mqi.source_ingest.ingest_status IS '수집 처리상태';

COMMENT ON COLUMN mqi.source_ingest.importer_ref IS '수집 실행 주체의 내부 식별자';

COMMENT ON COLUMN mqi.source_ingest.remark IS '비고';

COMMENT ON COLUMN mqi.source_ingest.recorded_at IS 'DB 최초 저장 시각; 실제 제조/관측 시각과 다름';

COMMENT ON COLUMN mqi.source_ingest.updated_at IS 'DB 최종 변경 시각';

COMMENT ON COLUMN mqi.source_ingest.row_version IS '시스템 변경 버전; 원본 개정번호 아님';

COMMENT ON COLUMN mqi.source_ingest.record_state IS 'ACTIVE / VOID; VOID는 보존된 무효 기록, 참조 삭제 안 함';

CREATE TABLE mqi.source_bundle (
    bundle_id UUID DEFAULT gen_random_uuid() NOT NULL,
    ingest_id UUID NOT NULL,
    parent_bundle_id UUID,
    bundle_name VARCHAR(255) NOT NULL,
    bundle_type VARCHAR(30) NOT NULL,
    original_path TEXT,
    raw_date_hint VARCHAR(100),
    date_hint_type VARCHAR(30),
    remark TEXT,
    archive_asset_id UUID,
    recorded_at TIMESTAMPTZ DEFAULT clock_timestamp() NOT NULL,
    updated_at TIMESTAMPTZ DEFAULT clock_timestamp() NOT NULL,
    row_version BIGINT DEFAULT 1 NOT NULL,
    record_state VARCHAR(10) DEFAULT 'ACTIVE' NOT NULL,
    CONSTRAINT pk_source_bundle_ PRIMARY KEY (bundle_id),
    CONSTRAINT uq_source_bundle_bundle_id_ingest_id UNIQUE (bundle_id, ingest_id),
    CONSTRAINT ck_source_bundle_row_version_positive CHECK (row_version > 0),
    CONSTRAINT ck_source_bundle_record_state_code CHECK (record_state IN ('ACTIVE', 'VOID')),
    CONSTRAINT ck_source_bundle_bundle_type_code CHECK (bundle_type IN ('ZIP', 'FOLDER', 'OTHER')),
    CONSTRAINT ck_source_bundle_no_self_reference CHECK (parent_bundle_id <> bundle_id),
    CONSTRAINT ck_source_bundle_zip_preserved CHECK (bundle_type <> 'ZIP' OR archive_asset_id IS NOT NULL)
);

COMMENT ON TABLE mqi.source_bundle IS '원본 자료 묶음';

COMMENT ON COLUMN mqi.source_bundle.bundle_id IS 'PK';

COMMENT ON COLUMN mqi.source_bundle.ingest_id IS 'FK → source_ingest';

COMMENT ON COLUMN mqi.source_bundle.parent_bundle_id IS '상위 자료 묶음 FK';

COMMENT ON COLUMN mqi.source_bundle.bundle_name IS '묶음 이름';

COMMENT ON COLUMN mqi.source_bundle.bundle_type IS 'ZIP / FOLDER / OTHER';

COMMENT ON COLUMN mqi.source_bundle.original_path IS '원본 상대경로 또는 위치';

COMMENT ON COLUMN mqi.source_bundle.raw_date_hint IS '폴더명 등에서 추출한 날짜 문자열';

COMMENT ON COLUMN mqi.source_bundle.date_hint_type IS '날짜 힌트 유형';

COMMENT ON COLUMN mqi.source_bundle.remark IS '비고';

COMMENT ON COLUMN mqi.source_bundle.archive_asset_id IS 'ZIP 자체의 원본 Asset; ZIP 묶음에서 필수, 내부 파일과 구분';

COMMENT ON COLUMN mqi.source_bundle.recorded_at IS 'DB 최초 저장 시각; 실제 제조/관측 시각과 다름';

COMMENT ON COLUMN mqi.source_bundle.updated_at IS 'DB 최종 변경 시각';

COMMENT ON COLUMN mqi.source_bundle.row_version IS '시스템 변경 버전; 원본 개정번호 아님';

COMMENT ON COLUMN mqi.source_bundle.record_state IS 'ACTIVE / VOID; VOID는 보존된 무효 기록, 참조 삭제 안 함';

CREATE TABLE mqi.source_asset (
    asset_id UUID DEFAULT gen_random_uuid() NOT NULL,
    sha256_hash CHAR(64) NOT NULL,
    asset_type VARCHAR(30) NOT NULL,
    mime_type VARCHAR(150),
    file_size_bytes BIGINT NOT NULL,
    storage_key TEXT NOT NULL,
    created_at TIMESTAMPTZ DEFAULT clock_timestamp() NOT NULL,
    remark TEXT,
    recorded_at TIMESTAMPTZ DEFAULT clock_timestamp() NOT NULL,
    updated_at TIMESTAMPTZ DEFAULT clock_timestamp() NOT NULL,
    row_version BIGINT DEFAULT 1 NOT NULL,
    record_state VARCHAR(10) DEFAULT 'ACTIVE' NOT NULL,
    CONSTRAINT pk_source_asset_ PRIMARY KEY (asset_id),
    CONSTRAINT uq_source_asset_sha256_hash UNIQUE (sha256_hash),
    CONSTRAINT uq_source_asset_storage_key UNIQUE (storage_key),
    CONSTRAINT ck_source_asset_row_version_positive CHECK (row_version > 0),
    CONSTRAINT ck_source_asset_record_state_code CHECK (record_state IN ('ACTIVE', 'VOID')),
    CONSTRAINT ck_source_asset_file_size_bytes_nonnegative CHECK (file_size_bytes >= 0),
    CONSTRAINT ck_source_asset_asset_type_code CHECK (asset_type IN ('PDF', 'IMAGE', 'EXCEL', 'ZIP', 'OTHER')),
    CONSTRAINT ck_source_asset_sha256_format CHECK (sha256_hash ~ '^[0-9a-f]{64}$'),
    CONSTRAINT ck_source_asset_storage_key_nonempty CHECK (btrim(storage_key) <> '')
);

COMMENT ON TABLE mqi.source_asset IS '원본 파일 식별';

COMMENT ON COLUMN mqi.source_asset.asset_id IS 'PK';

COMMENT ON COLUMN mqi.source_asset.sha256_hash IS '파일 내용 기반 SHA-256';

COMMENT ON COLUMN mqi.source_asset.asset_type IS 'PDF / IMAGE / EXCEL / OTHER';

COMMENT ON COLUMN mqi.source_asset.mime_type IS 'MIME 유형';

COMMENT ON COLUMN mqi.source_asset.file_size_bytes IS '파일 크기';

COMMENT ON COLUMN mqi.source_asset.storage_key IS '비공개 원본파일 저장 위치';

COMMENT ON COLUMN mqi.source_asset.created_at IS '시스템에 최초 등록한 시각';

COMMENT ON COLUMN mqi.source_asset.remark IS '비고';

COMMENT ON COLUMN mqi.source_asset.recorded_at IS 'DB 최초 저장 시각; 실제 제조/관측 시각과 다름';

COMMENT ON COLUMN mqi.source_asset.updated_at IS 'DB 최종 변경 시각';

COMMENT ON COLUMN mqi.source_asset.row_version IS '시스템 변경 버전; 원본 개정번호 아님';

COMMENT ON COLUMN mqi.source_asset.record_state IS 'ACTIVE / VOID; VOID는 보존된 무효 기록, 참조 삭제 안 함';

CREATE TABLE mqi.source_bundle_asset (
    bundle_asset_id UUID DEFAULT gen_random_uuid() NOT NULL,
    bundle_id UUID NOT NULL,
    asset_id UUID NOT NULL,
    original_filename VARCHAR(255) NOT NULL,
    relative_path TEXT NOT NULL,
    file_modified_at TIMESTAMPTZ,
    exif_taken_at_raw VARCHAR(100),
    raw_metadata JSONB,
    remark TEXT,
    recorded_at TIMESTAMPTZ DEFAULT clock_timestamp() NOT NULL,
    updated_at TIMESTAMPTZ DEFAULT clock_timestamp() NOT NULL,
    row_version BIGINT DEFAULT 1 NOT NULL,
    record_state VARCHAR(10) DEFAULT 'ACTIVE' NOT NULL,
    CONSTRAINT pk_source_bundle_asset_ PRIMARY KEY (bundle_asset_id),
    CONSTRAINT uq_source_bundle_asset_bundle_id_relative_path UNIQUE (bundle_id, relative_path),
    CONSTRAINT uq_source_bundle_asset_bundle_asset_id_asset_id UNIQUE (bundle_asset_id, asset_id),
    CONSTRAINT ck_source_bundle_asset_row_version_positive CHECK (row_version > 0),
    CONSTRAINT ck_source_bundle_asset_record_state_code CHECK (record_state IN ('ACTIVE', 'VOID'))
);

COMMENT ON TABLE mqi.source_bundle_asset IS '자료 묶음과 개별 파일';

COMMENT ON COLUMN mqi.source_bundle_asset.bundle_asset_id IS 'PK';

COMMENT ON COLUMN mqi.source_bundle_asset.bundle_id IS 'FK → source_bundle';

COMMENT ON COLUMN mqi.source_bundle_asset.asset_id IS 'FK → source_asset';

COMMENT ON COLUMN mqi.source_bundle_asset.original_filename IS '수집 당시 파일명';

COMMENT ON COLUMN mqi.source_bundle_asset.relative_path IS '묶음 내부 상대경로';

COMMENT ON COLUMN mqi.source_bundle_asset.file_modified_at IS '원본 파일시스템 수정시각';

COMMENT ON COLUMN mqi.source_bundle_asset.exif_taken_at_raw IS '사진 EXIF 촬영시각 원본';

COMMENT ON COLUMN mqi.source_bundle_asset.raw_metadata IS '기타 파일 메타데이터';

COMMENT ON COLUMN mqi.source_bundle_asset.remark IS '비고';

COMMENT ON COLUMN mqi.source_bundle_asset.recorded_at IS 'DB 최초 저장 시각; 실제 제조/관측 시각과 다름';

COMMENT ON COLUMN mqi.source_bundle_asset.updated_at IS 'DB 최종 변경 시각';

COMMENT ON COLUMN mqi.source_bundle_asset.row_version IS '시스템 변경 버전; 원본 개정번호 아님';

COMMENT ON COLUMN mqi.source_bundle_asset.record_state IS 'ACTIVE / VOID; VOID는 보존된 무효 기록, 참조 삭제 안 함';

CREATE TABLE mqi.source_document (
    document_id UUID DEFAULT gen_random_uuid() NOT NULL,
    document_type VARCHAR(50) NOT NULL,
    document_title VARCHAR(255),
    document_reference VARCHAR(150),
    validation_status VARCHAR(30) NOT NULL,
    remark TEXT,
    recorded_at TIMESTAMPTZ DEFAULT clock_timestamp() NOT NULL,
    updated_at TIMESTAMPTZ DEFAULT clock_timestamp() NOT NULL,
    row_version BIGINT DEFAULT 1 NOT NULL,
    record_state VARCHAR(10) DEFAULT 'ACTIVE' NOT NULL,
    CONSTRAINT pk_source_document_ PRIMARY KEY (document_id),
    CONSTRAINT ck_source_document_row_version_positive CHECK (row_version > 0),
    CONSTRAINT ck_source_document_record_state_code CHECK (record_state IN ('ACTIVE', 'VOID')),
    CONSTRAINT ck_source_document_validation_status_code CHECK (validation_status IN ('UNVERIFIED', 'VERIFIED', 'NEEDS_REVIEW', 'REJECTED')),
    CONSTRAINT ck_source_document_document_type_code CHECK (document_type IN ('PRODUCTION_JOURNAL', 'INJECTION_CONDITION', 'INSPECTION_JOURNAL', 'REWORK_EXCEL', 'ASSEMBLY_CARD', 'QUALITY_RECORD', 'OTHER'))
);

COMMENT ON TABLE mqi.source_document IS '논리적 원본문서';

COMMENT ON COLUMN mqi.source_document.document_id IS 'PK';

COMMENT ON COLUMN mqi.source_document.document_type IS '문서 유형';

COMMENT ON COLUMN mqi.source_document.document_title IS '확인된 문서 제목';

COMMENT ON COLUMN mqi.source_document.document_reference IS '원본 문서 식별정보';

COMMENT ON COLUMN mqi.source_document.validation_status IS '문서 식별 검증상태';

COMMENT ON COLUMN mqi.source_document.remark IS '비고';

COMMENT ON COLUMN mqi.source_document.recorded_at IS 'DB 최초 저장 시각; 실제 제조/관측 시각과 다름';

COMMENT ON COLUMN mqi.source_document.updated_at IS 'DB 최종 변경 시각';

COMMENT ON COLUMN mqi.source_document.row_version IS '시스템 변경 버전; 원본 개정번호 아님';

COMMENT ON COLUMN mqi.source_document.record_state IS 'ACTIVE / VOID; VOID는 보존된 무효 기록, 참조 삭제 안 함';

CREATE TABLE mqi.source_document_version (
    document_version_id UUID DEFAULT gen_random_uuid() NOT NULL,
    document_id UUID NOT NULL,
    asset_id UUID NOT NULL,
    template_id UUID,
    version_sequence INTEGER NOT NULL,
    original_revision_raw VARCHAR(100),
    validation_status VARCHAR(30) NOT NULL,
    remark TEXT,
    recorded_at TIMESTAMPTZ DEFAULT clock_timestamp() NOT NULL,
    updated_at TIMESTAMPTZ DEFAULT clock_timestamp() NOT NULL,
    row_version BIGINT DEFAULT 1 NOT NULL,
    record_state VARCHAR(10) DEFAULT 'ACTIVE' NOT NULL,
    CONSTRAINT pk_source_document_version_ PRIMARY KEY (document_version_id),
    CONSTRAINT uq_source_document_version_document_id_version_sequence UNIQUE (document_id, version_sequence),
    CONSTRAINT ck_source_document_version_row_version_positive CHECK (row_version > 0),
    CONSTRAINT ck_source_document_version_record_state_code CHECK (record_state IN ('ACTIVE', 'VOID')),
    CONSTRAINT ck_source_document_version_version_sequence_positive CHECK (version_sequence > 0),
    CONSTRAINT ck_source_document_version_validation_status_code CHECK (validation_status IN ('UNVERIFIED', 'VERIFIED', 'NEEDS_REVIEW', 'REJECTED'))
);

COMMENT ON TABLE mqi.source_document_version IS '원본문서 버전';

COMMENT ON COLUMN mqi.source_document_version.document_version_id IS 'PK';

COMMENT ON COLUMN mqi.source_document_version.document_id IS 'FK → source_document';

COMMENT ON COLUMN mqi.source_document_version.asset_id IS '해당 버전의 원본파일 FK';

COMMENT ON COLUMN mqi.source_document_version.template_id IS '확인된 서식 FK';

COMMENT ON COLUMN mqi.source_document_version.version_sequence IS '시스템 내부 문서 버전 순번';

COMMENT ON COLUMN mqi.source_document_version.original_revision_raw IS '원본에 적힌 개정정보';

COMMENT ON COLUMN mqi.source_document_version.validation_status IS '버전 검증상태';

COMMENT ON COLUMN mqi.source_document_version.remark IS '비고';

COMMENT ON COLUMN mqi.source_document_version.recorded_at IS 'DB 최초 저장 시각; 실제 제조/관측 시각과 다름';

COMMENT ON COLUMN mqi.source_document_version.updated_at IS 'DB 최종 변경 시각';

COMMENT ON COLUMN mqi.source_document_version.row_version IS '시스템 변경 버전; 원본 개정번호 아님';

COMMENT ON COLUMN mqi.source_document_version.record_state IS 'ACTIVE / VOID; VOID는 보존된 무효 기록, 참조 삭제 안 함';

CREATE TABLE mqi.source_page (
    source_page_id UUID DEFAULT gen_random_uuid() NOT NULL,
    asset_id UUID NOT NULL,
    page_number INTEGER NOT NULL,
    raw_page_label VARCHAR(50),
    remark TEXT,
    recorded_at TIMESTAMPTZ DEFAULT clock_timestamp() NOT NULL,
    updated_at TIMESTAMPTZ DEFAULT clock_timestamp() NOT NULL,
    row_version BIGINT DEFAULT 1 NOT NULL,
    record_state VARCHAR(10) DEFAULT 'ACTIVE' NOT NULL,
    CONSTRAINT pk_source_page_ PRIMARY KEY (source_page_id),
    CONSTRAINT uq_source_page_asset_id_page_number UNIQUE (asset_id, page_number),
    CONSTRAINT uq_source_page_source_page_id_asset_id UNIQUE (source_page_id, asset_id),
    CONSTRAINT ck_source_page_row_version_positive CHECK (row_version > 0),
    CONSTRAINT ck_source_page_record_state_code CHECK (record_state IN ('ACTIVE', 'VOID')),
    CONSTRAINT ck_source_page_page_number_positive CHECK (page_number > 0)
);

COMMENT ON TABLE mqi.source_page IS '원본파일의 페이지';

COMMENT ON COLUMN mqi.source_page.source_page_id IS 'PK';

COMMENT ON COLUMN mqi.source_page.asset_id IS 'FK → source_asset';

COMMENT ON COLUMN mqi.source_page.page_number IS '1부터 시작하는 원본파일 페이지 번호';

COMMENT ON COLUMN mqi.source_page.raw_page_label IS '원본에 인쇄된 페이지 표기';

COMMENT ON COLUMN mqi.source_page.remark IS '비고';

COMMENT ON COLUMN mqi.source_page.recorded_at IS 'DB 최초 저장 시각; 실제 제조/관측 시각과 다름';

COMMENT ON COLUMN mqi.source_page.updated_at IS 'DB 최종 변경 시각';

COMMENT ON COLUMN mqi.source_page.row_version IS '시스템 변경 버전; 원본 개정번호 아님';

COMMENT ON COLUMN mqi.source_page.record_state IS 'ACTIVE / VOID; VOID는 보존된 무효 기록, 참조 삭제 안 함';

CREATE TABLE mqi.form_template (
    template_id UUID DEFAULT gen_random_uuid() NOT NULL,
    template_code VARCHAR(100) NOT NULL,
    template_name VARCHAR(150) NOT NULL,
    template_version VARCHAR(50),
    process_id UUID,
    description TEXT,
    is_active BOOLEAN DEFAULT TRUE NOT NULL,
    recorded_at TIMESTAMPTZ DEFAULT clock_timestamp() NOT NULL,
    updated_at TIMESTAMPTZ DEFAULT clock_timestamp() NOT NULL,
    row_version BIGINT DEFAULT 1 NOT NULL,
    record_state VARCHAR(10) DEFAULT 'ACTIVE' NOT NULL,
    CONSTRAINT pk_form_template_ PRIMARY KEY (template_id),
    CONSTRAINT uq_form_template_template_code UNIQUE (template_code),
    CONSTRAINT ck_form_template_row_version_positive CHECK (row_version > 0),
    CONSTRAINT ck_form_template_record_state_code CHECK (record_state IN ('ACTIVE', 'VOID'))
);

COMMENT ON TABLE mqi.form_template IS '문서 서식';

COMMENT ON COLUMN mqi.form_template.template_id IS 'PK';

COMMENT ON COLUMN mqi.form_template.template_code IS '서식 식별코드';

COMMENT ON COLUMN mqi.form_template.template_name IS '서식 이름';

COMMENT ON COLUMN mqi.form_template.template_version IS '서식 버전';

COMMENT ON COLUMN mqi.form_template.process_id IS '적용 공정 FK';

COMMENT ON COLUMN mqi.form_template.description IS '서식 설명';

COMMENT ON COLUMN mqi.form_template.is_active IS '사용 여부';

COMMENT ON COLUMN mqi.form_template.recorded_at IS 'DB 최초 저장 시각; 실제 제조/관측 시각과 다름';

COMMENT ON COLUMN mqi.form_template.updated_at IS 'DB 최종 변경 시각';

COMMENT ON COLUMN mqi.form_template.row_version IS '시스템 변경 버전; 원본 개정번호 아님';

COMMENT ON COLUMN mqi.form_template.record_state IS 'ACTIVE / VOID; VOID는 보존된 무효 기록, 참조 삭제 안 함';

CREATE TABLE mqi.form_field_definition (
    form_field_id UUID DEFAULT gen_random_uuid() NOT NULL,
    template_id UUID NOT NULL,
    field_code VARCHAR(100) NOT NULL,
    field_label VARCHAR(150),
    value_kind VARCHAR(30),
    unit VARCHAR(30),
    is_required BOOLEAN NOT NULL,
    description TEXT,
    recorded_at TIMESTAMPTZ DEFAULT clock_timestamp() NOT NULL,
    updated_at TIMESTAMPTZ DEFAULT clock_timestamp() NOT NULL,
    row_version BIGINT DEFAULT 1 NOT NULL,
    record_state VARCHAR(10) DEFAULT 'ACTIVE' NOT NULL,
    CONSTRAINT pk_form_field_definition_ PRIMARY KEY (form_field_id),
    CONSTRAINT uq_form_field_definition_template_id_field_code UNIQUE (template_id, field_code),
    CONSTRAINT ck_form_field_definition_row_version_positive CHECK (row_version > 0),
    CONSTRAINT ck_form_field_definition_record_state_code CHECK (record_state IN ('ACTIVE', 'VOID'))
);

COMMENT ON TABLE mqi.form_field_definition IS '서식 항목 정의';

COMMENT ON COLUMN mqi.form_field_definition.form_field_id IS 'PK';

COMMENT ON COLUMN mqi.form_field_definition.template_id IS 'FK → form_template';

COMMENT ON COLUMN mqi.form_field_definition.field_code IS '필드 식별코드';

COMMENT ON COLUMN mqi.form_field_definition.field_label IS '서식상 표기명';

COMMENT ON COLUMN mqi.form_field_definition.value_kind IS '숫자·문자·날짜 등';

COMMENT ON COLUMN mqi.form_field_definition.unit IS '표시단위';

COMMENT ON COLUMN mqi.form_field_definition.is_required IS '서식상 필수 여부';

COMMENT ON COLUMN mqi.form_field_definition.description IS '항목 설명';

COMMENT ON COLUMN mqi.form_field_definition.recorded_at IS 'DB 최초 저장 시각; 실제 제조/관측 시각과 다름';

COMMENT ON COLUMN mqi.form_field_definition.updated_at IS 'DB 최종 변경 시각';

COMMENT ON COLUMN mqi.form_field_definition.row_version IS '시스템 변경 버전; 원본 개정번호 아님';

COMMENT ON COLUMN mqi.form_field_definition.record_state IS 'ACTIVE / VOID; VOID는 보존된 무효 기록, 참조 삭제 안 함';

CREATE TABLE mqi.source_location (
    source_location_id UUID DEFAULT gen_random_uuid() NOT NULL,
    bundle_asset_id UUID NOT NULL,
    source_page_id UUID,
    locator_type VARCHAR(30) NOT NULL,
    sheet_name VARCHAR(150),
    cell_reference VARCHAR(100),
    region_json JSONB,
    source_label VARCHAR(150),
    remark TEXT,
    asset_id UUID NOT NULL,
    recorded_at TIMESTAMPTZ DEFAULT clock_timestamp() NOT NULL,
    updated_at TIMESTAMPTZ DEFAULT clock_timestamp() NOT NULL,
    row_version BIGINT DEFAULT 1 NOT NULL,
    record_state VARCHAR(10) DEFAULT 'ACTIVE' NOT NULL,
    CONSTRAINT pk_source_location_ PRIMARY KEY (source_location_id),
    CONSTRAINT uq_source_location_source_location_id_bundle_asset_id UNIQUE (source_location_id, bundle_asset_id),
    CONSTRAINT ck_source_location_row_version_positive CHECK (row_version > 0),
    CONSTRAINT ck_source_location_record_state_code CHECK (record_state IN ('ACTIVE', 'VOID')),
    CONSTRAINT ck_source_location_locator_type_code CHECK (locator_type IN ('FILE', 'PDF_PAGE', 'PDF_REGION', 'EXCEL_CELL', 'EXCEL_RANGE', 'IMAGE_REGION')),
    CONSTRAINT ck_source_location_pdf_page_required CHECK (locator_type NOT IN ('PDF_PAGE','PDF_REGION') OR source_page_id IS NOT NULL),
    CONSTRAINT ck_source_location_excel_location CHECK (locator_type NOT IN ('EXCEL_CELL','EXCEL_RANGE') OR (sheet_name IS NOT NULL AND btrim(sheet_name) <> '' AND cell_reference IS NOT NULL AND btrim(cell_reference) <> '')),
    CONSTRAINT ck_source_location_region_required CHECK (locator_type NOT IN ('PDF_REGION','IMAGE_REGION') OR (region_json IS NOT NULL AND jsonb_typeof(region_json) = 'object' AND region_json ?& ARRAY['coordinate_system','width','height','bounds']))
);

COMMENT ON TABLE mqi.source_location IS '원본 필드의 위치';

COMMENT ON COLUMN mqi.source_location.source_location_id IS 'PK';

COMMENT ON COLUMN mqi.source_location.bundle_asset_id IS 'FK → source_bundle_asset';

COMMENT ON COLUMN mqi.source_location.source_page_id IS 'PDF 페이지 FK';

COMMENT ON COLUMN mqi.source_location.locator_type IS '위치 표현 유형';

COMMENT ON COLUMN mqi.source_location.sheet_name IS 'Excel 시트 이름';

COMMENT ON COLUMN mqi.source_location.cell_reference IS 'Excel 셀 또는 범위';

COMMENT ON COLUMN mqi.source_location.region_json IS '사진·PDF 영역 좌표';

COMMENT ON COLUMN mqi.source_location.source_label IS '원본의 항목명';

COMMENT ON COLUMN mqi.source_location.remark IS '비고';

COMMENT ON COLUMN mqi.source_location.asset_id IS 'bundle_asset_id의 파일 식별자; 페이지 일치 복합 FK용';

COMMENT ON COLUMN mqi.source_location.recorded_at IS 'DB 최초 저장 시각; 실제 제조/관측 시각과 다름';

COMMENT ON COLUMN mqi.source_location.updated_at IS 'DB 최종 변경 시각';

COMMENT ON COLUMN mqi.source_location.row_version IS '시스템 변경 버전; 원본 개정번호 아님';

COMMENT ON COLUMN mqi.source_location.record_state IS 'ACTIVE / VOID; VOID는 보존된 무효 기록, 참조 삭제 안 함';

CREATE TABLE mqi.extraction_run (
    extraction_run_id UUID DEFAULT gen_random_uuid() NOT NULL,
    bundle_asset_id UUID NOT NULL,
    extraction_method VARCHAR(30) NOT NULL,
    model_name VARCHAR(150),
    prompt_version VARCHAR(100),
    parser_version VARCHAR(100),
    started_at TIMESTAMPTZ NOT NULL,
    completed_at TIMESTAMPTZ,
    extraction_status VARCHAR(30) NOT NULL,
    remark TEXT,
    recorded_at TIMESTAMPTZ DEFAULT clock_timestamp() NOT NULL,
    updated_at TIMESTAMPTZ DEFAULT clock_timestamp() NOT NULL,
    row_version BIGINT DEFAULT 1 NOT NULL,
    record_state VARCHAR(10) DEFAULT 'ACTIVE' NOT NULL,
    CONSTRAINT pk_extraction_run_ PRIMARY KEY (extraction_run_id),
    CONSTRAINT uq_extraction_run_extraction_run_id_bundle_asset_id UNIQUE (extraction_run_id, bundle_asset_id),
    CONSTRAINT ck_extraction_run_row_version_positive CHECK (row_version > 0),
    CONSTRAINT ck_extraction_run_record_state_code CHECK (record_state IN ('ACTIVE', 'VOID')),
    CONSTRAINT ck_extraction_run_completed_at_order CHECK (completed_at >= started_at),
    CONSTRAINT ck_extraction_run_extraction_method_code CHECK (extraction_method IN ('OCR', 'VISION_LLM', 'DOCUMENT_PARSER', 'EXCEL_PARSER', 'MANUAL')),
    CONSTRAINT ck_extraction_run_extraction_status_code CHECK (extraction_status IN ('RUNNING', 'COMPLETED', 'PARTIAL', 'FAILED'))
);

COMMENT ON TABLE mqi.extraction_run IS 'AI 추출 실행이력';

COMMENT ON COLUMN mqi.extraction_run.extraction_run_id IS 'PK';

COMMENT ON COLUMN mqi.extraction_run.bundle_asset_id IS '처리 대상 파일 FK';

COMMENT ON COLUMN mqi.extraction_run.extraction_method IS '추출 방식';

COMMENT ON COLUMN mqi.extraction_run.model_name IS '사용한 AI 모델';

COMMENT ON COLUMN mqi.extraction_run.prompt_version IS '추출 프롬프트 버전';

COMMENT ON COLUMN mqi.extraction_run.parser_version IS '파서 버전';

COMMENT ON COLUMN mqi.extraction_run.started_at IS '추출 시작시각';

COMMENT ON COLUMN mqi.extraction_run.completed_at IS '추출 완료시각';

COMMENT ON COLUMN mqi.extraction_run.extraction_status IS '실행상태';

COMMENT ON COLUMN mqi.extraction_run.remark IS '비고';

COMMENT ON COLUMN mqi.extraction_run.recorded_at IS 'DB 최초 저장 시각; 실제 제조/관측 시각과 다름';

COMMENT ON COLUMN mqi.extraction_run.updated_at IS 'DB 최종 변경 시각';

COMMENT ON COLUMN mqi.extraction_run.row_version IS '시스템 변경 버전; 원본 개정번호 아님';

COMMENT ON COLUMN mqi.extraction_run.record_state IS 'ACTIVE / VOID; VOID는 보존된 무효 기록, 참조 삭제 안 함';

CREATE TABLE mqi.extracted_field (
    extracted_field_id UUID DEFAULT gen_random_uuid() NOT NULL,
    extraction_run_id UUID NOT NULL,
    source_location_id UUID NOT NULL,
    form_field_id UUID,
    field_code VARCHAR(100) NOT NULL,
    raw_value TEXT,
    extracted_value TEXT,
    raw_formula_text TEXT,
    confidence NUMERIC(5,4),
    validation_status VARCHAR(30) NOT NULL,
    extracted_at TIMESTAMPTZ NOT NULL,
    remark TEXT,
    bundle_asset_id UUID NOT NULL,
    current_review_id UUID,
    recorded_at TIMESTAMPTZ DEFAULT clock_timestamp() NOT NULL,
    updated_at TIMESTAMPTZ DEFAULT clock_timestamp() NOT NULL,
    row_version BIGINT DEFAULT 1 NOT NULL,
    record_state VARCHAR(10) DEFAULT 'ACTIVE' NOT NULL,
    CONSTRAINT pk_extracted_field_ PRIMARY KEY (extracted_field_id),
    CONSTRAINT ck_extracted_field_row_version_positive CHECK (row_version > 0),
    CONSTRAINT ck_extracted_field_record_state_code CHECK (record_state IN ('ACTIVE', 'VOID')),
    CONSTRAINT ck_extracted_field_confidence_finite CHECK (confidence NOT IN ('NaN'::numeric, 'Infinity'::numeric, '-Infinity'::numeric)),
    CONSTRAINT ck_extracted_field_confidence_range CHECK (confidence BETWEEN 0 AND 1),
    CONSTRAINT ck_extracted_field_validation_status_code CHECK (validation_status IN ('UNREVIEWED', 'VERIFIED', 'CORRECTED', 'REJECTED', 'NEEDS_REVIEW')),
    CONSTRAINT ck_extracted_field_review_state CHECK ((current_review_id IS NULL AND validation_status = 'UNREVIEWED') OR (current_review_id IS NOT NULL AND validation_status <> 'UNREVIEWED'))
);

COMMENT ON TABLE mqi.extracted_field IS '원본 필드 추출값';

COMMENT ON COLUMN mqi.extracted_field.extracted_field_id IS 'PK';

COMMENT ON COLUMN mqi.extracted_field.extraction_run_id IS 'FK → extraction_run';

COMMENT ON COLUMN mqi.extracted_field.source_location_id IS 'FK → source_location';

COMMENT ON COLUMN mqi.extracted_field.form_field_id IS '확인된 서식 필드 FK';

COMMENT ON COLUMN mqi.extracted_field.field_code IS '추출 항목 코드';

COMMENT ON COLUMN mqi.extracted_field.raw_value IS '원본에서 인식한 기재내용';

COMMENT ON COLUMN mqi.extracted_field.extracted_value IS 'AI·파서가 정규화한 값';

COMMENT ON COLUMN mqi.extracted_field.raw_formula_text IS 'Excel 수식 원본';

COMMENT ON COLUMN mqi.extracted_field.confidence IS '추출 신뢰도';

COMMENT ON COLUMN mqi.extracted_field.validation_status IS '검증상태';

COMMENT ON COLUMN mqi.extracted_field.extracted_at IS '추출시각';

COMMENT ON COLUMN mqi.extracted_field.remark IS '비고';

COMMENT ON COLUMN mqi.extracted_field.bundle_asset_id IS '추출 실행과 원본 위치의 동일 수집 맥락 검증용';

COMMENT ON COLUMN mqi.extracted_field.current_review_id IS '명시적으로 현재 채택한 검토; 최신 시각 자동 채택 금지';

COMMENT ON COLUMN mqi.extracted_field.recorded_at IS 'DB 최초 저장 시각; 실제 제조/관측 시각과 다름';

COMMENT ON COLUMN mqi.extracted_field.updated_at IS 'DB 최종 변경 시각';

COMMENT ON COLUMN mqi.extracted_field.row_version IS '시스템 변경 버전; 원본 개정번호 아님';

COMMENT ON COLUMN mqi.extracted_field.record_state IS 'ACTIVE / VOID; VOID는 보존된 무효 기록, 참조 삭제 안 함';

CREATE TABLE mqi.field_review (
    field_review_id UUID DEFAULT gen_random_uuid() NOT NULL,
    extracted_field_id UUID NOT NULL,
    review_status VARCHAR(30) NOT NULL,
    reviewed_value TEXT,
    review_reason_code VARCHAR(50),
    review_note TEXT,
    reviewer_ref VARCHAR(100),
    reviewed_at TIMESTAMPTZ NOT NULL,
    recorded_at TIMESTAMPTZ DEFAULT clock_timestamp() NOT NULL,
    updated_at TIMESTAMPTZ DEFAULT clock_timestamp() NOT NULL,
    row_version BIGINT DEFAULT 1 NOT NULL,
    record_state VARCHAR(10) DEFAULT 'ACTIVE' NOT NULL,
    CONSTRAINT pk_field_review_ PRIMARY KEY (field_review_id),
    CONSTRAINT uq_field_review_field_review_id_extracted_field_id UNIQUE (field_review_id, extracted_field_id),
    CONSTRAINT ck_field_review_row_version_positive CHECK (row_version > 0),
    CONSTRAINT ck_field_review_record_state_code CHECK (record_state IN ('ACTIVE', 'VOID')),
    CONSTRAINT ck_field_review_review_status_code CHECK (review_status IN ('VERIFIED', 'CORRECTED', 'REJECTED', 'NEEDS_REVIEW')),
    CONSTRAINT ck_field_review_review_reason_code_code CHECK (review_reason_code IN ('EXTRACTION_ERROR', 'SOURCE_TYPO', 'FORMAT_ERROR', 'INCONSISTENT_SOURCE', 'OTHER'))
);

COMMENT ON TABLE mqi.field_review IS '필드 검증 이력';

COMMENT ON COLUMN mqi.field_review.field_review_id IS 'PK';

COMMENT ON COLUMN mqi.field_review.extracted_field_id IS 'FK → extracted_field';

COMMENT ON COLUMN mqi.field_review.review_status IS '검증결과';

COMMENT ON COLUMN mqi.field_review.reviewed_value IS '검증 후 확인한 값';

COMMENT ON COLUMN mqi.field_review.review_reason_code IS '수정 또는 제외 사유';

COMMENT ON COLUMN mqi.field_review.review_note IS '상세 검토내용';

COMMENT ON COLUMN mqi.field_review.reviewer_ref IS '검증자의 내부 식별자';

COMMENT ON COLUMN mqi.field_review.reviewed_at IS '검증시각';

COMMENT ON COLUMN mqi.field_review.recorded_at IS 'DB 최초 저장 시각; 실제 제조/관측 시각과 다름';

COMMENT ON COLUMN mqi.field_review.updated_at IS 'DB 최종 변경 시각';

COMMENT ON COLUMN mqi.field_review.row_version IS '시스템 변경 버전; 원본 개정번호 아님';

COMMENT ON COLUMN mqi.field_review.record_state IS 'ACTIVE / VOID; VOID는 보존된 무효 기록, 참조 삭제 안 함';

CREATE TABLE mqi.field_provenance_link (
    provenance_link_id UUID DEFAULT gen_random_uuid() NOT NULL,
    extracted_field_id UUID NOT NULL,
    field_review_id UUID,
    parameter_observation_id UUID,
    process_run_result_id UUID,
    measurement_id UUID,
    quality_finding_id UUID,
    inspection_lot_id UUID,
    rework_id UUID,
    material_usage_id UUID,
    process_run_lot_id UUID,
    production_run_id UUID,
    traceability_card_id UUID,
    spec_item_id UUID,
    quality_check_id UUID,
    target_column_name VARCHAR(100) NOT NULL,
    evidence_role VARCHAR(30) NOT NULL,
    remark TEXT,
    target_product_id UUID,
    target_model_id UUID,
    target_process_id UUID,
    target_line_id UUID,
    target_lot_id UUID,
    process_run_id UUID,
    target_equipment_id UUID,
    target_position_id UUID,
    target_equipment_connection_id UUID,
    target_equipment_usage_id UUID,
    target_parameter_id UUID,
    target_spec_id UUID,
    target_material_id UUID,
    target_material_lot_id UUID,
    target_worker_id UUID,
    target_assignment_id UUID,
    target_event_id UUID,
    inspection_run_id UUID,
    target_inspection_run_link_id UUID,
    target_defect_type_id UUID,
    target_scheme_id UUID,
    target_mapping_id UUID,
    target_rework_origin_link_id UUID,
    target_value_snapshot TEXT,
    recorded_at TIMESTAMPTZ DEFAULT clock_timestamp() NOT NULL,
    updated_at TIMESTAMPTZ DEFAULT clock_timestamp() NOT NULL,
    row_version BIGINT DEFAULT 1 NOT NULL,
    record_state VARCHAR(10) DEFAULT 'ACTIVE' NOT NULL,
    CONSTRAINT pk_field_provenance_link_ PRIMARY KEY (provenance_link_id),
    CONSTRAINT ck_field_provenance_link_row_version_positive CHECK (row_version > 0),
    CONSTRAINT ck_field_provenance_link_record_state_code CHECK (record_state IN ('ACTIVE', 'VOID')),
    CONSTRAINT ck_field_provenance_link_evidence_role_code CHECK (evidence_role IN ('PRIMARY', 'CROSS_CHECK', 'CONTRADICTORY')),
    CONSTRAINT ck_field_provenance_link_exactly_one_target CHECK (num_nonnulls(parameter_observation_id, process_run_result_id, measurement_id, quality_finding_id, inspection_lot_id, rework_id, material_usage_id, process_run_lot_id, production_run_id, traceability_card_id, spec_item_id, quality_check_id, target_product_id, target_model_id, target_process_id, target_line_id, target_lot_id, process_run_id, target_equipment_id, target_position_id, target_equipment_connection_id, target_equipment_usage_id, target_parameter_id, target_spec_id, target_material_id, target_material_lot_id, target_worker_id, target_assignment_id, target_event_id, inspection_run_id, target_inspection_run_link_id, target_defect_type_id, target_scheme_id, target_mapping_id, target_rework_origin_link_id) = 1),
    CONSTRAINT ck_field_provenance_link_primary_review_required CHECK (evidence_role <> 'PRIMARY' OR field_review_id IS NOT NULL)
);

COMMENT ON TABLE mqi.field_provenance_link IS '필드 단위 출처 연결';

COMMENT ON COLUMN mqi.field_provenance_link.provenance_link_id IS 'PK';

COMMENT ON COLUMN mqi.field_provenance_link.extracted_field_id IS 'FK → extracted_field';

COMMENT ON COLUMN mqi.field_provenance_link.field_review_id IS '채택한 검증 이력 FK';

COMMENT ON COLUMN mqi.field_provenance_link.parameter_observation_id IS 'FK → parameter_observation';

COMMENT ON COLUMN mqi.field_provenance_link.process_run_result_id IS 'FK → process_run_result';

COMMENT ON COLUMN mqi.field_provenance_link.measurement_id IS 'FK → measurement';

COMMENT ON COLUMN mqi.field_provenance_link.quality_finding_id IS 'FK → quality_finding';

COMMENT ON COLUMN mqi.field_provenance_link.inspection_lot_id IS 'FK → inspection_lot';

COMMENT ON COLUMN mqi.field_provenance_link.rework_id IS 'FK → rework_record';

COMMENT ON COLUMN mqi.field_provenance_link.material_usage_id IS 'FK → material_usage';

COMMENT ON COLUMN mqi.field_provenance_link.process_run_lot_id IS 'FK → process_run_lot';

COMMENT ON COLUMN mqi.field_provenance_link.production_run_id IS 'FK → production_run';

COMMENT ON COLUMN mqi.field_provenance_link.traceability_card_id IS 'FK → traceability_card';

COMMENT ON COLUMN mqi.field_provenance_link.spec_item_id IS 'FK → process_setup_spec_item';

COMMENT ON COLUMN mqi.field_provenance_link.quality_check_id IS 'FK → quality_check';

COMMENT ON COLUMN mqi.field_provenance_link.target_column_name IS '대상 업무 테이블 컬럼명';

COMMENT ON COLUMN mqi.field_provenance_link.evidence_role IS '근거의 역할';

COMMENT ON COLUMN mqi.field_provenance_link.remark IS '비고';

COMMENT ON COLUMN mqi.field_provenance_link.target_product_id IS 'FK → product; 35개 업무 대상 중 정확히 하나';

COMMENT ON COLUMN mqi.field_provenance_link.target_model_id IS 'FK → product_model; 35개 업무 대상 중 정확히 하나';

COMMENT ON COLUMN mqi.field_provenance_link.target_process_id IS 'FK → process; 35개 업무 대상 중 정확히 하나';

COMMENT ON COLUMN mqi.field_provenance_link.target_line_id IS 'FK → production_line; 35개 업무 대상 중 정확히 하나';

COMMENT ON COLUMN mqi.field_provenance_link.target_lot_id IS 'FK → production_lot; 35개 업무 대상 중 정확히 하나';

COMMENT ON COLUMN mqi.field_provenance_link.process_run_id IS 'FK → process_run; 35개 업무 대상 중 정확히 하나';

COMMENT ON COLUMN mqi.field_provenance_link.target_equipment_id IS 'FK → equipment; 35개 업무 대상 중 정확히 하나';

COMMENT ON COLUMN mqi.field_provenance_link.target_position_id IS 'FK → equipment_position; 35개 업무 대상 중 정확히 하나';

COMMENT ON COLUMN mqi.field_provenance_link.target_equipment_connection_id IS 'FK → equipment_connection; 35개 업무 대상 중 정확히 하나';

COMMENT ON COLUMN mqi.field_provenance_link.target_equipment_usage_id IS 'FK → process_equipment_usage; 35개 업무 대상 중 정확히 하나';

COMMENT ON COLUMN mqi.field_provenance_link.target_parameter_id IS 'FK → parameter_definition; 35개 업무 대상 중 정확히 하나';

COMMENT ON COLUMN mqi.field_provenance_link.target_spec_id IS 'FK → process_setup_spec; 35개 업무 대상 중 정확히 하나';

COMMENT ON COLUMN mqi.field_provenance_link.target_material_id IS 'FK → material; 35개 업무 대상 중 정확히 하나';

COMMENT ON COLUMN mqi.field_provenance_link.target_material_lot_id IS 'FK → material_lot; 35개 업무 대상 중 정확히 하나';

COMMENT ON COLUMN mqi.field_provenance_link.target_worker_id IS 'FK → worker; 35개 업무 대상 중 정확히 하나';

COMMENT ON COLUMN mqi.field_provenance_link.target_assignment_id IS 'FK → worker_assignment; 35개 업무 대상 중 정확히 하나';

COMMENT ON COLUMN mqi.field_provenance_link.target_event_id IS 'FK → production_event; 35개 업무 대상 중 정확히 하나';

COMMENT ON COLUMN mqi.field_provenance_link.inspection_run_id IS 'FK → inspection_run; 35개 업무 대상 중 정확히 하나';

COMMENT ON COLUMN mqi.field_provenance_link.target_inspection_run_link_id IS 'FK → inspection_run_link; 35개 업무 대상 중 정확히 하나';

COMMENT ON COLUMN mqi.field_provenance_link.target_defect_type_id IS 'FK → defect_type; 35개 업무 대상 중 정확히 하나';

COMMENT ON COLUMN mqi.field_provenance_link.target_scheme_id IS 'FK → lot_code_scheme; 35개 업무 대상 중 정확히 하나';

COMMENT ON COLUMN mqi.field_provenance_link.target_mapping_id IS 'FK → lot_code_mapping; 35개 업무 대상 중 정확히 하나';

COMMENT ON COLUMN mqi.field_provenance_link.target_rework_origin_link_id IS 'FK → rework_origin_link; 35개 업무 대상 중 정확히 하나';

COMMENT ON COLUMN mqi.field_provenance_link.target_value_snapshot IS '출처 연결 시점 업무값의 DB 정규화 텍스트; 서버 기록';

COMMENT ON COLUMN mqi.field_provenance_link.recorded_at IS 'DB 최초 저장 시각; 실제 제조/관측 시각과 다름';

COMMENT ON COLUMN mqi.field_provenance_link.updated_at IS 'DB 최종 변경 시각';

COMMENT ON COLUMN mqi.field_provenance_link.row_version IS '시스템 변경 버전; 원본 개정번호 아님';

COMMENT ON COLUMN mqi.field_provenance_link.record_state IS 'ACTIVE / VOID; VOID는 보존된 무효 기록, 참조 삭제 안 함';

CREATE TABLE mqi.source_run_link (
    source_run_link_id UUID DEFAULT gen_random_uuid() NOT NULL,
    bundle_asset_id UUID NOT NULL,
    source_page_id UUID,
    production_run_id UUID,
    process_run_id UUID,
    inspection_run_id UUID,
    linkage_status VARCHAR(30) NOT NULL,
    confidence NUMERIC(5,4),
    evidence_note TEXT,
    remark TEXT,
    asset_id UUID NOT NULL,
    recorded_at TIMESTAMPTZ DEFAULT clock_timestamp() NOT NULL,
    updated_at TIMESTAMPTZ DEFAULT clock_timestamp() NOT NULL,
    row_version BIGINT DEFAULT 1 NOT NULL,
    record_state VARCHAR(10) DEFAULT 'ACTIVE' NOT NULL,
    CONSTRAINT pk_source_run_link_ PRIMARY KEY (source_run_link_id),
    CONSTRAINT ck_source_run_link_row_version_positive CHECK (row_version > 0),
    CONSTRAINT ck_source_run_link_record_state_code CHECK (record_state IN ('ACTIVE', 'VOID')),
    CONSTRAINT ck_source_run_link_linkage_status_code CHECK (linkage_status IN ('CONFIRMED', 'CANDIDATE')),
    CONSTRAINT ck_source_run_link_confidence_finite CHECK (confidence NOT IN ('NaN'::numeric, 'Infinity'::numeric, '-Infinity'::numeric)),
    CONSTRAINT ck_source_run_link_confidence_range CHECK (confidence BETWEEN 0 AND 1),
    CONSTRAINT ck_source_run_link_exactly_one_target CHECK (num_nonnulls(production_run_id, process_run_id, inspection_run_id) = 1)
);

COMMENT ON TABLE mqi.source_run_link IS '원본과 실행이력 연결';

COMMENT ON COLUMN mqi.source_run_link.source_run_link_id IS 'PK';

COMMENT ON COLUMN mqi.source_run_link.bundle_asset_id IS 'FK → source_bundle_asset';

COMMENT ON COLUMN mqi.source_run_link.source_page_id IS '페이지가 식별된 경우 FK';

COMMENT ON COLUMN mqi.source_run_link.production_run_id IS 'FK → production_run';

COMMENT ON COLUMN mqi.source_run_link.process_run_id IS 'FK → process_run';

COMMENT ON COLUMN mqi.source_run_link.inspection_run_id IS 'FK → inspection_run';

COMMENT ON COLUMN mqi.source_run_link.linkage_status IS '연결 검증상태';

COMMENT ON COLUMN mqi.source_run_link.confidence IS '연결 신뢰도';

COMMENT ON COLUMN mqi.source_run_link.evidence_note IS '연결 근거';

COMMENT ON COLUMN mqi.source_run_link.remark IS '비고';

COMMENT ON COLUMN mqi.source_run_link.asset_id IS 'bundle_asset_id의 파일 식별자; 페이지 일치 복합 FK용';

COMMENT ON COLUMN mqi.source_run_link.recorded_at IS 'DB 최초 저장 시각; 실제 제조/관측 시각과 다름';

COMMENT ON COLUMN mqi.source_run_link.updated_at IS 'DB 최종 변경 시각';

COMMENT ON COLUMN mqi.source_run_link.row_version IS '시스템 변경 버전; 원본 개정번호 아님';

COMMENT ON COLUMN mqi.source_run_link.record_state IS 'ACTIVE / VOID; VOID는 보존된 무효 기록, 참조 삭제 안 함';

ALTER TABLE mqi.product_model ADD CONSTRAINT fk_product_model_product_id FOREIGN KEY (product_id) REFERENCES mqi.product (product_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.production_lot ADD CONSTRAINT fk_production_lot_model_id FOREIGN KEY (model_id) REFERENCES mqi.product_model (model_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

CREATE INDEX ix_production_lot_model_id_lot_date ON mqi.production_lot (model_id, lot_date);

ALTER TABLE mqi.production_run ADD CONSTRAINT fk_production_run_model_id FOREIGN KEY (model_id) REFERENCES mqi.product_model (model_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.production_run ADD CONSTRAINT fk_production_run_line_id FOREIGN KEY (line_id) REFERENCES mqi.production_line (line_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

CREATE INDEX ix_production_run_model_id_work_date ON mqi.production_run (model_id, work_date);

CREATE INDEX ix_production_run_line_id ON mqi.production_run (line_id);

ALTER TABLE mqi.process_run ADD CONSTRAINT fk_process_run_run_id FOREIGN KEY (run_id) REFERENCES mqi.production_run (run_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.process_run ADD CONSTRAINT fk_process_run_process_id FOREIGN KEY (process_id) REFERENCES mqi.process (process_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.process_run ADD CONSTRAINT fk_process_run_model_id FOREIGN KEY (model_id) REFERENCES mqi.product_model (model_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.process_run ADD CONSTRAINT fk_process_run_run_id_model_id FOREIGN KEY (run_id, model_id) REFERENCES mqi.production_run (run_id, model_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

CREATE INDEX ix_process_run_process_id_work_date ON mqi.process_run (process_id, work_date);

CREATE INDEX ix_process_run_run_id_model_id ON mqi.process_run (run_id, model_id);

CREATE INDEX ix_process_run_model_id ON mqi.process_run (model_id);

ALTER TABLE mqi.process_run_result ADD CONSTRAINT fk_process_run_result_process_run_id FOREIGN KEY (process_run_id) REFERENCES mqi.process_run (process_run_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.process_run_lot ADD CONSTRAINT fk_process_run_lot_process_run_id FOREIGN KEY (process_run_id) REFERENCES mqi.process_run (process_run_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.process_run_lot ADD CONSTRAINT fk_process_run_lot_production_lot_id FOREIGN KEY (production_lot_id) REFERENCES mqi.production_lot (lot_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.process_run_lot ADD CONSTRAINT fk_process_run_lot_model_id FOREIGN KEY (model_id) REFERENCES mqi.product_model (model_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.process_run_lot ADD CONSTRAINT fk_process_run_lot_process_run_id_model_id FOREIGN KEY (process_run_id, model_id) REFERENCES mqi.process_run (process_run_id, model_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.process_run_lot ADD CONSTRAINT fk_process_run_lot_production_lot_id_model_id FOREIGN KEY (production_lot_id, model_id) REFERENCES mqi.production_lot (lot_id, model_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

CREATE INDEX ix_process_run_lot_process_run_id_model_id ON mqi.process_run_lot (process_run_id, model_id);

CREATE INDEX ix_process_run_lot_production_lot_id_model_id ON mqi.process_run_lot (production_lot_id, model_id);

CREATE INDEX ix_process_run_lot_model_id ON mqi.process_run_lot (model_id);

ALTER TABLE mqi.equipment ADD CONSTRAINT fk_equipment_line_id FOREIGN KEY (line_id) REFERENCES mqi.production_line (line_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

CREATE INDEX ix_equipment_line_id ON mqi.equipment (line_id);

ALTER TABLE mqi.equipment_position ADD CONSTRAINT fk_equipment_position_equipment_id FOREIGN KEY (equipment_id) REFERENCES mqi.equipment (equipment_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.equipment_connection ADD CONSTRAINT fk_equipment_connection_host_equipment_id FOREIGN KEY (host_equipment_id) REFERENCES mqi.equipment (equipment_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.equipment_connection ADD CONSTRAINT fk_equipment_connection_connected_equipment_id FOREIGN KEY (connected_equipment_id) REFERENCES mqi.equipment (equipment_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

CREATE INDEX ix_equipment_connection_host_equipment_id ON mqi.equipment_connection (host_equipment_id);

CREATE INDEX ix_equipment_connection_connected_equipment_id ON mqi.equipment_connection (connected_equipment_id);

ALTER TABLE mqi.process_equipment_usage ADD CONSTRAINT fk_process_equipment_usage_process_run_id FOREIGN KEY (process_run_id) REFERENCES mqi.process_run (process_run_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.process_equipment_usage ADD CONSTRAINT fk_process_equipment_usage_equipment_id FOREIGN KEY (equipment_id) REFERENCES mqi.equipment (equipment_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

CREATE INDEX ix_process_equipment_usage_process_run_id ON mqi.process_equipment_usage (process_run_id);

CREATE INDEX ix_process_equipment_usage_equipment_id ON mqi.process_equipment_usage (equipment_id);

ALTER TABLE mqi.parameter_definition ADD CONSTRAINT fk_parameter_definition_process_id FOREIGN KEY (process_id) REFERENCES mqi.process (process_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

CREATE INDEX ix_parameter_definition_process_id ON mqi.parameter_definition (process_id);

ALTER TABLE mqi.process_setup_spec ADD CONSTRAINT fk_process_setup_spec_model_id FOREIGN KEY (model_id) REFERENCES mqi.product_model (model_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.process_setup_spec ADD CONSTRAINT fk_process_setup_spec_process_id FOREIGN KEY (process_id) REFERENCES mqi.process (process_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.process_setup_spec ADD CONSTRAINT fk_process_setup_spec_equipment_id FOREIGN KEY (equipment_id) REFERENCES mqi.equipment (equipment_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

CREATE INDEX ix_process_setup_spec_model_id ON mqi.process_setup_spec (model_id);

CREATE INDEX ix_process_setup_spec_process_id ON mqi.process_setup_spec (process_id);

CREATE INDEX ix_process_setup_spec_equipment_id ON mqi.process_setup_spec (equipment_id);

ALTER TABLE mqi.process_setup_spec_item ADD CONSTRAINT fk_process_setup_spec_item_spec_id FOREIGN KEY (spec_id) REFERENCES mqi.process_setup_spec (spec_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.process_setup_spec_item ADD CONSTRAINT fk_process_setup_spec_item_parameter_id FOREIGN KEY (parameter_id) REFERENCES mqi.parameter_definition (parameter_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.process_setup_spec_item ADD CONSTRAINT fk_process_setup_spec_item_position_id FOREIGN KEY (position_id) REFERENCES mqi.equipment_position (position_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

CREATE INDEX ix_process_setup_spec_item_spec_id ON mqi.process_setup_spec_item (spec_id);

CREATE INDEX ix_process_setup_spec_item_parameter_id ON mqi.process_setup_spec_item (parameter_id);

CREATE INDEX ix_process_setup_spec_item_position_id ON mqi.process_setup_spec_item (position_id);

ALTER TABLE mqi.parameter_observation ADD CONSTRAINT fk_parameter_observation_process_run_id FOREIGN KEY (process_run_id) REFERENCES mqi.process_run (process_run_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.parameter_observation ADD CONSTRAINT fk_parameter_observation_equipment_id FOREIGN KEY (equipment_id) REFERENCES mqi.equipment (equipment_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.parameter_observation ADD CONSTRAINT fk_parameter_observation_position_id FOREIGN KEY (position_id) REFERENCES mqi.equipment_position (position_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.parameter_observation ADD CONSTRAINT fk_parameter_observation_parameter_id FOREIGN KEY (parameter_id) REFERENCES mqi.parameter_definition (parameter_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.parameter_observation ADD CONSTRAINT fk_parameter_observation_position_id_equipment_id FOREIGN KEY (position_id, equipment_id) REFERENCES mqi.equipment_position (position_id, equipment_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

CREATE INDEX ix_parameter_observation_equipment_id_parameter_id_observed_at ON mqi.parameter_observation (equipment_id, parameter_id, observed_at);

CREATE INDEX ix_parameter_observation_position_id_equipment_id ON mqi.parameter_observation (position_id, equipment_id);

CREATE INDEX ix_parameter_observation_process_run_id ON mqi.parameter_observation (process_run_id);

CREATE INDEX ix_parameter_observation_parameter_id ON mqi.parameter_observation (parameter_id);

ALTER TABLE mqi.material_lot ADD CONSTRAINT fk_material_lot_material_id FOREIGN KEY (material_id) REFERENCES mqi.material (material_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

CREATE INDEX ix_material_lot_material_id ON mqi.material_lot (material_id);

ALTER TABLE mqi.material_usage ADD CONSTRAINT fk_material_usage_process_run_id FOREIGN KEY (process_run_id) REFERENCES mqi.process_run (process_run_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.material_usage ADD CONSTRAINT fk_material_usage_material_id FOREIGN KEY (material_id) REFERENCES mqi.material (material_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.material_usage ADD CONSTRAINT fk_material_usage_material_lot_id FOREIGN KEY (material_lot_id) REFERENCES mqi.material_lot (material_lot_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.material_usage ADD CONSTRAINT fk_material_usage_material_lot_id_material_id FOREIGN KEY (material_lot_id, material_id) REFERENCES mqi.material_lot (material_lot_id, material_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

CREATE INDEX ix_material_usage_material_lot_id_material_id ON mqi.material_usage (material_lot_id, material_id);

CREATE INDEX ix_material_usage_process_run_id ON mqi.material_usage (process_run_id);

CREATE INDEX ix_material_usage_material_id ON mqi.material_usage (material_id);

ALTER TABLE mqi.worker_assignment ADD CONSTRAINT fk_worker_assignment_worker_id FOREIGN KEY (worker_id) REFERENCES mqi.worker (worker_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.worker_assignment ADD CONSTRAINT fk_worker_assignment_production_run_id FOREIGN KEY (production_run_id) REFERENCES mqi.production_run (run_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.worker_assignment ADD CONSTRAINT fk_worker_assignment_process_run_id FOREIGN KEY (process_run_id) REFERENCES mqi.process_run (process_run_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

CREATE INDEX ix_worker_assignment_worker_id ON mqi.worker_assignment (worker_id);

CREATE INDEX ix_worker_assignment_production_run_id ON mqi.worker_assignment (production_run_id);

CREATE INDEX ix_worker_assignment_process_run_id ON mqi.worker_assignment (process_run_id);

ALTER TABLE mqi.production_event ADD CONSTRAINT fk_production_event_production_run_id FOREIGN KEY (production_run_id) REFERENCES mqi.production_run (run_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.production_event ADD CONSTRAINT fk_production_event_process_run_id FOREIGN KEY (process_run_id) REFERENCES mqi.process_run (process_run_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.production_event ADD CONSTRAINT fk_production_event_equipment_id FOREIGN KEY (equipment_id) REFERENCES mqi.equipment (equipment_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

CREATE INDEX ix_production_event_production_run_id ON mqi.production_event (production_run_id);

CREATE INDEX ix_production_event_process_run_id ON mqi.production_event (process_run_id);

CREATE INDEX ix_production_event_equipment_id ON mqi.production_event (equipment_id);

ALTER TABLE mqi.quality_check ADD CONSTRAINT fk_quality_check_model_id FOREIGN KEY (model_id) REFERENCES mqi.product_model (model_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.quality_check ADD CONSTRAINT fk_quality_check_process_run_id FOREIGN KEY (process_run_id) REFERENCES mqi.process_run (process_run_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.quality_check ADD CONSTRAINT fk_quality_check_checker_id FOREIGN KEY (checker_id) REFERENCES mqi.worker (worker_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.quality_check ADD CONSTRAINT fk_quality_check_process_run_id_model_id FOREIGN KEY (process_run_id, model_id) REFERENCES mqi.process_run (process_run_id, model_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

CREATE INDEX ix_quality_check_process_run_id_model_id ON mqi.quality_check (process_run_id, model_id);

CREATE INDEX ix_quality_check_model_id ON mqi.quality_check (model_id);

CREATE INDEX ix_quality_check_checker_id ON mqi.quality_check (checker_id);

ALTER TABLE mqi.measurement ADD CONSTRAINT fk_measurement_quality_check_id FOREIGN KEY (quality_check_id) REFERENCES mqi.quality_check (quality_check_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

CREATE INDEX ix_measurement_quality_check_id_measurement_item_code ON mqi.measurement (quality_check_id, measurement_item_code);

ALTER TABLE mqi.inspection_run ADD CONSTRAINT fk_inspection_run_model_id FOREIGN KEY (model_id) REFERENCES mqi.product_model (model_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.inspection_run ADD CONSTRAINT fk_inspection_run_process_run_id FOREIGN KEY (process_run_id) REFERENCES mqi.process_run (process_run_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.inspection_run ADD CONSTRAINT fk_inspection_run_inspector_id FOREIGN KEY (inspector_id) REFERENCES mqi.worker (worker_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.inspection_run ADD CONSTRAINT fk_inspection_run_target_defect_type_id FOREIGN KEY (target_defect_type_id) REFERENCES mqi.defect_type (defect_type_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.inspection_run ADD CONSTRAINT fk_inspection_run_process_run_id_model_id FOREIGN KEY (process_run_id, model_id) REFERENCES mqi.process_run (process_run_id, model_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

CREATE INDEX ix_inspection_run_model_id_inspection_date ON mqi.inspection_run (model_id, inspection_date);

CREATE INDEX ix_inspection_run_process_run_id_model_id ON mqi.inspection_run (process_run_id, model_id);

CREATE INDEX ix_inspection_run_inspector_id ON mqi.inspection_run (inspector_id);

CREATE INDEX ix_inspection_run_target_defect_type_id ON mqi.inspection_run (target_defect_type_id);

ALTER TABLE mqi.inspection_lot ADD CONSTRAINT fk_inspection_lot_inspection_run_id FOREIGN KEY (inspection_run_id) REFERENCES mqi.inspection_run (inspection_run_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.inspection_lot ADD CONSTRAINT fk_inspection_lot_production_lot_id FOREIGN KEY (production_lot_id) REFERENCES mqi.production_lot (lot_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.inspection_lot ADD CONSTRAINT fk_inspection_lot_model_id FOREIGN KEY (model_id) REFERENCES mqi.product_model (model_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.inspection_lot ADD CONSTRAINT fk_inspection_lot_inspection_run_id_model_id FOREIGN KEY (inspection_run_id, model_id) REFERENCES mqi.inspection_run (inspection_run_id, model_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.inspection_lot ADD CONSTRAINT fk_inspection_lot_production_lot_id_model_id FOREIGN KEY (production_lot_id, model_id) REFERENCES mqi.production_lot (lot_id, model_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

CREATE INDEX ix_inspection_lot_inspection_run_id_model_id ON mqi.inspection_lot (inspection_run_id, model_id);

CREATE INDEX ix_inspection_lot_production_lot_id_model_id ON mqi.inspection_lot (production_lot_id, model_id);

CREATE INDEX ix_inspection_lot_model_id ON mqi.inspection_lot (model_id);

ALTER TABLE mqi.inspection_run_link ADD CONSTRAINT fk_inspection_run_link_prior_inspection_run_id FOREIGN KEY (prior_inspection_run_id) REFERENCES mqi.inspection_run (inspection_run_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.inspection_run_link ADD CONSTRAINT fk_inspection_run_link_followup_inspection_run_id FOREIGN KEY (followup_inspection_run_id) REFERENCES mqi.inspection_run (inspection_run_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.inspection_run_link ADD CONSTRAINT fk_inspection_run_link_model_id FOREIGN KEY (model_id) REFERENCES mqi.product_model (model_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.inspection_run_link ADD CONSTRAINT fk_inspection_run_link_prior_inspection_run_id_model_id FOREIGN KEY (prior_inspection_run_id, model_id) REFERENCES mqi.inspection_run (inspection_run_id, model_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.inspection_run_link ADD CONSTRAINT fk_inspection_run_link_followup_inspection_run_id_model_id FOREIGN KEY (followup_inspection_run_id, model_id) REFERENCES mqi.inspection_run (inspection_run_id, model_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

CREATE INDEX ix_inspection_run_link_prior_inspection_run_id_model_id ON mqi.inspection_run_link (prior_inspection_run_id, model_id);

CREATE INDEX ix_inspection_run_link_followup_inspection_run_id_model_id ON mqi.inspection_run_link (followup_inspection_run_id, model_id);

CREATE INDEX ix_inspection_run_link_model_id ON mqi.inspection_run_link (model_id);

ALTER TABLE mqi.quality_finding ADD CONSTRAINT fk_quality_finding_inspection_run_id FOREIGN KEY (inspection_run_id) REFERENCES mqi.inspection_run (inspection_run_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.quality_finding ADD CONSTRAINT fk_quality_finding_inspection_lot_id FOREIGN KEY (inspection_lot_id) REFERENCES mqi.inspection_lot (inspection_lot_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.quality_finding ADD CONSTRAINT fk_quality_finding_process_run_id FOREIGN KEY (process_run_id) REFERENCES mqi.process_run (process_run_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.quality_finding ADD CONSTRAINT fk_quality_finding_defect_type_id FOREIGN KEY (defect_type_id) REFERENCES mqi.defect_type (defect_type_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.quality_finding ADD CONSTRAINT fk_quality_finding_parent_finding_id FOREIGN KEY (parent_finding_id) REFERENCES mqi.quality_finding (quality_finding_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.quality_finding ADD CONSTRAINT fk_quality_finding_inspection_lot_id_inspection_run_id FOREIGN KEY (inspection_lot_id, inspection_run_id) REFERENCES mqi.inspection_lot (inspection_lot_id, inspection_run_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.quality_finding ADD CONSTRAINT fk_quality_finding_inspection_run_id_model_id FOREIGN KEY (inspection_run_id, model_id) REFERENCES mqi.inspection_run (inspection_run_id, model_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.quality_finding ADD CONSTRAINT fk_quality_finding_process_run_id_model_id FOREIGN KEY (process_run_id, model_id) REFERENCES mqi.process_run (process_run_id, model_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.quality_finding ADD CONSTRAINT fk_quality_finding_parent_finding_id_model_id FOREIGN KEY (parent_finding_id, model_id) REFERENCES mqi.quality_finding (quality_finding_id, model_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

CREATE INDEX ix_quality_finding_inspection_lot_id_inspection_run_id ON mqi.quality_finding (inspection_lot_id, inspection_run_id);

CREATE INDEX ix_quality_finding_inspection_run_id_model_id ON mqi.quality_finding (inspection_run_id, model_id);

CREATE INDEX ix_quality_finding_process_run_id_model_id ON mqi.quality_finding (process_run_id, model_id);

CREATE INDEX ix_quality_finding_parent_finding_id_model_id ON mqi.quality_finding (parent_finding_id, model_id);

CREATE INDEX ix_quality_finding_defect_type_id ON mqi.quality_finding (defect_type_id);

ALTER TABLE mqi.lot_code_mapping ADD CONSTRAINT fk_lot_code_mapping_scheme_id FOREIGN KEY (scheme_id) REFERENCES mqi.lot_code_scheme (scheme_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

CREATE INDEX ix_lot_code_mapping_scheme_id_marking_code_lot_date ON mqi.lot_code_mapping (scheme_id, marking_code, lot_date);

ALTER TABLE mqi.rework_record ADD CONSTRAINT fk_rework_record_model_id FOREIGN KEY (model_id) REFERENCES mqi.product_model (model_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.rework_record ADD CONSTRAINT fk_rework_record_lot_code_mapping_id FOREIGN KEY (lot_code_mapping_id) REFERENCES mqi.lot_code_mapping (mapping_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

CREATE INDEX ix_rework_record_model_id_work_date ON mqi.rework_record (model_id, work_date);

CREATE INDEX ix_rework_record_lot_code_mapping_id ON mqi.rework_record (lot_code_mapping_id);

ALTER TABLE mqi.rework_origin_link ADD CONSTRAINT fk_rework_origin_link_rework_id FOREIGN KEY (rework_id) REFERENCES mqi.rework_record (rework_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.rework_origin_link ADD CONSTRAINT fk_rework_origin_link_original_lot_id FOREIGN KEY (original_lot_id) REFERENCES mqi.production_lot (lot_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.rework_origin_link ADD CONSTRAINT fk_rework_origin_link_original_process_run_id FOREIGN KEY (original_process_run_id) REFERENCES mqi.process_run (process_run_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.rework_origin_link ADD CONSTRAINT fk_rework_origin_link_model_id FOREIGN KEY (model_id) REFERENCES mqi.product_model (model_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.rework_origin_link ADD CONSTRAINT fk_rework_origin_link_rework_id_model_id FOREIGN KEY (rework_id, model_id) REFERENCES mqi.rework_record (rework_id, model_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.rework_origin_link ADD CONSTRAINT fk_rework_origin_link_original_lot_id_model_id FOREIGN KEY (original_lot_id, model_id) REFERENCES mqi.production_lot (lot_id, model_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.rework_origin_link ADD CONSTRAINT fk_rework_origin_link_original_process_run_id_model_id FOREIGN KEY (original_process_run_id, model_id) REFERENCES mqi.process_run (process_run_id, model_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

CREATE INDEX ix_rework_origin_link_rework_id_model_id ON mqi.rework_origin_link (rework_id, model_id);

CREATE INDEX ix_rework_origin_link_original_lot_id_model_id ON mqi.rework_origin_link (original_lot_id, model_id);

CREATE INDEX ix_rework_origin_link_original_process_run_id_model_id ON mqi.rework_origin_link (original_process_run_id, model_id);

CREATE INDEX ix_rework_origin_link_model_id ON mqi.rework_origin_link (model_id);

ALTER TABLE mqi.traceability_card ADD CONSTRAINT fk_traceability_card_model_id FOREIGN KEY (model_id) REFERENCES mqi.product_model (model_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

CREATE INDEX ix_traceability_card_model_id ON mqi.traceability_card (model_id);

ALTER TABLE mqi.source_bundle ADD CONSTRAINT fk_source_bundle_ingest_id FOREIGN KEY (ingest_id) REFERENCES mqi.source_ingest (ingest_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.source_bundle ADD CONSTRAINT fk_source_bundle_parent_bundle_id FOREIGN KEY (parent_bundle_id) REFERENCES mqi.source_bundle (bundle_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.source_bundle ADD CONSTRAINT fk_source_bundle_parent_bundle_id_ingest_id FOREIGN KEY (parent_bundle_id, ingest_id) REFERENCES mqi.source_bundle (bundle_id, ingest_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.source_bundle ADD CONSTRAINT fk_source_bundle_archive_asset_id FOREIGN KEY (archive_asset_id) REFERENCES mqi.source_asset (asset_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

CREATE INDEX ix_source_bundle_parent_bundle_id_ingest_id ON mqi.source_bundle (parent_bundle_id, ingest_id);

CREATE INDEX ix_source_bundle_ingest_id ON mqi.source_bundle (ingest_id);

CREATE INDEX ix_source_bundle_archive_asset_id ON mqi.source_bundle (archive_asset_id);

ALTER TABLE mqi.source_bundle_asset ADD CONSTRAINT fk_source_bundle_asset_bundle_id FOREIGN KEY (bundle_id) REFERENCES mqi.source_bundle (bundle_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.source_bundle_asset ADD CONSTRAINT fk_source_bundle_asset_asset_id FOREIGN KEY (asset_id) REFERENCES mqi.source_asset (asset_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

CREATE INDEX ix_source_bundle_asset_asset_id ON mqi.source_bundle_asset (asset_id);

ALTER TABLE mqi.source_document_version ADD CONSTRAINT fk_source_document_version_document_id FOREIGN KEY (document_id) REFERENCES mqi.source_document (document_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.source_document_version ADD CONSTRAINT fk_source_document_version_asset_id FOREIGN KEY (asset_id) REFERENCES mqi.source_asset (asset_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.source_document_version ADD CONSTRAINT fk_source_document_version_template_id FOREIGN KEY (template_id) REFERENCES mqi.form_template (template_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

CREATE INDEX ix_source_document_version_asset_id ON mqi.source_document_version (asset_id);

CREATE INDEX ix_source_document_version_template_id ON mqi.source_document_version (template_id);

ALTER TABLE mqi.source_page ADD CONSTRAINT fk_source_page_asset_id FOREIGN KEY (asset_id) REFERENCES mqi.source_asset (asset_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.form_template ADD CONSTRAINT fk_form_template_process_id FOREIGN KEY (process_id) REFERENCES mqi.process (process_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

CREATE INDEX ix_form_template_process_id ON mqi.form_template (process_id);

ALTER TABLE mqi.form_field_definition ADD CONSTRAINT fk_form_field_definition_template_id FOREIGN KEY (template_id) REFERENCES mqi.form_template (template_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.source_location ADD CONSTRAINT fk_source_location_bundle_asset_id FOREIGN KEY (bundle_asset_id) REFERENCES mqi.source_bundle_asset (bundle_asset_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.source_location ADD CONSTRAINT fk_source_location_source_page_id FOREIGN KEY (source_page_id) REFERENCES mqi.source_page (source_page_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.source_location ADD CONSTRAINT fk_source_location_bundle_asset_id_asset_id FOREIGN KEY (bundle_asset_id, asset_id) REFERENCES mqi.source_bundle_asset (bundle_asset_id, asset_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.source_location ADD CONSTRAINT fk_source_location_source_page_id_asset_id FOREIGN KEY (source_page_id, asset_id) REFERENCES mqi.source_page (source_page_id, asset_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

CREATE INDEX ix_source_location_bundle_asset_id_asset_id ON mqi.source_location (bundle_asset_id, asset_id);

CREATE INDEX ix_source_location_source_page_id_asset_id ON mqi.source_location (source_page_id, asset_id);

ALTER TABLE mqi.extraction_run ADD CONSTRAINT fk_extraction_run_bundle_asset_id FOREIGN KEY (bundle_asset_id) REFERENCES mqi.source_bundle_asset (bundle_asset_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

CREATE INDEX ix_extraction_run_bundle_asset_id ON mqi.extraction_run (bundle_asset_id);

ALTER TABLE mqi.extracted_field ADD CONSTRAINT fk_extracted_field_extraction_run_id FOREIGN KEY (extraction_run_id) REFERENCES mqi.extraction_run (extraction_run_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.extracted_field ADD CONSTRAINT fk_extracted_field_source_location_id FOREIGN KEY (source_location_id) REFERENCES mqi.source_location (source_location_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.extracted_field ADD CONSTRAINT fk_extracted_field_form_field_id FOREIGN KEY (form_field_id) REFERENCES mqi.form_field_definition (form_field_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.extracted_field ADD CONSTRAINT fk_extracted_field_extraction_run_id_bundle_asset_id FOREIGN KEY (extraction_run_id, bundle_asset_id) REFERENCES mqi.extraction_run (extraction_run_id, bundle_asset_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.extracted_field ADD CONSTRAINT fk_extracted_field_source_location_id_bundle_asset_id FOREIGN KEY (source_location_id, bundle_asset_id) REFERENCES mqi.source_location (source_location_id, bundle_asset_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.extracted_field ADD CONSTRAINT fk_extracted_field_current_review_id_extracted_field_id FOREIGN KEY (current_review_id, extracted_field_id) REFERENCES mqi.field_review (field_review_id, extracted_field_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

CREATE INDEX ix_extracted_field_extraction_run_id_bundle_asset_id ON mqi.extracted_field (extraction_run_id, bundle_asset_id);

CREATE INDEX ix_extracted_field_source_location_id_bundle_asset_id ON mqi.extracted_field (source_location_id, bundle_asset_id);

CREATE INDEX ix_extracted_field_current_review_id_extracted_field_id ON mqi.extracted_field (current_review_id, extracted_field_id);

CREATE INDEX ix_extracted_field_form_field_id ON mqi.extracted_field (form_field_id);

ALTER TABLE mqi.field_review ADD CONSTRAINT fk_field_review_extracted_field_id FOREIGN KEY (extracted_field_id) REFERENCES mqi.extracted_field (extracted_field_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

CREATE INDEX ix_field_review_extracted_field_id_reviewed_at ON mqi.field_review (extracted_field_id, reviewed_at);

ALTER TABLE mqi.field_provenance_link ADD CONSTRAINT fk_field_provenance_link_extracted_field_id FOREIGN KEY (extracted_field_id) REFERENCES mqi.extracted_field (extracted_field_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.field_provenance_link ADD CONSTRAINT fk_field_provenance_link_field_review_id FOREIGN KEY (field_review_id) REFERENCES mqi.field_review (field_review_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.field_provenance_link ADD CONSTRAINT fk_field_provenance_link_parameter_observation_id FOREIGN KEY (parameter_observation_id) REFERENCES mqi.parameter_observation (observation_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.field_provenance_link ADD CONSTRAINT fk_field_provenance_link_process_run_result_id FOREIGN KEY (process_run_result_id) REFERENCES mqi.process_run_result (process_run_result_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.field_provenance_link ADD CONSTRAINT fk_field_provenance_link_measurement_id FOREIGN KEY (measurement_id) REFERENCES mqi.measurement (measurement_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.field_provenance_link ADD CONSTRAINT fk_field_provenance_link_quality_finding_id FOREIGN KEY (quality_finding_id) REFERENCES mqi.quality_finding (quality_finding_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.field_provenance_link ADD CONSTRAINT fk_field_provenance_link_inspection_lot_id FOREIGN KEY (inspection_lot_id) REFERENCES mqi.inspection_lot (inspection_lot_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.field_provenance_link ADD CONSTRAINT fk_field_provenance_link_rework_id FOREIGN KEY (rework_id) REFERENCES mqi.rework_record (rework_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.field_provenance_link ADD CONSTRAINT fk_field_provenance_link_material_usage_id FOREIGN KEY (material_usage_id) REFERENCES mqi.material_usage (material_usage_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.field_provenance_link ADD CONSTRAINT fk_field_provenance_link_process_run_lot_id FOREIGN KEY (process_run_lot_id) REFERENCES mqi.process_run_lot (process_run_lot_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.field_provenance_link ADD CONSTRAINT fk_field_provenance_link_production_run_id FOREIGN KEY (production_run_id) REFERENCES mqi.production_run (run_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.field_provenance_link ADD CONSTRAINT fk_field_provenance_link_traceability_card_id FOREIGN KEY (traceability_card_id) REFERENCES mqi.traceability_card (traceability_card_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.field_provenance_link ADD CONSTRAINT fk_field_provenance_link_spec_item_id FOREIGN KEY (spec_item_id) REFERENCES mqi.process_setup_spec_item (spec_item_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.field_provenance_link ADD CONSTRAINT fk_field_provenance_link_quality_check_id FOREIGN KEY (quality_check_id) REFERENCES mqi.quality_check (quality_check_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.field_provenance_link ADD CONSTRAINT fk_field_provenance_link_field_review_id_extracted_field_id FOREIGN KEY (field_review_id, extracted_field_id) REFERENCES mqi.field_review (field_review_id, extracted_field_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.field_provenance_link ADD CONSTRAINT fk_field_provenance_link_target_product_id FOREIGN KEY (target_product_id) REFERENCES mqi.product (product_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.field_provenance_link ADD CONSTRAINT fk_field_provenance_link_target_model_id FOREIGN KEY (target_model_id) REFERENCES mqi.product_model (model_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.field_provenance_link ADD CONSTRAINT fk_field_provenance_link_target_process_id FOREIGN KEY (target_process_id) REFERENCES mqi.process (process_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.field_provenance_link ADD CONSTRAINT fk_field_provenance_link_target_line_id FOREIGN KEY (target_line_id) REFERENCES mqi.production_line (line_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.field_provenance_link ADD CONSTRAINT fk_field_provenance_link_target_lot_id FOREIGN KEY (target_lot_id) REFERENCES mqi.production_lot (lot_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.field_provenance_link ADD CONSTRAINT fk_field_provenance_link_process_run_id FOREIGN KEY (process_run_id) REFERENCES mqi.process_run (process_run_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.field_provenance_link ADD CONSTRAINT fk_field_provenance_link_target_equipment_id FOREIGN KEY (target_equipment_id) REFERENCES mqi.equipment (equipment_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.field_provenance_link ADD CONSTRAINT fk_field_provenance_link_target_position_id FOREIGN KEY (target_position_id) REFERENCES mqi.equipment_position (position_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.field_provenance_link ADD CONSTRAINT fk_field_provenance_link_target_equipment_connection_id FOREIGN KEY (target_equipment_connection_id) REFERENCES mqi.equipment_connection (equipment_connection_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.field_provenance_link ADD CONSTRAINT fk_field_provenance_link_target_equipment_usage_id FOREIGN KEY (target_equipment_usage_id) REFERENCES mqi.process_equipment_usage (equipment_usage_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.field_provenance_link ADD CONSTRAINT fk_field_provenance_link_target_parameter_id FOREIGN KEY (target_parameter_id) REFERENCES mqi.parameter_definition (parameter_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.field_provenance_link ADD CONSTRAINT fk_field_provenance_link_target_spec_id FOREIGN KEY (target_spec_id) REFERENCES mqi.process_setup_spec (spec_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.field_provenance_link ADD CONSTRAINT fk_field_provenance_link_target_material_id FOREIGN KEY (target_material_id) REFERENCES mqi.material (material_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.field_provenance_link ADD CONSTRAINT fk_field_provenance_link_target_material_lot_id FOREIGN KEY (target_material_lot_id) REFERENCES mqi.material_lot (material_lot_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.field_provenance_link ADD CONSTRAINT fk_field_provenance_link_target_worker_id FOREIGN KEY (target_worker_id) REFERENCES mqi.worker (worker_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.field_provenance_link ADD CONSTRAINT fk_field_provenance_link_target_assignment_id FOREIGN KEY (target_assignment_id) REFERENCES mqi.worker_assignment (assignment_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.field_provenance_link ADD CONSTRAINT fk_field_provenance_link_target_event_id FOREIGN KEY (target_event_id) REFERENCES mqi.production_event (event_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.field_provenance_link ADD CONSTRAINT fk_field_provenance_link_inspection_run_id FOREIGN KEY (inspection_run_id) REFERENCES mqi.inspection_run (inspection_run_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.field_provenance_link ADD CONSTRAINT fk_field_provenance_link_target_inspection_run_link_id FOREIGN KEY (target_inspection_run_link_id) REFERENCES mqi.inspection_run_link (inspection_run_link_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.field_provenance_link ADD CONSTRAINT fk_field_provenance_link_target_defect_type_id FOREIGN KEY (target_defect_type_id) REFERENCES mqi.defect_type (defect_type_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.field_provenance_link ADD CONSTRAINT fk_field_provenance_link_target_scheme_id FOREIGN KEY (target_scheme_id) REFERENCES mqi.lot_code_scheme (scheme_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.field_provenance_link ADD CONSTRAINT fk_field_provenance_link_target_mapping_id FOREIGN KEY (target_mapping_id) REFERENCES mqi.lot_code_mapping (mapping_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.field_provenance_link ADD CONSTRAINT fk_field_provenance_link_target_rework_origin_link_id FOREIGN KEY (target_rework_origin_link_id) REFERENCES mqi.rework_origin_link (rework_origin_link_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

CREATE INDEX ix_field_provenance_link_field_review_id_extracted_field_id ON mqi.field_provenance_link (field_review_id, extracted_field_id);

CREATE INDEX ix_field_provenance_link_extracted_field_id ON mqi.field_provenance_link (extracted_field_id);

CREATE INDEX ix_field_provenance_link_parameter_observation_id ON mqi.field_provenance_link (parameter_observation_id);

CREATE INDEX ix_field_provenance_link_process_run_result_id ON mqi.field_provenance_link (process_run_result_id);

CREATE INDEX ix_field_provenance_link_measurement_id ON mqi.field_provenance_link (measurement_id);

CREATE INDEX ix_field_provenance_link_quality_finding_id ON mqi.field_provenance_link (quality_finding_id);

CREATE INDEX ix_field_provenance_link_inspection_lot_id ON mqi.field_provenance_link (inspection_lot_id);

CREATE INDEX ix_field_provenance_link_rework_id ON mqi.field_provenance_link (rework_id);

CREATE INDEX ix_field_provenance_link_material_usage_id ON mqi.field_provenance_link (material_usage_id);

CREATE INDEX ix_field_provenance_link_process_run_lot_id ON mqi.field_provenance_link (process_run_lot_id);

CREATE INDEX ix_field_provenance_link_production_run_id ON mqi.field_provenance_link (production_run_id);

CREATE INDEX ix_field_provenance_link_traceability_card_id ON mqi.field_provenance_link (traceability_card_id);

CREATE INDEX ix_field_provenance_link_spec_item_id ON mqi.field_provenance_link (spec_item_id);

CREATE INDEX ix_field_provenance_link_quality_check_id ON mqi.field_provenance_link (quality_check_id);

CREATE INDEX ix_field_provenance_link_target_product_id ON mqi.field_provenance_link (target_product_id);

CREATE INDEX ix_field_provenance_link_target_model_id ON mqi.field_provenance_link (target_model_id);

CREATE INDEX ix_field_provenance_link_target_process_id ON mqi.field_provenance_link (target_process_id);

CREATE INDEX ix_field_provenance_link_target_line_id ON mqi.field_provenance_link (target_line_id);

CREATE INDEX ix_field_provenance_link_target_lot_id ON mqi.field_provenance_link (target_lot_id);

CREATE INDEX ix_field_provenance_link_process_run_id ON mqi.field_provenance_link (process_run_id);

CREATE INDEX ix_field_provenance_link_target_equipment_id ON mqi.field_provenance_link (target_equipment_id);

CREATE INDEX ix_field_provenance_link_target_position_id ON mqi.field_provenance_link (target_position_id);

CREATE INDEX ix_field_provenance_link_target_equipment_connection_id ON mqi.field_provenance_link (target_equipment_connection_id);

CREATE INDEX ix_field_provenance_link_target_equipment_usage_id ON mqi.field_provenance_link (target_equipment_usage_id);

CREATE INDEX ix_field_provenance_link_target_parameter_id ON mqi.field_provenance_link (target_parameter_id);

CREATE INDEX ix_field_provenance_link_target_spec_id ON mqi.field_provenance_link (target_spec_id);

CREATE INDEX ix_field_provenance_link_target_material_id ON mqi.field_provenance_link (target_material_id);

CREATE INDEX ix_field_provenance_link_target_material_lot_id ON mqi.field_provenance_link (target_material_lot_id);

CREATE INDEX ix_field_provenance_link_target_worker_id ON mqi.field_provenance_link (target_worker_id);

CREATE INDEX ix_field_provenance_link_target_assignment_id ON mqi.field_provenance_link (target_assignment_id);

CREATE INDEX ix_field_provenance_link_target_event_id ON mqi.field_provenance_link (target_event_id);

CREATE INDEX ix_field_provenance_link_inspection_run_id ON mqi.field_provenance_link (inspection_run_id);

CREATE INDEX ix_field_provenance_link_target_inspection_run_link_id ON mqi.field_provenance_link (target_inspection_run_link_id);

CREATE INDEX ix_field_provenance_link_target_defect_type_id ON mqi.field_provenance_link (target_defect_type_id);

CREATE INDEX ix_field_provenance_link_target_scheme_id ON mqi.field_provenance_link (target_scheme_id);

CREATE INDEX ix_field_provenance_link_target_mapping_id ON mqi.field_provenance_link (target_mapping_id);

CREATE INDEX ix_field_provenance_link_target_rework_origin_link_id ON mqi.field_provenance_link (target_rework_origin_link_id);

ALTER TABLE mqi.source_run_link ADD CONSTRAINT fk_source_run_link_bundle_asset_id FOREIGN KEY (bundle_asset_id) REFERENCES mqi.source_bundle_asset (bundle_asset_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.source_run_link ADD CONSTRAINT fk_source_run_link_source_page_id FOREIGN KEY (source_page_id) REFERENCES mqi.source_page (source_page_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.source_run_link ADD CONSTRAINT fk_source_run_link_production_run_id FOREIGN KEY (production_run_id) REFERENCES mqi.production_run (run_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.source_run_link ADD CONSTRAINT fk_source_run_link_process_run_id FOREIGN KEY (process_run_id) REFERENCES mqi.process_run (process_run_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.source_run_link ADD CONSTRAINT fk_source_run_link_inspection_run_id FOREIGN KEY (inspection_run_id) REFERENCES mqi.inspection_run (inspection_run_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.source_run_link ADD CONSTRAINT fk_source_run_link_bundle_asset_id_asset_id FOREIGN KEY (bundle_asset_id, asset_id) REFERENCES mqi.source_bundle_asset (bundle_asset_id, asset_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

ALTER TABLE mqi.source_run_link ADD CONSTRAINT fk_source_run_link_source_page_id_asset_id FOREIGN KEY (source_page_id, asset_id) REFERENCES mqi.source_page (source_page_id, asset_id) MATCH SIMPLE ON UPDATE RESTRICT ON DELETE RESTRICT;

CREATE INDEX ix_source_run_link_bundle_asset_id_linkage_status ON mqi.source_run_link (bundle_asset_id, linkage_status);

CREATE INDEX ix_source_run_link_bundle_asset_id_asset_id ON mqi.source_run_link (bundle_asset_id, asset_id);

CREATE INDEX ix_source_run_link_source_page_id_asset_id ON mqi.source_run_link (source_page_id, asset_id);

CREATE INDEX ix_source_run_link_production_run_id ON mqi.source_run_link (production_run_id);

CREATE INDEX ix_source_run_link_process_run_id ON mqi.source_run_link (process_run_id);

CREATE INDEX ix_source_run_link_inspection_run_id ON mqi.source_run_link (inspection_run_id);

-- Included verbatim by build-schema.py after tables, keys, and indexes.
CREATE TABLE mqi_audit.row_change (
    audit_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    table_name text NOT NULL,
    row_id uuid NOT NULL,
    operation text NOT NULL CHECK (operation IN ('INSERT','UPDATE')),
    old_row jsonb,
    new_row jsonb NOT NULL,
    changed_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    transaction_id bigint NOT NULL DEFAULT txid_current(),
    database_login text NOT NULL,
    database_role text NOT NULL,
    actor_ref text NOT NULL,
    change_reason text NOT NULL,
    request_id text
);
CREATE INDEX ix_row_change_record ON mqi_audit.row_change(table_name,row_id,audit_id);
CREATE INDEX ix_row_change_time ON mqi_audit.row_change(changed_at);
ALTER TABLE mqi_audit.row_change ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON mqi_audit.row_change FROM PUBLIC;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA mqi_audit FROM PUBLIC;

CREATE FUNCTION mqi.reject_removal() RETURNS trigger LANGUAGE plpgsql
SET search_path=pg_catalog AS $$
BEGIN
    RAISE EXCEPTION 'removal forbidden; preserve history and use VOID/new version' USING ERRCODE='23514';
END $$;
CREATE TRIGGER preserve_audit BEFORE UPDATE OR DELETE OR TRUNCATE ON mqi_audit.row_change
FOR EACH STATEMENT EXECUTE FUNCTION mqi.reject_removal();

CREATE FUNCTION mqi.write_guard() RETURNS trigger LANGUAGE plpgsql
SET search_path=pg_catalog AS $$
DECLARE oldj jsonb; newj jsonb; c text;
BEGIN
    IF current_setting('transaction_isolation') <> 'serializable' THEN
        RAISE EXCEPTION 'mqi writes require BEGIN ISOLATION LEVEL SERIALIZABLE; retry whole transaction on 40001'
            USING ERRCODE='25000';
    END IF;
    IF nullif(btrim(current_setting('mqi.actor_ref',true)),'') IS NULL
       OR nullif(btrim(current_setting('mqi.change_reason',true)),'') IS NULL THEN
        RAISE EXCEPTION 'mqi.actor_ref and mqi.change_reason are required' USING ERRCODE='23514';
    END IF;
    IF TG_OP='DELETE' THEN
        RAISE EXCEPTION 'DELETE forbidden: mark VOID with an audit reason' USING ERRCODE='23514';
    END IF;
    IF TG_OP='INSERT' THEN
        NEW.recorded_at := clock_timestamp(); NEW.updated_at := NEW.recorded_at; NEW.row_version := 1;
        RETURN NEW;
    END IF;
    oldj := to_jsonb(OLD); newj := to_jsonb(NEW);
    IF oldj->TG_ARGV[0] IS DISTINCT FROM newj->TG_ARGV[0] THEN
        RAISE EXCEPTION 'primary identity is immutable' USING ERRCODE='23514';
    END IF;
    IF NEW.row_version <> OLD.row_version THEN
        RAISE EXCEPTION 'row version conflict' USING ERRCODE='40001';
    END IF;
    IF TG_ARGV[1]='append' AND
       (oldj - ARRAY['updated_at','row_version','record_state']) IS DISTINCT FROM
       (newj - ARRAY['updated_at','row_version','record_state']) THEN
        RAISE EXCEPTION 'immutable evidence: create a new row/version' USING ERRCODE='23514';
    END IF;
    IF TG_ARGV[2] <> '' THEN
        FOREACH c IN ARRAY string_to_array(TG_ARGV[2],',') LOOP
            IF oldj->c IS DISTINCT FROM newj->c THEN
                RAISE EXCEPTION 'immutable semantic/original field %.%', TG_TABLE_NAME,c USING ERRCODE='23514';
            END IF;
        END LOOP;
    END IF;
    NEW.recorded_at := OLD.recorded_at; NEW.updated_at := clock_timestamp(); NEW.row_version := OLD.row_version + 1;
    RETURN NEW;
END $$;

CREATE FUNCTION mqi_audit.capture() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog AS $$
BEGIN
    INSERT INTO mqi_audit.row_change(table_name,row_id,operation,old_row,new_row,database_login,database_role,actor_ref,change_reason,request_id)
    VALUES(TG_TABLE_NAME,(to_jsonb(NEW)->>TG_ARGV[0])::uuid,TG_OP,
        CASE WHEN TG_OP='UPDATE' THEN to_jsonb(OLD) ELSE NULL END,to_jsonb(NEW),session_user,
        current_setting('role'),current_setting('mqi.actor_ref'),current_setting('mqi.change_reason'),
        nullif(current_setting('mqi.request_id',true),''));
    RETURN NEW;
END $$;

CREATE FUNCTION mqi.validate_semantics() RETURNS trigger LANGUAGE plpgsql
SET search_path=pg_catalog,mqi AS $$
DECLARE
    p record; s record; r record; target_table text; target_pk text; target_col text;
    target_id uuid; actual_value text; typed_review text; target_type text; j jsonb;
    a uuid; b uuid; cycle_found boolean;
BEGIN
    IF TG_TABLE_NAME='source_bundle' THEN
        IF NEW.archive_asset_id IS NOT NULL AND NOT EXISTS
           (SELECT 1 FROM mqi.source_asset WHERE asset_id=NEW.archive_asset_id AND asset_type='ZIP') THEN
            RAISE EXCEPTION 'archive Asset must be ZIP' USING ERRCODE='23514';
        END IF;
        WITH RECURSIVE ancestors(id) AS (
            SELECT NEW.parent_bundle_id WHERE NEW.parent_bundle_id IS NOT NULL
            UNION SELECT sb.parent_bundle_id FROM mqi.source_bundle sb JOIN ancestors x ON sb.bundle_id=x.id
                  WHERE sb.parent_bundle_id IS NOT NULL
        ) SELECT EXISTS(SELECT 1 FROM ancestors WHERE id=NEW.bundle_id) INTO cycle_found;
        IF cycle_found THEN RAISE EXCEPTION 'bundle cycle' USING ERRCODE='23514'; END IF;
    ELSIF TG_TABLE_NAME='inspection_run_link' THEN
        WITH RECURSIVE descendants(id) AS (
            SELECT NEW.followup_inspection_run_id
            UNION SELECT il.followup_inspection_run_id FROM mqi.inspection_run_link il
                JOIN descendants x ON il.prior_inspection_run_id=x.id
                WHERE il.inspection_run_link_id<>NEW.inspection_run_link_id
        ) SELECT EXISTS(SELECT 1 FROM descendants WHERE id=NEW.prior_inspection_run_id) INTO cycle_found;
        IF cycle_found THEN RAISE EXCEPTION 'inspection cycle' USING ERRCODE='23514'; END IF;
    ELSIF TG_TABLE_NAME='quality_finding' THEN
        SELECT model_id INTO b FROM mqi.inspection_run WHERE inspection_run_id=NEW.inspection_run_id;
        IF b IS NULL THEN SELECT model_id INTO b FROM mqi.process_run WHERE process_run_id=NEW.process_run_id; END IF;
        IF NEW.model_id IS NULL THEN NEW.model_id:=b;
        ELSIF NEW.model_id IS DISTINCT FROM b THEN RAISE EXCEPTION 'finding model mismatch' USING ERRCODE='23514'; END IF;
        WITH RECURSIVE ancestors(id) AS (
            SELECT NEW.parent_finding_id WHERE NEW.parent_finding_id IS NOT NULL
            UNION SELECT qf.parent_finding_id FROM mqi.quality_finding qf JOIN ancestors x ON qf.quality_finding_id=x.id
                  WHERE qf.parent_finding_id IS NOT NULL
        ) SELECT EXISTS(SELECT 1 FROM ancestors WHERE id=NEW.quality_finding_id) INTO cycle_found;
        IF cycle_found THEN RAISE EXCEPTION 'finding cycle' USING ERRCODE='23514'; END IF;
        IF NEW.parent_finding_id IS NOT NULL THEN
            SELECT coalesce(ir.model_id,pr.model_id) INTO a FROM mqi.quality_finding qf
            LEFT JOIN mqi.inspection_run ir ON ir.inspection_run_id=qf.inspection_run_id
            LEFT JOIN mqi.process_run pr ON pr.process_run_id=qf.process_run_id WHERE qf.quality_finding_id=NEW.parent_finding_id;
            SELECT model_id INTO b FROM mqi.inspection_run WHERE inspection_run_id=NEW.inspection_run_id;
            IF b IS NULL THEN SELECT model_id INTO b FROM mqi.process_run WHERE process_run_id=NEW.process_run_id; END IF;
            IF a IS DISTINCT FROM b THEN RAISE EXCEPTION 'parent finding model mismatch' USING ERRCODE='23514'; END IF;
        END IF;
    ELSIF TG_TABLE_NAME IN ('parameter_observation','process_setup_spec_item') THEN
        SELECT * INTO p FROM mqi.parameter_definition WHERE parameter_id=NEW.parameter_id;
        IF TG_TABLE_NAME='parameter_observation' THEN
            IF p.value_kind='NUMBER' AND NEW.value_text IS NOT NULL OR
               p.value_kind IN ('CODE','TEXT') AND NEW.value_numeric IS NOT NULL THEN
                RAISE EXCEPTION 'observation value kind mismatch' USING ERRCODE='23514';
            END IF;
            IF NEW.process_run_id IS NOT NULL THEN
                SELECT process_id INTO a FROM mqi.process_run WHERE process_run_id=NEW.process_run_id;
                IF p.process_id IS NOT NULL AND p.process_id IS DISTINCT FROM a THEN
                    RAISE EXCEPTION 'observation process mismatch' USING ERRCODE='23514';
                END IF;
                IF NOT EXISTS(SELECT 1 FROM mqi.process_equipment_usage WHERE process_run_id=NEW.process_run_id AND equipment_id=NEW.equipment_id) THEN
                    RAISE EXCEPTION 'observation requires documented equipment usage; otherwise leave run NULL' USING ERRCODE='23514';
                END IF;
            END IF;
        ELSE
            SELECT * INTO s FROM mqi.process_setup_spec WHERE spec_id=NEW.spec_id;
            IF p.process_id IS NOT NULL AND p.process_id IS DISTINCT FROM s.process_id THEN
                RAISE EXCEPTION 'spec parameter process mismatch' USING ERRCODE='23514';
            END IF;
            IF p.value_kind='NUMBER' AND NEW.target_text IS NOT NULL OR
               p.value_kind IN ('CODE','TEXT') AND num_nonnulls(NEW.target_numeric,NEW.min_numeric,NEW.max_numeric)>0 THEN
                RAISE EXCEPTION 'spec value kind mismatch' USING ERRCODE='23514';
            END IF;
            IF NEW.position_id IS NOT NULL THEN
                SELECT equipment_id INTO a FROM mqi.equipment_position WHERE position_id=NEW.position_id;
                IF s.equipment_id IS NULL OR a IS DISTINCT FROM s.equipment_id THEN
                    RAISE EXCEPTION 'position-specific spec needs its equipment' USING ERRCODE='23514';
                END IF;
            END IF;
        END IF;
        IF p.position_scope='EQUIPMENT' AND NEW.position_id IS NOT NULL THEN
            RAISE EXCEPTION 'equipment-wide parameter must not specify a position' USING ERRCODE='23514';
        END IF;
        -- POSITION with unknown position remains representable; flagged for review, not guessed.
    ELSIF TG_TABLE_NAME='rework_record' THEN
        IF NEW.lot_code_mapping_id IS NOT NULL AND NEW.marked_lot_date IS NOT NULL AND NOT EXISTS
           (SELECT 1 FROM mqi.lot_code_mapping WHERE mapping_id=NEW.lot_code_mapping_id AND lot_date=NEW.marked_lot_date) THEN
            RAISE EXCEPTION 'marked date/mapping mismatch' USING ERRCODE='23514';
        END IF;
        -- Raw code and numeric serial discrepancies are preserved; no quantity generation.
    ELSIF TG_TABLE_NAME='rework_origin_link' THEN
        IF NEW.original_process_run_id IS NOT NULL AND NOT EXISTS
           (SELECT 1 FROM mqi.process_run_lot WHERE process_run_id=NEW.original_process_run_id AND production_lot_id=NEW.original_lot_id) THEN
            RAISE EXCEPTION 'origin process must have documented LOT link' USING ERRCODE='23514';
        END IF;
    ELSIF TG_TABLE_NAME='extracted_field' THEN
        IF NEW.current_review_id IS NOT NULL THEN
            SELECT * INTO r FROM mqi.field_review WHERE field_review_id=NEW.current_review_id AND extracted_field_id=NEW.extracted_field_id;
            IF NOT FOUND OR r.record_state<>'ACTIVE' THEN RAISE EXCEPTION 'invalid selected review' USING ERRCODE='23514'; END IF;
            NEW.validation_status := r.review_status;
        ELSE
            NEW.validation_status := 'UNREVIEWED';
        END IF;
    ELSIF TG_TABLE_NAME='field_review' THEN
        IF NEW.record_state='VOID' AND (
            EXISTS(SELECT 1 FROM mqi.extracted_field WHERE current_review_id=NEW.field_review_id) OR
            EXISTS(SELECT 1 FROM mqi.field_provenance_link WHERE field_review_id=NEW.field_review_id AND evidence_role='PRIMARY' AND record_state='ACTIVE')) THEN
            RAISE EXCEPTION 'select a replacement review and void active PRIMARY links first' USING ERRCODE='23514';
        END IF;
    ELSIF TG_TABLE_NAME='field_provenance_link' THEN
        IF TG_OP='UPDATE' THEN RETURN NEW; END IF; -- Only VOID metadata can change; snapshot is historical.
        j:=to_jsonb(NEW);
        -- Whitelist targets through actual single-column FKs, not a client-supplied table name.
        SELECT rt.relname,ra.attname,(j->>ca.attname)::uuid INTO target_table,target_pk,target_id
        FROM pg_constraint f
        JOIN pg_class rt ON rt.oid=f.confrelid
        JOIN pg_attribute ca ON ca.attrelid=f.conrelid AND ca.attnum=f.conkey[1]
        JOIN pg_attribute ra ON ra.attrelid=f.confrelid AND ra.attnum=f.confkey[1]
        WHERE f.conrelid='mqi.field_provenance_link'::regclass AND f.contype='f' AND cardinality(f.conkey)=1
          AND rt.relname NOT IN ('field_review','extracted_field') AND j->>ca.attname IS NOT NULL;
        IF target_table IS NULL THEN RAISE EXCEPTION 'missing provenance target' USING ERRCODE='23514'; END IF;
        target_col:=NEW.target_column_name;
        SELECT format_type(att.atttypid,att.atttypmod) INTO target_type FROM pg_attribute att
        WHERE att.attrelid=format('mqi.%I',target_table)::regclass AND att.attname=target_col AND att.attnum>0 AND NOT att.attisdropped;
        IF target_type IS NULL OR target_col=target_pk OR target_col IN ('recorded_at','updated_at','row_version','record_state') THEN
            RAISE EXCEPTION 'invalid or system provenance column' USING ERRCODE='23514';
        END IF;
        EXECUTE format('SELECT %I::text FROM mqi.%I WHERE %I=$1',target_col,target_table,target_pk) INTO actual_value USING target_id;
        IF NEW.evidence_role='PRIMARY' THEN
            SELECT * INTO r FROM mqi.field_review WHERE field_review_id=NEW.field_review_id AND extracted_field_id=NEW.extracted_field_id;
            IF NOT FOUND OR r.review_status NOT IN ('VERIFIED','CORRECTED') OR r.record_state<>'ACTIVE' THEN
                RAISE EXCEPTION 'PRIMARY needs an explicit successful review' USING ERRCODE='23514';
            END IF;
            IF r.review_reason_code='SOURCE_TYPO' AND
               (target_table='parameter_observation' AND target_col IN ('value_numeric','value_text') OR
                target_table='measurement' AND target_col='measured_value') THEN
                RAISE EXCEPTION 'source typo cannot establish an actual measurement' USING ERRCODE='23514';
            END IF;
            EXECUTE format('SELECT ($1::%s)::text',target_type) INTO typed_review USING r.reviewed_value;
            IF typed_review IS DISTINCT FROM actual_value THEN
                RAISE EXCEPTION 'reviewed value differs from target value' USING ERRCODE='23514';
            END IF;
        END IF;
        IF TG_OP='INSERT' THEN NEW.target_value_snapshot:=actual_value; END IF;
    END IF;
    RETURN NEW;
END $$;


CREATE TRIGGER a_write_guard BEFORE INSERT OR UPDATE OR DELETE ON mqi.product FOR EACH ROW EXECUTE FUNCTION mqi.write_guard('product_id','mutable','');

CREATE TRIGGER z_audit AFTER INSERT OR UPDATE ON mqi.product FOR EACH ROW EXECUTE FUNCTION mqi_audit.capture('product_id');

CREATE TRIGGER a_no_truncate BEFORE TRUNCATE ON mqi.product FOR EACH STATEMENT EXECUTE FUNCTION mqi.reject_removal();

ALTER TABLE mqi.product ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE mqi.product FROM PUBLIC;

CREATE TRIGGER a_write_guard BEFORE INSERT OR UPDATE OR DELETE ON mqi.product_model FOR EACH ROW EXECUTE FUNCTION mqi.write_guard('model_id','mutable','');

CREATE TRIGGER z_audit AFTER INSERT OR UPDATE ON mqi.product_model FOR EACH ROW EXECUTE FUNCTION mqi_audit.capture('model_id');

CREATE TRIGGER a_no_truncate BEFORE TRUNCATE ON mqi.product_model FOR EACH STATEMENT EXECUTE FUNCTION mqi.reject_removal();

ALTER TABLE mqi.product_model ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE mqi.product_model FROM PUBLIC;

CREATE TRIGGER a_write_guard BEFORE INSERT OR UPDATE OR DELETE ON mqi.process FOR EACH ROW EXECUTE FUNCTION mqi.write_guard('process_id','mutable','');

CREATE TRIGGER z_audit AFTER INSERT OR UPDATE ON mqi.process FOR EACH ROW EXECUTE FUNCTION mqi_audit.capture('process_id');

CREATE TRIGGER a_no_truncate BEFORE TRUNCATE ON mqi.process FOR EACH STATEMENT EXECUTE FUNCTION mqi.reject_removal();

ALTER TABLE mqi.process ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE mqi.process FROM PUBLIC;

CREATE TRIGGER a_write_guard BEFORE INSERT OR UPDATE OR DELETE ON mqi.production_line FOR EACH ROW EXECUTE FUNCTION mqi.write_guard('line_id','mutable','');

CREATE TRIGGER z_audit AFTER INSERT OR UPDATE ON mqi.production_line FOR EACH ROW EXECUTE FUNCTION mqi_audit.capture('line_id');

CREATE TRIGGER a_no_truncate BEFORE TRUNCATE ON mqi.production_line FOR EACH STATEMENT EXECUTE FUNCTION mqi.reject_removal();

ALTER TABLE mqi.production_line ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE mqi.production_line FROM PUBLIC;

CREATE TRIGGER a_write_guard BEFORE INSERT OR UPDATE OR DELETE ON mqi.production_lot FOR EACH ROW EXECUTE FUNCTION mqi.write_guard('lot_id','mutable','');

CREATE TRIGGER z_audit AFTER INSERT OR UPDATE ON mqi.production_lot FOR EACH ROW EXECUTE FUNCTION mqi_audit.capture('lot_id');

CREATE TRIGGER a_no_truncate BEFORE TRUNCATE ON mqi.production_lot FOR EACH STATEMENT EXECUTE FUNCTION mqi.reject_removal();

ALTER TABLE mqi.production_lot ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE mqi.production_lot FROM PUBLIC;

CREATE TRIGGER a_write_guard BEFORE INSERT OR UPDATE OR DELETE ON mqi.production_run FOR EACH ROW EXECUTE FUNCTION mqi.write_guard('run_id','mutable','');

CREATE TRIGGER z_audit AFTER INSERT OR UPDATE ON mqi.production_run FOR EACH ROW EXECUTE FUNCTION mqi_audit.capture('run_id');

CREATE TRIGGER a_no_truncate BEFORE TRUNCATE ON mqi.production_run FOR EACH STATEMENT EXECUTE FUNCTION mqi.reject_removal();

ALTER TABLE mqi.production_run ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE mqi.production_run FROM PUBLIC;

CREATE FUNCTION mqi.derive_process_run() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,mqi AS $$ DECLARE v uuid; BEGIN SELECT model_id INTO v FROM mqi.production_run WHERE run_id = NEW.run_id; IF NEW.model_id IS NULL THEN NEW.model_id := v; ELSIF NEW.model_id IS DISTINCT FROM v THEN RAISE EXCEPTION 'context mismatch: process_run.model_id' USING ERRCODE='23514'; END IF; RETURN NEW; END $$;

CREATE TRIGGER b_context BEFORE INSERT OR UPDATE ON mqi.process_run FOR EACH ROW EXECUTE FUNCTION mqi.derive_process_run();

CREATE TRIGGER a_write_guard BEFORE INSERT OR UPDATE OR DELETE ON mqi.process_run FOR EACH ROW EXECUTE FUNCTION mqi.write_guard('process_run_id','mutable','process_id');

CREATE TRIGGER z_audit AFTER INSERT OR UPDATE ON mqi.process_run FOR EACH ROW EXECUTE FUNCTION mqi_audit.capture('process_run_id');

CREATE TRIGGER a_no_truncate BEFORE TRUNCATE ON mqi.process_run FOR EACH STATEMENT EXECUTE FUNCTION mqi.reject_removal();

ALTER TABLE mqi.process_run ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE mqi.process_run FROM PUBLIC;

CREATE TRIGGER a_write_guard BEFORE INSERT OR UPDATE OR DELETE ON mqi.process_run_result FOR EACH ROW EXECUTE FUNCTION mqi.write_guard('process_run_result_id','mutable','');

CREATE TRIGGER z_audit AFTER INSERT OR UPDATE ON mqi.process_run_result FOR EACH ROW EXECUTE FUNCTION mqi_audit.capture('process_run_result_id');

CREATE TRIGGER a_no_truncate BEFORE TRUNCATE ON mqi.process_run_result FOR EACH STATEMENT EXECUTE FUNCTION mqi.reject_removal();

ALTER TABLE mqi.process_run_result ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE mqi.process_run_result FROM PUBLIC;

CREATE FUNCTION mqi.derive_process_run_lot() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,mqi AS $$ DECLARE v uuid; BEGIN SELECT model_id INTO v FROM mqi.process_run WHERE process_run_id = NEW.process_run_id; IF NEW.model_id IS NULL THEN NEW.model_id := v; ELSIF NEW.model_id IS DISTINCT FROM v THEN RAISE EXCEPTION 'context mismatch: process_run_lot.model_id' USING ERRCODE='23514'; END IF; RETURN NEW; END $$;

CREATE TRIGGER b_context BEFORE INSERT OR UPDATE ON mqi.process_run_lot FOR EACH ROW EXECUTE FUNCTION mqi.derive_process_run_lot();

CREATE TRIGGER a_write_guard BEFORE INSERT OR UPDATE OR DELETE ON mqi.process_run_lot FOR EACH ROW EXECUTE FUNCTION mqi.write_guard('process_run_lot_id','mutable','process_run_id,production_lot_id');

CREATE TRIGGER z_audit AFTER INSERT OR UPDATE ON mqi.process_run_lot FOR EACH ROW EXECUTE FUNCTION mqi_audit.capture('process_run_lot_id');

CREATE TRIGGER a_no_truncate BEFORE TRUNCATE ON mqi.process_run_lot FOR EACH STATEMENT EXECUTE FUNCTION mqi.reject_removal();

ALTER TABLE mqi.process_run_lot ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE mqi.process_run_lot FROM PUBLIC;

CREATE TRIGGER a_write_guard BEFORE INSERT OR UPDATE OR DELETE ON mqi.equipment FOR EACH ROW EXECUTE FUNCTION mqi.write_guard('equipment_id','mutable','');

CREATE TRIGGER z_audit AFTER INSERT OR UPDATE ON mqi.equipment FOR EACH ROW EXECUTE FUNCTION mqi_audit.capture('equipment_id');

CREATE TRIGGER a_no_truncate BEFORE TRUNCATE ON mqi.equipment FOR EACH STATEMENT EXECUTE FUNCTION mqi.reject_removal();

ALTER TABLE mqi.equipment ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE mqi.equipment FROM PUBLIC;

CREATE TRIGGER a_write_guard BEFORE INSERT OR UPDATE OR DELETE ON mqi.equipment_position FOR EACH ROW EXECUTE FUNCTION mqi.write_guard('position_id','mutable','equipment_id');

CREATE TRIGGER z_audit AFTER INSERT OR UPDATE ON mqi.equipment_position FOR EACH ROW EXECUTE FUNCTION mqi_audit.capture('position_id');

CREATE TRIGGER a_no_truncate BEFORE TRUNCATE ON mqi.equipment_position FOR EACH STATEMENT EXECUTE FUNCTION mqi.reject_removal();

ALTER TABLE mqi.equipment_position ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE mqi.equipment_position FROM PUBLIC;

CREATE TRIGGER a_write_guard BEFORE INSERT OR UPDATE OR DELETE ON mqi.equipment_connection FOR EACH ROW EXECUTE FUNCTION mqi.write_guard('equipment_connection_id','mutable','');

CREATE TRIGGER z_audit AFTER INSERT OR UPDATE ON mqi.equipment_connection FOR EACH ROW EXECUTE FUNCTION mqi_audit.capture('equipment_connection_id');

CREATE TRIGGER a_no_truncate BEFORE TRUNCATE ON mqi.equipment_connection FOR EACH STATEMENT EXECUTE FUNCTION mqi.reject_removal();

ALTER TABLE mqi.equipment_connection ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE mqi.equipment_connection FROM PUBLIC;

CREATE TRIGGER a_write_guard BEFORE INSERT OR UPDATE OR DELETE ON mqi.process_equipment_usage FOR EACH ROW EXECUTE FUNCTION mqi.write_guard('equipment_usage_id','mutable','process_run_id,equipment_id');

CREATE TRIGGER z_audit AFTER INSERT OR UPDATE ON mqi.process_equipment_usage FOR EACH ROW EXECUTE FUNCTION mqi_audit.capture('equipment_usage_id');

CREATE TRIGGER a_no_truncate BEFORE TRUNCATE ON mqi.process_equipment_usage FOR EACH STATEMENT EXECUTE FUNCTION mqi.reject_removal();

ALTER TABLE mqi.process_equipment_usage ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE mqi.process_equipment_usage FROM PUBLIC;

CREATE TRIGGER a_write_guard BEFORE INSERT OR UPDATE OR DELETE ON mqi.parameter_definition FOR EACH ROW EXECUTE FUNCTION mqi.write_guard('parameter_id','mutable','process_id,value_kind,position_scope,unit');

CREATE TRIGGER z_audit AFTER INSERT OR UPDATE ON mqi.parameter_definition FOR EACH ROW EXECUTE FUNCTION mqi_audit.capture('parameter_id');

CREATE TRIGGER a_no_truncate BEFORE TRUNCATE ON mqi.parameter_definition FOR EACH STATEMENT EXECUTE FUNCTION mqi.reject_removal();

ALTER TABLE mqi.parameter_definition ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE mqi.parameter_definition FROM PUBLIC;

CREATE TRIGGER a_write_guard BEFORE INSERT OR UPDATE OR DELETE ON mqi.process_setup_spec FOR EACH ROW EXECUTE FUNCTION mqi.write_guard('spec_id','mutable','process_id,equipment_id,model_id');

CREATE TRIGGER z_audit AFTER INSERT OR UPDATE ON mqi.process_setup_spec FOR EACH ROW EXECUTE FUNCTION mqi_audit.capture('spec_id');

CREATE TRIGGER a_no_truncate BEFORE TRUNCATE ON mqi.process_setup_spec FOR EACH STATEMENT EXECUTE FUNCTION mqi.reject_removal();

ALTER TABLE mqi.process_setup_spec ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE mqi.process_setup_spec FROM PUBLIC;

CREATE TRIGGER a_write_guard BEFORE INSERT OR UPDATE OR DELETE ON mqi.process_setup_spec_item FOR EACH ROW EXECUTE FUNCTION mqi.write_guard('spec_item_id','mutable','');

CREATE TRIGGER z_audit AFTER INSERT OR UPDATE ON mqi.process_setup_spec_item FOR EACH ROW EXECUTE FUNCTION mqi_audit.capture('spec_item_id');

CREATE TRIGGER a_no_truncate BEFORE TRUNCATE ON mqi.process_setup_spec_item FOR EACH STATEMENT EXECUTE FUNCTION mqi.reject_removal();

ALTER TABLE mqi.process_setup_spec_item ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE mqi.process_setup_spec_item FROM PUBLIC;

CREATE TRIGGER a_write_guard BEFORE INSERT OR UPDATE OR DELETE ON mqi.parameter_observation FOR EACH ROW EXECUTE FUNCTION mqi.write_guard('observation_id','mutable','raw_value_text');

CREATE TRIGGER z_audit AFTER INSERT OR UPDATE ON mqi.parameter_observation FOR EACH ROW EXECUTE FUNCTION mqi_audit.capture('observation_id');

CREATE TRIGGER a_no_truncate BEFORE TRUNCATE ON mqi.parameter_observation FOR EACH STATEMENT EXECUTE FUNCTION mqi.reject_removal();

ALTER TABLE mqi.parameter_observation ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE mqi.parameter_observation FROM PUBLIC;

CREATE TRIGGER a_write_guard BEFORE INSERT OR UPDATE OR DELETE ON mqi.material FOR EACH ROW EXECUTE FUNCTION mqi.write_guard('material_id','mutable','');

CREATE TRIGGER z_audit AFTER INSERT OR UPDATE ON mqi.material FOR EACH ROW EXECUTE FUNCTION mqi_audit.capture('material_id');

CREATE TRIGGER a_no_truncate BEFORE TRUNCATE ON mqi.material FOR EACH STATEMENT EXECUTE FUNCTION mqi.reject_removal();

ALTER TABLE mqi.material ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE mqi.material FROM PUBLIC;

CREATE TRIGGER a_write_guard BEFORE INSERT OR UPDATE OR DELETE ON mqi.material_lot FOR EACH ROW EXECUTE FUNCTION mqi.write_guard('material_lot_id','mutable','');

CREATE TRIGGER z_audit AFTER INSERT OR UPDATE ON mqi.material_lot FOR EACH ROW EXECUTE FUNCTION mqi_audit.capture('material_lot_id');

CREATE TRIGGER a_no_truncate BEFORE TRUNCATE ON mqi.material_lot FOR EACH STATEMENT EXECUTE FUNCTION mqi.reject_removal();

ALTER TABLE mqi.material_lot ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE mqi.material_lot FROM PUBLIC;

CREATE TRIGGER a_write_guard BEFORE INSERT OR UPDATE OR DELETE ON mqi.material_usage FOR EACH ROW EXECUTE FUNCTION mqi.write_guard('material_usage_id','mutable','');

CREATE TRIGGER z_audit AFTER INSERT OR UPDATE ON mqi.material_usage FOR EACH ROW EXECUTE FUNCTION mqi_audit.capture('material_usage_id');

CREATE TRIGGER a_no_truncate BEFORE TRUNCATE ON mqi.material_usage FOR EACH STATEMENT EXECUTE FUNCTION mqi.reject_removal();

ALTER TABLE mqi.material_usage ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE mqi.material_usage FROM PUBLIC;

CREATE TRIGGER a_write_guard BEFORE INSERT OR UPDATE OR DELETE ON mqi.worker FOR EACH ROW EXECUTE FUNCTION mqi.write_guard('worker_id','mutable','');

CREATE TRIGGER z_audit AFTER INSERT OR UPDATE ON mqi.worker FOR EACH ROW EXECUTE FUNCTION mqi_audit.capture('worker_id');

CREATE TRIGGER a_no_truncate BEFORE TRUNCATE ON mqi.worker FOR EACH STATEMENT EXECUTE FUNCTION mqi.reject_removal();

ALTER TABLE mqi.worker ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE mqi.worker FROM PUBLIC;

CREATE TRIGGER a_write_guard BEFORE INSERT OR UPDATE OR DELETE ON mqi.worker_assignment FOR EACH ROW EXECUTE FUNCTION mqi.write_guard('assignment_id','mutable','');

CREATE TRIGGER z_audit AFTER INSERT OR UPDATE ON mqi.worker_assignment FOR EACH ROW EXECUTE FUNCTION mqi_audit.capture('assignment_id');

CREATE TRIGGER a_no_truncate BEFORE TRUNCATE ON mqi.worker_assignment FOR EACH STATEMENT EXECUTE FUNCTION mqi.reject_removal();

ALTER TABLE mqi.worker_assignment ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE mqi.worker_assignment FROM PUBLIC;

CREATE TRIGGER a_write_guard BEFORE INSERT OR UPDATE OR DELETE ON mqi.production_event FOR EACH ROW EXECUTE FUNCTION mqi.write_guard('event_id','mutable','');

CREATE TRIGGER z_audit AFTER INSERT OR UPDATE ON mqi.production_event FOR EACH ROW EXECUTE FUNCTION mqi_audit.capture('event_id');

CREATE TRIGGER a_no_truncate BEFORE TRUNCATE ON mqi.production_event FOR EACH STATEMENT EXECUTE FUNCTION mqi.reject_removal();

ALTER TABLE mqi.production_event ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE mqi.production_event FROM PUBLIC;

CREATE TRIGGER a_write_guard BEFORE INSERT OR UPDATE OR DELETE ON mqi.quality_check FOR EACH ROW EXECUTE FUNCTION mqi.write_guard('quality_check_id','mutable','');

CREATE TRIGGER z_audit AFTER INSERT OR UPDATE ON mqi.quality_check FOR EACH ROW EXECUTE FUNCTION mqi_audit.capture('quality_check_id');

CREATE TRIGGER a_no_truncate BEFORE TRUNCATE ON mqi.quality_check FOR EACH STATEMENT EXECUTE FUNCTION mqi.reject_removal();

ALTER TABLE mqi.quality_check ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE mqi.quality_check FROM PUBLIC;

CREATE TRIGGER a_write_guard BEFORE INSERT OR UPDATE OR DELETE ON mqi.measurement FOR EACH ROW EXECUTE FUNCTION mqi.write_guard('measurement_id','mutable','raw_value_text');

CREATE TRIGGER z_audit AFTER INSERT OR UPDATE ON mqi.measurement FOR EACH ROW EXECUTE FUNCTION mqi_audit.capture('measurement_id');

CREATE TRIGGER a_no_truncate BEFORE TRUNCATE ON mqi.measurement FOR EACH STATEMENT EXECUTE FUNCTION mqi.reject_removal();

ALTER TABLE mqi.measurement ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE mqi.measurement FROM PUBLIC;

CREATE TRIGGER a_write_guard BEFORE INSERT OR UPDATE OR DELETE ON mqi.inspection_run FOR EACH ROW EXECUTE FUNCTION mqi.write_guard('inspection_run_id','mutable','');

CREATE TRIGGER z_audit AFTER INSERT OR UPDATE ON mqi.inspection_run FOR EACH ROW EXECUTE FUNCTION mqi_audit.capture('inspection_run_id');

CREATE TRIGGER a_no_truncate BEFORE TRUNCATE ON mqi.inspection_run FOR EACH STATEMENT EXECUTE FUNCTION mqi.reject_removal();

ALTER TABLE mqi.inspection_run ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE mqi.inspection_run FROM PUBLIC;

CREATE FUNCTION mqi.derive_inspection_lot() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,mqi AS $$ DECLARE v uuid; BEGIN SELECT model_id INTO v FROM mqi.inspection_run WHERE inspection_run_id = NEW.inspection_run_id; IF NEW.model_id IS NULL THEN NEW.model_id := v; ELSIF NEW.model_id IS DISTINCT FROM v THEN RAISE EXCEPTION 'context mismatch: inspection_lot.model_id' USING ERRCODE='23514'; END IF; RETURN NEW; END $$;

CREATE TRIGGER b_context BEFORE INSERT OR UPDATE ON mqi.inspection_lot FOR EACH ROW EXECUTE FUNCTION mqi.derive_inspection_lot();

CREATE TRIGGER a_write_guard BEFORE INSERT OR UPDATE OR DELETE ON mqi.inspection_lot FOR EACH ROW EXECUTE FUNCTION mqi.write_guard('inspection_lot_id','mutable','');

CREATE TRIGGER z_audit AFTER INSERT OR UPDATE ON mqi.inspection_lot FOR EACH ROW EXECUTE FUNCTION mqi_audit.capture('inspection_lot_id');

CREATE TRIGGER a_no_truncate BEFORE TRUNCATE ON mqi.inspection_lot FOR EACH STATEMENT EXECUTE FUNCTION mqi.reject_removal();

ALTER TABLE mqi.inspection_lot ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE mqi.inspection_lot FROM PUBLIC;

CREATE FUNCTION mqi.derive_inspection_run_link() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,mqi AS $$ DECLARE v uuid; BEGIN SELECT model_id INTO v FROM mqi.inspection_run WHERE inspection_run_id = NEW.prior_inspection_run_id; IF NEW.model_id IS NULL THEN NEW.model_id := v; ELSIF NEW.model_id IS DISTINCT FROM v THEN RAISE EXCEPTION 'context mismatch: inspection_run_link.model_id' USING ERRCODE='23514'; END IF; RETURN NEW; END $$;

CREATE TRIGGER b_context BEFORE INSERT OR UPDATE ON mqi.inspection_run_link FOR EACH ROW EXECUTE FUNCTION mqi.derive_inspection_run_link();

CREATE TRIGGER a_write_guard BEFORE INSERT OR UPDATE OR DELETE ON mqi.inspection_run_link FOR EACH ROW EXECUTE FUNCTION mqi.write_guard('inspection_run_link_id','mutable','');

CREATE TRIGGER z_audit AFTER INSERT OR UPDATE ON mqi.inspection_run_link FOR EACH ROW EXECUTE FUNCTION mqi_audit.capture('inspection_run_link_id');

CREATE TRIGGER a_no_truncate BEFORE TRUNCATE ON mqi.inspection_run_link FOR EACH STATEMENT EXECUTE FUNCTION mqi.reject_removal();

ALTER TABLE mqi.inspection_run_link ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE mqi.inspection_run_link FROM PUBLIC;

CREATE TRIGGER a_write_guard BEFORE INSERT OR UPDATE OR DELETE ON mqi.defect_type FOR EACH ROW EXECUTE FUNCTION mqi.write_guard('defect_type_id','mutable','');

CREATE TRIGGER z_audit AFTER INSERT OR UPDATE ON mqi.defect_type FOR EACH ROW EXECUTE FUNCTION mqi_audit.capture('defect_type_id');

CREATE TRIGGER a_no_truncate BEFORE TRUNCATE ON mqi.defect_type FOR EACH STATEMENT EXECUTE FUNCTION mqi.reject_removal();

ALTER TABLE mqi.defect_type ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE mqi.defect_type FROM PUBLIC;

CREATE TRIGGER a_write_guard BEFORE INSERT OR UPDATE OR DELETE ON mqi.quality_finding FOR EACH ROW EXECUTE FUNCTION mqi.write_guard('quality_finding_id','mutable','raw_quantity_text,raw_defect_name');

CREATE TRIGGER z_audit AFTER INSERT OR UPDATE ON mqi.quality_finding FOR EACH ROW EXECUTE FUNCTION mqi_audit.capture('quality_finding_id');

CREATE TRIGGER a_no_truncate BEFORE TRUNCATE ON mqi.quality_finding FOR EACH STATEMENT EXECUTE FUNCTION mqi.reject_removal();

ALTER TABLE mqi.quality_finding ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE mqi.quality_finding FROM PUBLIC;

CREATE TRIGGER a_write_guard BEFORE INSERT OR UPDATE OR DELETE ON mqi.lot_code_scheme FOR EACH ROW EXECUTE FUNCTION mqi.write_guard('scheme_id','mutable','');

CREATE TRIGGER z_audit AFTER INSERT OR UPDATE ON mqi.lot_code_scheme FOR EACH ROW EXECUTE FUNCTION mqi_audit.capture('scheme_id');

CREATE TRIGGER a_no_truncate BEFORE TRUNCATE ON mqi.lot_code_scheme FOR EACH STATEMENT EXECUTE FUNCTION mqi.reject_removal();

ALTER TABLE mqi.lot_code_scheme ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE mqi.lot_code_scheme FROM PUBLIC;

CREATE TRIGGER a_write_guard BEFORE INSERT OR UPDATE OR DELETE ON mqi.lot_code_mapping FOR EACH ROW EXECUTE FUNCTION mqi.write_guard('mapping_id','mutable','scheme_id,marking_code,lot_date');

CREATE TRIGGER z_audit AFTER INSERT OR UPDATE ON mqi.lot_code_mapping FOR EACH ROW EXECUTE FUNCTION mqi_audit.capture('mapping_id');

CREATE TRIGGER a_no_truncate BEFORE TRUNCATE ON mqi.lot_code_mapping FOR EACH STATEMENT EXECUTE FUNCTION mqi.reject_removal();

ALTER TABLE mqi.lot_code_mapping ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE mqi.lot_code_mapping FROM PUBLIC;

CREATE TRIGGER a_write_guard BEFORE INSERT OR UPDATE OR DELETE ON mqi.rework_record FOR EACH ROW EXECUTE FUNCTION mqi.write_guard('rework_id','mutable','serial_start_raw,serial_end_raw,raw_note');

CREATE TRIGGER z_audit AFTER INSERT OR UPDATE ON mqi.rework_record FOR EACH ROW EXECUTE FUNCTION mqi_audit.capture('rework_id');

CREATE TRIGGER a_no_truncate BEFORE TRUNCATE ON mqi.rework_record FOR EACH STATEMENT EXECUTE FUNCTION mqi.reject_removal();

ALTER TABLE mqi.rework_record ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE mqi.rework_record FROM PUBLIC;

CREATE FUNCTION mqi.derive_rework_origin_link() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,mqi AS $$ DECLARE v uuid; BEGIN SELECT model_id INTO v FROM mqi.rework_record WHERE rework_id = NEW.rework_id; IF NEW.model_id IS NULL THEN NEW.model_id := v; ELSIF NEW.model_id IS DISTINCT FROM v THEN RAISE EXCEPTION 'context mismatch: rework_origin_link.model_id' USING ERRCODE='23514'; END IF; RETURN NEW; END $$;

CREATE TRIGGER b_context BEFORE INSERT OR UPDATE ON mqi.rework_origin_link FOR EACH ROW EXECUTE FUNCTION mqi.derive_rework_origin_link();

CREATE TRIGGER a_write_guard BEFORE INSERT OR UPDATE OR DELETE ON mqi.rework_origin_link FOR EACH ROW EXECUTE FUNCTION mqi.write_guard('rework_origin_link_id','mutable','');

CREATE TRIGGER z_audit AFTER INSERT OR UPDATE ON mqi.rework_origin_link FOR EACH ROW EXECUTE FUNCTION mqi_audit.capture('rework_origin_link_id');

CREATE TRIGGER a_no_truncate BEFORE TRUNCATE ON mqi.rework_origin_link FOR EACH STATEMENT EXECUTE FUNCTION mqi.reject_removal();

ALTER TABLE mqi.rework_origin_link ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE mqi.rework_origin_link FROM PUBLIC;

CREATE TRIGGER a_write_guard BEFORE INSERT OR UPDATE OR DELETE ON mqi.traceability_card FOR EACH ROW EXECUTE FUNCTION mqi.write_guard('traceability_card_id','mutable','');

CREATE TRIGGER z_audit AFTER INSERT OR UPDATE ON mqi.traceability_card FOR EACH ROW EXECUTE FUNCTION mqi_audit.capture('traceability_card_id');

CREATE TRIGGER a_no_truncate BEFORE TRUNCATE ON mqi.traceability_card FOR EACH STATEMENT EXECUTE FUNCTION mqi.reject_removal();

ALTER TABLE mqi.traceability_card ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE mqi.traceability_card FROM PUBLIC;

CREATE TRIGGER a_write_guard BEFORE INSERT OR UPDATE OR DELETE ON mqi.source_ingest FOR EACH ROW EXECUTE FUNCTION mqi.write_guard('ingest_id','mutable','started_at,ingest_method');

CREATE TRIGGER z_audit AFTER INSERT OR UPDATE ON mqi.source_ingest FOR EACH ROW EXECUTE FUNCTION mqi_audit.capture('ingest_id');

CREATE TRIGGER a_no_truncate BEFORE TRUNCATE ON mqi.source_ingest FOR EACH STATEMENT EXECUTE FUNCTION mqi.reject_removal();

ALTER TABLE mqi.source_ingest ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE mqi.source_ingest FROM PUBLIC;

CREATE TRIGGER a_write_guard BEFORE INSERT OR UPDATE OR DELETE ON mqi.source_bundle FOR EACH ROW EXECUTE FUNCTION mqi.write_guard('bundle_id','append','');

CREATE TRIGGER z_audit AFTER INSERT OR UPDATE ON mqi.source_bundle FOR EACH ROW EXECUTE FUNCTION mqi_audit.capture('bundle_id');

CREATE TRIGGER a_no_truncate BEFORE TRUNCATE ON mqi.source_bundle FOR EACH STATEMENT EXECUTE FUNCTION mqi.reject_removal();

ALTER TABLE mqi.source_bundle ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE mqi.source_bundle FROM PUBLIC;

CREATE TRIGGER a_write_guard BEFORE INSERT OR UPDATE OR DELETE ON mqi.source_asset FOR EACH ROW EXECUTE FUNCTION mqi.write_guard('asset_id','append','');

CREATE TRIGGER z_audit AFTER INSERT OR UPDATE ON mqi.source_asset FOR EACH ROW EXECUTE FUNCTION mqi_audit.capture('asset_id');

CREATE TRIGGER a_no_truncate BEFORE TRUNCATE ON mqi.source_asset FOR EACH STATEMENT EXECUTE FUNCTION mqi.reject_removal();

ALTER TABLE mqi.source_asset ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE mqi.source_asset FROM PUBLIC;

CREATE TRIGGER a_write_guard BEFORE INSERT OR UPDATE OR DELETE ON mqi.source_bundle_asset FOR EACH ROW EXECUTE FUNCTION mqi.write_guard('bundle_asset_id','append','');

CREATE TRIGGER z_audit AFTER INSERT OR UPDATE ON mqi.source_bundle_asset FOR EACH ROW EXECUTE FUNCTION mqi_audit.capture('bundle_asset_id');

CREATE TRIGGER a_no_truncate BEFORE TRUNCATE ON mqi.source_bundle_asset FOR EACH STATEMENT EXECUTE FUNCTION mqi.reject_removal();

ALTER TABLE mqi.source_bundle_asset ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE mqi.source_bundle_asset FROM PUBLIC;

CREATE TRIGGER a_write_guard BEFORE INSERT OR UPDATE OR DELETE ON mqi.source_document FOR EACH ROW EXECUTE FUNCTION mqi.write_guard('document_id','mutable','');

CREATE TRIGGER z_audit AFTER INSERT OR UPDATE ON mqi.source_document FOR EACH ROW EXECUTE FUNCTION mqi_audit.capture('document_id');

CREATE TRIGGER a_no_truncate BEFORE TRUNCATE ON mqi.source_document FOR EACH STATEMENT EXECUTE FUNCTION mqi.reject_removal();

ALTER TABLE mqi.source_document ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE mqi.source_document FROM PUBLIC;

CREATE TRIGGER a_write_guard BEFORE INSERT OR UPDATE OR DELETE ON mqi.source_document_version FOR EACH ROW EXECUTE FUNCTION mqi.write_guard('document_version_id','append','');

CREATE TRIGGER z_audit AFTER INSERT OR UPDATE ON mqi.source_document_version FOR EACH ROW EXECUTE FUNCTION mqi_audit.capture('document_version_id');

CREATE TRIGGER a_no_truncate BEFORE TRUNCATE ON mqi.source_document_version FOR EACH STATEMENT EXECUTE FUNCTION mqi.reject_removal();

ALTER TABLE mqi.source_document_version ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE mqi.source_document_version FROM PUBLIC;

CREATE TRIGGER a_write_guard BEFORE INSERT OR UPDATE OR DELETE ON mqi.source_page FOR EACH ROW EXECUTE FUNCTION mqi.write_guard('source_page_id','append','');

CREATE TRIGGER z_audit AFTER INSERT OR UPDATE ON mqi.source_page FOR EACH ROW EXECUTE FUNCTION mqi_audit.capture('source_page_id');

CREATE TRIGGER a_no_truncate BEFORE TRUNCATE ON mqi.source_page FOR EACH STATEMENT EXECUTE FUNCTION mqi.reject_removal();

ALTER TABLE mqi.source_page ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE mqi.source_page FROM PUBLIC;

CREATE TRIGGER a_write_guard BEFORE INSERT OR UPDATE OR DELETE ON mqi.form_template FOR EACH ROW EXECUTE FUNCTION mqi.write_guard('template_id','mutable','');

CREATE TRIGGER z_audit AFTER INSERT OR UPDATE ON mqi.form_template FOR EACH ROW EXECUTE FUNCTION mqi_audit.capture('template_id');

CREATE TRIGGER a_no_truncate BEFORE TRUNCATE ON mqi.form_template FOR EACH STATEMENT EXECUTE FUNCTION mqi.reject_removal();

ALTER TABLE mqi.form_template ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE mqi.form_template FROM PUBLIC;

CREATE TRIGGER a_write_guard BEFORE INSERT OR UPDATE OR DELETE ON mqi.form_field_definition FOR EACH ROW EXECUTE FUNCTION mqi.write_guard('form_field_id','mutable','');

CREATE TRIGGER z_audit AFTER INSERT OR UPDATE ON mqi.form_field_definition FOR EACH ROW EXECUTE FUNCTION mqi_audit.capture('form_field_id');

CREATE TRIGGER a_no_truncate BEFORE TRUNCATE ON mqi.form_field_definition FOR EACH STATEMENT EXECUTE FUNCTION mqi.reject_removal();

ALTER TABLE mqi.form_field_definition ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE mqi.form_field_definition FROM PUBLIC;

CREATE FUNCTION mqi.derive_source_location() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,mqi AS $$ DECLARE v uuid; BEGIN SELECT asset_id INTO v FROM mqi.source_bundle_asset WHERE bundle_asset_id = NEW.bundle_asset_id; IF NEW.asset_id IS NULL THEN NEW.asset_id := v; ELSIF NEW.asset_id IS DISTINCT FROM v THEN RAISE EXCEPTION 'context mismatch: source_location.asset_id' USING ERRCODE='23514'; END IF; RETURN NEW; END $$;

CREATE TRIGGER b_context BEFORE INSERT OR UPDATE ON mqi.source_location FOR EACH ROW EXECUTE FUNCTION mqi.derive_source_location();

CREATE TRIGGER a_write_guard BEFORE INSERT OR UPDATE OR DELETE ON mqi.source_location FOR EACH ROW EXECUTE FUNCTION mqi.write_guard('source_location_id','append','');

CREATE TRIGGER z_audit AFTER INSERT OR UPDATE ON mqi.source_location FOR EACH ROW EXECUTE FUNCTION mqi_audit.capture('source_location_id');

CREATE TRIGGER a_no_truncate BEFORE TRUNCATE ON mqi.source_location FOR EACH STATEMENT EXECUTE FUNCTION mqi.reject_removal();

ALTER TABLE mqi.source_location ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE mqi.source_location FROM PUBLIC;

CREATE TRIGGER a_write_guard BEFORE INSERT OR UPDATE OR DELETE ON mqi.extraction_run FOR EACH ROW EXECUTE FUNCTION mqi.write_guard('extraction_run_id','mutable','bundle_asset_id,extraction_method,model_name,prompt_version,parser_version,started_at');

CREATE TRIGGER z_audit AFTER INSERT OR UPDATE ON mqi.extraction_run FOR EACH ROW EXECUTE FUNCTION mqi_audit.capture('extraction_run_id');

CREATE TRIGGER a_no_truncate BEFORE TRUNCATE ON mqi.extraction_run FOR EACH STATEMENT EXECUTE FUNCTION mqi.reject_removal();

ALTER TABLE mqi.extraction_run ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE mqi.extraction_run FROM PUBLIC;

CREATE FUNCTION mqi.derive_extracted_field() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,mqi AS $$ DECLARE v uuid; BEGIN SELECT bundle_asset_id INTO v FROM mqi.extraction_run WHERE extraction_run_id = NEW.extraction_run_id; IF NEW.bundle_asset_id IS NULL THEN NEW.bundle_asset_id := v; ELSIF NEW.bundle_asset_id IS DISTINCT FROM v THEN RAISE EXCEPTION 'context mismatch: extracted_field.bundle_asset_id' USING ERRCODE='23514'; END IF; RETURN NEW; END $$;

CREATE TRIGGER b_context BEFORE INSERT OR UPDATE ON mqi.extracted_field FOR EACH ROW EXECUTE FUNCTION mqi.derive_extracted_field();

CREATE TRIGGER a_write_guard BEFORE INSERT OR UPDATE OR DELETE ON mqi.extracted_field FOR EACH ROW EXECUTE FUNCTION mqi.write_guard('extracted_field_id','mutable','extraction_run_id,source_location_id,form_field_id,field_code,raw_value,extracted_value,raw_formula_text,confidence,extracted_at,bundle_asset_id');

CREATE TRIGGER z_audit AFTER INSERT OR UPDATE ON mqi.extracted_field FOR EACH ROW EXECUTE FUNCTION mqi_audit.capture('extracted_field_id');

CREATE TRIGGER a_no_truncate BEFORE TRUNCATE ON mqi.extracted_field FOR EACH STATEMENT EXECUTE FUNCTION mqi.reject_removal();

ALTER TABLE mqi.extracted_field ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE mqi.extracted_field FROM PUBLIC;

CREATE TRIGGER a_write_guard BEFORE INSERT OR UPDATE OR DELETE ON mqi.field_review FOR EACH ROW EXECUTE FUNCTION mqi.write_guard('field_review_id','append','');

CREATE TRIGGER z_audit AFTER INSERT OR UPDATE ON mqi.field_review FOR EACH ROW EXECUTE FUNCTION mqi_audit.capture('field_review_id');

CREATE TRIGGER a_no_truncate BEFORE TRUNCATE ON mqi.field_review FOR EACH STATEMENT EXECUTE FUNCTION mqi.reject_removal();

ALTER TABLE mqi.field_review ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE mqi.field_review FROM PUBLIC;

CREATE TRIGGER a_write_guard BEFORE INSERT OR UPDATE OR DELETE ON mqi.field_provenance_link FOR EACH ROW EXECUTE FUNCTION mqi.write_guard('provenance_link_id','append','');

CREATE TRIGGER z_audit AFTER INSERT OR UPDATE ON mqi.field_provenance_link FOR EACH ROW EXECUTE FUNCTION mqi_audit.capture('provenance_link_id');

CREATE TRIGGER a_no_truncate BEFORE TRUNCATE ON mqi.field_provenance_link FOR EACH STATEMENT EXECUTE FUNCTION mqi.reject_removal();

ALTER TABLE mqi.field_provenance_link ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE mqi.field_provenance_link FROM PUBLIC;

CREATE FUNCTION mqi.derive_source_run_link() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,mqi AS $$ DECLARE v uuid; BEGIN SELECT asset_id INTO v FROM mqi.source_bundle_asset WHERE bundle_asset_id = NEW.bundle_asset_id; IF NEW.asset_id IS NULL THEN NEW.asset_id := v; ELSIF NEW.asset_id IS DISTINCT FROM v THEN RAISE EXCEPTION 'context mismatch: source_run_link.asset_id' USING ERRCODE='23514'; END IF; RETURN NEW; END $$;

CREATE TRIGGER b_context BEFORE INSERT OR UPDATE ON mqi.source_run_link FOR EACH ROW EXECUTE FUNCTION mqi.derive_source_run_link();

CREATE TRIGGER a_write_guard BEFORE INSERT OR UPDATE OR DELETE ON mqi.source_run_link FOR EACH ROW EXECUTE FUNCTION mqi.write_guard('source_run_link_id','mutable','');

CREATE TRIGGER z_audit AFTER INSERT OR UPDATE ON mqi.source_run_link FOR EACH ROW EXECUTE FUNCTION mqi_audit.capture('source_run_link_id');

CREATE TRIGGER a_no_truncate BEFORE TRUNCATE ON mqi.source_run_link FOR EACH STATEMENT EXECUTE FUNCTION mqi.reject_removal();

ALTER TABLE mqi.source_run_link ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE mqi.source_run_link FROM PUBLIC;

CREATE TRIGGER c_semantics BEFORE INSERT OR UPDATE ON mqi.source_bundle FOR EACH ROW EXECUTE FUNCTION mqi.validate_semantics();

CREATE TRIGGER c_semantics BEFORE INSERT OR UPDATE ON mqi.quality_finding FOR EACH ROW EXECUTE FUNCTION mqi.validate_semantics();

CREATE TRIGGER c_semantics BEFORE INSERT OR UPDATE ON mqi.inspection_run_link FOR EACH ROW EXECUTE FUNCTION mqi.validate_semantics();

CREATE TRIGGER c_semantics BEFORE INSERT OR UPDATE ON mqi.parameter_observation FOR EACH ROW EXECUTE FUNCTION mqi.validate_semantics();

CREATE TRIGGER c_semantics BEFORE INSERT OR UPDATE ON mqi.process_setup_spec_item FOR EACH ROW EXECUTE FUNCTION mqi.validate_semantics();

CREATE TRIGGER c_semantics BEFORE INSERT OR UPDATE ON mqi.rework_record FOR EACH ROW EXECUTE FUNCTION mqi.validate_semantics();

CREATE TRIGGER c_semantics BEFORE INSERT OR UPDATE ON mqi.rework_origin_link FOR EACH ROW EXECUTE FUNCTION mqi.validate_semantics();

CREATE TRIGGER c_semantics BEFORE INSERT OR UPDATE ON mqi.extracted_field FOR EACH ROW EXECUTE FUNCTION mqi.validate_semantics();

CREATE TRIGGER c_semantics BEFORE INSERT OR UPDATE ON mqi.field_review FOR EACH ROW EXECUTE FUNCTION mqi.validate_semantics();

CREATE TRIGGER c_semantics BEFORE INSERT OR UPDATE ON mqi.field_provenance_link FOR EACH ROW EXECUTE FUNCTION mqi.validate_semantics();

REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA mqi, mqi_audit FROM PUBLIC;

DO $$ DECLARE r text; BEGIN FOREACH r IN ARRAY ARRAY['anon','authenticated','service_role'] LOOP IF EXISTS(SELECT 1 FROM pg_roles WHERE rolname=r) THEN EXECUTE format('REVOKE ALL ON SCHEMA mqi, mqi_audit FROM %I',r); EXECUTE format('REVOKE ALL ON ALL TABLES IN SCHEMA mqi, mqi_audit FROM %I',r); EXECUTE format('REVOKE ALL ON ALL SEQUENCES IN SCHEMA mqi, mqi_audit FROM %I',r); EXECUTE format('REVOKE ALL ON ALL FUNCTIONS IN SCHEMA mqi, mqi_audit FROM %I',r); END IF; END LOOP; END $$;

-- MQI FUNCTION ACL: keep this block last in every migration.
-- Schema-scoped default REVOKE cannot undo PostgreSQL's global PUBLIC EXECUTE.
-- Apply explicit ACLs before this migration transaction commits; no global defaults changed.
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA mqi, mqi_audit FROM PUBLIC;
DO $mqi_function_acl$
DECLARE app_role text;
BEGIN
    FOREACH app_role IN ARRAY ARRAY['anon', 'authenticated', 'service_role'] LOOP
        IF EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = app_role) THEN
            EXECUTE format('REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA mqi, mqi_audit FROM %I', app_role);
        END IF;
    END LOOP;
END
$mqi_function_acl$;
