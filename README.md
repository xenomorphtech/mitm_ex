# mitm

**TODO: Add description**

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `mitm` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [{:mitm, "~> 0.1.0"}]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at [https://hexdocs.pm/mitm](https://hexdocs.pm/mitm).

## use

```
defmodule MyProxy do
    def route(source, dest, dest_port) do
        IO.inspect {:route, source, dest, dest_port}

          case {source, dest, dest_port} do
            _ -> %{module: Raw, uplink: nil}
          end
    end
end

Mitme.Acceptor.Supervisor.start_link [
    %{port: 31330, router: MyProxy},
    %{port: 31331, router: CollectorProxy, listener_type: :sock5}
]

```
