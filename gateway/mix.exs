defmodule Gateway.MixProject do
  use Mix.Project

  def project do
    [
      app: :gateway,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      releases: releases()
    ]
  end

  # `MIX_ENV=prod mix release` builds _build/prod/rel/gateway. it is built on debian 13
  # and runs on debian 13 (the pilot box), with erts bundled, so the box needs no erlang
  defp releases do
    [
      gateway: [
        include_executables_for: [:unix],
        applications: [runtime_tools: :permanent]
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {Gateway.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:breakline, path: "../core"},
      {:slipstream, "~> 1.3"},
      {:stream_data, "~> 1.4", only: :test}
    ]
  end
end
