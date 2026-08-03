defmodule AutoNuke.LogFormatterTest do
  use ExUnit.Case, async: true

  alias AutoNuke.LogFormatter

  defp event(msg) do
    %{level: :error, msg: msg, meta: %{time: 1_700_000_000_000_000}}
  end

  defp format(msg) do
    msg |> event() |> LogFormatter.format(nil) |> IO.iodata_to_binary()
  end

  test "formats plain string messages" do
    assert format({:string, "hello"}) =~ "[error] hello"
  end

  test "formats reports — this is the shape crash reports arrive in" do
    line = format({:report, %{reason: :badarg, pid: :some_pid}})

    assert line =~ "[error]"
    assert line =~ "badarg"
  end

  test "formats format/args messages" do
    assert format({~c"~ts failed", ["pump"]}) =~ "pump failed"
  end

  test "survives messages that aren't printable at all" do
    line = format({:string, [%{not: "chardata"}]})

    assert line =~ "[error]"
    refute line == ""
  end

  test "never raises, whatever it is given" do
    for msg <- [
          {:report, [improper: :list]},
          {:report, "not a report"},
          {~c"~p", []},
          :bare_atom,
          {:string, [1_114_112]}
        ] do
      assert is_binary(format(msg))
    end
  end
end
