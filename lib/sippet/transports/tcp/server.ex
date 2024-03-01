defmodule Sippet.Transports.TCP.Server do
  use ThousandIsland.Handler

  alias ThousandIsland.{Socket}
  alias Sippet.{Message, Transports.DialogCache}

  require Logger

  @impl ThousandIsland.Handler
  def handle_connection(socket, state) do
    if is_tls?(socket) do
      Logger.warning("TLS client hello received on a plain text TCP transport")
      {:close, state}
    else
      {:ok, {host, port} = peer} = Socket.peername(socket)

        DialogCache.handle_connection(state[:dialog_cache], host, port, self())

        state =
          state
          |> Keyword.put(:peer, peer)

        {:continue, state}
    end
  end

  @exit_code <<255, 244, 255, 253, 6>>
  @impl ThousandIsland.Handler
  def handle_data(@exit_code, _socket, state), do: {:close, state}

  @impl ThousandIsland.Handler
  def handle_data(data, _socket, state) do
    {host, port} = state[:peer]

    Sippet.Router.handle_transport_message(
      state[:sippet],
      data,
      {:tcp, host, port}
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
  def handle_info({:plug_conn, :sent}, {socket, state}),
    do: {:noreply, {socket, state}, socket.read_timeout}

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
    {address, port} = state[:peer]

    DialogCache.handle_disconnection(state[:dialog_cache], address, port)

    Logger.info("Peer Disconnection: #{inspect(state[:peer])}")

    {:shutdown, state}
  end

  def is_tls?(socket) do
    case ThousandIsland.Socket.recv(socket, 24) do
      {:ok, <<22::8, 3::8, minor::8, _::binary>>} when minor in [1, 3] -> true
      _ -> false
    end
  end

  def stringify_hostport(host, port) when is_tuple(host), do: "#{host |> :inet.ntoa() |> to_string()}:#{port}"

end
