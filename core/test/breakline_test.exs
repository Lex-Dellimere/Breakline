defmodule BreaklineTest do
  use ExUnit.Case, async: true

  @tzdb Breakline.time_zone_database()

  test "bundled tzdata knows sydney skips 02:00-03:00 on 2026-10-04" do
    assert {:gap, _before, _after} =
             DateTime.new(~D[2026-10-04], ~T[02:30:00], "Australia/Sydney", @tzdb)
  end

  test "bundled tzdata knows brisbane has no dst" do
    assert {:ok, dt} = DateTime.new(~D[2026-10-04], ~T[02:30:00], "Australia/Brisbane", @tzdb)
    assert dt.utc_offset + dt.std_offset == 10 * 3600
  end
end
