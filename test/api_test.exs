defmodule AutoNuke.APITest do
  use ExUnit.Case, async: false

  alias AutoNuke.API
  alias AutoNuke.Test.MockAPI

  describe "get_float/1" do
    test "parses a float with a decimal point" do
      MockAPI.mock_get("TEST_FLOAT", "166.2")
      assert API.get_float("TEST_FLOAT") == 166.2
    end

    test "parses a bare integer" do
      MockAPI.mock_get("TEST_FLOAT", "166")
      assert API.get_float("TEST_FLOAT") == 166.0
    end

    test "parses a float with a decimal comma" do
      MockAPI.mock_get("TEST_FLOAT", "166,2")
      assert API.get_float("TEST_FLOAT") == 166.2
    end
  end
end
