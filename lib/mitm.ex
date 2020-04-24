defmodule Mitm do
  def start(_, _) do
    # to be removed
    :ssl.start()

    :ets.new(:routing_table, [:public, :named_table, :ordered_set])

    opts = [
      strategy: :one_for_one,
      name: Mitm.Supervisor,
      max_seconds: 1,
      max_restarts: 999_999_999_999
    ]

    Supervisor.start_link([], opts)
  end
end
