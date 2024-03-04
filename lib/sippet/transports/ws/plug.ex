defmodule Sippet.Transports.WS.Plug do
  require Logger
  require Plug

  ## TODO: Add configuration for requiring TLS

  # include all options passed in by bandit
  def init(options), do: options

  # we do not care about path, more so authentication
  def call(%{method: "GET"} = conn, options),
    do: authorize(conn, options)

  # the caller attempted to use
  def call(conn, options),
      do: no_impl(conn, options)

  def authorize(conn, options) do
    # TODO: configurable authorization in digest, TLS, or both, in HTTP leg or SIP leg
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
        Keyword.put(
          options, :peer, Plug.Conn.get_peer_data(conn)
        ),
        timeout: 60_000,
        validate_utf8: true
      )

    else
      no_impl(conn)
    end
  end

  defp no_impl(conn, _options \\ []),
       do: Plug.Conn.send_resp(conn, 418, "I'm a teapot")
end
