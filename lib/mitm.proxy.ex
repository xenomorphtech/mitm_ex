defmodule Mitme.Acceptor.Supervisor do
  use Supervisor

  def start_link(args) do
    Supervisor.start_link(__MODULE__, args, name: __MODULE__)
  end

  def init(args) do
    IO.inspect(args)
    :ssl.start()

    :ets.new(:mitme_cache, [:public, :named_table, :ordered_set])

    children =
      Enum.map(args, fn x ->
        worker(Mitme.Acceptor, [x], id: x[:port])
      end)

    IO.inspect(children)

    supervise(children, strategy: :one_for_one)
  end
end

defmodule Mitme.Acceptor do
  use GenServer

  def start_link(%{port: port} = args) do
    GenServer.start(__MODULE__, args, [])
  end

  def init(%{port: port} = args) do
    type = Map.get(args, :type, nil)
    uplink = Map.get(args, :uplink, nil)
    module = Map.get(args, :module, Raw)
    router = Map.get(args, :router, Crash)
    listener_type = Map.get(args, :listener_type, :nat)

    params = %{
      type: type,
      uplink: uplink,
      module: module,
      router: router,
      listener_type: listener_type
    }

    IO.puts("listen on port #{port} #{type} #{inspect(uplink)}")

    {:ok, listenSocket} =
      :gen_tcp.listen(port, [
        {:ip, {0, 0, 0, 0}},
        {:active, false},
        {:reuseaddr, true},
        {:nodelay, true}
      ])

    {:ok, _} = :prim_inet.async_accept(listenSocket, -1)

    {:ok, %{listen_socket: listenSocket, clients: [], params: params}}
  end

  def handle_info(
        {:inet_async, listenSocket, _, {:ok, clientSocket}},
        state = %{params: %{type: type} = params}
      ) do
    :prim_inet.async_accept(listenSocket, -1)
    {:ok, pid} = Mitme.Gsm.start(params)
    :inet_db.register_socket(clientSocket, :inet_tcp)
    :gen_tcp.controlling_process(clientSocket, pid)

    send(pid, {:pass_socket, clientSocket})

    Process.monitor(pid)

    {:noreply, %{state | clients: [pid | state.clients]}}
  end

  def handle_info({:inet_async, _listenSocket, _, error}, state) do
    IO.puts(
      "#{inspect(__MODULE__)}: Error in inet_async accept, shutting down. #{inspect(error)}"
    )

    {:stop, error, state}
  end

  def handle_info(_, state) do
    {:noreply, state}
  end

  def handle_call(:get_clients, _from, state) do
    {:reply, state.clients, state}
  end
end

defmodule Mitme.Gsm do
  use GenServer

  def start(type) do
    GenServer.start(__MODULE__, type, [])
  end

  def init(params) do
    IO.puts("starting gsm: #{inspect(params)}")
    {:ok, params}
  end

  def handle_info({:tcp_closed, _}, state) do
    IO.puts("connection closed (close)")
    %{dest: servs, source: clients} = state
    :gen_tcp.close(servs)
    :gen_tcp.close(clients)

    module = state[:module]

    if module do
      module.on_close(nil, state)
    end

    {:stop, {:shutdown, :tcp_closed}, state}
  end

  def handle_info({:tcp_error, _, _err}, state) do
    %{dest: servs, source: clients} = state
    :gen_tcp.close(servs)
    :gen_tcp.close(clients)
    IO.puts("connection closed (error)")

    module = state[:module]

    if module do
      module.on_close(state)
    end

    {:stop, {:shutdown, :tcp_error}, state}
  end

  # {:sslsocket, {:gen_tcp, port, :tls_connection, :undefined}, [#PID<0.180.0>, #PID<0.179.0>]}
  def handle_info({:ssl, _, bin}, flow = %{mode: :raw, module: module}) do
    %{sm: _sm, dest: servs, source: clients} = flow

    # a subtle guess atm
    socket = servs
    IO.inspect({servs, clients})

    flow =
      case module.proc_packet(socket == servs, bin, flow) do
        {:send, bin, flow} ->
          case socket do
            ^servs ->
              :gen_tcp.send(clients, bin)

            ^clients ->
              :gen_tcp.send(servs, bin)
          end

          flow

        nflow ->
          nflow
      end

    {:noreply, flow}
  end

  def handle_info({:tcp, socket, bin}, flow = %{mode: :raw, module: module}) do
    # proc bin

    %{sm: _sm, dest: servs, source: clients} = flow

    flow =
      case module.proc_packet(socket == servs, bin, flow) do
        {:send, bin, nflow} ->
          case socket do
            ^servs ->
              :gen_tcp.send(clients, bin)

            ^clients ->
              :gen_tcp.send(servs, bin)
          end

          nflow

        nflow ->
          nflow
      end

    {:noreply, flow}
  end

  # test mode
  def handle_info({:pass_socket, clientSocket}, state) do
    {:ok, {sourceAddr, sourcePort}} = :inet.peername(clientSocket)
    sourceAddrBin = :inet_parse.ntoa(sourceAddr)

    IO.inspect({:pass_socket, state})

    {destAddrBin, destPort} =
      case state.listener_type do
        :nat ->
          get_original_destionation(clientSocket)

        :sock5 ->
          sock5_handshake(clientSocket)
      end

    IO.inspect({:dest, destAddrBin, destPort})

    :ok = :inet.setopts(clientSocket, [{:active, true}, :binary])

    router = state[:router]
    state = Map.merge(state, router.route(sourceAddr, destAddrBin, destPort))
    module = state.module

    # IO.pstate[:uplink]uts "uplink? #{inspect state[:uplink]}"
    uplinks =
      case state[:uplink] do
        {_, _} = a -> [a]
        a -> a
      end

    IO.inspect({:uplinks, uplinks})

    serverSocket =
      case uplinks do
        [first_uplink | next_uplinks] ->
          {s5h, s5p} = first_uplink

          {:ok, serverSocket} =
            :gen_tcp.connect(:binary.bin_to_list(s5h), s5p, [{:active, false}, :binary])

          Enum.each(next_uplinks, fn {destAddrBin, destPort} ->
            IO.inspect({:connecting_next_uplink, {destAddrBin, destPort}})
            :gen_tcp.send(serverSocket, <<5, 1, 0>>)
            {:ok, <<5, 0>>} = :gen_tcp.recv(serverSocket, 0)

            len = byte_size(destAddrBin)

            :gen_tcp.send(
              serverSocket,
              <<5, 1, 0, 3, len, destAddrBin::binary, destPort::integer-size(16)>>
            )

            {:ok, realsocketreply} = :gen_tcp.recv(serverSocket, 10)

            if <<5, 0, 0, 1, 0, 0, 0, 0, 0, 0>> != realsocketreply do
              IO.inspect({"discarted reply from real sock server:", realsocketreply})
            end
          end)

          IO.inspect({:connecting_final_target, {destAddrBin, destPort}})

          :gen_tcp.send(serverSocket, <<5, 1, 0>>)
          {:ok, <<5, 0>>} = :gen_tcp.recv(serverSocket, 0)

          {destAddrBin, destPort} = module.connect_addr(destAddrBin, destPort)
          Process.put(:dest_addr, destAddrBin)
          Process.put(:dest_port, destPort)

          # IO.inspect "connecting via proxy to #{inspect {a,b,c,d}}:#{destPort}"

          len = byte_size(destAddrBin)

          :gen_tcp.send(
            serverSocket,
            <<5, 1, 0, 3, len, destAddrBin::binary, destPort::integer-size(16)>>
          )

          {:ok, realsocketreply} = :gen_tcp.recv(serverSocket, 10)

          if <<5, 0, 0, 1, 0, 0, 0, 0, 0, 0>> != realsocketreply do
            IO.inspect({"discarted reply from real sock server:", realsocketreply})
          end

          # :inet.setopts(serverSocket, [{:active, :true}, :binary])

          serverSocket

        nil ->
          Process.put(:dest_addr, destAddrBin)
          Process.put(:dest_port, destPort)

          {:ok, serverSocket} =
            :gen_tcp.connect(to_charlist(destAddrBin), destPort, [{:active, false}, :binary])

          serverSocket
      end

    case state.listener_type do
      :sock5 ->
        sock5_notify_connected(clientSocket)

      _ ->
        nil
    end

    flow = %{
      module: module,
      mode: :raw,
      sm: %{},
      dest: serverSocket,
      source: clientSocket,
      dest_addr: Process.get(:dest_addr),
      dest_port: Process.get(:dest_port)
    }

    flow = module.on_connect(flow)

    {:noreply, flow}
  end

  # sock5 implementation
  def sock5_handshake(clientSocket) do
    {:ok, [5, 1, 0]} = :gen_tcp.recv(clientSocket, 3)

    :gen_tcp.send(clientSocket, <<5, 0>>)

    {:ok, moredata} = :gen_tcp.recv(clientSocket, 0)

    {destAddr, destPort, _ver, _moredata} =
      case :binary.list_to_bin(moredata) do
        <<5, v, 0, 3, len, addr::binary-size(len), port::integer-size(16)>> ->
          {addr, port, v, <<5, 1, 0, 3, len, addr::binary-size(len), port::integer-size(16)>>}

        <<5, v, 0, 1, a, b, c, d, port::integer-size(16)>> ->
          addr = :unicode.characters_to_binary(:inet_parse.ntoa({a, b, c, d}))

          {addr, port, v, <<5, 1, 0, 1, a, b, c, d, port::integer-size(16)>>}
      end

    {destAddr, destPort}
  end

  def sock5_notify_connected(clientSocket) do
    # custom version, for fast hooks
    :gen_tcp.send(clientSocket, <<5, 0, 0, 1, 0, 0, 0, 0, 0, 0>>)
  end

  def get_original_destionation(clientSocket) do
    # get SO_origdestination
    {:ok, [{:raw, 0, 80, info}]} = :inet.getopts(clientSocket, [{:raw, 0, 80, 16}])

    <<_::integer-size(16), destPort::big-integer-size(16), a::integer-size(8), b::integer-size(8),
      c::integer-size(8), d::integer-size(8), _::binary>> = info

    destAddr = {a, b, c, d}
    destAddrBin = :unicode.characters_to_binary(:inet_parse.ntoa(destAddr))
    {destAddrBin, destPort}
  end

  def handle_info(anything, flow = %{module: module}) do
    module.handle_info(anything, flow)
  end
end
