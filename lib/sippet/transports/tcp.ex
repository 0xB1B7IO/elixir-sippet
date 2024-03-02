defmodule Sippet.Transports.TCP do
  @moduledoc """
  Implements a TCP transport via ThousandIsland
  Connections will persist unless you override the handlers yourself.
  Connections are also reused for subsequent requests sent to and from the client.
  """

  require Logger
  use GenServer

  alias Sippet.{
    Message,
    Message.RequestLine,
    Message.StatusLine,
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

    scheme = Keyword.get(options, :scheme, :sip)
    family = Keyword.get(options, :family, :inet)
    ip =
      Keyword.get(options, :ip, {0,0,0,0})
      |> case do
        ip when is_tuple(ip) ->
          ip
        ip when is_binary(ip) ->
          Utils.resolve_name(ip, family)
        end
    port = Keyword.get(options, :port, 5060)
    port_range = Keyword.get(options, :port_range, 10_000..20_000)
    handler_module = Keyword.get(options, :handler_module, Transports.TCP.Server)

    session_cache = Sippet.Transports.SessionCache.init(options[:sippet])

    {transport_module, transport_options} =
      case scheme do
        :sips ->
          raise "unimplemented"
        :sip ->
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
        Logger.debug("started TCP transport: #{inspect(self())}")
        {:noreply, Keyword.put_new(state, :socket, pid)}

      {:error, reason} ->
        Logger.error(
          "tcp://#{state[:address]}:#{state[:port]} " <>
            "#{inspect(reason)}, retrying in 10s..."
        )

        Process.sleep(10_000)

        {:noreply, nil, {:continue, state}}
    end
  end

  @impl true
  def handle_call(
        {:send_message, %Message{start_line: %StatusLine{}} = response,
         host, port, _key},
        _from,
        state
      ) do
    with {:ok, peer_ip} <- Utils.resolve_name(host, state[:family]) do
      case SessionCache.lookup(state[:session_cache], peer_ip, port) do
        [{_key, handler}] ->
          # found handler, relay message
          send(handler, {:send_message, response})
          # reply :ok to the caller
          {:reply, :ok, state}

        [] ->
          {:reply, {:error, :no_handler}, state}
      end
    end
  end

  @impl true
  def handle_call(
        {:send_message, %Message{start_line: %RequestLine{}} = request,
        host, port, _key},
        _from,
        state
      ) do
    with {:ok, peer_ip} <- Utils.resolve_name(host, state[:family]) do
      case SessionCache.lookup(state[:connections], peer_ip, port) do
        [{_key, handler}] ->
          send(handler, {:send_message, request})
          {:reply, :ok, state}

        [] ->
          :ok # TODO: connect to remote TCP server
      end
    else
      {:error, reason} ->
        Logger.warning("Socket error:  tcp://#{state[:address]}:#{state[:port]}: #{inspect(reason)}")
    end
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
