defmodule DNSCache do
  use GenServer

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  def init(_) do
    :ets.new(:dns_cache, [:set, :protected, :named_table])
    {:ok, %{counter: 1}}
  end

  def handle_call({:resolve, name}, _from, state) do
    case :ets.lookup(:dns_cache, name) do
      [{^name, ip}] ->
        {:reply, ip, state}
      [] ->
        {ip, new_state} = generate_ip(state)
        :ets.insert(:dns_cache, {name, ip})
        {:reply, ip, new_state}
    end
  end

  defp generate_ip(%{counter: counter}) do
    d = rem(counter, 256)
    c = div(counter, 256)
    ip = "10.0.#{c}.#{d}"
    {ip, %{counter: counter+1}}
  end

  def reverse_lookup(ip) do
    case :ets.match_object(:dns_cache, {:_, ip}) do
      [{name, ^ip}] ->
        name 
      [] ->
        nil 
    end
  end
end
