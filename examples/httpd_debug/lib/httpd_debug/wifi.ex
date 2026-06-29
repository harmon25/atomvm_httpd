defmodule HttpdDebug.WiFi do
  @moduledoc """
  WiFi STA connectivity for HttpdDebug.

  Reads WiFi credentials from compile-time environment variables
  and establishes a connection to the configured access point.
  """

  @compile {:no_warn_undefined, :network}

  @wifi_ssid System.get_env("ATOMVM_WIFI_SSID")
  @wifi_psk System.get_env("ATOMVM_WIFI_PSK")
  @connect_timeout 15_000
  # Number of @connect_timeout cycles to wait for an IP before giving up.
  # The first association after boot is frequently flaky (one STA_DISCONNECTED
  # before it sticks), so be patient rather than bailing on the first hiccup.
  @max_wait_cycles 8

  def connect do
    unless @wifi_ssid do
      IO.puts("ERROR: ATOMVM_WIFI_SSID environment variable not set")
      IO.puts("Set it before building: export ATOMVM_WIFI_SSID=\"your-ssid\"")
      {:error, :missing_ssid}
    else
      IO.puts("WiFi: Connecting to #{@wifi_ssid}...")
      start_network()
    end
  end

  defp start_network do
    parent = self()

    sta_config =
      [
        ssid: @wifi_ssid,
        connected: fn -> handle_connected(parent) end,
        disconnected: fn -> handle_disconnected(parent) end,
        got_ip: fn ip_info -> handle_got_ip(parent, ip_info) end
      ]
      |> maybe_add_psk(@wifi_psk)

    network_config = [sta: sta_config]

    case :network.start(network_config) do
      {:ok, _pid} ->
        IO.puts("WiFi: Network driver started")
        wait_for_ip(@max_wait_cycles)

      # On a reconnect attempt the driver is already running; just wait for IP.
      {:error, {:already_started, _pid}} ->
        wait_for_ip(@max_wait_cycles)

      {:error, reason} ->
        IO.puts("WiFi: Failed to start network driver: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp maybe_add_psk(config, nil), do: config
  defp maybe_add_psk(config, ""), do: config
  defp maybe_add_psk(config, psk), do: Keyword.put(config, :psk, psk)

  defp wait_for_ip(0) do
    IO.puts("WiFi: Gave up waiting for IP address")
    {:error, :timeout}
  end

  defp wait_for_ip(cycles) do
    receive do
      {:wifi_connected} ->
        IO.puts("WiFi: Connected to AP")
        # Got association — reset patience while we wait for DHCP.
        wait_for_ip(@max_wait_cycles)

      {:wifi_disconnected} ->
        IO.puts("WiFi: Disconnected from AP, waiting for reconnect...")
        wait_for_ip(cycles)

      {:wifi_got_ip, ip_info} ->
        IO.puts("WiFi: Got IP #{inspect(ip_info)}")
        {:ok, ip_info}
    after
      @connect_timeout ->
        IO.puts("WiFi: still waiting for IP (#{cycles - 1} cycles left)...")
        wait_for_ip(cycles - 1)
    end
  end

  defp handle_connected(parent) do
    send(parent, {:wifi_connected})
  end

  defp handle_disconnected(parent) do
    send(parent, {:wifi_disconnected})
  end

  defp handle_got_ip(parent, ip_info) do
    send(parent, {:wifi_got_ip, ip_info})
  end
end
