defmodule Raw do
  use GenServer

  def init(_) do
    {:ok, %{}}
  end

  def connect_addr(address, port) do
    {address, port}
  end

  def on_connect(flow = %{dest: socket}) do
    case socket do
      socket when is_port(socket) ->
        :inet.setopts(socket, [{:active, true}, :binary, {:nodelay, true}])

      {:gen_tcp, x} ->
        :inet.setopts(socket, [{:active, true}, :binary, {:nodelay, true}])

      _ ->
        :ssl.setopts(socket, [{:active, true}, :binary, {:nodelay, true}])
    end

    flow
  end

  def on_close(_socket, state) do
    state
  end

  def proc_packet(_side, p, s) do
    {:send, p, s}
  end
end
