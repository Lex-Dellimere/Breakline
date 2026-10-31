defmodule Gateway.ClockTest do
  # touches application env and a :persistent_term cache
  use ExUnit.Case, async: false

  alias Gateway.Clock.{Fake, System}

  describe "System" do
    setup do
      System.reset_cache()

      on_exit(fn ->
        Application.delete_env(:gateway, :clock_command)
        Application.put_env(:gateway, :assume_clock_synced, false)
        System.reset_cache()
      end)
    end

    test "now is utc in whole seconds" do
      now = System.now()
      assert now.time_zone == "Etc/UTC"
      assert now.microsecond == {0, 0}
    end

    test "parses timedatectl output" do
      assert System.parse("yes\n") == {:ok, true}
      assert System.parse("no") == {:ok, false}
      assert System.parse("") == :error
      assert System.parse("maybe") == :error
    end

    test "a missing timedatectl falls back to :assume_clock_synced, default false" do
      Application.put_env(:gateway, :clock_command, {"breakline-no-such-timedatectl", []})
      Application.delete_env(:gateway, :assume_clock_synced)
      refute System.synced?()

      System.reset_cache()
      Application.put_env(:gateway, :assume_clock_synced, true)
      assert System.synced?()
    end

    test "a failing command falls back too" do
      Application.put_env(:gateway, :clock_command, {"false", []})
      Application.put_env(:gateway, :assume_clock_synced, false)
      refute System.synced?()
    end

    test "the answer is cached" do
      Application.put_env(:gateway, :clock_command, {"echo", ["yes"]})
      assert System.synced?()
      Application.put_env(:gateway, :clock_command, {"echo", ["no"]})
      assert System.synced?()
      System.reset_cache()
      refute System.synced?()
    end
  end

  describe "Fake" do
    test "set, advance and sync" do
      start_supervised!({Fake, now: ~U[2026-11-02 00:00:00.123Z], synced?: false})
      assert Fake.now() == ~U[2026-11-02 00:00:00Z]
      refute Fake.synced?()

      Fake.advance(90)
      assert Fake.now() == ~U[2026-11-02 00:01:30Z]

      Fake.set_now(
        DateTime.new!(~D[2026-11-02], ~T[12:00:00], "Australia/Sydney", Tz.TimeZoneDatabase)
      )

      assert Fake.now() == ~U[2026-11-02 01:00:00Z]

      Fake.set_synced(true)
      assert Fake.synced?()
    end
  end
end
