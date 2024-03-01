defmodule Sippet.Transports.WS.Plug do
  require Logger
  require Plug

  ## TODO: Add configuration for requiring TLS
  ## TODO: Test implementors using their own Plugs

  def init(options) do
    options
  end

  def call(%{request_path: "/", method: "GET"} = conn, options),
    do: authorize(conn, options)

  def call(conn,_),
    do: Plug.Conn.send_resp(conn, 404, "Not Found")

  def authorize(conn, options) do
    with _parsed_creds <- Plug.BasicAuth.parse_basic_auth(conn) do
      upgrade(conn, options)
    else
      _ ->
        Plug.Conn.send_resp(conn, 401, "Unauthorized")
    end
  end

  def upgrade(conn, options) do
    if Plug.Conn.get_req_header(conn, "sec-websocket-protocol") == ["sip"] do
      conn = Plug.Conn.put_resp_header(conn, "sec-websocket-protocol", "sip")

      WebSockAdapter.upgrade(
        conn,
        Sippet.Transports.WS.Server,
        Keyword.put(options, :peer, Plug.Conn.get_peer_data(conn)),
        timeout: 60_000,
        validate_utf8: true
      )
    else
      Plug.Conn.send_resp(conn, 418, "I'm a teapot")
    end
  end
end
