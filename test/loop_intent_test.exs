defmodule AutoNuke.LoopIntentTest do
  use ExUnit.Case, async: false

  alias AutoNuke.LoopIntent

  test "records and reports intent" do
    start_supervised!(LoopIntent)

    assert LoopIntent.intents() == %{}
    assert :ok = LoopIntent.set_active(1)
    assert :ok = LoopIntent.set_stopped(3)
    assert LoopIntent.intents() == %{1 => :active, 3 => :stopped}

    # Intent is overwritten, not accumulated:
    assert :ok = LoopIntent.set_active(3)
    assert LoopIntent.intents() == %{1 => :active, 3 => :active}
  end

  test "tolerates not running at all" do
    assert LoopIntent.set_active(1) == {:error, :not_running}
    assert LoopIntent.intents() == %{}
  end
end
