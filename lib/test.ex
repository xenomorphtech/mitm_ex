defmodule TestRouter do
  def route(source, dest, dest_port) do
    res =
      case {source, dest, dest_port} do
        {_, dest, 443} ->

          rdest =
            case dest do
              "1.2.3.4" ->
                "openapi-zinny3.game.kakao.com"

              "1.2.3.5" ->
                "session-zinny3.game.kakao.com"
            end


          IO.inspect({"dest", rdest})
          %{
            real_dest: rdest,
            module: Raw,
            type: :ssl,
            uplink: [
              {"127.0.0.1", 9081}
            ]
          }

        _ ->
          %{module: Raw, uplink: {"127.0.0.1", 9081}}
      end

    IO.inspect({:route, source, dest, dest_port, res}, pretty: false)

    res
  end

  def test(specs \\ [%{port: 31332, router: TestRouter, type: :ssl}]) do
    {:ok, _} = Mitme.Acceptor.Supervisor.start_link(specs)
  end
end
