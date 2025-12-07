defmodule AtomvmHttpd do
  @moduledoc """
  Elixir wrapper for the AtomVM HTTP server.

  This module provides Elixir-friendly functions for starting and configuring
  the HTTP server, as well as helper functions for creating handler configurations.

  ## Quick Start

      # Start a simple file server
      config = AtomvmHttpd.file_handler_config(:my_app)
      {:ok, server} = AtomvmHttpd.start_link(8080, [{[], config}])

  ## Handler Types

  - `httpd_file_handler` - Serves static files from priv directory
  - `httpd_api_handler` - REST API handler
  - `httpd_ws_handler` - WebSocket handler
  """

  @type port_number :: 0..65535
  @type path :: [binary()]
  @type handler_config :: %{handler: module(), handler_config: map()}
  @type config :: [{path(), handler_config()}]

  @doc """
  Starts an HTTP server linked to the current process.

  ## Parameters

  - `port` - The TCP port to listen on
  - `config` - A list of path/handler configurations

  ## Example

      config = [
        {[<<"api">>], AtomvmHttpd.api_handler_config(MyApiModule)},
        {[], AtomvmHttpd.file_handler_config(:my_app)}
      ]
      {:ok, server} = AtomvmHttpd.start_link(8080, config)
  """
  @spec start_link(port_number(), config()) :: {:ok, pid()} | {:error, term()}
  def start_link(port, config) do
    :httpd.start_link(port, config)
  end

  @doc """
  Starts an HTTP server linked to the current process, binding to a specific address.

  ## Parameters

  - `address` - `:any`, `:loopback`, or an IPv4 tuple like `{192, 168, 1, 1}`
  - `port` - The TCP port to listen on
  - `config` - A list of path/handler configurations
  """
  @spec start_link(:any | :loopback | tuple(), port_number(), config()) ::
          {:ok, pid()} | {:error, term()}
  def start_link(address, port, config) do
    :httpd.start_link(address, port, config)
  end

  @doc """
  Starts an HTTP server (not linked).
  """
  @spec start(port_number(), config()) :: {:ok, pid()} | {:error, term()}
  def start(port, config) do
    :httpd.start(port, config)
  end

  @doc """
  Stops the HTTP server.
  """
  @spec stop(pid()) :: :ok
  def stop(server) do
    :httpd.stop(server)
  end

  @doc """
  Creates a file handler configuration for serving static files.

  ## Parameters

  - `app` - The application atom (from your mix.exs `:app` key).
    **Important:** This must be the application name, NOT an Elixir module name.

  ## Example

      # In mix.exs: def project, do: [app: :my_web_app, ...]
      # Files in priv/ will be served

      config = AtomvmHttpd.file_handler_config(:my_web_app)
      # Serves priv/index.html at /index.html
  """
  @spec file_handler_config(atom()) :: handler_config()
  def file_handler_config(app) when is_atom(app) do
    %{
      handler: :httpd_file_handler,
      handler_config: %{app: app}
    }
  end

  @doc """
  Creates an API handler configuration for REST endpoints.

  ## Parameters

  - `module` - The module implementing the `httpd_api_handler` behaviour
  - `args` - Optional arguments passed to your handler (default: `nil`)

  ## Example

      defmodule MyApi do
        @behaviour :httpd_api_handler

        def handle_api_request(:get, [<<"status">>], _request, _args) do
          {:close, %{status: :ok}}
        end
      end

      config = AtomvmHttpd.api_handler_config(MyApi)
  """
  @spec api_handler_config(module(), term()) :: handler_config()
  def api_handler_config(module, args \\ nil) when is_atom(module) do
    %{
      handler: :httpd_api_handler,
      handler_config: %{module: module, args: args}
    }
  end

  @doc """
  Creates a WebSocket handler configuration.

  ## Parameters

  - `module` - The module implementing the `httpd_ws_handler` behaviour
  - `args` - Optional arguments passed to your handler (default: `nil`)

  ## Example

      defmodule MyWebSocket do
        @behaviour :httpd_ws_handler

        def handle_ws_init(_websocket, _path, _args) do
          {:ok, %{}}
        end

        def handle_ws_message(data, state) do
          {:reply, data, state}  # Echo back
        end
      end

      config = AtomvmHttpd.ws_handler_config(MyWebSocket)
  """
  @spec ws_handler_config(module(), term()) :: handler_config()
  def ws_handler_config(module, args \\ nil) when is_atom(module) do
    %{
      handler: :httpd_ws_handler,
      handler_config: %{module: module, args: args}
    }
  end

  @doc """
  Creates a combined configuration for a typical web application with:
  - API routes under `/api`
  - WebSocket routes under `/ws`
  - Static files for everything else

  ## Parameters

  - `opts` - Keyword list with:
    - `:app` (required) - Application name for static files
    - `:api_module` - Module for API handling (optional)
    - `:api_args` - Args for API handler (optional)
    - `:ws_module` - Module for WebSocket handling (optional)
    - `:ws_args` - Args for WebSocket handler (optional)

  ## Example

      config = AtomvmHttpd.web_app_config(
        app: :my_app,
        api_module: MyApi,
        ws_module: MyWebSocket
      )
      {:ok, server} = AtomvmHttpd.start_link(8080, config)
  """
  @spec web_app_config(keyword()) :: config()
  def web_app_config(opts) do
    app = Keyword.fetch!(opts, :app)

    config = []

    config =
      case Keyword.get(opts, :api_module) do
        nil ->
          config

        api_module ->
          api_args = Keyword.get(opts, :api_args)
          [{[<<"api">>], api_handler_config(api_module, api_args)} | config]
      end

    config =
      case Keyword.get(opts, :ws_module) do
        nil ->
          config

        ws_module ->
          ws_args = Keyword.get(opts, :ws_args)
          [{[<<"ws">>], ws_handler_config(ws_module, ws_args)} | config]
      end

    # File handler should be last (catch-all)
    config ++ [{[], file_handler_config(app)}]
  end
end
