defmodule Sippet.Transports.DialogCache do

  @moduledoc """
    a cache for sippet socket handlers to announce and reserve session details
  """

  def init(name),
    do: :ets.new(name, [:set, :public, {:write_concurrency, true}])

  def key(key) when is_binary(key),
    do: key

  def key(ip, port) when is_tuple(ip),
    do: :erlang.term_to_binary({ip, port})

  def handle_connection(table, key, handler) when is_binary(key),
    do: :ets.insert(table, {key, handler})

  def handle_connection(table, ip, port, handler),
    do: :ets.insert(table, {key(ip, port), handler})

  def handle_disconnection(table, address, port),
    do: handle_disconnection(table, key(address, port))

  def handle_disconnection(table, key) when is_binary(key),
    do: :ets.delete(table, key)

  def lookup(table, key),
    do: :ets.lookup(table, key)

  def lookup(table, host, port),
    do: :ets.lookup(table, key(host, port))

  def teardown(table), do: :ets.delete(table)
end
