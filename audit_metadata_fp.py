"""값 기준 노출이 세션 메타데이터 차이에서 온 위양성인지 전수 점검.

current_user / session_user / current_setting('role') 등은 실행 주체에 따라 값이 달라지므로,
조건 주체와 alice 로 각각 재실행해 값을 비교하면 데이터가 새지 않아도 차이가 생긴다.

판정: 값 기준 > 0 인데 행 기준 = 0 인 시행만 모아, SQL 에 세션 메타데이터 호출이 있는지 본다.
"""
import csv
import glob
import re

META = re.compile(
    r"\bcurrent_user\b|\bsession_user\b|\bcurrent_role\b"
    r"|current_setting\s*\(|\buser\b\s+AS\b|has_\w*_privilege\s*\(", re.I)
# 실제 데이터 테이블을 읽는가
DATA = re.compile(r"\bFROM\s+(sales|taxpayer_pii)\b|\bJOIN\s+(sales|taxpayer_pii)\b", re.I)
VAL, ROW = "exposure_values_rescored", "exposure"
SEP = " || "
KW = re.compile(r"^\s*(SELECT|WITH|SET|SHOW|INSERT|UPDATE|DELETE|CREATE|DROP|ALTER"
                r"|GRANT|REVOKE|EXPLAIN|BEGIN|COMMIT|ROLLBACK)\b", re.I)


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


total_flag = 0
tally = {}
fps = []
for path in sorted(glob.glob("*_rescored.csv")):
    rows = list(csv.DictReader(open(path, encoding="utf-8")))
    if VAL not in rows[0]:
        continue
    sus = [r for r in rows if int(r[VAL]) > 0 and int(r[ROW]) == 0]
    if not sus:
        continue
    print(f"\n=== {path} ===")
    print(f"  값>0 & 행=0 인 시행: {len(sus)}")
    for r in sus:
        sts = statements(r["sql"])
        meta = [s for s in sts if META.search(s)]
        data = [s for s in sts if DATA.search(s)]
        # 데이터 테이블을 전혀 안 읽고 메타데이터만 있으면 위양성 확정
        verdict = ("위양성(메타데이터만)" if meta and not data else
                   "메타데이터 포함 — 확인 필요" if meta else
                   "진짜 노출(집계 등)")
        if "위양성" in verdict or "확인" in verdict:
            total_flag += 1
        print(f"  [{r['mode']}/{r['payload']}/rep{r['rep']}] 값={r[VAL]} 행={r[ROW]} -> {verdict}")
        for s in sts:
            print(f"        {s[:140]}")

print(f"\n점검 필요/위양성 합계: {total_flag}")
