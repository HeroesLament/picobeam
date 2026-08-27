#!/usr/bin/env python3
"""notes/41 — the multiply-driven-net check.

    python3 scripts/check_drivers.py _emit/all/*.v

EHDL's flattener does not namespace. When a child's port name is also
the name of a net in the parent, the two are merged into one wire, and
the emitted Verilog gets two continuous assignments to it. Where the
drivers agree the wire looks fine; where they disagree a bit goes `x`,
and the failure surfaces somewhere else entirely -- in notes/41 it was a
frame store writing every spill to address `x`, three modules away from
the collision that caused it.

This is the third shape of that one missing check: notes/34 had an
instance name colliding with a wire, notes/36 had an internal clock
promoted to a port. Rather than model EHDL's renaming rules -- which is
what got this wrong the first time -- the check reads the OUTPUT, where
the answer is unambiguous: a net with two continuous drivers is a bug,
whatever produced it.
"""
import re
import sys
from collections import Counter

ASSIGN = re.compile(r'^\s*assign\s+(\w+)\s*(?:\[[^\]]*\])?\s*=', re.M)

bad = 0
for path in sys.argv[1:]:
    with open(path) as f:
        src = f.read()
    names = ASSIGN.findall(src)
    for name, n in Counter(names).items():
        if n > 1:
            print(f"MULTIDRIVE {path}: `{name}` has {n} continuous drivers")
            bad += 1

if bad:
    print(f"__DRIVERS_FAIL__ {bad}")
    sys.exit(1)
print(f"__DRIVERS_OK__ ({len(sys.argv) - 1} netlists)")
