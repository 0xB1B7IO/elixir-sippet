defmodule Sippet.Transports.TCP.Buffer do
  @moduledoc """
  used for delimiting SIP messages for stream (tcp) sources

  RFC3261 18.3
  Content-Length header MUST present over
  stream oriented transports to delimit the message
  """

  require Logger

  @spec read(bitstring(), any(), non_neg_integer(), non_neg_integer()) ::
          {:ok, binary()}
          | {:error, atom()}
          | {:ok, binary(), binary()}
  def read(buffer, socket, max_size, timeout) do
    if byte_size(buffer) >= max_size do
      {:error, :buffer_overload}
    else
      case String.split(buffer, "\r\n\r\n", parts: 2) do
        [_headers, <<>>] -> {:ok, buffer}

        [_raw] -> recv(buffer, socket, max_size, timeout)

        [headers, body] ->
          case get_content_length(headers, body) do
            :done -> {:ok, buffer}

            {:read_body, bytes_to_read} -> recv(buffer, socket, bytes_to_read, timeout)

            {:trim_body, i} ->
              {buffer, remaining} = String.split_at(buffer, i)
              {:ok, buffer, remaining}

            {:error, _} = err -> err
          end

      end
    end
  end

  defp recv(buffer, socket, n_bytes, timeout) do
    case ThousandIsland.Socket.recv(socket, n_bytes, timeout) do
      {:ok, rest} -> {:ok, buffer<>rest}
      {:error, _} = error -> error
    end
  end

  defp get_content_length(headers, body) do
    with [_, untrimmed] <- String.split(headers, "Content-Length: ", include_captures: true),
      [raw | _rest] <- String.split(untrimmed, "\r\n"),
      content_length <- String.to_integer(raw) do

        cond do
          content_length == byte_size(body) ->
            :done
          content_length > byte_size(body) ->
            {:read_body, (content_length - byte_size(body))}
          content_length < byte_size(body) ->
            {:trim_body, content_length + byte_size(headers)}
        end

    else
      _ -> {:error, :missing_content_length}
    end
  end

end
