#!/bin/bash
# =============================================================
# find_min_clk.sh
# 自動二分逼近「剛好能達標的最小時脈週期 (CLKP)」
#
# 原理：HLS 的 Estimated 是估算值，不同 Target 會給不同結果，
#       所以用二分法逐步逼近：設一個值 → 只跑 csynth → 抓 Estimated
#       → 達標(Est<=Target)就往下壓、不達標就往上放 → 收斂。
#
# 用法：放在 resize 範例資料夾裡(跟 run_hls.tcl 同層)執行：
#   chmod +x find_min_clk.sh
#   ./find_min_clk.sh
# 執行前務必已 source Vitis、export OpenCV(跟平常跑一樣)。
# =============================================================

# ---------- 可調參數 ----------
LOW=3.0           # 搜尋下界(ns)：你覺得不可能達到的最快值
HIGH=8.0          # 搜尋上界(ns)：你確定一定能達標的較慢值
TOL=0.1           # 收斂精度(ns)：上下界差小於這個就停止
MARGIN=0.05       # 餘裕(ns)：最後在最佳值上加一點點餘裕，較保險
TCL="run_hls.tcl"
RPT="resize.prj/sol1/syn/report/resize_accel_csynth.rpt"
# --------------------------------

if [ ! -f "$TCL" ]; then
  echo "[錯誤] 找不到 $TCL，請在 resize 範例資料夾裡執行。"
  exit 1
fi

# 備份原始 tcl
cp "$TCL" "${TCL}.bak"
echo "[備份] 已備份原始 $TCL 為 ${TCL}.bak"

# 暫時改成「只跑 csynth」以加速(逼近階段不需要 csim/cosim)
sed -i 's/^set CSIM .*/set CSIM 0/'   "$TCL"
sed -i 's/^set CSYNTH .*/set CSYNTH 1/' "$TCL"
sed -i 's/^set COSIM .*/set COSIM 0/'  "$TCL"
echo "[設定] 逼近階段：CSIM=0 CSYNTH=1 COSIM=0(只合成、加速)"
echo ""

# 把某個 CLKP 寫進 tcl
set_clkp () {
  local v=$1
  if grep -q "info exists CLKP" "$TCL"; then
    # 形如：if {![info exists CLKP]} { set CLKP 3.3 }
    sed -i "s/set CLKP [0-9.]*/set CLKP $v/g" "$TCL"
  elif grep -q "^set CLKP" "$TCL"; then
    sed -i "s/^set CLKP .*/set CLKP $v/" "$TCL"
  else
    echo "[警告] 找不到 CLKP 設定行，請手動確認 $TCL"
  fi
}

# 跑一次 csynth，回傳 Estimated(ns)；失敗回傳 -1
run_one () {
  local clkp=$1
  set_clkp "$clkp"
  # 跑合成(把 log 導到檔案，避免洗版)
  vitis_hls -f "$TCL" > /tmp/hls_run.log 2>&1

  if [ ! -f "$RPT" ]; then
    echo "-1"; return
  fi
  # 從報告抓 Estimated 那個數字
  # 報告格式類似：  |ap_clk | 3.30 ns | 5.663 ns | 0.89 ns |
  local est
  est=$(grep -i "ap_clk" "$RPT" | grep -oE "[0-9]+\.[0-9]+" | sed -n '2p')
  if [ -z "$est" ]; then echo "-1"; else echo "$est"; fi
}

echo "========================================================"
echo " 開始二分逼近：範圍 [$LOW, $HIGH] ns，精度 $TOL ns"
echo "========================================================"

best=""   # 目前找到「達標」的最小 Target
printf "%-8s %-12s %-12s %-10s\n" "次數" "Target(ns)" "Estimated(ns)" "結果"
echo "--------------------------------------------------------"

iter=0
while (( $(echo "$HIGH - $LOW > $TOL" | bc -l) )); do
  iter=$((iter+1))
  mid=$(echo "scale=3; ($LOW + $HIGH) / 2" | bc -l)

  est=$(run_one "$mid")

  if [ "$est" == "-1" ]; then
    # 合成失敗(可能太苛或出錯)，當作不達標往上放
    printf "%-8s %-12s %-12s %-10s\n" "$iter" "$mid" "FAIL" "合成失敗→放寬"
    LOW="$mid"
    continue
  fi

  # 判斷達標否：Estimated <= Target ?
  if (( $(echo "$est <= $mid" | bc -l) )); then
    printf "%-8s %-12s %-12s %-10s\n" "$iter" "$mid" "$est" "達標↓壓更低"
    best="$mid"          # 記下這個達標的值
    HIGH="$mid"          # 達標，往更低的方向找
  else
    printf "%-8s %-12s %-12s %-10s\n" "$iter" "$mid" "$est" "未達標↑放寬"
    LOW="$mid"           # 沒達標，往較慢的方向找
  fi
done

echo "--------------------------------------------------------"
if [ -z "$best" ]; then
  echo "[結果] 在 [$LOW, $HIGH] 範圍內找不到達標值，請把 HIGH 調大重試。"
  cp "${TCL}.bak" "$TCL"
  echo "[還原] 已還原原始 $TCL"
  exit 1
fi

# 加上餘裕，較保險
final=$(echo "scale=3; $best + $MARGIN" | bc -l)
echo "[結果] 剛好達標的最小 Target ≈ $best ns"
echo "       建議採用(含 $MARGIN ns 餘裕)：CLKP = $final ns"
echo ""

# 用建議值跑一次「完整流程」做最終驗證
echo "========================================================"
echo " 用 CLKP = $final 跑完整流程(csim+csynth+cosim)做最終驗證"
echo "========================================================"
set_clkp "$final"
sed -i 's/^set CSIM .*/set CSIM 1/'   "$TCL"
sed -i 's/^set CSYNTH .*/set CSYNTH 1/' "$TCL"
sed -i 's/^set COSIM .*/set COSIM 1/'  "$TCL"
vitis_hls -f "$TCL" > /tmp/hls_final.log 2>&1

echo ""
echo "[最終時序]"
grep -i "ap_clk" "$RPT" | head -1
echo ""
echo "[cosim 結果]"
grep -i "co-simulation finished\|Test Passed\|Test Failed" /tmp/hls_final.log | head -3
echo ""
echo "完整 log：/tmp/hls_final.log"
echo "(原始 tcl 已備份在 ${TCL}.bak，要還原就 cp ${TCL}.bak $TCL)"
