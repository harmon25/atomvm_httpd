defmodule ElixirHttp do
  @moduledoc """
  Elixir httpd example
  """
  @compile {:no_warn_undefined, :network}

  def start do
    :ok = start_network()

    :ok = start_http()

    Process.sleep(:infinity)
  end

  # resolved at compile time
  @ssid System.get_env("SSID")
  @psk System.get_env("PSK")

  def start_network() do
    Process.sleep(500)
    config = [ssid: @ssid, psk: @psk]

    case :network.wait_for_sta(config, 15_000) do
      {:ok, _} ->
        :ok

      {:error, :disconnected} ->
        # try again...
        start_network()

      {:error, {:already_started, _pid}} ->
        Process.sleep(500)
        :ok

      {:error, err} ->
        IO.puts("Error starting network #{inspect(err)}")

        :error
    end
  end

  defp start_http(port \\ 8080) do
    config = [
      # API endpoints at /api/*
      {["api"],
       %{
         handler: :httpd_api_handler,
         handler_config: %{
           module: ElixirHttp.ApiHandler
         }
       }},
      # WebSocket at /ws/*
      {["ws"],
       %{
         handler: :httpd_ws_handler,
         handler_config: %{
           module: ElixirHttp.WsHandler
         }
       }},
      # Static files from priv/ at root
      {[],
       %{
         handler: :httpd_file_handler,
         handler_config: %{
           app: :elixir_http
         }
       }}
    ]

    IO.puts("Starting httpd on port #{port}...")

    case :httpd.start(port, config) do
      {:ok, _pid} ->
        IO.puts("httpd started.")
        :ok

      error ->
        IO.puts("An error occurred: #{inspect(error)}")
        :error
    end
  end
end
