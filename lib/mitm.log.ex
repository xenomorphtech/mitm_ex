defmodule Mitm.Log do
  def open(path) do
    ets = :ets.new(:table, [:ordered_set])
    counter = :atomics.new(1, [])
    counter_send = :atomics.new(1, [])
    counter_recv = :atomics.new(1, [])
    counter_raw = :atomics.new(1, [])
    counter_send_raw = :atomics.new(1, [])
    counter_recv_raw = :atomics.new(1, [])
    binding() |> Enum.into(%{})
  end

  def save(log) do
    :ok = File.mkdir_p!(Path.dirname(log.path))
    :ets.tab2file(log.ets, '#{log.path}')
  end

  def log_send_raw(log, bin) do
    packet_idx = :atomics.add_get(log.counter_raw, 1, 1)
    packet_idx_side = :atomics.add_get(log.counter_send_raw, 1, 1)
    :ets.insert(log.ets, {{:raw, packet_idx}, :send, packet_idx_side, :os.system_time(1000), bin})
  end

  def log_recv_raw(log, bin) do
    packet_idx = :atomics.add_get(log.counter_raw, 1, 1)
    packet_idx_side = :atomics.add_get(log.counter_recv_raw, 1, 1)
    :ets.insert(log.ets, {{:raw, packet_idx}, :recv, packet_idx_side, :os.system_time(1000), bin})
  end

  def log_send(_log, []), do: nil

  def log_send(log, [pkt | pkts]) do
    log_send(log, pkt)
    log_send(log, pkts)
  end

  def log_send(log, pkt) do
    packet_idx = :atomics.add_get(log.counter, 1, 1)
    packet_idx_side = :atomics.add_get(log.counter_send, 1, 1)

    :ets.insert(
      log.ets,
      {{:parsed, packet_idx}, :send, packet_idx_side, :os.system_time(1000), pkt}
    )
  end

  def log_recv(_log, []), do: nil

  def log_recv(log, [pkt | pkts]) do
    log_recv(log, pkt)
    log_recv(log, pkts)
  end

  def log_recv(log, pkt) do
    packet_idx = :atomics.add_get(log.counter, 1, 1)
    packet_idx_side = :atomics.add_get(log.counter_recv, 1, 1)

    :ets.insert(
      log.ets,
      {{:parsed, packet_idx}, :recv, packet_idx_side, :os.system_time(1000), pkt}
    )
  end

  def read(path, type \\ :parsed)

  def read(path, :parsed) do
    {:ok, ets} = :ets.file2tab('#{path}')

    :ets.tab2list(ets)
    |> Enum.map(fn
      {{:parsed, _b}, c, _d, e, f} ->
        time = String.slice("#{DateTime.from_unix!(e, :millisecond)}", 0..-2)
        Map.merge(f, %{_time: time, _timestamp: e, _side: c})

      _ ->
        nil
    end)
    |> Enum.filter(& &1)
  end

  def read(path, :raw) do
    {:ok, ets} = :ets.file2tab('#{path}')

    :ets.tab2list(ets)
    |> Enum.map(fn
      {{:raw, b}, c, d, e, f} -> {b, c, d, e, f}
      _ -> nil
    end)
    |> Enum.filter(& &1)
  end
end
