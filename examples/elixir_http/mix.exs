defmodule ElixirHttp.MixProject do
  use Mix.Project

  def project do
    [
      app: :elixir_http,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      atomvm: [
        # Change to Lux.Test for minimal testing without networking
        start: ElixirHttp,
        flash_offset: 0x250000
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:pythonx, "~> 0.4.7", runtime: false},
      {:exatomvm, github: "atomvm/ExAtomVM", runtime: false},
      {:atomvm_httpd, path: "../../"},
      # Test-only dependencies
      {:req, "~> 0.5", only: :test, runtime: false},
      {:websockex, "~> 0.4.3", only: :test, runtime: false}
    ]
  end
end
