defmodule Sippet.Transports.WS.Server do
  require Logger

  alias Sippet.{Transports.DialogCache}
  alias Sippet.{Message}

  def init(state) do
    ## TODO: set timeout on inbound data

    {:ok, state}
  end

  @keepalive <<13, 10, 13, 10>>
  def handle_in({@keepalive, _}, state), do: {:noreply, state}
  @exit_code <<255, 244, 255, 253, 6>>
  def handle_in({@exit_code, _}, state), do: {:close, state}

  def handle_in({data, [opcode: _any]}, state) do
    peer = state[:peer]

    with {:ok, msg} <- Sippet.Message.parse(data) do
      call_id = Message.get_header(msg, :call_id)

      DialogCache.handle_connection(state[:dialog_cache], call_id, self())

      Sippet.Router.handle_transport_message(state[:sippet], data, {state[:scheme], peer.address, peer.port})
    else
      err ->
        Logger.warning(inspect(err))
    end

    {:ok, state}
  end

  def handle_info({:send_message, msg}, state) do
    io_msg = Sippet.Message.to_iodata(msg)

    {:push, {:text, io_msg}, state}
  end

  def terminate(_any, state) do
    {:ok, state}
  end

end
