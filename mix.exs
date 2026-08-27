defmodule PicoBEAM.MixProject do
  use Mix.Project

  def project do
    [
      app: :pico_beam,
      version: "0.1.0-rc.1",
      elixir: "~> 1.14",
      description:
        "picoBEAM — an Erlang machine in FPGA fabric. The reference model, " <>
          "the ISA and its encoding, the Core Erlang and Elixir front end, " <>
          "and the machine itself written in EHDL.",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      # The hardware language. `../ehdl` resolves to the sibling checkout
      # on a dev machine and to the staged copy in a work container
      # alike; there is no published package yet, so a checkout beside
      # this one is a prerequisite and the README says so.
      {:ehdl, path: "../ehdl"},
      # Pinned: rustler 0.37.3+ needs Elixir >= 1.15 (System.cmd :lines),
      # and the oldest toolchain this repo supports (~> 1.14) must still
      # build the ehdl dep's sim NIF.
      {:rustler, "~> 0.36.0", override: true, runtime: false}
    ]
  end
end
