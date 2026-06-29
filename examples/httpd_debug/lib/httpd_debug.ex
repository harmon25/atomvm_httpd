defmodule HttpdDebug do
  @moduledoc """
  Debug/test application for atomvm_httpd on ESP32.

  This application demonstrates and stress-tests the HTTP server with:
  - WiFi STA connectivity with DHCP
  - Built-in stats and command handlers
  - Debug API endpoints for testing large requests/responses
  - Static file serving (test dashboard)

  Set WiFi credentials via environment variables before building:
    export ATOMVM_WIFI_SSID="your-ssid"
    export ATOMVM_WIFI_PSK="your-password"
  """

  require Logger

  @chunk_size 4096

  # Delay before retrying after a WiFi/HTTPD startup failure. AtomVM does not
  # implement erlang:halt/1, and halting would end the soak anyway, so instead
  # we loop and retry forever — the device self-heals across AP outages, which
  # is essential for multi-hour/day endurance runs.
  @retry_delay 5_000

  def start do
    IO.puts("HttpdDebug starting...")
    run()
  end

  defp run do
    # Connect to WiFi and wait for IP
    case HttpdDebug.WiFi.connect() do
      {:ok, ip_info} ->
        ip = format_ip(extract_ip(ip_info))
        IO.puts("HTTPD starting on http://#{ip}:80")

        # Start HTTP server with debug configuration
        case start_httpd() do
          {:ok, _pid} ->
            IO.puts("HTTPD ready at http://#{ip}:80")
            IO.puts("Open browser or run: ./scripts/test.sh #{ip}")
            Process.sleep(:infinity)

          {:error, reason} ->
            IO.puts("ERROR: Failed to start HTTPD: #{inspect(reason)}; retrying in 5s")
            Process.sleep(@retry_delay)
            run()
        end

      {:error, reason} ->
        IO.puts("ERROR: WiFi connection failed: #{inspect(reason)}; retrying in 5s")
        Process.sleep(@retry_delay)
        run()
    end
  end

  defp start_httpd do
    port = 80

    socket_options = %{
      chunk_size: @chunk_size
    }

    config = [
      # Stats API at /api/stats/system and /api/stats/memory
      {[<<"api">>, <<"stats">>],
       %{
         handler: :httpd_api_handler,
         handler_config: %{module: :httpd_stats_api_handler}
       }},

      # Command API at /api/cmd/restart
      {[<<"api">>, <<"cmd">>],
       %{
         handler: :httpd_api_handler,
         handler_config: %{module: :httpd_cmd_api_handler}
       }},

      # Debug test endpoints at /api/*
      {[<<"api">>],
       %{
         handler: :httpd_api_handler,
         handler_config: %{module: HttpdDebug.DebugApiHandler}
       }},

      # Static file handler for test dashboard (catch-all)
      {[],
       %{
         handler: :httpd_file_handler,
         handler_config: %{app: :httpd_debug}
       }}
    ]

    :httpd.start_link(:any, port, socket_options, config)
  end

  # AtomVM network driver returns {IP, Netmask, Gateway} tuple
  defp extract_ip({ip, _netmask, _gateway}), do: ip
  defp extract_ip(ip), do: ip

  defp format_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"
  defp format_ip(ip) when is_list(ip), do: to_string(ip)
  defp format_ip(ip), do: inspect(ip)
end
