defmodule Sippet.Transports.TCP.Server do
  use ThousandIsland.Handler

  alias ThousandIsland.{Socket}
  alias Sippet.{
    Router,
    Message,
    Transports.TCP,
    Transports.TCP.Buffer
  }

  require Logger

  @impl ThousandIsland.Handler
  def handle_connection(socket, state) do
    {:ok, {peer_ip, peer_port} = peer} = Socket.peername(socket)

    connection_id = TCP.connection_id(peer_ip, peer_port)

    :ets.insert(state[:connection_cache], {connection_id, self()})

    state =
      state
      |> Keyword.put(:peer, peer)
      |> Keyword.put(:connection_id, connection_id)

    {:continue, state}
  end

  # todo: let implementor choose keepalive behavior
  @impl ThousandIsland.Handler
  def handle_data("\r\n\r\n", _socket, state), do: {:continue, state}

  @impl ThousandIsland.Handler
  def handle_data(<<255,244,255,253,6>>, _socket, state), do: {:close, state}

  @impl ThousandIsland.Handler
  def handle_data(buffer, socket, state) do
    {ip, port} = state[:peer]
    from = {state[:protocol], ip, port}

    case Buffer.handle_buffer(buffer, socket, state[:max_size], state[:timeout]) do
      {:ok, io_msg} ->
        Router.handle_transport_message(state[:sippet], io_msg, from)
        {:continue, state}
      {:error, :missing_content_length} ->
        Logger.warning("dropping packet, reason: :missing_content_length")
        {:close, state}
      {:error, :timeout} ->
        {:close, state}
      {:error, :closed} ->
        {:close, state}
      {:error, _} = error ->
        Logger.warning(inspect(error))
        {:close, state}
    end
  end

  @impl GenServer
  def handle_info({:send_message, msg}, {socket, state}) do
    io_msg = Message.to_iodata(msg)

    with :ok <- ThousandIsland.Socket.send(socket, io_msg) do
      {:noreply, {socket, state}}
    else
      err ->
        Logger.warning("#{inspect(err)}")
        {:noreply, {socket, state}}
    end
  end

  @impl ThousandIsland.Handler
  def handle_error(reason, _socket, state) do
    Logger.warning("error: #{inspect(reason)}")
    {:close, state}
  end

  @impl ThousandIsland.Handler
  def handle_timeout(_socket, state),
    do: {:close, state}

  @impl ThousandIsland.Handler
  def handle_close(_socket, state) do
    TCP.clean_up_connection(state[:connection_cache],state[:connection_id])
    {:shutdown, state}
  end



end
