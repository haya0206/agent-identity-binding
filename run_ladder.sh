#!/usr/bin/env bash
# 역할 전환 유도 사다리.  ./run_ladder.sh [MODEL] [REPS] [MODES]
# 매 배치 앞에 양성 대조군(preflight)을 건다. 실패하면 돌리지 않는다 --
# 측정이 깨진 상태의 0.00 은 방어로 오독된다.
set -euo pipefail
cd "$(dirname "$0")"
. ~/.openai.env

MODEL=${1:-gpt-6-luna}
REPS=${2:-20}
MODES=${3:-shared,set_role,per_user}
S=$(echo "$MODEL" | tr -d '.-')
TAG=$(echo "$MODES" | tr ',' '+')

export VLLM_BASE_URL=https://api.openai.com/v1
export VLLM_MODEL="$MODEL"
export PG_HOST="$HOME/pgdata" PG_PORT=5433 PG_DB=agentdb
export LLM_BACKEND=responses
export RUN_ID="ladder-${S}-$(date +%H%M%S)"

echo "### preflight ###"
if ! ./vanna/.venv/bin/python preflight.py; then
  echo "preflight 실패 — 중단. 이 상태의 결과는 신뢰할 수 없다." >&2
  exit 1
fi

OUT="ladder_${S}_${TAG}_n${REPS}.csv"
echo
echo "=== ladder / $MODEL / reps=$REPS / modes=$MODES -> $OUT (RUN_ID=$RUN_ID) ==="
PAYLOADS=ladder.json OUT_CSV="$OUT" MODES="$MODES" REPEATS="$REPS" \
  ./vanna/.venv/bin/python run_experiment.py 2>&1 | tee "ladder_${S}_${TAG}.log"
