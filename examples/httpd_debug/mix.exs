defmodule HttpdDebug.MixProject do
  use Mix.Project

  def project do
    [
      app: :httpd_debug,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      atomvm: [
        start: HttpdDebug,
        flash_offset: 0x250000
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:atomvm_httpd, path: "../.."},
      {:exatomvm, github: "atomvm/exatomvm", runtime: false}
    ]
  end
end
