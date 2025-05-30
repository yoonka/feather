defmodule AdaptersTest do
  use ExUnit.Case
  doctest Adapters

  test "greets the world" do
    assert Adapters.hello() == :world
  end
end
