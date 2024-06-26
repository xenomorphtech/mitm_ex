defmodule Mitme.Acceptor.Supervisor do
  use Supervisor

  def start_link(args) do
    Supervisor.start_link(__MODULE__, args, name: __MODULE__)
  end

  def init(args) do
    IO.inspect(args)
    :ssl.start()

    :ets.new(:mitme_cache, [:public, :named_table, :ordered_set])

    children = [
      worker(
        DynamicSupervisor,
        [[max_restarts: 10000, seconds: 1, strategy: :one_for_one, name: MitmWorkers]],
        id: :workers
      )
      | Enum.map(args, fn x ->
          worker(Mitme.Acceptor, [x], id: x[:port])
        end)
    ]

    IO.inspect(children)

    supervise(children, [strategy: :one_for_one, max_restarts: 10000, seconds: 1])
  end
end

defmodule Mitme.Acceptor do
  use GenServer

  def start_link(%{port: port} = args) do
    GenServer.start_link(__MODULE__, args, [])
  end

  def init(%{port: port} = args) do
    type = Map.get(args, :type, nil)
    uplink = Map.get(args, :uplink, nil)
    module = Map.get(args, :module, Raw)
    router = Map.get(args, :router, Crash)
    listener_type = Map.get(args, :listener_type, :nat)
    source_ip = Map.get(args, :source_ip, nil)

    params = %{
      type: type,
      uplink: uplink,
      module: module,
      router: router,
      listener_type: listener_type,
      source_ip: source_ip
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
    spec = {Mitme.Gsm, params}
    {:ok, pid} = DynamicSupervisor.start_child(MitmWorkers, spec)
    :inet_db.register_socket(clientSocket, :inet_tcp)
    :gen_tcp.controlling_process(clientSocket, pid)

    send(pid, {:pass_socket, clientSocket})

    # Process.monitor(pid)

    {:noreply, state}
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
  use GenServer, restart: :temporary
  import Kernel, except: [send: 2]

  def start_link(type) do
    GenServer.start_link(__MODULE__, type, [])
  end

  def init(params) do
    # IO.puts("starting gsm: #{inspect(params)}")
    {:ok, params}
  end

  def handle_info({:ssl_closed, _} =  s, state) do
    #IO.puts("ssl connection closed (close) #{inspect s} #{inspect state}")
    %{dest: servs, source: clients} = state
    con_close(servs)
    con_close(clients)

    module = state[:module]

    if module do
      module.on_close(nil, state)
    end

    {:stop, {:shutdown, :tcp_closed}, state}
  end

  def handle_info({:tcp_closed, _}, state) do
  
    #IO.puts("connection closed (close)")
    
    %{dest: servs, source: clients} = state
    con_close(servs)
    con_close(clients)

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
    #IO.puts("connection closed (error)")

    module = state[:module]

    if module do
      module.on_close(state)
    end

    {:stop, {:shutdown, :tcp_error}, state}
  end

  # {:sslsocket, {:gen_tcp, port, :tls_connection, :undefined}, [#PID<0.180.0>, #PID<0.179.0>]}
  def handle_info({:ssl, socket, bin}, flow = %{mode: :raw, module: module}) do
    %{sm: _sm, dest: servs, source: clients} = flow

    #    IO.puts("got ssl info")

    side =
      case socket do
        ^servs -> :server
        ^clients -> :client
      end

    flow =
      case module.proc_packet(side, bin, flow) do
        {:send, bin, flow} ->
          case socket do
            ^servs ->
              send(clients, bin)

            ^clients ->
              send(servs, bin)
          end

          flow

        nflow ->
          nflow
      end

    {:noreply, flow}
  end

  def con_close({:sslsocket, _, _} = socket) do
    :ssl.close(socket)
  end

  def con_close({:gen_tcp, _} = socket) do
    :gen_tcp.close(socket)
  end

  def con_close(socket) do
    :gen_tcp.close(socket)
  end

  def send({:sslsocket, _, _} = socket, bin) do
    # IO.inspect({"sending ssl info", socket, bin})
    :ssl.send(socket, bin)
  end

  def send({:gen_tcp, _} = socket, bin) do
    :gen_tcp.send(socket, bin)
  end

  def send(socket, bin) do
    :gen_tcp.send(socket, bin)
  end

  def handle_info({:tcp, socket, bin}, flow = %{mode: :raw, module: module}) do
    # proc bin
    %{sm: _sm, dest: servs, source: clients} = flow

    side =
      case socket do
        ^servs -> :server
        ^clients -> :client
      end

    flow =
      case module.proc_packet(side, bin, flow) do
        {:send, bin, nflow} ->
          case socket do
            ^servs ->
              send(clients, bin)

            ^clients ->
              send(servs, bin)
          end

          nflow

        nflow ->
          nflow
      end

    {:noreply, flow}
  end

  # test mode
  def handle_info({:pass_socket, orig_clientSocket}, state) do
    {:ok, {sourceAddr, sourcePort}} = :inet.peername(orig_clientSocket)
    sourceAddrBin = sourceAddr |> :inet_parse.ntoa() |> :unicode.characters_to_binary()

    source_ip =
      case state[:source_ip] do
        :dynamic ->
          {:ok, {local_ip, _local_port}} = :inet.sockname(orig_clientSocket)
          local_ip

        x ->
          x
      end

    {destAddrBin, destPort, auth} =
      case state.listener_type do
        :nat ->
          {a, b} = get_original_destination(orig_clientSocket, sourceAddrBin)
          {a, b, nil}

        :sock5 ->
          sock5_handshake(orig_clientSocket)
      end

    # for ssl:
    # 1.router
    # 2.sock5_notify
    # 3.do ssl handhsake
    # 4.ssl connect

    # otherwise: revision number 94e51a681175cb7006971d0a70697db2831a328c
    #     IO.inspect({:pass_socket, state})

    router = state[:router]
    state = Map.put(state, :proxy_auth, auth)

    state = Map.merge(state, router.route(state, sourceAddr, destAddrBin, destPort))

    module = state.module

    case state.listener_type do
      :sock5 ->
        sock5_notify_connected(orig_clientSocket)

      _ ->
        nil
    end

    clientSocket =
      case state do
        %{type: :ssl, cert: {cert_file, pem_file}} ->
          # TODO: backwards compatibility, delete
          IO.inspect("doing ssl handhsake with custom certs")

          {:ok, socket} =
            :ssl.handshake(orig_clientSocket, [
              {:active, true},
              {:certfile, cert_file |> :binary.bin_to_list()},
              {:keyfile, pem_file |> :binary.bin_to_list()}
            ])

            IO.inspect "handshake done"

          :ssl.setopts(socket, [{:active, true}, :binary])
          socket

        %{type: :ssl} ->
          # gotta get the sni here
          IO.inspect("doing ssl handhsake")

          {:ok, socket} =
            :ssl.handshake(orig_clientSocket, [
              {:active, true},
              {:certfile, 'private/cert.pem'},
              {:keyfile, 'private/key.pem'}
            ])

          :ssl.setopts(socket, [{:active, true}, :binary])
          socket

        _ ->
          :ok = :inet.setopts(orig_clientSocket, [{:active, true}, :binary, {:nodelay, true}])
          orig_clientSocket
      end

    # IO.inspect({:source_ip, state, source_ip})

    # IO.inspect({:dest, destAddrBin, destPort})

    #  "uplink? #{inspect state[:uplink]}"
    uplinks =
      case state[:uplink] do
        nil -> nil
        a when is_list(a) -> a
        a -> [a]
      end

    # IO.inspect({:uplinks, uplinks})

    #IO.inspect({:real_dest, state[:real_dest], state})

    destAddrBin =
      case state[:real_dest] do
        nil -> destAddrBin
        x -> x
      end

    {destAddrBin, destPort} = module.connect_addr(destAddrBin, destPort)

    {:ok, serverSocket} = tcp_connect({destAddrBin, destPort}, uplinks, source_ip)

    #IO.puts("tcp connected")

    serverSocket =
      if state[:type] == :ssl do
        sni =
          case state[:real_dest] do
            x when is_binary(x) -> :binary.bin_to_list(x)
            x -> x
          end

        IO.inspect("connecting ssl side")

        {:ok, socket} =
          :ssl.connect(serverSocket, [
            {:active, true},
            {:verify, :verify_none},
            {:server_name_indication, sni}
          ])

        :ssl.setopts(socket, [{:active, true}, :binary])
        IO.puts("serverside: ssl connected")
        socket
      else
        serverSocket
      end

    flow = %{
      type: state[:type],
      module: module,
      mode: :raw,
      sm: %{},
      dest: serverSocket,
      source: clientSocket,
      dest_addr: destAddrBin,
      dest_port: destPort,
      proxy_auth: auth
    }

    flow = module.on_connect(flow)

    {:noreply, flow}
  end

  def tcp_connect({destAddrBin, destPort}, uplinks = {_, _}, source_ip) do
    tcp_connect({destAddrBin, destPort}, [uplinks], source_ip)
  end

  def tcp_connect({destAddrBin, destPort}, uplinks, source_ip) do
    serverSocket =
      case uplinks do
        [first_uplink | next_uplinks] ->
          {s5h, s5p} = get_proxy_host_port(first_uplink)
          opts = [{:active, false}, :binary]

          opts =
            if source_ip do
              [{:ip, source_ip} | opts]
            else
              opts
            end

          # IO.inspect(opts)
          {:ok, serverSocket} = :gen_tcp.connect(:binary.bin_to_list(s5h), s5p, opts)

          last_uplink =
            if next_uplinks != [] do
              Enum.reduce(next_uplinks, first_uplink, fn uplink, prev_uplink ->
                # IO.inspect({:connecting_next_uplink, uplink})
                host_port = get_proxy_host_port(uplink)
                :ok = proxy_handshake(serverSocket, prev_uplink, host_port)
                uplink
              end)
            else
              first_uplink
            end

          :ok = proxy_handshake(serverSocket, last_uplink, {destAddrBin, destPort})

          serverSocket

        nil ->
          opts = [{:active, false}, :binary]

          opts =
            if source_ip do
              [{:ip, source_ip} | opts]
            else
              opts
            end

          # IO.inspect(opts)

          {:ok, serverSocket} = :gen_tcp.connect(to_charlist(destAddrBin), destPort, opts)

          serverSocket
      end

    {:ok, serverSocket}
  end

  def get_proxy_host_port({a, b}) do
    {a, b}
  end

  def get_proxy_host_port(%{ip: ip, port: port}) do
    {ip, port}
  end

  def proxy_handshake(serverSocket, %{type: :socks5} = uplink, {destAddrBin, destPort}) do
    # {:ok, serverSocket} =
    #   :gen_tcp.connect('#{uplink.ip}', uplink.port, [{:active, false}, :binary])

    case uplink[:username] do
      nil -> :ok = :gen_tcp.send(serverSocket, <<5, 1, 0>>)
      _ -> :ok = :gen_tcp.send(serverSocket, <<5, 1, 2>>)
    end

    {:ok, <<5, auth_method>>} = :gen_tcp.recv(serverSocket, 2, 30_000)

    # 00000000  05 01 02                                           ...
    #    00000000  05 02                                              ..
    # 00000003  01 06 38 38 38 38 38 38  06 38 38 38 38 38 38      ..888888 .888888
    #    00000002  01 00                                              ..
    # 00000012  05 03 00 01 00 00 00 00  00 00                     ........ ..
    #    00000004  05 00 00 01 0a 00 00 04  d0 2e                     ........ ..

    case auth_method do
      0 ->
        :ok

      2 ->
        :ok =
          :gen_tcp.send(
            serverSocket,
            <<1, byte_size(uplink.username), uplink.username::binary, byte_size(uplink.password),
              uplink.password::binary>>
          )

        {:ok, <<_, 0>>} = :gen_tcp.recv(serverSocket, 2, 60_000)
    end

    # assume IPV4

    len = byte_size(destAddrBin)

    :ok = :gen_tcp.send(serverSocket, <<5, 1, 0, 3, len, destAddrBin::binary, destPort::16>>)
    {:ok, <<5, 0, 0, type>>} = :gen_tcp.recv(serverSocket, 4, 30_000)

    case type do
      # ipv4
      1 ->
        {:ok, _addr_port} = :gen_tcp.recv(serverSocket, 6, 100)

      3 ->
        # domain name
        {:ok, dis} = :gen_tcp.recv(serverSocket, 0, 100)
        #BuffLog.add({:discarded, dis})

      4 ->
        # ipv6
        {:ok, dis} = :gen_tcp.recv(serverSocket, 0, 100)
        #BuffLog.add({:discarded, dis})
    end

    :ok
  end

  def proxy_handshake(serverSocket, {_s5h, _s5p}, {destAddrBin, destPort}) do
    :gen_tcp.send(serverSocket, <<5, 1, 0>>)
    {:ok, <<5, 0>>} = :gen_tcp.recv(serverSocket, 0)

    len = byte_size(destAddrBin)

    :gen_tcp.send(
      serverSocket,
      <<5, 1, 0, 3, len, destAddrBin::binary, destPort::integer-size(16)>>
    )

    {:ok, realsocketreply} = :gen_tcp.recv(serverSocket, 10)

    case realsocketreply do
      <<5, 0, 0, 1, _, _, _, _, _, _>> ->
        nil

      _ ->
        IO.inspect({"discarted reply from real sock server:", realsocketreply})
    end

    :ok
  end

  """
  previous s5 stuff
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
  """

  def proxy_handshake(serverSocket, %{type: :http} = proxy, {destAddrBin, destPort}) do
    socket = serverSocket

    base64 = Base.encode64(<<proxy.username::binary, ":", proxy.password::binary>>)
    proxy_auth = <<"Basic ", base64::binary>>
    # proxy_auth = "Proxy-Authorization" <> proxyAuth

    hostPort = <<destAddrBin::binary, ":", Integer.to_string(destPort)::binary>>
    pConn = <<"keep-alive">>

    proxyRequestBin = [
      "CONNECT ",
      hostPort,
      " HTTP/1.1\r\n",
      "Host: ",
      hostPort,
      "\r\n",
      "Proxy-Authorization: ",
      proxy_auth,
      "\r\n",
      "Proxy-Connection: ",
      pConn,
      "\r\n\r\n"
    ]

    # IO.inspect(proxyRequestBin)

    :gen_tcp.send(socket, proxyRequestBin)

    timeout = 30000

    {ok, 200, headers, replyBody} = :comsat_core_http.get_response(socket, timeout)

    # IO.inspect({headers, replyBody})

    :ok
  end

  # sock5 implementation
  def sock5_handshake(clientSocket) do
    {:ok, [5, count]} = :gen_tcp.recv(clientSocket, 2)
    {:ok, auth_methods} = :gen_tcp.recv(clientSocket, count)

    auth =
      if 2 in auth_methods do
        :gen_tcp.send(clientSocket, <<5, 2>>)
        {:ok, [1, size]} = :gen_tcp.recv(clientSocket, 2)
        {:ok, username} = :gen_tcp.recv(clientSocket, size)
        {:ok, [psize]} = :gen_tcp.recv(clientSocket, 1)
        {:ok, pass} = :gen_tcp.recv(clientSocket, psize)

        :gen_tcp.send(clientSocket, <<1, 0>>)

        {:binary.list_to_bin(username), :binary.list_to_bin(pass)}
      else
        :gen_tcp.send(clientSocket, <<5, 0>>)
        nil
      end

    #IO.inspect(auth)

    {:ok, moredata} = :gen_tcp.recv(clientSocket, 0)

    {destAddr, destPort, _ver, _moredata} =
      case :binary.list_to_bin(moredata) do
        <<5, v, 0, 3, len, addr::binary-size(len), port::integer-size(16)>> ->
          {addr, port, v, <<5, 1, 0, 3, len, addr::binary-size(len), port::integer-size(16)>>}

        <<5, v, 0, 1, a, b, c, d, port::integer-size(16)>> ->
          addr = :unicode.characters_to_binary(:inet_parse.ntoa({a, b, c, d}))

          {addr, port, v, <<5, 1, 0, 1, a, b, c, d, port::integer-size(16)>>}
      end

    {destAddr, destPort, auth}
  end

  def sock5_notify_connected(clientSocket) do
    # custom version, for fast hooks
    :gen_tcp.send(clientSocket, <<5, 0, 0, 1, 0, 0, 0, 0, 0, 0>>)
  end

  def get_original_destination(clientSocket, source) do
    case :inet.getopts(clientSocket, [{:raw, 0, 80, 16}]) do
      {:ok, [{:raw, 0, 80, info}]} ->
        <<_::integer-size(16), destPort::big-integer-size(16), a::integer-size(8),
          b::integer-size(8), c::integer-size(8), d::integer-size(8), _::binary>> = info

        destAddr = {a, b, c, d}
        destAddrBin = :unicode.characters_to_binary(:inet_parse.ntoa(destAddr))
        {destAddrBin, destPort}

      {:ok, []} ->
        res = :binary.list_to_bin(:os.cmd('sudo /sbin/pfctl -s state'))

        [f | _] =
          Enum.filter(String.split(res, "\n"), fn x ->
            String.contains?(x, source)
          end)

        [a, b, c] = String.split(f, " <- ")
        [address, port] = String.split(b, ":")
        a1 = to_charlist(address)
        {p1, _} = :string.to_integer(port)
        {a1, p1}

      {type, options} ->
        raise MatchError, message: {type, options}
    end
  end

  def handle_info(anything, flow = %{module: module}) do
    # IO.inspect({:warning, "discarded_message", anything})
    module.handle_info(anything, flow)
  end
end
