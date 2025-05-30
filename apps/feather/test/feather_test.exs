defmodule FeatherTest do
  use ExUnit.Case
  doctest Feather

  test "greets the world" do
    assert Feather.hello() == :world
  end
end
