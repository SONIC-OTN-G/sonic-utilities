#!/bin/bash
# =============================================================
# 場景一:PMON 輪詢驗證(daemon → STATE_DB)
#
# 用法   :ssh 進 VM 後執行   sudo bash s1_pmon_poll.sh
# 前提   :VM 內 13 容器 Up(啟動方法見 45-三场景演示总览 §0)
# 性質   :純唯讀,零改動,可反覆跑
# 時長   :約 30 秒
# 對應文檔:45-三场景演示总览(初学者版) §1
# =============================================================
PASS=0; FAIL=0
G='\033[32m'; R='\033[31m'; B='\033[1m'; N='\033[0m'
ok()  { echo -e "  ${G}✓${N} $1"; PASS=$((PASS+1)); }
bad() { echo -e "  ${R}✗${N} $1 —— 預期匹配: $2"; FAIL=$((FAIL+1)); }
expect() {  # $1=說明  $2=命令  $3=預期(grep -E)
  echo -e "${B}── $1${N}"
  echo "\$ $2"
  out=$(eval "$2" 2>&1)
  echo "$out" | sed 's/^/    /' | head -8
  if echo "$out" | grep -qE "$3"; then ok "$1"; else bad "$1" "$3"; fi
  echo
}
note() { echo "# $1"; echo; }

# 0. 環境自檢:必須在 VM 上跑
sudo docker ps >/dev/null 2>&1 || {
  echo "✗ 看不到 docker——本腳本要在 VM 上跑(先 ssh -p 2222 admin@localhost,見 45 §0)"; exit 9; }

echo -e "${B}========== 場景一:PMON 輪詢(daemon → STATE_DB)==========${N}\n"
note "故事:PMON 容器裡的 daemon 定時讀硬件(仿真=HalPlatformApiServer 模擬件),
      讀數寫進 STATE_DB。值不動=硬件沒變化;timestamp 每輪刷新=輪詢管道活著。"

# 1. 容器在位
#    預期輸出:pmon: Up / database: Up
expect "容器清單(pmon/database 在列)" \
  "sudo docker ps --format '{{.Names}}: {{.Status}}'" \
  '^pmon: Up'

#    預期輸出:psud RUNNING(psud 若 FATAL 會自動拉起——VM 重啟後已知漂移,見 45 §4)
status=$(sudo docker exec pmon supervisorctl status)
echo -e "${B}── pmon daemon:psud(電源)${N}"
echo "\$ sudo docker exec pmon supervisorctl status"
echo "$status" | sed 's/^/    /'
if echo "$status" | grep -qE '^psud +RUNNING'; then
  ok "psud RUNNING"
else
  note "psud 非 RUNNING(歷史症狀:FATAL Exited too quickly)→ 自癒:supervisorctl start psud"
  sudo docker exec pmon supervisorctl start psud
  sleep 12
  status=$(sudo docker exec pmon supervisorctl status)
  echo "$status" | grep '^psud' | sed 's/^/    /'
  if echo "$status" | grep -qE '^psud +RUNNING'; then ok "psud RUNNING(自癒成功)"; else bad "psud RUNNING" "start 後 RUNNING"; fi
fi
echo

expect "pmon daemon:thermalctld" \
  "sudo docker exec pmon supervisorctl status" \
  'thermalctld +RUNNING'

# 2. 輪詢成果:STATE_DB 有數據
#    預期輸出:37.0(模擬硬件常數溫度)
expect "溫度數據在流" \
  "sonic-db-cli STATE_DB HGET 'TEMPERATURE_INFO|System Board' temperature" \
  '^37\.0'
#    預期輸出:71.0(默認高溫門限)
expect "高溫門限默認值" \
  "sonic-db-cli STATE_DB HGET 'TEMPERATURE_INFO|System Board' high_threshold" \
  '^71\.0'

# 3. 證明「在輪詢」:timestamp 3 秒一跳
#    手動演示版:watch -n 1 "date +%T; sonic-db-cli STATE_DB HGET
#    'TEMPERATURE_INFO|System Board' timestamp"
#    腳本自動化:讀兩次隔 4 秒,值變了=輪詢中
note "預期:兩次 timestamp 不同(thermalctld 3 秒節奏,4 秒內必換)"
check_ts() {
  local a b
  a=$(sonic-db-cli STATE_DB HGET 'TEMPERATURE_INFO|System Board' timestamp)
  sleep 4
  b=$(sonic-db-cli STATE_DB HGET 'TEMPERATURE_INFO|System Board' timestamp)
  echo "    第一次: $a"
  echo "    第二次: $b"
  [ -n "$a" ] && [ -n "$b" ] && [ "$a" != "$b" ]
}
if check_ts; then
  ok "timestamp 在跳(輪詢管道活著)"
else
  note "timestamp 凍結(歷史症狀:進程在但寫循環掛住)→ 自癒:restart thermalctld"
  sudo docker exec pmon supervisorctl restart thermalctld
  sleep 8
  if check_ts; then ok "timestamp 在跳(自癒成功)"; else bad "timestamp 在跳" "兩次值不同(3 秒參數沒套?見 45 §4)"; fi
fi

echo -e "${B}========== 結果:PASS=$PASS FAIL=$FAIL ==========${N}"
[ "$FAIL" -eq 0 ]
