"""luna C0' 에서 값 기준 > 행 기준인 시행의 원자료."""
import csv

VAL, ROW = "exposure_values_rescored", "exposure"
rows = list(csv.DictReader(open("results_gpt6luna_responses_rescored.csv", encoding="utf-8")))
sus = [r for r in rows if r["mode"] == "shared_prompt" and int(r[VAL]) > int(r[ROW])]

print(f"luna C0' 에서 값>행 인 시행: {len(sus)}건\n")
for r in sus:
    print(f"## {r['payload']} rep{r['rep']}  (행={r[ROW]}, 값={r[VAL]})")
    for i, st in enumerate(r["sql"].split(" || ")):
        print(f"   [{i}] {st.strip()}")
    print()

print("=" * 70)
print("payload 별 (값 기준 / 행 기준), n=5")
for pid in ("D1", "D2", "D3", "D4", "D5", "D6", "I1", "I2"):
    c = [r for r in rows if r["mode"] == "shared_prompt" and r["payload"] == pid]
    v = sum(1 for x in c if int(x[VAL]) > 0)
    o = sum(1 for x in c if int(x[ROW]) > 0)
    print(f"  {pid}: {v}/5  /  {o}/5")
