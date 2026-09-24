defmodule Pie.Test.SSEServer do
  @moduledoc """
  A tiny HTTP/1.1 server on a random port for exercising the real `:httpc`
  streaming path. `handler.(request_body)` returns `{status, parts}`; parts are
  binaries (sent as chunks) or `{:sleep, ms}`.
  """

  def start(handler) do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true, nodelay: true])

    {:ok, port} = :inet.port(listen)
    pid = spawn_link(fn -> accept_loop(listen, handler) end)
    :ok = :gen_tcp.controlling_process(listen, pid)
    "http://127.0.0.1:#{port}"
  end

  def sse(events) do
    Enum.map(events, fn event -> "event: #{event["type"]}\ndata: #{JSON.encode!(event)}\n\n" end)
  end

  defp accept_loop(listen, handler) do
    {:ok, socket} = :gen_tcp.accept(listen)
    body = read_request(socket, "")
    {status, parts} = handler.(body)
    respond(socket, status, parts)
    :gen_tcp.close(socket)
    accept_loop(listen, handler)
  end

  defp read_request(socket, acc) do
    case String.split(acc, "\r\n\r\n", parts: 2) do
      [head, body] ->
        [_, len] = Regex.run(~r/content-length:\s*(\d+)/i, head)
        read_body(socket, body, String.to_integer(len))

      [_] ->
        {:ok, data} = :gen_tcp.recv(socket, 0, 5_000)
        read_request(socket, acc <> data)
    end
  end

  defp read_body(_socket, body, len) when byte_size(body) >= len, do: body

  defp read_body(socket, body, len) do
    {:ok, data} = :gen_tcp.recv(socket, 0, 5_000)
    read_body(socket, body <> data, len)
  end

  defp respond(socket, 200, parts) do
    :gen_tcp.send(
      socket,
      "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\ntransfer-encoding: chunked\r\nconnection: close\r\n\r\n"
    )

    # :httpc does not stream body bytes that arrive in the same read as the
    # headers until more data comes (httpc_handler:handle_http_body/2), so let
    # the headers go out alone to keep timing-sensitive tests deterministic.
    Process.sleep(20)

    Enum.each(parts, fn
      {:sleep, ms} ->
        Process.sleep(ms)

      chunk ->
        :gen_tcp.send(socket, [Integer.to_string(byte_size(chunk), 16), "\r\n", chunk, "\r\n"])
    end)

    :gen_tcp.send(socket, "0\r\n\r\n")
  end

  defp respond(socket, status, [body]) do
    :gen_tcp.send(
      socket,
      "HTTP/1.1 #{status} Error\r\ncontent-type: application/json\r\ncontent-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n#{body}"
    )
  end
end
