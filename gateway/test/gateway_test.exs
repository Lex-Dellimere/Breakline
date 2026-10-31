defmodule GatewayTest do
  use ExUnit.Case, async: true

  test "application supervisor is running" do
    assert Process.whereis(Gateway.Supervisor) |> Process.alive?()
  end

  test "core is available as a dependency" do
    assert Breakline.time_zone_database() == Tz.TimeZoneDatabase
  end
end
