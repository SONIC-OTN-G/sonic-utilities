#!/bin/bash
# =============================================================
# 場景二:PMON 設硬件數值(thermalctl 改門限 → 越限告警翻轉)
#
# 用法   :ssh 進 VM 後執行   sudo bash s2_thermalctl.sh
# 前提   :VM host /usr/local/bin/thermalctl 在位
# 性質   :命令寫硬件門限,腳本結束時**自動還原 71**;可反覆跑
# 時長   :約 40 秒
# 對應文檔:45-三场景演示总览(初学者版) §2
# =============================================================
PASS=0; FAIL=0
G='\033[32m'; R='\033[31m'; B='\033[1m'; N='\033[0m'
ok()  { echo -e "  ${G}✓${N} $1"; PASS=$((PASS+1)); }
bad() { echo -e "  ${R}✗${N} $1 —— 預期匹配: $2"; FAIL=$((FAIL+1)); }
expect() {
  echo -e "${B}── $1${N}"
  echo "\$ $2"
  out=$(eval "$2" 2>&1)
  echo "$out" | sed 's/^/    /' | head -8
  if echo "$out" | grep -qE "$3"; then ok "$1"; else bad "$1" "$3"; fi
  echo
}
note() { echo "# $1"; echo; }

THR="System Board"; BASE=71; LOW=35
RESTORED=0
restore() {  # 任何退出路徑都還原門限,防中途失敗留 35
  if [ "$RESTORED" = "0" ]; then
    sudo thermalctl set-high-threshold "$THR" $BASE >/dev/null 2>&1
    RESTORED=1
    echo "# (退出保護:門限已還原 $BASE)"
  fi
}
trap restore EXIT

command -v thermalctl >/dev/null 2>&1 || {
  echo "✗ 找不到 thermalctl——本腳本要在 VM 上跑(工具在 /usr/local/bin/)"; exit 9; }

echo -e "${B}========== 場景二:命令設硬件數值 → thermalctld 反應 ==========${N}\n"
note "故事:把高溫門限 71→35(低於現值 37,製造越限)→ thermalctld 3 秒內
      輪詢到 → STATE_DB 告警翻 True → 還原恢復。命令設硬件數值,反應肉眼可見。"

# 1. 記基準
#    預期輸出:Board 行 = 37 / 71 / 10.4 / False(溫度/高門限/低門限/告警)
expect "基準:門限 71、無告警" \
  "sudo thermalctl show" \
  '71.*False|False.*71'

# 2. 命令下發:71 → 35
#    預期輸出:System Board high_threshold -> 35.0: OK
expect "命令設門限 35" \
  "sudo thermalctl set-high-threshold \"$THR\" $LOW" \
  ': OK'

# 3. 看反應:≤3 秒告警翻 True(輪詢最多等 8 秒)
note "預期:HighThr 變 35、Warning 變 True(37 > 35 越限),通常 3 秒內"
hit=0
for i in $(seq 1 8); do
  out=$(sudo thermalctl show)
  if echo "$out" | grep -q 'True'; then hit=1; break; fi
  sleep 1
done
echo "$out" | sed 's/^/    /'
if [ "$hit" = "1" ]; then ok "越限告警翻轉(第 ${i} 秒內)"; else bad "越限告警翻轉" "8 秒內 True"; fi
echo

# 4. 還原:35 → 71
#    預期輸出:System Board high_threshold -> 71.0: OK
expect "還原門限 71" \
  "sudo thermalctl set-high-threshold \"$THR\" $BASE" \
  ': OK'
RESTORED=1

# 5. 確認告警回 False(輪詢最多等 8 秒)
note "預期:Warning 回 False"
hit=0
for i in $(seq 1 8); do
  out=$(sudo thermalctl show)
  if echo "$out" | grep -q 'False'; then hit=1; break; fi
  sleep 1
done
echo "$out" | sed 's/^/    /'
if [ "$hit" = "1" ]; then ok "告警復位"; else bad "告警復位" "8 秒內 False"; fi
echo

echo -e "${B}========== 結果:PASS=$PASS FAIL=$FAIL ==========${N}"
[ "$FAIL" -eq 0 ]
