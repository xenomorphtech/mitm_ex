defmodule Mitm.Hexdump do
  use GenServer

  def init(_) do
    {:ok, %{}}
  end

  def connect_addr(address, port) do
    {address, port}
  end

  def on_connect(flow = %{dest: socket}) do
    :inet.setopts(socket, [{:active, true}, :binary])
    Map.merge(flow, %{start_time: :os.system_time(1)})
  end

  def on_close(socket, state) do
    state
  end

  # server conn
  def proc_packet(side = true, bin, s) do
    IO.puts("<- #{s.dest_addr} #{s.dest_port}")
    IO.puts(Hexdump.to_string(bin))
    {:send, bin, s}
  end

  # client conn
  def proc_packet(side = false, bin, s) do
    IO.puts("-> #{s.dest_addr} #{s.dest_port}")
    IO.puts(Hexdump.to_string(bin))
    {:send, bin, s}
  end
end
