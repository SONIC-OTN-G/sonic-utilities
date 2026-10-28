#!/bin/bash
# =============================================================
# 場景三:syncd C++ 採集閉環(配置 → 線程 → 當前窗 → 歷史歸檔)
#
# 用法   :ssh 進 VM 後執行   sudo bash s3_syncd_collect.sh [--keep] [--wait-history]
#   --keep          結束時不關採集(線程保留跑著,便於人工看 db10)
#   --wait-history  真等到 5 分窗跨界,驗證 db10 歸檔(最多約 6 分半)
# 前提   :syncd 容器 RUNNING;三件套已套(腳本會自檢)
# 性質   :種配置(LPUSH 同款可重跑);默認結束時 disable 收尾
# 時長   :預設約 2 分鐘;--wait-history 最長約 6 分半
# 對應文檔:45-三场景演示总览(初学者版) §3
# =============================================================
PASS=0; FAIL=0
G='\033[32m'; R='\033[31m'; B='\033[1m'; N='\033[0m'
ok()  { echo -e "  ${G}✓${N} $1"; PASS=$((PASS+1)); }
bad() { echo -e "  ${R}✗${N} $1 —— 預期: $2"; FAIL=$((FAIL+1)); }
expect() {
  echo -e "${B}── $1${N}"
  echo "\$ $2"
  out=$(eval "$2" 2>&1)
  echo "$out" | sed 's/^/    /' | head -8
  if echo "$out" | grep -qE "$3"; then ok "$1"; else bad "$1" "$3"; fi
  echo
}
note() { echo "# $1"; echo; }

KEEP=0; WAIT=0
for a in "$@"; do
  [ "$a" = "--keep" ] && KEEP=1
  [ "$a" = "--wait-history" ] && WAIT=1
done

# 0. 環境自檢
sudo docker ps >/dev/null 2>&1 || {
  echo "✗ 看不到 docker——本腳本要在 VM 上跑(見 45 §0)"; exit 9; }

echo -e "${B}========== 場景三:syncd C++ 採集(OtaiGaugeCollector)==========${N}\n"
note "故事:syncd 進程內 C++ 採集器,訂閱 FLEX_COUNTER_DB,一個採集組一條線程。
      正常系統由 orchagent 寫 db5;本仿真無 orchagent,用 op 佇列協議手工種配置
      (原理見 43-OTAI对象编号与op队列协议)。先得有硬件對象——手工 create 線卡。"

# 1. 前檢:syncd 活著、依賴完整
#    預期:syncd RUNNING
expect "syncd 進程 RUNNING" \
  "sudo docker exec syncd supervisorctl status" \
  '^syncd +RUNNING'
#    預期:0(非 0 = 三件套沒套好,見 44-容器層修復與重套清單)
expect "三件套依賴完整(ldd not found 歸零)" \
  "sudo docker exec syncd ldd /usr/lib/x86_64-linux-gnu/libswsscommon.so.0.0.0 | grep -c 'not found'" \
  '^0$'

# 2. 手工 create 線卡(必帶 4 個通知指針,否則 10 秒後 SEGV)
#    預期:無報錯;syncd 日誌出現 processOidCreate: creating linecard
note "op 佇列協議:LPUSH 一筆 op + PUBLISH 敲鐘(等價 ProducerTable::set)
      4 個 0xdeadbeef 指針會被 syncd updateNotificationsPointers 換成自家 handler"
redis-cli -n 1 LPUSH "ASIC_STATE_KEY_VALUE_OP_QUEUE" \
  "OTAI_OBJECT_TYPE_LINECARD:oid:0x1000000000000" \
  '["OTAI_LINECARD_ATTR_LINECARD_STATE_CHANGE_NOTIFY","0xdeadbeef","OTAI_LINECARD_ATTR_LINECARD_ALARM_NOTIFY","0xdeadbeef","OTAI_LINECARD_ATTR_LINECARD_OCM_SPECTRUM_POWER_NOTIFY","0xdeadbeef","OTAI_LINECARD_ATTR_LINECARD_OTDR_RESULT_NOTIFY","0xdeadbeef"]' \
  "Screate" >/dev/null
redis-cli -n 1 PUBLISH "ASIC_STATE_CHANNEL@1" "G" >/dev/null
echo "  (線卡 create 已下發;成功的硬指標是後面 db2 出 8 鍵,此處不設門檻)"; echo

# 3. 給線卡起名(採集鍵名來源;HSET 回 1=新建 0=已存在,皆正常)
redis-cli -n 2 HSET "COUNTERS_LINECARD_NAME_MAP" "oid:0x1000000000000" "linecard1" >/dev/null
echo "  (NAME_MAP 已寫)"; echo

# 4. 開採集組(組名含 1S_STAT_GAUGE 才會被採集器認;1 秒採樣)
#    預期:syncd 日誌 processFlexCounterGroupEvent group is 1S_STAT_GAUGE
#          → Flex_Counter thread started
redis-cli -n 5 LPUSH "FLEX_COUNTER_GROUP_TABLE_KEY_VALUE_OP_QUEUE" "1S_STAT_GAUGE" \
  '["POLL_INTERVAL","1000","FLEX_COUNTER_STATUS","enable"]' "SSET" >/dev/null
redis-cli -n 5 PUBLISH "FLEX_COUNTER_GROUP_TABLE_CHANNEL@5" "G" >/dev/null
echo "  (採集組已下發 enable)"; echo

# 5. 指定採什麼(線卡的 4 項 stat)
#    預期:syncd 日誌 addCounter vid is 0x1000000000000 rid ... m_propGroup 2
redis-cli -n 5 LPUSH "FLEX_COUNTER_TABLE_KEY_VALUE_OP_QUEUE" "1S_STAT_GAUGE:oid:0x1000000000000" \
  '["id_list","OTAI_LINECARD_STAT_TEMPERATURE,OTAI_LINECARD_STAT_CPU_UTILIZATION,OTAI_LINECARD_STAT_MEMORY_AVAILABLE,OTAI_LINECARD_STAT_MEMORY_UTILIZED"]' "SSET" >/dev/null
redis-cli -n 5 PUBLISH "FLEX_COUNTER_TABLE_CHANNEL@5" "G" >/dev/null
echo "  (counter 行已下發;等採集器開工…)"; echo

sleep 8

# 6. 看當前窗:COUNTERS_DB(db2)浮現 8 鍵(4 stat × 15min/24h 雙窗)
#    預期:數到 8
expect "當前窗 8 鍵浮現" \
  "redis-cli -n 2 --scan --pattern 'LINECARD:linecard1_*' | wc -l" \
  '^8$'

# 7. 當刻值
#    預期:35.0(與模擬硬件 json 一致;CPU 值目前型別錯位,演示挑 Temperature/Memory)
expect "溫度 instant=35.0" \
  "redis-cli -n 2 HGET 'LINECARD:linecard1_Temperature:15_pm_current' instant" \
  '^35\.0$'

# 8. 看整個對象(--json)
#    預期:interval=300000000000 ns(=5 分窗,補丁#5)、current_validity=complete
expect "JSON 全欄(interval=5 分窗)" \
  "redis-cli --json -n 2 HGETALL 'LINECARD:linecard1_Temperature:15_pm_current'" \
  '"interval":"300000000000".*"current_validity":"complete"'

# 9. 歷史歸檔
if [ "$WAIT" = "1" ]; then
  now=$(date +%s); wait_s=$(( 300 - now % 300 + 15 ))
  note "--wait-history:等 5 分窗跨界(整點+15 秒),約 ${wait_s} 秒…"
  sleep "$wait_s"
  #    預期:至少 1 條 …15_pm_history_<窗起ns>;TTL≈2 天。注意查 db10,不是 db15
  expect "db10 歸檔鍵出現" \
    "redis-cli -n 10 --scan --pattern '*pm_history*' | head -3" \
    'pm_history'
  #    預期:syncd 日誌 history write done
  expect "歸檔日誌落帳" \
    "sudo grep -E 'history write done' /var/log/syslog | tail -2" \
    'history write done'
else
  note "歷史歸檔要等 5 分窗跨界;之後手動驗證(或重跑本腳本加 --wait-history):
        sudo docker exec database redis-cli -n 10 --scan --pattern '*pm_history*' | head -3
        sudo docker exec database redis-cli --json -n 10 HGETALL '<上面掃到的鍵>'
        sudo grep -E 'history write done' /var/log/syslog | tail -2
        ※ 注意查 db10(GB_COUNTERS_DB),不是 db15——42 §8.5"
fi

# 10. 收尾:關採集(配置驅動,即時生效;數據凍結留庫無妨,重開機即清)
if [ "$KEEP" = "1" ]; then
  note "--keep:採集組保持 enable,線程繼續跑"
else
  redis-cli -n 5 LPUSH "FLEX_COUNTER_GROUP_TABLE_KEY_VALUE_OP_QUEUE" "1S_STAT_GAUGE" \
    '["POLL_INTERVAL","1000","FLEX_COUNTER_STATUS","disable"]' "SSET" >/dev/null
  redis-cli -n 5 PUBLISH "FLEX_COUNTER_GROUP_TABLE_CHANNEL@5" "G" >/dev/null
  echo "  (採集組已 disable 收尾;重跑本腳本即可再開)"; echo
fi

echo -e "${B}========== 結果:PASS=$PASS FAIL=$FAIL ==========${N}"
[ "$FAIL" -eq 0 ]
