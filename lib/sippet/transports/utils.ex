defmodule Sippet.Transports.Utils do

  # todo: test behavior for host-family disagreement
  def resolve_name(host, family) do
    host
    |> String.to_charlist()
    |> :inet.getaddr(family)
  end

  def stringify_sockname(socket) do
    {:ok, {ip, port}} = :inet.sockname(socket)

    address =
      ip
      |> :inet_parse.ntoa()
      |> to_string()

    "#{address}:#{port}"
  end

  def stringify_hostport(host, port) do
    "#{host}:#{port}"
  end

  # rfc7118 clients must transmit this field to ID websocket SIP elements sessions
  def get_instance_id(msg) do
    with [{_cid, _, instance_data}] <- Sippet.Message.get_header(msg, :contact),
      raw_instance_id <- Map.get(instance_data, "+sip.instance"),
      raw_instance_id <- String.trim_leading(raw_instance_id, "<"),
      instance_id <- String.trim_trailing(raw_instance_id, ">") do
        {:ok, instance_id}
    else
      error ->
        {:error, error}
    end
  end

end
