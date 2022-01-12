defmodule RaiseHTPPS do
  use GenServer

  # a ramdom module i like to use for a simple hack, when u change https: to http: in a url

  def init(_) do
    {:ok, %{}}
  end

  def connect_addr(address, _port) do
    IO.puts("RaiseHTTPS changing adress")
    {address, 443}
  end

  def on_connect(socket) do
    {:ok, sslsocket} = :ssl.connect(socket, [])

    :ssl.setopts(sslsocket, [{:active, true}])
    IO.inspect({RaiseHTPPS, :on_connect, sslsocket})

    sslsocket
  end

  def on_close(_socket, state) do
    state
  end

  def proc_packet(side, p, state) do
    %{sm: _sm, dest: servs, source: clients} = state

    if !side do
      p = String.replace(p, "Host: somehost:4043", "Host: somehost")

      IO.puts("sending encrypted stuff")
      sslsend = :ssl.send(servs, p)
      IO.inspect({:sslsend, sslsend})
    else
      IO.puts("sending plain text")
      :gen_tcp.send(clients, p)
    end

    nil
  end
end
