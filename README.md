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

HexDump traffic on port 3000  
Transparently pass through without logging every other port  

```
defmodule MyProxy do
    def route(source, dest, dest_port) do
        IO.inspect {:route, source, dest, dest_port}

          case {source, dest, dest_port} do
            {_, _, 3000} -> %{module: Mitm.Hexdump, uplink: nil}
            _ -> %{module: Raw, uplink: nil}
          end
    end
end

Mitme.Acceptor.Supervisor.start_link [
    %{port: 31330, router: MyProxy},
    %{port: 31331, router: CollectorProxy, listener_type: :sock5}
]

```

## Hexdump helper

```
Hexdump.parse """
00000000  00 00 06 00 01 00 03 00  04 00 0e 00 00 00 00 00  ................
00000010  00 07 01 08 01 00 28 00  00 00 24 00 00 00 ed 90  ......(... ....3
"""
= {
    "000006000100030004000e00000000000007010801002800000024000000ed90",
    "<<0, 0, 6, 0, 1, 0, 3, 0, 4, 0, 14, 0, 0, 0, 0, 0, 0, 7, 1, 8, 1, 0, 40, 0, 0, 0, 36, 0, 0, 0, 237, 144>>"
}
```