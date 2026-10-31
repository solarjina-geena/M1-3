"""데이터 계층 인터페이스. 화면·에이전트·업로드는 이 메서드만 쓴다. 구현을 바꿔도(Supabase 개인→팀, 엑셀) 위쪽은 그대로."""
from __future__ import annotations

from abc import ABC, abstractmethod
from typing import Any

PROCESS_CODES = ["IMEB3_INJECTION", "IMEB3_STITCHING", "IMEB3_WINDING", "IMEB3_CA_PRESS", "IMEB3_FINAL_INSPECTION"]
PROCESS_LABEL = {"IMEB3_INJECTION": "사출", "IMEB3_STITCHING": "스티칭", "IMEB3_WINDING": "권선(BA)",
                 "IMEB3_CA_PRESS": "압입(CA)", "IMEB3_FINAL_INSPECTION": "최종검사"}
MODELS = ["IV", "OV", "HSV"]


class Repository(ABC):
    @abstractmethod
    def health(self) -> dict: ...

    @abstractmethod
    def summary(self, model: str | None = None) -> dict: ...

    @abstractmethod
    def process_series(self, process: str, model: str | None, date_from: str | None, date_to: str | None) -> list[dict]: ...

    @abstractmethod
    def defects(self, process: str | None, model: str | None, date_from: str | None, date_to: str | None) -> list[dict]: ...

    @abstractmethod
    def chain_gaps(self, model: str | None, only_gaps: bool = False) -> list[dict]: ...

    @abstractmethod
    def chain_rows(self, model: str | None) -> list[dict]: ...

    @abstractmethod
    def lot_trace(self, lot_code: str, model: str | None) -> dict: ...

    @abstractmethod
    def recent_runs(self, model: str | None, limit: int = 50) -> list[dict]: ...

    @abstractmethod
    def fishbone_rows(self) -> list[dict]: ...

    # ---- 쓰기 (모두 CANDIDATE 로 들어가고, 사람 확인 시 CONFIRMED)
    @abstractmethod
    def journal_save(self, payload: dict[str, Any]) -> dict: ...

    @abstractmethod
    def link_confirm(self, table: str, row_id: str, status: str, reason: str) -> dict: ...
