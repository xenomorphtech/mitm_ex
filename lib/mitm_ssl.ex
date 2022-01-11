defmodule Mitm.Ssl do
  def start_link(port \\ 443) do
    pid =
      spawn_link(fn ->
        :ssl.start()

        {:ok, listenSocket} =
          :ssl.listen(port, [
            {:certfile, 'private/cert.pem'},
            {:keyfile, 'private/key.pem'},
            {:active, false},
            {:reuseaddr, true}
          ])

        loop(listenSocket)
      end)

    {:ok, pid}
  end

  def loop(listenSocket) do
    {:ok, socket} = :ssl.transport_accept(listenSocket)

    pid =
      spawn(fn ->
        socket =
          receive do
            {:socket, socket} ->
              socket
          end

        __MODULE__.new_worker(socket)
      end)

    :ssl.controlling_process(socket, pid)
    send(pid, {:socket, socket})

    __MODULE__.loop(listenSocket)
  end

  def new_worker(socket) do
    IO.puts("new connection")
    :timer.sleep(1000)
    # , [cookie: false, verify: :verify_none]
    :ssl.setopts(socket, [{:active, false}, :binary])
    {:ok, socket} = :ssl.handshake(socket, [{:active, false}])
    :ssl.setopts(socket, [{:active, true}, :binary])

    loop(%{
      source: socket
      #      dest: socket1
    })
  end

  def loop(state) do
    receive do
      x ->
        IO.inspect(x)
    after
      500 ->
        nil
    end

    __MODULE__.loop(state)
  end
end

defmodule GatewayClient do
  def newsession(remote_host, session_id) do
    :ssl.start()

    remote_host =
      if is_binary(remote_host) do
        :binary.bin_to_list(remote_host)
      else
        remote_host
      end

    IO.inspect("connecting to gw #{remote_host}")

    {:ok, socket} = :ssl.connect(remote_host, 443, [])
    :ssl.setopts(socket, [{:active, false}, :binary])
    key = "123"

    IO.inspect("connected")

    :ssl.send(
      socket,
      <<"newsession#", byte_size(key)::32-little, key::binary, session_id::64-little>>
    )

    {:ok, res = <<"ok#", port_num::32-little>>} = :ssl.recv(socket, 0)
    IO.inspect(port_num)
    :ssl.close(socket)

    {:ok, port_num}
  end
end
