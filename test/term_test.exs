defmodule PicoBEAM.TermTest do
  use ExUnit.Case, async: true

  alias PicoBEAM.Term

  test "words are 36 bits with a 4-bit tag" do
    w = Term.int(-1)
    assert w < Bitwise.bsl(1, 36)
    assert Term.tag_name(w) == :int
  end

  test "fixnum roundtrip across the signed 32-bit range" do
    for v <- [0, 1, -1, 42, -42, Term.int_max(), Term.int_min()] do
      assert Term.int_value(Term.int(v)) == v
    end
  end

  test "overflow is refused, never wrapped" do
    assert {:error, :overflow} = Term.int_checked(Term.int_max() + 1)
    assert {:error, :overflow} = Term.int_checked(Term.int_min() - 1)
    assert {:ok, _} = Term.int_checked(Term.int_max())
  end

  test "pid field layout: engine 4 | slot 6 | serial 22" do
    pid = Term.pid(9, 33, 0x2ABCDE)
    assert Term.tag_name(pid) == :pid
    assert Term.pid_engine(pid) == 9
    assert Term.pid_slot(pid) == 33
    assert Term.pid_serial(pid) == 0x2ABCDE
  end

  test "reserved atoms hold their fixed indices" do
    assert Enum.at(Term.reserved_atoms(), 0) == :normal
    assert :overflow in Term.reserved_atoms()
    assert :heap_full in Term.reserved_atoms()
    assert Term.reserved_atom_count() == length(Term.reserved_atoms())
  end
end
