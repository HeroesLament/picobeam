#!/bin/bash
# Cross-engine spawn on the ULX3S (notes/49): wait for the bitstream,
# program SRAM, push the image over the debug cable, read the status line.
cd "$HOME/src/picobeam"
TTY=/dev/cu.usbserial-D01477
echo "--- waiting for the bitstream ---"
for i in $(seq 1 300); do
  grep -q __M5_BUILD_DONE__ /tmp/m5build.log && break
  sleep 5
done
if ! grep -q __M5_BUILD_DONE__ /tmp/m5build.log; then
  echo "__BUILD_NEVER_FINISHED__"; tail -5 /tmp/m5build.log; exit 1
fi
grep -E "Max frequency for clock|LUT4|TRELLIS_FF|DP16KD|MULT18" /tmp/m5build.log | head -8
echo "--- programming SRAM ---"
fujprog _emit/ulx3s/picobeam_m5.bit 2>&1 | tail -3
sleep 3
echo "--- pushing the image and listening ---"
rm -f /tmp/board.txt
fujprog -P "$TTY" -b 115200 -a _emit/sd/spawn2.img -t > /tmp/board.txt 2>&1 &
sleep 12
pkill -f "fujprog -P"
sleep 1
echo "--- status lines from the board ---"
tr -c '[:print:]\n' '\n' < /tmp/board.txt | grep -E '^p[0-9a-f]' | tail -8
echo "__BOARDRUN_DONE__"
