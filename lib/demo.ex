defmodule Sippet.Demo do
  alias Sippet.{
    Message,
    Message.RequestLine
  }

  require Logger

  use Sippet.Core

  @stack_name :demo_1

  def start_link() do
    with {:ok, _pid} <- Sippet.start_link(name: @stack_name),
        {:ok, _pid} <- Sippet.Transports.WS.start_link(name: @stack_name, port: 80)
        do
          Sippet.register_core(@stack_name, Sippet.Demo)
        end
  end

  def receive_request(%Message{start_line: %RequestLine{method: :register}} = request, _server_key) do

    Logger.debug(to_string(request))

    response =
      Sippet.Message.to_response(request, 200)

    Logger.debug(to_string(response))

    Sippet.send(@stack_name, response)

  end

  def receive_request(%Message{start_line: %RequestLine{method: _method}} = request, _server_key) do

    response =
      Sippet.Message.to_response(request, 501) # not implemented

    Sippet.send(@stack_name, response)

  end


  def receive_response(_response, _client_key), do: :ok
  def receive_error(_reason, _key), do: :ok

end
