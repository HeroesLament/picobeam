defmodule PicoBEAM.RTL.NameTable do
  @moduledoc """
  M7 — the registered-name table (`notes/50`): `register/2`,
  `whereis/1`, `unregister/1`, and `Name ! Msg`.

  Eight entries of {name, slot, serial}, fully associative, in flops —
  a CAM, because every port is a parallel compare: `whereis` and the
  send-path resolve ask "which entry holds this atom", registration
  asks "is this atom or this pid already here", and a death asks
  "which entry holds this slot+serial". Eight is the honest v1 size;
  the ninth registration is `:system_limit` on both the model and the
  gates, by agreement rather than accident.

  ONE PER MACHINE (`notes/53`): an engine is a scheduler, the machine
  is the node, and BEAM's registry is node-global. The unit lives at
  the top level with a full interface per engine — flops make a second
  true port cheap, and dual-porting dissolves every arbitration
  question: lookups never contend, simultaneous registration of the
  SAME name gives port B `badarg` (exactly what BEAM's serialization
  hands the loser of that race), and death-clears from two engines
  target different entries by construction.

  (It lived inside `BarrelEngine` for one note's time — `notes/50`
  built it under the engine-is-a-node doctrine this note retired.)

  The serial rides each entry so a death clears only the incarnation
  that registered: a name registered by slot 3 serial 5 must survive
  the death of slot 3 serial 6 — that process was never the name's
  owner, whatever slot it recycled.

  One write site per entry register, muxed by priority: death, then
  unregister, then registration into the first free entry. A death and
  a registration in the same cycle touch different entries by
  construction (the dying pid's entry is occupied; the registration
  lands in a free one).
  """

  use Hw.Component

  clock :clk, freq: 50.0

  input :rst, 1

  # lookup (combinational): atom payload in, pid fields out
  input :q_name, 16
  output :q_hit, 1
  output :q_eng, 4
  output :q_slot, 5
  output :q_serial, 22

  # registration legality, answered combinationally for the SAME name
  # and pid the write port carries
  input :w_name, 16
  input :w_eng, 4
  input :w_slot, 5
  input :w_serial, 22
  input :w_en, 1
  output :name_taken, 1
  output :pid_taken, 1
  output :table_full, 1

  # unregister
  input :clr_en, 1
  input :clr_name, 16

  # a death releases its name — BEAM's auto-unregister
  input :die_en, 1
  input :die_eng, 4
  input :die_slot, 5
  input :die_serial, 22

  # ---- interface B: the second engine's full set (`notes/53`)
  input :q2_name, 16
  output :q2_hit, 1
  output :q2_eng, 4
  output :q2_slot, 5
  output :q2_serial, 22
  input :w2_name, 16
  input :w2_eng, 4
  input :w2_slot, 5
  input :w2_serial, 22
  input :w2_en, 1
  output :name_taken2, 1
  output :pid_taken2, 1
  output :table_full2, 1
  input :clr2_en, 1
  input :clr2_name, 16
  input :die2_en, 1
  input :die2_eng, 4
  input :die2_slot, 5
  input :die2_serial, 22

  wire :v0, 1, init: 0
  wire :v1, 1, init: 0
  wire :v2, 1, init: 0
  wire :v3, 1, init: 0
  wire :v4, 1, init: 0
  wire :v5, 1, init: 0
  wire :v6, 1, init: 0
  wire :v7, 1, init: 0
  wire :n0, 16, init: 0
  wire :n1, 16, init: 0
  wire :n2, 16, init: 0
  wire :n3, 16, init: 0
  wire :n4, 16, init: 0
  wire :n5, 16, init: 0
  wire :n6, 16, init: 0
  wire :n7, 16, init: 0
  wire :s0, 31, init: 0
  wire :s1, 31, init: 0
  wire :s2, 31, init: 0
  wire :s3, 31, init: 0
  wire :s4, 31, init: 0
  wire :s5, 31, init: 0
  wire :s6, 31, init: 0
  wire :s7, 31, init: 0

  wire :qh0, 1
  wire :qh1, 1
  wire :qh2, 1
  wire :qh3, 1
  wire :qh4, 1
  wire :qh5, 1
  wire :qh6, 1
  wire :qh7, 1
  wire :q_ent, 31
  wire :wn0, 1
  wire :wn1, 1
  wire :wn2, 1
  wire :wn3, 1
  wire :wn4, 1
  wire :wn5, 1
  wire :wn6, 1
  wire :wn7, 1
  wire :wp0, 1
  wire :wp1, 1
  wire :wp2, 1
  wire :wp3, 1
  wire :wp4, 1
  wire :wp5, 1
  wire :wp6, 1
  wire :wp7, 1
  wire :d0, 1
  wire :d1, 1
  wire :d2, 1
  wire :d3, 1
  wire :d4, 1
  wire :d5, 1
  wire :d6, 1
  wire :d7, 1
  wire :c0, 1
  wire :c1, 1
  wire :c2, 1
  wire :c3, 1
  wire :c4, 1
  wire :c5, 1
  wire :c6, 1
  wire :c7, 1
  wire :f0, 1
  wire :f1, 1
  wire :f2, 1
  wire :f3, 1
  wire :f4, 1
  wire :f5, 1
  wire :f6, 1
  wire :f7, 1
  wire :die_ent, 31
  wire :die2_ent, 31
  wire :w_ent, 31
  wire :w2_ent, 31
  wire :qb0, 1
  wire :qb1, 1
  wire :qb2, 1
  wire :qb3, 1
  wire :qb4, 1
  wire :qb5, 1
  wire :qb6, 1
  wire :qb7, 1
  wire :q2_ent, 31
  wire :e0_, 1
  wire :e1_, 1
  wire :e2_, 1
  wire :e3_, 1
  wire :e4_, 1
  wire :e5_, 1
  wire :e6_, 1
  wire :e7_, 1
  wire :k0, 1
  wire :k1, 1
  wire :k2, 1
  wire :k3, 1
  wire :k4, 1
  wire :k5, 1
  wire :k6, 1
  wire :k7, 1
  wire :g0, 1
  wire :g1, 1
  wire :g2, 1
  wire :g3, 1
  wire :g4, 1
  wire :g5, 1
  wire :g6, 1
  wire :g7, 1
  wire :w2_same, 1

  comb do
    die_ent = die_eng * 134_217_728 + die_slot * 4_194_304 + die_serial
    die2_ent = die2_eng * 134_217_728 + die2_slot * 4_194_304 + die2_serial
    w_ent = w_eng * 134_217_728 + w_slot * 4_194_304 + w_serial
    w2_ent = w2_eng * 134_217_728 + w2_slot * 4_194_304 + w2_serial

    # lookup: parallel name compare over the valid entries
    qh0 = band(v0, n0 == q_name)
    qh1 = band(v1, n1 == q_name)
    qh2 = band(v2, n2 == q_name)
    qh3 = band(v3, n3 == q_name)
    qh4 = band(v4, n4 == q_name)
    qh5 = band(v5, n5 == q_name)
    qh6 = band(v6, n6 == q_name)
    qh7 = band(v7, n7 == q_name)
    q_hit = bor(qh0, bor(qh1, bor(qh2, bor(qh3, bor(qh4, bor(qh5, bor(qh6, qh7)))))))
    # registration keeps names unique, so the hit vector is one-hot and
    # this OR tree is a mux (3 levels; a sum would chain 7 carries)
    q_ent =
      bor(bor(bor(qh0 * s0, qh1 * s1), bor(qh2 * s2, qh3 * s3)),
        bor(bor(qh4 * s4, qh5 * s5), bor(qh6 * s6, qh7 * s7)))
    q_eng = q_ent[30..27]
    q_slot = q_ent[26..22]
    q_serial = q_ent[21..0]

    # interface B's lookup: an independent compare bank — flops, so a
    # second read port is muxes, not a constraint
    qb0 = band(v0, n0 == q2_name)
    qb1 = band(v1, n1 == q2_name)
    qb2 = band(v2, n2 == q2_name)
    qb3 = band(v3, n3 == q2_name)
    qb4 = band(v4, n4 == q2_name)
    qb5 = band(v5, n5 == q2_name)
    qb6 = band(v6, n6 == q2_name)
    qb7 = band(v7, n7 == q2_name)
    q2_hit = bor(qb0, bor(qb1, bor(qb2, bor(qb3, bor(qb4, bor(qb5, bor(qb6, qb7)))))))
    q2_ent =
      bor(bor(bor(qb0 * s0, qb1 * s1), bor(qb2 * s2, qb3 * s3)),
        bor(bor(qb4 * s4, qb5 * s5), bor(qb6 * s6, qb7 * s7)))
    q2_eng = q2_ent[30..27]
    q2_slot = q2_ent[26..22]
    q2_serial = q2_ent[21..0]

    # registration legality
    wn0 = band(v0, n0 == w_name)
    wn1 = band(v1, n1 == w_name)
    wn2 = band(v2, n2 == w_name)
    wn3 = band(v3, n3 == w_name)
    wn4 = band(v4, n4 == w_name)
    wn5 = band(v5, n5 == w_name)
    wn6 = band(v6, n6 == w_name)
    wn7 = band(v7, n7 == w_name)
    name_taken = bor(wn0, bor(wn1, bor(wn2, bor(wn3, bor(wn4, bor(wn5, bor(wn6, wn7)))))))

    wp0 = band(v0, s0 == w_ent)
    wp1 = band(v1, s1 == w_ent)
    wp2 = band(v2, s2 == w_ent)
    wp3 = band(v3, s3 == w_ent)
    wp4 = band(v4, s4 == w_ent)
    wp5 = band(v5, s5 == w_ent)
    wp6 = band(v6, s6 == w_ent)
    wp7 = band(v7, s7 == w_ent)
    pid_taken = bor(wp0, bor(wp1, bor(wp2, bor(wp3, bor(wp4, bor(wp5, bor(wp6, wp7)))))))

    table_full = band(v0, band(v1, band(v2, band(v3, band(v4, band(v5, band(v6, v7)))))))

    # B's registration legality. `w2_same` is the race BEAM serializes:
    # both engines registering ONE name in one cycle — port B loses,
    # exactly as the second caller through BEAM's lock would
    e0_ = band(v0, n0 == w2_name)
    e1_ = band(v1, n1 == w2_name)
    e2_ = band(v2, n2 == w2_name)
    e3_ = band(v3, n3 == w2_name)
    e4_ = band(v4, n4 == w2_name)
    e5_ = band(v5, n5 == w2_name)
    e6_ = band(v6, n6 == w2_name)
    e7_ = band(v7, n7 == w2_name)
    w2_same = band(w_en, w_name == w2_name)

    name_taken2 =
      bor(w2_same,
        bor(e0_, bor(e1_, bor(e2_, bor(e3_, bor(e4_, bor(e5_, bor(e6_, e7_))))))))

    k0 = band(v0, s0 == w2_ent)
    k1 = band(v1, s1 == w2_ent)
    k2 = band(v2, s2 == w2_ent)
    k3 = band(v3, s3 == w2_ent)
    k4 = band(v4, s4 == w2_ent)
    k5 = band(v5, s5 == w2_ent)
    k6 = band(v6, s6 == w2_ent)
    k7 = band(v7, s7 == w2_ent)
    pid_taken2 = bor(k0, bor(k1, bor(k2, bor(k3, bor(k4, bor(k5, bor(k6, k7)))))))

    # full for B counts A's same-cycle claim: seven valids plus a
    # pending write is a full table from where B stands
    table_full2 = band(bor(v0, band(w_en, f0)),
      band(bor(v1, band(w_en, f1)),
        band(bor(v2, band(w_en, f2)),
          band(bor(v3, band(w_en, f3)),
            band(bor(v4, band(w_en, f4)),
              band(bor(v5, band(w_en, f5)),
                band(bor(v6, band(w_en, f6)), bor(v7, band(w_en, f7)))))))))

    # death: clear the incarnation that registered, nothing else
    d0 = bor(band(die_en, band(v0, s0 == die_ent)),
      band(die2_en, band(v0, s0 == die2_ent)))
    d1 = bor(band(die_en, band(v1, s1 == die_ent)),
      band(die2_en, band(v1, s1 == die2_ent)))
    d2 = bor(band(die_en, band(v2, s2 == die_ent)),
      band(die2_en, band(v2, s2 == die2_ent)))
    d3 = bor(band(die_en, band(v3, s3 == die_ent)),
      band(die2_en, band(v3, s3 == die2_ent)))
    d4 = bor(band(die_en, band(v4, s4 == die_ent)),
      band(die2_en, band(v4, s4 == die2_ent)))
    d5 = bor(band(die_en, band(v5, s5 == die_ent)),
      band(die2_en, band(v5, s5 == die2_ent)))
    d6 = bor(band(die_en, band(v6, s6 == die_ent)),
      band(die2_en, band(v6, s6 == die2_ent)))
    d7 = bor(band(die_en, band(v7, s7 == die_ent)),
      band(die2_en, band(v7, s7 == die2_ent)))

    # unregister: the engine already checked the name is present
    c0 = bor(band(clr_en, band(v0, n0 == clr_name)),
      band(clr2_en, band(v0, n0 == clr2_name)))
    c1 = bor(band(clr_en, band(v1, n1 == clr_name)),
      band(clr2_en, band(v1, n1 == clr2_name)))
    c2 = bor(band(clr_en, band(v2, n2 == clr_name)),
      band(clr2_en, band(v2, n2 == clr2_name)))
    c3 = bor(band(clr_en, band(v3, n3 == clr_name)),
      band(clr2_en, band(v3, n3 == clr2_name)))
    c4 = bor(band(clr_en, band(v4, n4 == clr_name)),
      band(clr2_en, band(v4, n4 == clr2_name)))
    c5 = bor(band(clr_en, band(v5, n5 == clr_name)),
      band(clr2_en, band(v5, n5 == clr2_name)))
    c6 = bor(band(clr_en, band(v6, n6 == clr_name)),
      band(clr2_en, band(v6, n6 == clr2_name)))
    c7 = bor(band(clr_en, band(v7, n7 == clr_name)),
      band(clr2_en, band(v7, n7 == clr2_name)))

    # first-free priority for the write
    f0 = band(w_en, bnot(v0))
    f1 = band(w_en, band(v0, bnot(v1)))
    f2 = band(w_en, band(v0, band(v1, bnot(v2))))
    f3 = band(w_en, band(v0, band(v1, band(v2, bnot(v3)))))
    f4 = band(w_en, band(v0, band(v1, band(v2, band(v3, bnot(v4))))))
    f5 = band(w_en, band(v0, band(v1, band(v2, band(v3, band(v4, bnot(v5)))))))
    f6 = band(w_en, band(v0, band(v1, band(v2, band(v3, band(v4, band(v5, bnot(v6))))))))
    f7 = band(w_en, band(v0, band(v1, band(v2, band(v3, band(v4, band(v5, band(v6, bnot(v7)))))))))

    # B's write lands in the first entry that is neither valid nor
    # A's claim this cycle. The one-hot g-vector is a priority encoder
    # over `bnot(bor(v, f))`.
    g0 = band(w2_en, bnot(bor(v0, f0)))
    g1 = band(w2_en, band(bor(v0, f0), bnot(bor(v1, f1))))
    g2 = band(w2_en, band(bor(v0, f0), band(bor(v1, f1), bnot(bor(v2, f2)))))
    g3 = band(w2_en,
      band(bor(v0, f0), band(bor(v1, f1), band(bor(v2, f2), bnot(bor(v3, f3))))))
    g4 = band(w2_en,
      band(bor(v0, f0),
        band(bor(v1, f1), band(bor(v2, f2), band(bor(v3, f3), bnot(bor(v4, f4)))))))
    g5 = band(w2_en,
      band(bor(v0, f0),
        band(bor(v1, f1),
          band(bor(v2, f2), band(bor(v3, f3), band(bor(v4, f4), bnot(bor(v5, f5))))))))
    g6 = band(w2_en,
      band(bor(v0, f0),
        band(bor(v1, f1),
          band(bor(v2, f2),
            band(bor(v3, f3), band(bor(v4, f4), band(bor(v5, f5), bnot(bor(v6, f6)))))))))
    g7 = band(w2_en,
      band(bor(v0, f0),
        band(bor(v1, f1),
          band(bor(v2, f2),
            band(bor(v3, f3),
              band(bor(v4, f4),
                band(bor(v5, f5), band(bor(v6, f6), bnot(bor(v7, f7))))))))))
  end

  on :clk do
    if rst == 1 do
      v0 = 0
      v1 = 0
      v2 = 0
      v3 = 0
      v4 = 0
      v5 = 0
      v6 = 0
      v7 = 0
    else
      if bor(d0, c0) == 1 do
        v0 = 0
      end

      if bor(d1, c1) == 1 do
        v1 = 0
      end

      if bor(d2, c2) == 1 do
        v2 = 0
      end

      if bor(d3, c3) == 1 do
        v3 = 0
      end

      if bor(d4, c4) == 1 do
        v4 = 0
      end

      if bor(d5, c5) == 1 do
        v5 = 0
      end

      if bor(d6, c6) == 1 do
        v6 = 0
      end

      if bor(d7, c7) == 1 do
        v7 = 0
      end

      if f0 == 1 do
        v0 = 1
        n0 = w_name
        s0 = w_ent
      end

      if g0 == 1 do
        v0 = 1
        n0 = w2_name
        s0 = w2_ent
      end

      if f1 == 1 do
        v1 = 1
        n1 = w_name
        s1 = w_ent
      end

      if g1 == 1 do
        v1 = 1
        n1 = w2_name
        s1 = w2_ent
      end

      if f2 == 1 do
        v2 = 1
        n2 = w_name
        s2 = w_ent
      end

      if g2 == 1 do
        v2 = 1
        n2 = w2_name
        s2 = w2_ent
      end

      if f3 == 1 do
        v3 = 1
        n3 = w_name
        s3 = w_ent
      end

      if g3 == 1 do
        v3 = 1
        n3 = w2_name
        s3 = w2_ent
      end

      if f4 == 1 do
        v4 = 1
        n4 = w_name
        s4 = w_ent
      end

      if g4 == 1 do
        v4 = 1
        n4 = w2_name
        s4 = w2_ent
      end

      if f5 == 1 do
        v5 = 1
        n5 = w_name
        s5 = w_ent
      end

      if g5 == 1 do
        v5 = 1
        n5 = w2_name
        s5 = w2_ent
      end

      if f6 == 1 do
        v6 = 1
        n6 = w_name
        s6 = w_ent
      end

      if g6 == 1 do
        v6 = 1
        n6 = w2_name
        s6 = w2_ent
      end

      if f7 == 1 do
        v7 = 1
        n7 = w_name
        s7 = w_ent
      end

      if g7 == 1 do
        v7 = 1
        n7 = w2_name
        s7 = w2_ent
      end
    end
  end
end
