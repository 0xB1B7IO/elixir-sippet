defmodule Sippet.Transports.TCP.Server do
  use ThousandIsland.Handler

  alias ThousandIsland.{Socket}
  alias Sippet.{Router, Message, Transports.TCP}

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

  @impl ThousandIsland.Handler
  def handle_data({<<22::8, 3::8, minor::8, _::binary>>, _}, _socket, state)
      when minor in [1,3], do: {:close, state}

  @keep_alive <<13, 10, 13, 10>>
  @impl ThousandIsland.Handler
  def handle_data({@keep_alive, _}, _socket, state), do: {:continue, state}

  @exit_code <<255, 244, 255, 253, 6>>
  @impl ThousandIsland.Handler
  def handle_data({@exit_code, _}, _socket, state), do: {:close, state}

  @impl ThousandIsland.Handler
  def handle_data(data, _socket, state) do
    {peer_host, peer_port} = state[:peer]

    Router.handle_transport_message(
      state[:sippet],
      data,
      {state[:scheme], peer_host, peer_port}
    )

    {:continue, state}
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

  @impl GenServer
  def handle_info({:EXIT, _pid, :normal}, {socket, state}),
    do: {:noreply, {socket, state}, socket.read_timeout}

  @impl ThousandIsland.Handler
  def handle_error(reason, _socket, state) do
    Logger.error("#{inspect(self())}|#{inspect(reason)}")
    {:continue, state}
  end

  @impl ThousandIsland.Handler
  def handle_timeout(_socket, state), do: {:close, state}

  @impl ThousandIsland.Handler
  def handle_close(_socket, state) do
    connection_id = state[:connection_id]

    :ets.delete(state[:connection_cache], connection_id)

    Logger.debug("Peer Disconnection on #{inspect(state[:name])}: #{inspect(state[:peer])}")

    {:shutdown, state}
  end

end
