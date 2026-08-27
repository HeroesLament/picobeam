#!/usr/bin/env python3
"""Make an ehdl netlist iverilog-clean.

ehdl emits `hdl_case` as a signal declared `wire` but assigned inside an
`always @(*)` block, which iverilog rejects. The fix is to redeclare
exactly those signals as `reg` — but only those: a `hdl_case` in a
`comb` block lowers to a continuous `assign` instead, and turning THAT
into a reg is the same error in the other direction. So decide per
signal by looking at how it is actually driven.

    patch_netlist.py IN OUT
"""
import re
import sys

src = open(sys.argv[1]).read()

# a signal driven by `assign x = ...` stays a wire; one driven by a bare
# `x = ...` (inside an always block) has to become a reg
assigned = set(re.findall(r'^\s*assign\s+(\w+)\s*=', src, re.M))
procedural = set(re.findall(r'^\s+(_case_\d+)\s*=', src, re.M))
procedural |= set(re.findall(r'^\s+(?:if\s*\([^)]*\)\s*)(_case_\d+)\s*=', src, re.M))
to_reg = procedural - assigned

out = []
for line in src.split('\n'):
    m = re.match(r'^(\s*)wire(\s+(?:\[[^\]]+\]\s*)?)(\w+);$', line)
    if m and m.group(3) in to_reg:
        line = f"{m.group(1)}reg{m.group(2)}{m.group(3)};"
    out.append(line)

src2 = '\n'.join(out)

# ---- zero every memory that has no initialiser of its own.
#
# On an ECP5 a BRAM or LUT-RAM powers up defined; in iverilog an
# unwritten reg array reads X, and X does not stay contained. The
# one-hot-sum mux idiom this codebase uses everywhere propagates it,
# because `0 * X` is X — so an unread entry of a memory nothing has
# touched poisons a signal through a term that is not even selected,
# and the symptom shows up several states downstream of the cause.
#
# That has now cost three separate debugging sessions (the serialiser's
# traversal stack, the literal pool, and a mailbox column), so it is
# fixed here rather than remembered in each testbench. Memories that
# ehdl already initialises are left alone: their `initial` block is the
# real power-up state and must not be raced.
mems = re.findall(r'^\s*reg\s*(?:\[[^\]]+\]\s*)?(\w+)\s*\[\s*0\s*:\s*(\d+)\s*\]\s*;',
                  src2, re.M)
inited = set(re.findall(r'^\s+(\w+)\[\d+\]\s*=', src2, re.M))

zeroed = [(n, d) for n, d in mems if n not in inited]
if zeroed:
    body = ["", "  // simulation power-up: see patch_netlist.py", "  integer _pz;", "  initial begin"]
    for n, d in zeroed:
        body.append(f"    for (_pz = 0; _pz <= {d}; _pz = _pz + 1) {n}[_pz] = 0;")
    body.append("  end")
    idx = src2.rstrip().rfind('\nendmodule')
    src2 = src2[:idx] + '\n' + '\n'.join(body) + src2[idx:]

open(sys.argv[2], 'w').write(src2)
print(f"{sys.argv[1]}: {len(to_reg)} wire->reg, {len(zeroed)} mems zeroed", file=sys.stderr)
