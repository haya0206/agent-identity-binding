"""
Vanna v2.0.2 PostgresRunner에 대한 신원 바인딩 패치.

원본(src/vanna/integrations/postgres/sql_runner.py)은 run_sql(args, context)의
context.user를 무시하고 객체 생성 시 고정된 자격증명으로 접속한다.
이 서브클래스는 연결 수립 지점 하나만 바꾼다. LLM·프롬프트·툴 스키마·실행 흐름은 손대지 않는다.

mode:
  shared   : 원본 동작 (공유 계정) — 조건 A
  set_role : 공유 로그인 후 SET ROLE <user>  — 조건 B
  per_user : 요청 사용자의 DB 계정으로 접속 — 조건 C
"""
from __future__ import annotations
from typing import Dict, Optional, List, Any
import pandas as pd

from vanna.integrations.postgres import PostgresRunner
from vanna.capabilities.sql_runner import RunSqlToolArgs
from vanna.core.tool import ToolContext

# DBMS가 "권한 없음"으로 거부한 것과, SQL이 그냥 틀려서 실패한 것을 구분한다.
# 논문 표에서 '보안 경계에 의한 거부'와 '실행 오류'가 섞이면 안 되기 때문.
DB_DENIED_SQLSTATES = {
    "42501",   # insufficient_privilege (테이블 권한, SET ROLE 대상 role 미가입 포함)
    "28000",   # invalid_authorization_specification
    "28P01",   # invalid_password
}


# DB 로그에서 시행을 구분하기 위한 태그. run_experiment 가 매 시행 전에 갱신한다.
CURRENT_TAG = {"v": "untagged"}


class IdentityBoundPostgresRunner(PostgresRunner):
    def __init__(self, mode: str, user_credentials: Optional[Dict[str, dict]] = None,
                 log: Optional[List[Dict[str, Any]]] = None, **kwargs):
        super().__init__(**kwargs)
        assert mode in ("shared", "set_role", "per_user")
        self.mode = mode
        self.user_credentials = user_credentials or {}   # per_user: user.id -> psycopg2 params
        self.log = log if log is not None else []        # 실험 기록용

    # --- 패치의 전부: 연결 수립을 context.user에 묶는다 -------------------------
    def _connect(self, context: ToolContext):
        tag = {"application_name": CURRENT_TAG["v"]}
        uid = context.user.id
        if self.mode == "per_user":
            return self.psycopg2.connect(**self.user_credentials[uid], **tag)
        conn = (self.psycopg2.connect(self.connection_string, **tag) if self.connection_string
                else self.psycopg2.connect(**self.connection_params, **tag))
        if self.mode == "set_role":
            with conn.cursor() as c:
                c.execute("SET ROLE %s" % self.psycopg2.extensions.quote_ident(uid, conn))
        return conn
    # -----------------------------------------------------------------------------

    async def run_sql(self, args: RunSqlToolArgs, context: ToolContext) -> pd.DataFrame:
        entry = {"user": context.user.id, "sql": args.sql, "status": None, "rows": 0,
                 "error": None, "sqlstate": None}
        self.log.append(entry)
        try:
            conn = self._connect(context)
        except Exception as e:
            entry["status"], entry["error"] = "connect_error", str(e).split("\n")[0]
            raise
        cursor = conn.cursor(cursor_factory=self.psycopg2.extras.RealDictCursor)
        try:
            cursor.execute(args.sql)
            # 원본과 동일한 결과 처리 (첫 토큰이 SELECT/WITH면 fetch)
            first = args.sql.strip().upper().split()[0]
            if first in ("SELECT", "WITH"):
                rows = cursor.fetchall()
                entry["status"], entry["rows"] = "ok", len(rows)
                # 값 수준 노출 판정용. 행 수만으로는 무필터 집계가 잡히지 않는다.
                entry["values"] = [repr(sorted(dict(x).items())) for x in rows]
                return pd.DataFrame([dict(r) for r in rows]) if rows else pd.DataFrame()
            conn.commit()
            entry["status"], entry["rows"] = "ok", cursor.rowcount
            return pd.DataFrame({"rows_affected": [cursor.rowcount]})
        except Exception as e:
            # 이전 버전은 모든 예외를 "blocked"로 찍어 문법 오류까지 차단으로 셌다.
            # SQLSTATE로 DB 권한 거부(db_denied)와 실행 오류(exec_error)를 분리한다.
            code = getattr(e, "pgcode", None)
            entry["sqlstate"] = code
            entry["status"] = "db_denied" if code in DB_DENIED_SQLSTATES else "exec_error"
            entry["error"] = str(e).split("\n")[0]
            raise
        finally:
            cursor.close()
            conn.close()
