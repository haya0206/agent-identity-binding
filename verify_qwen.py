"""Qwen 결과가 수정된 오라클로 재채점됐는지, 무엇이 달라졌는지 확인.

값 != 행 인 모든 시행을 본다 (판정이 바뀐 것뿐 아니라 튜플 수만 달라진 것도 포함).
앞선 점검은 '값>0 & 행=0' 만 봐서 후자를 놓쳤다.
"""
import csv
import re

VAL, ROW = "exposure_values_rescored", "exposure"
SEP = " || "
KW = re.compile(r"^\s*(SELECT|WITH|SET|SHOW|INSERT|UPDATE|DELETE|CREATE|DROP|ALTER"
                r"|GRANT|REVOKE|EXPLAIN|BEGIN|COMMIT|ROLLBACK)\b", re.I)
IDENT = re.compile(r"\bcurrent_user\b|\bsession_user\b|\bcurrent_role\b"
                   r"|has_\w*_privilege\s*\(", re.I)


def statements(s):
    if not s.strip():
        return []
    out = []
    for p in (x.strip() for x in s.split(SEP) if x.strip()):
        if out and not KW.match(p):
            out[-1] += SEP + p
        else:
            out.append(p)
    return out


rows = list(csv.DictReader(open("results_rescored.csv", encoding="utf-8")))
print(f"results_rescored.csv  rows={len(rows)}  컬럼에 {VAL} 존재: {VAL in rows[0]}")

diff = [r for r in rows if int(r[VAL]) != int(r[ROW])]
print(f"\n값 != 행 인 시행: {len(diff)}건\n")
for r in diff:
    sts = statements(r["sql"])
    ident = [s for s in sts if IDENT.search(s)]
    print(f"[{r['mode']}/{r['payload']}/rep{r['rep']}] 행={r[ROW]} 값={r[VAL]} "
          f"차={int(r[VAL]) - int(r[ROW])}  신원파생SQL={'있음' if ident else '없음'}")
    for s in sts:
        print(f"      {s[:125]}")
    print()

print("=" * 72)
print("조건별 집계 (현재 오라클 기준)")
MODES = ["shared", "shared_prompt", "set_role", "per_user"]
LBL = {"shared": "C0", "shared_prompt": "C0'", "set_role": "C1", "per_user": "C2"}
print(f"{'':6s} " + "".join(f"{LBL[m]:>10s}" for m in MODES))
for title, fn in (
    ("ASR", lambda c: sum(1 for x in c if int(x[VAL]) > 0) / len(c)),
    ("ASR행", lambda c: sum(1 for x in c if int(x[ROW]) > 0) / len(c)),
):
    line = f"{title:6s} "
    for m in MODES:
        c = [r for r in rows if r["mode"] == m and r["kind"] == "attack"]
        line += f"{fn(c):>10.2f}"
    print(line)
for title, col in (("튜플", VAL), ("행", ROW)):
    line = f"{title:6s} "
    for m in MODES:
        c = [r for r in rows if r["mode"] == m and r["kind"] == "attack"]
        line += f"{sum(int(x[col]) for x in c):>10d}"
    print(line)

print("\n페이로드별 (값 / 행), n=5")
for pid in ("D1", "D2", "D3", "D4", "D5", "D6", "I1", "I2"):
    line = f"  {pid:4s}"
    for m in MODES:
        c = [r for r in rows if r["mode"] == m and r["payload"] == pid]
        v = sum(1 for x in c if int(x[VAL]) > 0) / len(c)
        o = sum(1 for x in c if int(x[ROW]) > 0) / len(c)
        line += f"   {v:.2f}/{o:.2f}"
    print(line)
