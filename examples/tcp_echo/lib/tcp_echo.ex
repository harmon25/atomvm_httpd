defmodule TcpEcho do
  @moduledoc """
  ESP32 entry point: connect to WiFi, start a `:tcp_server` running the echo
  protocol, and report the listening address on serial.
  """

  @port 8080
  @wifi_retries 10

  def start do
    IO.puts("TcpEcho starting...")

    case connect_wifi(@wifi_retries) do
      {:ok, ip_info} ->
        ip = format_ip(extract_ip(ip_info))
        IO.puts("TCP Echo starting on #{ip}:#{@port}")

        {:ok, _pid} =
          :tcp_server.start_link(
            %{port: @port},
            %{chunk_size: 4096},
            TcpEcho.EchoProtocol,
            %{}
          )

        IO.puts("TCP Echo ready at #{ip}:#{@port}")
        IO.puts("Run: ./scripts/test.sh #{ip}")
        Process.sleep(:infinity)

      {:error, reason} ->
        # AtomVM has no erlang:halt/1; just idle so the device stays inspectable.
        IO.puts("ERROR: WiFi failed after #{@wifi_retries} attempts: #{inspect(reason)}")
        Process.sleep(:infinity)
    end
  end

  defp connect_wifi(0), do: {:error, :max_retries}

  defp connect_wifi(attempts_left) do
    case TcpEcho.WiFi.connect() do
      {:ok, ip_info} ->
        {:ok, ip_info}

      {:error, reason} ->
        IO.puts(
          "WiFi: attempt failed (#{inspect(reason)}); retrying (#{attempts_left - 1} left)..."
        )

        Process.sleep(2_000)
        connect_wifi(attempts_left - 1)
    end
  end

  defp extract_ip({ip, _netmask, _gateway}), do: ip
  defp extract_ip(ip), do: ip

  defp format_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"
  defp format_ip(ip), do: inspect(ip)
end
