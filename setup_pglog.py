"""(2) DB 서버에서 모든 문장을 기록하고, 세션마다 application_name 에 실행 ID를 박는다.

하네스가 무엇을 놓치든 DB 가 받은 문장은 전부 남는다. 오라클의 재실행도 같은 DB 로 가므로
'oracle' 태그로 분리해야 에이전트 문장만 셀 수 있다. 멱등.
"""
import os
import pathlib
import shutil
import subprocess

HOME = pathlib.Path.home()
# 하네스는 이 스크립트와 같은 디렉토리에 있다고 본다.
BASE = pathlib.Path(__file__).resolve().parent
CONF = pathlib.Path(os.getenv("PGDATA", HOME / "pgdata")) / "postgresql.conf"
B, E = "# --- experiment statement logging (managed) ---", "# --- end experiment statement logging ---"

# ---------------------------------------------------------------- postgresql.conf
conf = CONF.read_text(encoding="utf-8")
if B in conf:
    print("postgresql.conf: already configured")
else:
    shutil.copy2(CONF, CONF.with_suffix(".conf.bak-logging"))
    conf += f"""
{B}
log_statement = 'all'
# %a = application_name. 하네스가 실행ID|mode|payload|rep 을 넣는다. 오라클은 'oracle:...'.
log_line_prefix = '%m [%p] %q%u@%d app=%a '
log_min_duration_statement = -1
log_rotation_size = 200MB
{E}
"""
    CONF.write_text(conf, encoding="utf-8")
    print("postgresql.conf: logging block appended")

subprocess.run([str(HOME / "pg/bin/pg_ctl"), "-D", str(HOME / "pgdata"), "reload"], check=True)

# ---------------------------------------------------------------- runner: 태그 주입
r = BASE / "identity_bound_runner.py"
src = r.read_text(encoding="utf-8")
if "CURRENT_TAG" in src:
    print(f"{r.name}: already tagged")
else:
    shutil.copy2(r, r.with_suffix(".py.bak-tag"))
    # 모듈 전역 태그. run_experiment 가 매 시행 전에 갱신한다.
    anchor = "    def _connect(self, context: ToolContext):"
    assert anchor in src, "runner _connect not found"
    src = src.replace(
        anchor,
        '''    def _connect(self, context: ToolContext):
        tag = {"application_name": CURRENT_TAG["v"]}''',
        1,
    )
    src = src.replace(
        "            return self.psycopg2.connect(**self.user_credentials[uid])",
        "            return self.psycopg2.connect(**self.user_credentials[uid], **tag)", 1)
    src = src.replace(
        "        conn = (self.psycopg2.connect(self.connection_string) if self.connection_string\n"
        "                else self.psycopg2.connect(**self.connection_params))",
        "        conn = (self.psycopg2.connect(self.connection_string, **tag) if self.connection_string\n"
        "                else self.psycopg2.connect(**self.connection_params, **tag))", 1)
    # 전역 선언을 클래스 앞에 삽입
    cls = "class IdentityBoundPostgresRunner"
    assert cls in src
    src = src.replace(
        cls,
        '# DB 로그에서 시행을 구분하기 위한 태그. run_experiment 가 매 시행 전에 갱신한다.\n'
        'CURRENT_TAG = {"v": "untagged"}\n\n\n' + cls, 1)
    r.write_text(src, encoding="utf-8")
    print(f"{r.name}: application_name tagging added")

# ---------------------------------------------------------------- experiment: 태그 갱신 + 오라클 태그
e = BASE / "run_experiment.py"
src = e.read_text(encoding="utf-8")
if "RUN_ID" in src:
    print(f"{e.name}: already tagged")
else:
    shutil.copy2(e, e.with_suffix(".py.bak-tag"))

    src = src.replace(
        "from identity_bound_runner import IdentityBoundPostgresRunner",
        "import identity_bound_runner\n"
        "from identity_bound_runner import IdentityBoundPostgresRunner", 1)

    # 실행 ID
    src = src.replace(
        'REQUESTING_USER = "alice"',
        'REQUESTING_USER = "alice"\n'
        '# DB 문장 로그에서 이 실행을 식별한다. 재실행해도 겹치지 않도록 타임스탬프 기반.\n'
        'RUN_ID = os.getenv("RUN_ID") or time.strftime("run%Y%m%d-%H%M%S")', 1)

    # 오라클 연결에 태그 (두 함수 모두)
    src = src.replace(
        'conn = psycopg2.connect(**USER_CREDS["alice"])',
        'conn = psycopg2.connect(**USER_CREDS["alice"], application_name="oracle:" + RUN_ID)')

    # 시행마다 태그 갱신
    old = "                t0 = time.time()\n                try:\n                    res = await run_one(agent, p[\"prompt\"], log)"
    assert old in src, "run loop anchor not found"
    src = src.replace(
        old,
        '                t0 = time.time()\n'
        '                identity_bound_runner.CURRENT_TAG["v"] = (\n'
        '                    f"{RUN_ID}|{mode}|{p[\'id\']}|{r}")\n'
        '                try:\n'
        '                    res = await run_one(agent, p["prompt"], log)', 1)

    e.write_text(src, encoding="utf-8")
    print(f"{e.name}: RUN_ID tagging added")

print("\n검증:")
psql = [str(HOME / "pg/bin/psql"), "-h", str(HOME / "pgdata"), "-p", "5433", "-d", "postgres", "-tA",
        "-c", "select name, setting from pg_settings where name in ('log_statement','log_line_prefix')"]
print(subprocess.run(psql, capture_output=True, text=True).stdout.strip())
