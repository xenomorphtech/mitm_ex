defmodule DNS.Server2 do
  @root_dns {198, 41, 0, 4}
  @default_dns_port 53

  use GenServer

  def start_link(%{static_names: _, uplink_server: _} = opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def stop(server) do
    GenServer.stop(server)
  end

  def recursive_lookup(server, domain) do
    GenServer.call(server, {:recursive_lookup, domain})
  end

  @impl true
  def init(opts) do
    {:ok, udp_server} = :gen_udp.open(2053, active: true, mode: :binary)

    state = Map.merge(opts, %{udp_server: udp_server, callees: %{}})
    {:ok, state}
  end

  @impl true
  def handle_call({:recursive_lookup, domain}, from, %{udp_server: udp_server} = state) do
    query =
      domain
      |> DNS.Packet.new_query()

    binary =
      query
      |> DNS.Packet.to_binary()

    :ok = :gen_udp.send(udp_server, {@root_dns, @default_dns_port}, binary)

    {:noreply, put_in(state.callees[query.header.id], %{from: from, query: query})}
  end

  @impl true
  def handle_info(
        {:udp, udp_server, host, port, request},
        %{udp_server: udp_server, static_names: static_names} = state
      ) do
    # IO.inspect(request, limit: 99999)

    dec = DNS.Packet.parse(request)
    IO.inspect({:request, dec.questions})

    query = Enum.find(dec.questions, &(&1.type == :A))

    name =
      case query do
        %{name: name} ->
          name

        _ ->
          nil
      end

    map = hardcoded = Map.get(static_names, name)

    IO.puts("dns request: #{name}")

    if !hardcoded do
      spawn(DNS.TCPWorker, :init, [
        request,
        {host, port},
        %{host: state.uplink_server, uplinks: state[:proxy]},
        self()
      ])
    else
      packet = DNS.Packet.to_binary(make_reply(dec.header.id, name, hardcoded))
      IO.puts("sending crafted response")

      :gen_udp.send(
        udp_server,
        {host, port},
        packet
      )
    end

    {:noreply, state}
  end

  def make_reply(id, domain, addr) do
    %DNS.Packet{
      additionals: [],
      answers: [
        %{
          addr: addr,
          domain: domain,
          ttl: 153,
          type: :A
        }
      ],
      authorities: [],
      header: %DNS.Packet.Header{
        additional_count: 0,
        answer_count: 1,
        authoritative_answer: false,
        authority_count: 0,
        id: id,
        operation_code: 0,
        query_response: true,
        question_count: 1,
        recursion_available: true,
        recursion_desired: true,
        reserved: 0,
        response_code: 0,
        truncated_message: false
      },
      questions: [%DNS.Packet.Question{name: domain, type: :A}]
    }
  end

  @impl true
  def handle_info(
        {:udp, udp_server, _, @default_dns_port, response},
        %{udp_server: udp_server} = state
      ) do
    response = DNS.Packet.parse(response)

    {callee, new_state} = pop_in(state.callees[response.header.id])

    if response.header.answer_count > 0 do
      GenServer.reply(callee.from, {:ok, response})

      {:noreply, new_state}
    else
      [%{host: next_dns_server_domain} | _] = response.authorities

      %{addr: next_dns_server_ip} =
        response.additionals
        |> Enum.find(&match?(%{domain: ^next_dns_server_domain, type: :A}, &1))

      :ok =
        :gen_udp.send(
          udp_server,
          {next_dns_server_ip, @default_dns_port},
          DNS.Packet.to_binary(callee.query)
        )

      {:noreply, put_in(new_state.callees[response.header.id], callee)}
    end
  end

  @impl true
  def handle_info(
        {:reply, dest, response},
        %{udp_server: udp_server} = state
      ) do
    :ok =
      :gen_udp.send(
        udp_server,
        dest,
        response
      )

    {:noreply, state}
  end
end

defmodule DNS.TCPWorker do
  def init(request, response_dest, connection = %{host: host}, parent) do
    # if proxy connect/handshake here....

    {:ok, tcp_socket} =
      Mitme.Gsm.tcp_connect({host, 53}, connection[:uplinks], connection[:source_ip])

    :inet.setopts(tcp_socket, [{:nodelay, true}, {:active, false}, :binary, {:packet, 2}])
    :ok = :gen_tcp.send(tcp_socket, request)
    {:ok, response} = :gen_tcp.recv(tcp_socket, 0)
    # IO.inspect(response, limit: 9999)

    send(parent, {:reply, response_dest, response})
    :gen_tcp.close(tcp_socket)
  end
end
