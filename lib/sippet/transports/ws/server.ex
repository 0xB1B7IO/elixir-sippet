defmodule Sippet.Transports.WS.Server do
  require Logger

  alias Sippet.{Router,Message}
  alias Sippet.Transports.{SessionCache, Utils}
  @moduledoc """
  a WIP websockets server side handler for sippet
  """

  def init(state) do
    {:ok, state}
  end

  @keepalive <<13, 10, 13, 10>>
  def handle_in({@keepalive, _}, state), do: {:noreply, state}
  @exit_code <<255, 244, 255, 253, 6>>
  def handle_in({@exit_code, _}, state), do: {:close, state}
  #TODO: handle tls cases

  def handle_in({data, [opcode: _any]}, state) do

    peer = state[:peer]

    with {:ok, msg} <- Message.parse(data),
      {:ok, instance_id} <- Utils.get_instance_id(msg) do

      SessionCache.handle_connection(state[:session_cache], instance_id, self())

      Router.handle_transport_message(state[:sippet], data, {state[:scheme], peer.address, peer.port})

    else
      error ->
        Logger.warning("could not parse data in websocket handler #{inspect(error)}")

        {:close, state}
    end
  end

  def handle_info({:send_message, msg = %Message{}}, state) do
    io_msg = Message.to_iodata(msg)

    {:push, {:text, io_msg}, state}
  end

  def terminate(_any, state) do
    {:ok, state}
  end

end
