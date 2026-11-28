defmodule Zaq.Test.SmtpCapture do
  @moduledoc false

  def child_spec(opts), do: %{id: make_ref(), start: {__MODULE__, :start_link, [opts]}}

  def start_link(opts) do
    Task.start_link(fn ->
      {:ok, listener} = :gen_tcp.listen(0, [:binary, packet: :line, active: false])
      {:ok, {_, port}} = :inet.sockname(listener)
      send(opts[:owner], {:smtp_listening, self(), port})
      accept(listener, opts)
    end)
  end

  defp accept(listener, opts) do
    {:ok, socket} = :gen_tcp.accept(listener)
    send(opts[:owner], :smtp_connection)
    :ok = :gen_tcp.send(socket, "220 capture.local ESMTP\r\n")
    session(socket, opts)
    :gen_tcp.close(socket)
    accept(listener, opts)
  end

  defp session(socket, opts) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, "DATA\r\n"} ->
        :ok = :gen_tcp.send(socket, "354 End with dot\r\n")
        send(opts[:owner], {:smtp_data, read_data(socket, [])})

        case opts[:response] do
          :close ->
            :ok

          response ->
            :ok = :gen_tcp.send(socket, response || "250 accepted\r\n")
            session(socket, opts)
        end

      {:ok, "QUIT\r\n"} ->
        :gen_tcp.send(socket, "221 bye\r\n")

      {:ok, command} ->
        send(opts[:owner], {:smtp_command, command})
        :ok = :gen_tcp.send(socket, "250 capture.local\r\n")
        session(socket, opts)

      {:error, :closed} ->
        :ok
    end
  end

  defp read_data(socket, lines) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, ".\r\n"} -> lines |> Enum.reverse() |> IO.iodata_to_binary()
      {:ok, line} -> read_data(socket, [line | lines])
    end
  end
end
