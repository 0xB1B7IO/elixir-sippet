defmodule Sippet.Transports.TCP.Client do
  require Logger
  # states:
  #   - init
  #   - connection attempts
  #   - connected
  # callbacks:
  #   - register connection
  #   - received message
  #   - sending message
  # options:
  #   - TLS CA
  #   - scheme
  #   - port

  #def start_link() do
  #end

  #@impl true
  #def init(args) do
  #end

  #@impl true
  #def handle_continue() do
  #end

  #@impl true
  #def handle_call() do
  #end

  #@impl true
  #def terminate() do
  #end

  #def close() do
  #end

  def connection_id(ip, port) when is_tuple(ip), do: :erlang.term_to_binary({ip, port})

  def clean_up_connection(connection_cache, connection_id) do
    try do
      {:ok, :ets.delete(connection_cache, connection_id)}
    rescue
      reason ->
        {:error, reason} # table was already deleted
    end
    :ok
  end

end
