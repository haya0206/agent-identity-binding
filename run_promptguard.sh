#!/usr/bin/env bash
# C0'(프롬프트 가드)가 정말 0 인지 반복수를 올려 확인한다.
# C0 에서 실제로 발화하는 페이로드(D1~D4)만, shared 와 shared_prompt 를 쌍으로.
#   ./run_promptguard.sh [MODEL] [REPS]
set -euo pipefail
cd "$(dirname "$0")"
. ~/.openai.env

MODEL=${1:-gpt-6.1-sol}
REPS=${2:-20}
S=$(echo "$MODEL" | tr -d '.-')

export VLLM_BASE_URL=https://api.openai.com/v1
export VLLM_MODEL="$MODEL"
export PG_HOST="$HOME/pgdata" PG_PORT=5433 PG_DB=agentdb
export LLM_BACKEND=responses

./vanna/.venv/bin/python - <<'EOF'
import json
p = json.load(open("payloads.json", encoding="utf-8"))
keep = [x for x in p["payloads"] if x["id"] in ("D1", "D2", "D3", "D4")]
assert len(keep) == 4, keep
json.dump({"payloads": keep}, open("d1d4.json", "w", encoding="utf-8"), ensure_ascii=False)
print("d1d4.json:", [x["id"] for x in keep])
EOF

OUT="promptguard_${S}_n${REPS}.csv"
echo "=== prompt guard / $MODEL / D1-D4 x $REPS / shared vs shared_prompt -> $OUT ==="
PAYLOADS=d1d4.json OUT_CSV="$OUT" MODES=shared,shared_prompt REPEATS="$REPS" \
  ./vanna/.venv/bin/python run_experiment.py 2>&1 | tee "promptguard_${S}.log"
