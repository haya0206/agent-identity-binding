#!/usr/bin/env bash
# 상용 모델로 표 2 재현. 키는 ~/.openai.env 에서 읽는다(이 파일에 키 없음).
#
#   ./run_gpt6.sh smoke  [MODEL]            U1+D1, shared 만, 1회 -- 배선 확인
#   ./run_gpt6.sh responses      [MODEL]    reasoning ON
#   ./run_gpt6.sh chat_noreason  [MODEL]    reasoning OFF
#   ./run_gpt6.sh payload D5 20  [MODEL]    특정 페이로드만 N회 (전 조건)
#
# MODEL 기본값 gpt-6-luna. 결과 파일명에 모델명이 들어가므로 덮어쓰지 않는다.
set -euo pipefail
cd "$(dirname "$0")"

[ -f ~/.openai.env ] || { echo "~/.openai.env 가 없습니다"; exit 1; }
# shellcheck disable=SC1090
. ~/.openai.env
[ -n "${OPENAI_API_KEY:-}" ] || { echo "OPENAI_API_KEY 가 비어 있습니다"; exit 1; }

export VLLM_BASE_URL=https://api.openai.com/v1
export PG_HOST="$HOME/pgdata"
export PG_PORT=5433
export PG_DB=agentdb

PY=./vanna/.venv/bin/python
ACTION=${1:-responses}
ALL_MODES=shared,shared_prompt,set_role,per_user

slug() { echo "$1" | tr -d '.-' ; }

case "$ACTION" in
  smoke)
    export VLLM_MODEL=${2:-gpt-6-luna}
    $PY - <<'EOF'
import json
p = json.load(open("payloads.json", encoding="utf-8"))
keep = [x for x in p["payloads"] if x["id"] in ("U1", "D1")]
json.dump({"payloads": keep}, open("smoke_payloads.json", "w", encoding="utf-8"),
          ensure_ascii=False, indent=2)
EOF
    LLM_BACKEND=responses PAYLOADS=smoke_payloads.json OUT_CSV=smoke.csv \
      MODES=shared REPEATS=1 $PY run_experiment.py
    ;;

  payload)
    PID=${2:?payload id 필요 (예: D5)}
    N=${3:-20}
    export VLLM_MODEL=${4:-gpt-6-luna}
    S=$(slug "$VLLM_MODEL")
    OUT="rep_${S}_${PID}_n${N}.csv"
    $PY - "$PID" <<'EOF'
import json, sys
pid = sys.argv[1]
p = json.load(open("payloads.json", encoding="utf-8"))
keep = [x for x in p["payloads"] if x["id"] == pid]
assert keep, f"payload {pid} not found"
json.dump({"payloads": keep}, open(f"only_{pid}.json", "w", encoding="utf-8"),
          ensure_ascii=False)
EOF
    echo "=== $VLLM_MODEL / $PID x $N (all modes) -> $OUT ==="
    LLM_BACKEND=responses PAYLOADS="only_${PID}.json" OUT_CSV="$OUT" \
      MODES=$ALL_MODES REPEATS="$N" $PY run_experiment.py 2>&1 | tee "rep_${S}_${PID}.log"
    ;;

  responses|chat_noreason)
    export VLLM_MODEL=${2:-gpt-6-luna}
    S=$(slug "$VLLM_MODEL")
    OUT="results_${S}_${ACTION}.csv"
    echo "=== $VLLM_MODEL / $ACTION -> $OUT ==="
    LLM_BACKEND=$ACTION OUT_CSV="$OUT" MODES=$ALL_MODES REPEATS=${REPEATS:-5} \
      $PY run_experiment.py 2>&1 | tee "run_${S}_${ACTION}.log"
    ;;

  *)
    echo "usage: $0 {smoke|responses|chat_noreason|payload <ID> <N>} [MODEL]"; exit 2 ;;
esac
