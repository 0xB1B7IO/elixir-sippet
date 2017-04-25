defmodule Sippet.Transactions.Server do
  alias Sippet.Message, as: Message
  alias Sippet.Message.RequestLine, as: RequestLine
  alias Sippet.Message.StatusLine, as: StatusLine
  alias Sippet.Transactions.Server.State, as: State

  @doc false
  @spec receive_request(GenServer.server, Message.request) :: :ok
  def receive_request(server, %Message{start_line: %RequestLine{}} = request),
    do: GenStateMachine.cast(server, {:incoming_request, request})

  @doc false
  @spec send_response(GenServer.server, Message.response) :: :ok
  def send_response(server, %Message{start_line: %StatusLine{}} = response),
    do: GenStateMachine.cast(server, {:outgoing_response, response})

  @doc false
  @spec receive_error(GenServer.server, reason :: term) :: :ok
  def receive_error(server, reason),
    do: GenStateMachine.cast(server, {:error, reason})

  defmacro __using__(opts) do
    quote location: :keep do
      use GenStateMachine, callback_mode: [:state_functions, :state_enter]

      alias Sippet.Transactions.Server.State, as: State

      require Logger

      def init(%State{key: key} = data) do
        Logger.info(fn -> "server transaction #{key} started" end)
        initial_state = unquote(opts)[:initial_state]
        {:ok, initial_state, data}
      end

      defp send_response(response, %State{key: key} = data) do
        extras = data.extras |> Map.put(:last_response, response)
        data = %{data | extras: extras}
        Sippet.Transports.send_message(response, key)
        data
      end

      defp receive_request(request, %State{key: key}),
        do: Sippet.Core.receive_request(request, key)

      def shutdown(reason, %State{key: key} = data) do
        Logger.warn(fn -> "server transaction #{key} shutdown: #{reason}" end)
        Sippet.Core.receive_error(reason, key)
        {:stop, :shutdown, data}
      end

      def timeout(data),
        do: shutdown(:timeout, data)

      defdelegate reliable?(request), to: Sippet.Transports

      def unhandled_event(event_type, event_content,
          %State{key: key} = data) do
            Logger.error(fn -> "server transaction #{key} got " <>
                               "unhandled_event/3: #{inspect event_type}, " <>
                               "#{inspect event_content}, #{inspect data}" end)
        {:stop, :shutdown, data}
      end
    end
  end
end
