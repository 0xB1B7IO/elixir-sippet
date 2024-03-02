defmodule Sippet.Transports.WS do

  alias Sippet.{
    Message,
    Message.RequestLine,
    Message.StatusLine,
    Transports.Utils,
    Transports.SessionCache
  }

  @moduledoc """
    This Module implements an RFC7118 transport Sippet using Bandit and
    WebsockAdapter Bandit as a configurable HTTP/WS server.
    _______________________________________

    Alice    (SIP WSS)    proxy.example.com
    |                            |
    | HTTP GET (WS handshake) F1 |
    |--------------------------->|
    | 101 Switching Protocols F2 |
    |<---------------------------|
    |                            |
    | REGISTER F3                |
    |--------------------------->|
    | 200 OK F4                  |
    |<---------------------------|
    |                            |
    _______________________________________

    WS implementation notes:

    o A Client MUST be ready to be challenged with an HTTP 401 challenge [RFC2617]
      by the Server, a Server SHOULD be able to challenge a given client
      during the handshake

    o A Client MAY attempt to use TLS on the HTTP leg or the SIP leg of a
      session, the exact TLS behavior MAY vary accordingly

    o A Client MUST be ready to add an RFC6265 derived session cookie when
      it connects to a server on the same FQDN as the WS server

    o A Client MUST specify "Sec-WebSocket-Protocol: sip" in it's request headers
      A Server MUST require the usage said header

    o A Server MUST be ready to read session cookies when present in the
      handshake and be prepped to detect if it came from a client navigating
      from the same FQDN as the server

    o A Server MAY decide not to add a "received" parameter to the top-most
      Via header.

    o A Client MAY not have the ability to discover the its local ip address or port
      when making a websocket connection, Servers MUST route responses to the
      socket address that initiated the session.

  """

  use GenServer
  require Logger

  def start_link(options) do
    name = # name for sippet stack
      Keyword.get(options, :name, nil)
      |> case do
          name when is_atom(name) -> name
          nil -> raise ArgumentError, "must provide a sippet name"
          _ -> raise ArgumentError, "sippet names must be atoms"
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
      Keyword.get(options, :scheme, :ws)
      |> case do
          :ws -> :ws
          :wss -> :wss
          _ -> raise ArgumentError, "#{inspect(__MODULE__)} only supports :ws and :wss schemes"
        end

    ip =
      case Utils.resolve_name(address, family) do
        {:ok, ip} -> ip
        {:error, reason} ->
          raise ArgumentError, ":address contains invalid IP or DNS name: #{inspect(reason)}"
      end

    port = Keyword.get(options, :port, 80)

    socket_addr = "#{scheme}://#{address}:#{port}"

    session_cache = SessionCache.init(options[:name])

    plug =
      Keyword.get(options, :plug,
      {
        Sippet.Transports.WS.Plug,
        [
          sippet: options[:name],
          scheme: scheme,
          session_cache: session_cache]
      })

    client_options = [
        sippet: name,
        scheme: scheme,
        ip: ip,
        port_range: Keyword.get(options, :port_range, 0),
        session_cache: session_cache
      ]

    bandit_options =[
        scheme: Keyword.get(options, :bandit_scheme, :http),
        ip: ip,
        port: port,
        plug: plug
      ]

    options =
      [
        sippet: name,
        scheme: scheme,
        ip: ip,
        address: address,
        port: port,
        family: family,
        socket_addr: socket_addr,
        session_cache: session_cache,
        bandit_options: bandit_options,
        client_options: client_options
      ]

    GenServer.start_link(__MODULE__, options)
  end

  @impl true
  def init(state) do
    Sippet.register_transport(state[:sippet], :ws, true)

    {:ok, nil, {:continue, state}}
  end

  @impl true
  def handle_continue(state, nil) do
    case Bandit.start_link(state[:bandit_options]) do
      {:ok, _pid} ->
        Logger.info(
          "Running sippet #{state[:sippet]} on " <>
          "#{state[:scheme]}://#{state[:address]}:#{state[:port]}"
        )

        {:noreply, state}
      _ = reason ->

        Logger.error(
          "#{state[:scheme]}://#{state[:ip]}:#{state[:port]}" <>
            "#{inspect(reason)}, retrying in 10s..."
        )

        Process.sleep(10_000)

        {:noreply, nil, {:continue, state}}
    end
  end

  @impl true
  def handle_call(
        {:send_message, %Message{start_line: %StatusLine{}} = response,
         _peer_host, _peer_port, _key},
        _from,
        state
      ) do
        instance_id = Utils.get_instance_id(response)
    case SessionCache.lookup(state[:session_cache], instance_id) do
      [{_instance_id, handler}] ->
        send(handler, {:send_message, response})

        {:reply, :ok, state}

      [] ->
        {:reply, {:error, :no_handler}, state}
    end
  end

  @impl true
  def handle_call(
        {:send_message, %Message{start_line: %RequestLine{}} = request,
        peer_host, peer_port, _key},
        _from,
        state
      ) do
    with {:ok, peer_ip} <- Utils.resolve_name(peer_host, state[:family]) do
      case SessionCache.lookup(state[:session_cache], peer_ip, peer_port) do
        [{_call_id, handler}] ->
          send(handler, {:send_message, request})
          {:reply, :ok, state}
        [] ->
          # TODO: connect to remote WS server)
          {:reply, {:error, :no_handler}, state}
      end
    else
      {:error, reason} ->
        Logger.warning("Socket error: #{state[:scheme]}://#{state[:ip]}:#{state[:port]} #{inspect(reason)}")
    end
  end

  def close(pid) do
    Process.exit(pid, :shutdown)

    :ok
  end

end
