defmodule Sippet.Transports.TCP do
  @moduledoc """
    Implements a TCP transport server via ThousandIsland
  """

  require Logger
  use GenServer

  alias Sippet.{
    Message,
    Transports.Utils
  }

  @spec start_link(keyword()) :: :ignore | {:error, any()} | {:ok, pid()}
  def start_link(options) do
    sippet =
      case Keyword.fetch(options, :name) do
        {:ok, sippet} when is_atom(sippet) ->
          sippet

        {:ok, other} ->
          raise ArgumentError, "expected :sippet to be an atom, got: #{inspect(other)}"

        :error ->
          raise ArgumentError, "expected :sippet option to be present"
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
      Keyword.get(options, :scheme, :tcp)
      |> case do
          :tcp -> :tcp
          :tls -> :tls
          _ -> raise ArgumentError, "#{inspect(__MODULE__)} only supports :tcp and :tls schemes"
        end

    ip =
      case Utils.resolve_name(address, family) do
        {:ok, ip} -> ip
        {:error, reason} ->
          raise ArgumentError, ":address contains invalid IP or DNS name: #{inspect(reason)}"
      end

    port =
      Keyword.get(options, :port, 5060)

    name =
      :"#{scheme}://#{sippet}@#{address}:#{port}"

    handler_module =
      Keyword.get(options, :handler_module, Sippet.Transports.TCP.Server)

    connection_cache =
      :ets.new(name, [
        :named_table,
        :set,
        :public,
        read_concurrency: true,
        write_concurrency: true
      ])

    handler_options = [
      sippet: sippet,
      name: name,
      scheme: scheme,
      connection_cache: connection_cache,
      ephemeral: true
    ]

    client_options = [
      sippet: sippet,
      connection_cache: connection_cache,
      port_range: Keyword.get(options, :port_range, 10_000..20_000),
    ]

    {transport_module, transport_options} =
      case scheme do
        :tls ->
          raise "unimplemented"
        :tcp ->
          {ThousandIsland.Transports.TCP, [ip: ip]}
      end

    thousand_island_options =
      Keyword.get(options, :thousand_island_options, [])
      |> Keyword.put(:port, port)
      |> Keyword.put(:transport_module, transport_module)
      |> Keyword.put(:transport_options, transport_options)
      |> Keyword.put(:handler_module, handler_module)
      |> Keyword.put(:handler_options, handler_options)

    options = [
      name: name,
      sippet: sippet,
      scheme: scheme,
      ip: ip,
      port: port,
      family: family,
      connection_cache: connection_cache,
      client_options: client_options,
      thousand_island_options: thousand_island_options
    ]

    GenServer.start_link(__MODULE__, options)
  end

  @doc """
  Starts the TCP transport.
  """
  @impl true
  def init(state) do
    Sippet.register_transport(state[:sippet], :tcp, true)

    {:ok, nil, {:continue, state}}
  end

  @impl true
  def handle_continue(state, nil) do
    with {:ok, client_supervisor} <- DynamicSupervisor.start_link(strategy: :one_for_one),
      {:ok, pid} <- ThousandIsland.start_link(state[:thousand_island_options]) do

        state =
          state
          |> Keyword.put_new(:socket, pid)
          |> Keyword.put(:client_supervisor, client_supervisor)

        Logger.debug("started TCP transport: #{state[:name]}")

        {:noreply, state}
    else
      error ->
        Logger.error(state[:name] <> " #{inspect(error)}, retrying in 10s...")

        Process.sleep(10_000)

        {:noreply, nil, {:continue, state}}
    end
  end

  @impl true
  def handle_call(
        {:send_message, %Message{} = message,
         peer_host, peer_port, key},
        _from,
        state
      ) do
    with {:ok, peer_ip} <- Utils.resolve_name(peer_host, state[:family]) do
      case :ets.lookup(state[:connection_cache], connection_id(peer_ip, peer_port)) do
        [{_id, handler}] ->
          # found handler, relay message
          send(handler, {:send_message, message})

        [] ->
          # TODO: connect to upstream server via config option
          Logger.warning("#{state[:scheme]}: no handler for #{inspect(peer_ip)}:#{peer_port}")

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

  @spec close(
          atom() | pid() | {atom(), any()} | {:via, atom(), any()},
          :infinity | non_neg_integer()
        ) :: :ok
  def close(pid, timeout \\ 15000), do: ThousandIsland.stop(pid, timeout)

  def connection_id(ip, port) when is_tuple(ip), do: :erlang.term_to_binary({ip, port})

end
