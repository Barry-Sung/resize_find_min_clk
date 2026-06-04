#!/bin/bash
# =============================================================
# find_min_clk_v2.sh  —— 更穩健版
# 修正：1) 不用 sed -i(改用 awk 重寫,避免暫存檔殘留與替換失敗)
#       2) 每次合成前刪舊報告,確保抓到的是「這次」的新報告
#       3) 合成失敗會明確報出,不會拿舊報告誤判
# =============================================================

# ---------- 可調參數 ----------
LOW=3.0
HIGH=8.0
TOL=0.1
MARGIN=0.05
TCL="run_hls.tcl"
RPT="resize.prj/sol1/syn/report/resize_accel_csynth.rpt"
# --------------------------------

# ---------- 自動載入 Vitis 與 OpenCV 環境 ----------
# (解決用 ./ 執行時子 shell 找不到 vitis_hls 的問題)
# 若你的 Vitis 裝在別的路徑,改這行
VITIS_SETTINGS="/tools/Xilinx/Vitis/2024.1/settings64.sh"
if ! command -v vitis_hls >/dev/null 2>&1; then
  if [ -f "$VITIS_SETTINGS" ]; then
    echo "[環境] 載入 Vitis: $VITIS_SETTINGS"
    source "$VITIS_SETTINGS"
  else
    echo "[錯誤] 找不到 vitis_hls,且 $VITIS_SETTINGS 不存在。請確認 Vitis 安裝路徑。"
    exit 1
  fi
fi
# OpenCV 環境變數(cosim 需要)
export OPENCV_INCLUDE=${OPENCV_INCLUDE:-/usr/local/include/opencv4}
export OPENCV_LIB=${OPENCV_LIB:-/usr/local/lib}
export LD_LIBRARY_PATH=/usr/local/lib:$LD_LIBRARY_PATH
# 再次確認
if ! command -v vitis_hls >/dev/null 2>&1; then
  echo "[錯誤] 載入後仍找不到 vitis_hls,請手動 source 後再執行。"; exit 1
fi
echo "[環境] vitis_hls 已就緒: $(which vitis_hls)"
echo ""

if [ ! -f "$TCL" ]; then echo "[錯誤] 找不到 $TCL,請在 resize 資料夾執行"; exit 1; fi

# 備份(只在第一次,避免覆蓋掉乾淨備份)
[ -f "${TCL}.orig" ] || cp "$TCL" "${TCL}.orig"
echo "[備份] 原始 tcl 保存在 ${TCL}.orig"

# 用 awk 重寫整個 tcl:設定開關與 CLKP(比 sed -i 穩,不留暫存檔)
# 參數:$1=CSIM $2=CSYNTH $3=COSIM $4=CLKP
rewrite_tcl () {
  awk -v csim="$1" -v csynth="$2" -v cosim="$3" -v clkp="$4" '
    /^set CSIM /        { print "set CSIM " csim; next }
    /^set CSYNTH /      { print "set CSYNTH " csynth; next }
    /^set COSIM /       { print "set COSIM " cosim; next }
    /set CLKP /         { sub(/set CLKP [0-9.]+/, "set CLKP " clkp); print; next }
    { print }
  ' "${TCL}.orig" > "$TCL"
}

# 跑一次合成,回傳 Estimated;失敗回 -1
run_one () {
  local clkp=$1
  rewrite_tcl 0 1 0 "$clkp"        # 只開 csynth
  rm -f "$RPT"                      # 關鍵:先刪舊報告,確保等下抓到的是新的
  vitis_hls -f "$TCL" > /tmp/hls_run.log 2>&1
  if [ ! -f "$RPT" ]; then echo "-1"; return; fi   # 報告沒產生 = 合成失敗
  # 抓 ap_clk 那行的第二個小數(Estimated)
  local est
  est=$(grep -i "ap_clk" "$RPT" | grep -oE "[0-9]+\.[0-9]+" | sed -n '2p')
  [ -z "$est" ] && echo "-1" || echo "$est"
}

echo "========================================================"
echo " 二分逼近:範圍 [$LOW, $HIGH] ns,精度 $TOL ns"
echo "========================================================"
printf "%-6s %-12s %-14s %-12s\n" "次數" "Target(ns)" "Estimated(ns)" "結果"
echo "--------------------------------------------------------"

best=""; iter=0
while (( $(echo "$HIGH - $LOW > $TOL" | bc -l) )); do
  iter=$((iter+1))
  mid=$(echo "scale=3; ($LOW + $HIGH)/2" | bc -l)
  est=$(run_one "$mid")

  if [ "$est" == "-1" ]; then
    printf "%-6s %-12s %-14s %-12s\n" "$iter" "$mid" "合成失敗" "→放寬"
    LOW="$mid"; continue
  fi
  if (( $(echo "$est <= $mid" | bc -l) )); then
    printf "%-6s %-12s %-14s %-12s\n" "$iter" "$mid" "$est" "達標↓壓低"
    best="$mid"; HIGH="$mid"
  else
    printf "%-6s %-12s %-14s %-12s\n" "$iter" "$mid" "$est" "未達標↑放寬"
    LOW="$mid"
  fi
done

echo "--------------------------------------------------------"
if [ -z "$best" ]; then
  echo "[結果] 範圍內找不到達標值,請把 HIGH 調大或檢查 /tmp/hls_run.log"
  cp "${TCL}.orig" "$TCL"; exit 1
fi

final=$(echo "scale=3; $best + $MARGIN" | bc -l)
echo "[結果] 剛好達標的最小 Target ≈ $best ns"
echo "       建議採用(含 $MARGIN 餘裕):CLKP = $final ns"
echo ""
echo "========================================================"
echo " 用 CLKP=$final 跑完整流程(csim+csynth+cosim)驗證"
echo "========================================================"
rewrite_tcl 1 1 1 "$final"
rm -f "$RPT"
vitis_hls -f "$TCL" > /tmp/hls_final.log 2>&1
echo ""
echo "[最終時序]"; grep -i "ap_clk" "$RPT" | head -1
echo ""
echo "[cosim 結果]"; grep -i "co-simulation finished\|Test Passed\|Test Failed" /tmp/hls_final.log | head -3
echo ""
echo "完整 log:/tmp/hls_final.log　/　原始 tcl 備份:${TCL}.orig"
