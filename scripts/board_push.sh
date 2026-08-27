#!/bin/bash
# Push a .pbi image to a running picoBEAM board and read its status line.
#
#   bash scripts/board_push.sh _emit/sd/blinky.img       # push, then listen
#   bash scripts/board_push.sh                           # listen only
#   LISTEN=30 bash scripts/board_push.sh _emit/sd/x.img  # listen longer
#
# Assumes the bitstream is already programmed (fujprog _emit/ulx3s/picobeam_m5.bit).
# An image push is a soft reboot: code loads, everything semantic resets
# (notes/26 entry 36), and the machine boots the image's entry point.
#
# The status line, one per second:  pPPP S FL CC AAA LLL Q E OO WD XX NN
#   OO = low byte of the last `out` (erlang:display/1) — also the LEDs
#        while BTN2 is held.  XX = last abnormal death reason.
#   CC = per-engine occupancy nibbles.
set -u
cd "$(dirname "$0")/.."
TTY="${TTY:-/dev/cu.usbserial-D01477}"
LISTEN="${LISTEN:-12}"

rm -f /tmp/board.txt
if [ $# -ge 1 ]; then
  fujprog -P "$TTY" -b 115200 -a "$1" -t > /tmp/board.txt 2>&1 &
else
  fujprog -P "$TTY" -b 115200 -t > /tmp/board.txt 2>&1 &
fi
sleep "$LISTEN"
pkill -f "fujprog -P"
sleep 1
echo "--- status lines from the board ---"
tr -c '[:print:]\n' '\n' < /tmp/board.txt | grep -E '^p[0-9a-f]' | tail -12
echo "__BOARD_PUSH_DONE__"
