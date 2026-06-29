defmodule AtomvmHttpd.MixProject do
  use Mix.Project

  def project do
    [
      app: :atomvm_httpd,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      compilers: Mix.compilers(),
      erlc_paths: ["src"],
      elixirc_paths: elixirc_paths(Mix.env()),
      erlc_options: erlc_options(Mix.env()),
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps, do: []

  defp erlc_options(:test), do: [:debug_info, {:d, :TEST}]
  defp erlc_options(_env), do: [:debug_info]

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]
end
