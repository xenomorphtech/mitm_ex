defmodule Transparent.Acceptor do
  def start_link(args) do
    pid = :erlang.spawn_link(__MODULE__, :loop, [args])
    :erlang.register(__MODULE__, pid)
    {:ok, pid}
  end

  def loop(s = %{port: port}) do
    IO.inspect({__MODULE__, :started})
    Process.sleep(500)
    IO.puts("listen on port: #{port}, uplink: #{inspect(s[:uplink])}")

    {:ok, listenSocket} =
      :gen_tcp.listen(port, [
        {:ip, {0, 0, 0, 0}},
        {:active, false},
        {:reuseaddr, true},
        {:nodelay, true},
        :binary
      ])

    {:ok, _} = :prim_inet.async_accept(listenSocket, -1)

    s = Map.put(s, :listen_socket, listenSocket)
    loop_1(s)
  end

  def loop_1(s) do
    receive do
      {:inet_async, listenSocket, _, {:ok, clientSocket}} ->
        IO.inspect("accepted client")
        :prim_inet.async_accept(listenSocket, -1)
        pid = :erlang.spawn(s.module, :loop, [s])
        :inet_db.register_socket(clientSocket, :inet_tcp)
        :gen_tcp.controlling_process(clientSocket, pid)
        send(pid, {:pass_socket, clientSocket})
        loop_1(s)

      ukn ->
        throw({:unknown_accept_msg, ukn})
    end
  end
end
