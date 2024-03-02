defmodule Sippet.Transports.TCP do
  @moduledoc """
    Implements a TCP transport server via ThousandIsland
  """

  require Logger
  use GenServer

  alias Sippet.{
    Message,
    Transports,
    Transports.Utils,
    Transports.SessionCache
  }

  @spec start_link(keyword()) :: :ignore | {:error, any()} | {:ok, pid()}
  def start_link(options) do
    sippet =
      case Keyword.fetch(options, :name) do
        {:ok, sippet} when is_atom(sippet) ->
          sippet

        {:ok, other} ->
          raise ArgumentError, "expected :sippet to be an atom, got: #{inspect(other)}"

        :error ->
          raise ArgumentError, "expected :sippet option to be present"
      end

    {address, family} =
      Keyword.get(options, :address, {"0.0.0.0", :inet})
      |> case do
        {address, family} when family in [:inet, :inet6] and is_binary(address) ->
          {address, family}

        {address, :inet} when is_binary(address) ->
          {address, :inet}

        other ->
          raise ArgumentError,
                "expected :address to be an address or {address, family} tuple, got: " <>
                  "#{inspect(other)}"
        end

    scheme =
      Keyword.get(options, :scheme, :tcp)
      |> case do
          :tcp -> :tcp
          :tls -> :tls
          _ -> raise ArgumentError, "#{inspect(__MODULE__)} only supports :tcp and :tls schemes"
        end

    ip =
      case Utils.resolve_name(address, family) do
        {:ok, ip} -> ip
        {:error, reason} ->
          raise ArgumentError, ":address contains invalid IP or DNS name: #{inspect(reason)}"
      end

    port = Keyword.get(options, :port, 5060)
    port_range = Keyword.get(options, :port_range, 10_000..20_000)
    handler_module = Keyword.get(options, :handler_module, Transports.TCP.Server)

    session_cache = Sippet.Transports.SessionCache.init(options[:sippet])

    {transport_module, transport_options} =
      case scheme do
        :tls ->
          raise "unimplemented"
        :tcp ->
          transport_options =
          Keyword.take(options, [:ip])
          |> then(&(Keyword.get(options, :transport_options, []) ++ &1))
        {ThousandIsland.Transports.TCP, transport_options}
      end

    handler_options = [
      sippet: sippet,
      session_cache: session_cache,
      ephemeral: true
    ]

    thousand_island_options =
      Keyword.get(options, :thousand_island_options, [])
      |> Keyword.put(:port, port)
      |> Keyword.put(:transport_module, transport_module)
      |> Keyword.put(:transport_options, transport_options)
      |> Keyword.put(:handler_module, handler_module)
      |> Keyword.put(:handler_options, handler_options)

    client_options = [
      sippet: sippet,
      session_cache: session_cache,
      port_range: port_range,
    ]

    options = [
      name: "#{scheme}://#{sippet}@#{address}:#{port}",
      sippet: sippet,
      scheme: scheme,
      ip: ip,
      port: port,
      family: family,
      session_cache: session_cache,
      client_options: client_options,
      thousand_island_options: thousand_island_options
    ]

    GenServer.start_link(__MODULE__, options)
  end

  @doc """
  Starts the TCP transport.
  """
  @impl true
  def init(state) do
    Sippet.register_transport(state[:sippet], :tcp, true)

    {:ok, nil, {:continue, state}}
  end

  @impl true
  def handle_continue(state, nil) do
    case ThousandIsland.start_link(state[:thousand_island_options]) do
      {:ok, pid} ->
        Logger.debug("started TCP transport: #{state[:name]}")

        {:noreply, Keyword.put_new(state, :socket, pid)}

      {:error, reason} ->
        Logger.error(state[:name] <>
          "#{inspect(reason)}, retrying in 10s..."
        )

        Process.sleep(10_000)

        {:noreply, nil, {:continue, state}}
    end
  end

  @impl true
  def handle_call(
        {:send_message, %Message{} = message,
         peer_host, peer_port, key},
        _from,
        state
      ) do
    with {:ok, peer_ip} <- Utils.resolve_name(peer_host, state[:family]) do
      case SessionCache.lookup(state[:session_cache], peer_ip, peer_port) do
        [{_id, handler}] ->
          # found handler, relay message
          send(handler, {:send_message, message})

        [] ->
          Logger.warning("no #{state[:scheme]} handler for #{peer_ip}:#{peer_port}")

          if key != nil do
            Sippet.Router.receive_transport_error(state[:sippet], key, :no_handler)
          end
      end

    end

    {:reply, :ok, state}
  end

  @impl true
  def terminate(reason, state) do
    SessionCache.teardown(state[:session_cache])

    Process.exit(self(), reason)
  end

  @spec close(
          atom() | pid() | {atom(), any()} | {:via, atom(), any()},
          :infinity | non_neg_integer()
        ) :: :ok
  def close(pid, timeout \\ 15000), do: ThousandIsland.stop(pid, timeout)



end
