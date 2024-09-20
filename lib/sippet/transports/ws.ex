defmodule Sippet.Transports.WS do
  @moduledoc """
    This Module implements an RFC7118 transport using Bandit,
    Plug, and WebsockAdapter as a configurable HTTP/WS server.

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
    o Clients MUST be ready to be challenged with an HTTP 401 challenge [RFC2617]
      by the Server, a Server SHOULD be able to challenge a given client
      during the handshake.
    o Clients MAY attempt to use TLS on the HTTP leg or the SIP leg of a
      session, the exact TLS behavior MAY vary accordingly.
    o Clients MUST be ready to add an RFC6265 derived session cookie when
      it connects to a server on the same FQDN as the WS server.
    o Clients MUST use "Sec-WebSocket-Protocol: sip" in it's request
      headers, Servers MUST require this.
    o Servers MUST be ready to read session cookies when present in the
      handshake and detect if it came from a client navigating from the
      same FQDN as the WS server.
    o Servers MAY decide not to add a "received" parameter to the top-most
      Via header.
    o Clients MAY not have the ability to discover the its local ip address or port
      when making a websocket connection, Servers MUST route responses to the
      socket address that initiated the session.
  """

  alias Sippet.{Message,Transports.Utils}
  use GenServer
  require Logger

  def start_link(options) do
    sippet = # name for sippet stack
      Keyword.get(options, :name, nil)
      |> case do
          sippet when is_atom(sippet) -> sippet
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

    protocol =
      Keyword.get(options, :protocol, :ws)
      |> case do
          :ws -> :ws
          :wss -> :wss
          _ ->
            raise  ArgumentError
        end

    ip =
      case Utils.resolve_name(address, family) do
        {:ok, ip} -> ip
        {:error, reason} ->
          raise ArgumentError,
                ":address contains invalid IP or DNS name: #{inspect(reason)}"
      end

    port =
      Keyword.get(options, :port, 80)

    port_range =
      Keyword.get(options, :port_range, 10_000..20_000)

    name =
      :"#{protocol}://#{sippet}@#{address}:#{port}"

    connection_cache =
      :ets.new(name, [
          :named_table,
          :set,
          :public,
          read_concurrency: true,
          write_concurrency: true
      ])

    plug =
      Keyword.get(options, :plug, {
        Sippet.Transports.WS.Plug,
        [
          sippet: sippet,
          protocol: protocol,
          ip: ip,
          port_range: Keyword.get(options, :port_range, 0),
          connection_cache: connection_cache
        ]
      })

    options =
      [
        name: name,
        sippet: sippet,
        protocol: protocol,
        ip: ip,
        address: address,
        port: port,
        port_range: port_range,
        family: family,
        connection_cache: connection_cache,
        protocol: Keyword.get(options, :bandit_protocol, :http),
        bandit_options: [
          ip: ip,
          port: port,
          plug: plug
        ]
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
        Logger.debug("started transport: #{state[:name]}")
        {:noreply, state}
      _ = reason ->
        Logger.error(state[:name], "#{inspect(reason)}, retrying...")
        Process.sleep(state[:timeout])
        {:noreply, nil, {:continue, state}}
    end
  end

  @impl true
  def handle_call(
        {:send_message, %Message{} = msg, _, _, key}, _, state
      ) do
    with {:ok, instance_id} <- instance_id(msg) do
      case :ets.lookup(state[:connection_cache], instance_id) do
        [{_instance_id, handler}] ->
          # found handler, relay message
          send(handler, {:send_message, msg})
        [] ->
          # add config option for upstream requests
          Logger.warning("no #{state[:protocol]} handler for #{instance_id}")
          if key != nil do
            Sippet.Router.receive_transport_error(state[:sippet], key, :no_handler)
          end
      end

    end
    {:reply, :ok, state}
  end

  @impl true
  def terminate(reason, state) do
    :ets.delete(state[:connection_cache])

    Process.exit(self(), reason)
  end

  # rfc7118 clients must transmit this field for upstream elements to ID sessions
  def instance_id(msg) do
    with [{_cid, _contact_uri, instance_data}] <- Sippet.Message.get_header(msg, :contact),
         raw_instance_id <- Map.get(instance_data, "+sip.instance") do
      instance_id =
        raw_instance_id
        |> String.trim_leading("<")
        |> String.trim_trailing(">")
      {:ok, instance_id}
    else
      error ->
        {:error, error}
    end
  end
end
