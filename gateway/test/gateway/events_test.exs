defmodule Gateway.EventsTest do
  use ExUnit.Case, async: true

  alias Gateway.Events

  setup do
    name = :"events_#{System.unique_integer([:positive])}"
    start_supervised!({Events, name: name, capacity: 3})
    %{ev: name}
  end

  test "keeps events in order and drains oldest first", %{ev: ev} do
    for i <- 1..2, do: Events.record(%{n: i}, ev)

    assert Events.recent(10, ev) == [%{n: 1}, %{n: 2}]
    assert Events.drain(1, ev) == [%{n: 1}]
    assert Events.drain(10, ev) == [%{n: 2}]
    assert Events.drain(10, ev) == []
  end

  test "is bounded: the oldest events are dropped and counted", %{ev: ev} do
    for i <- 1..5, do: Events.record(%{n: i}, ev)

    assert Events.recent(10, ev) == [%{n: 3}, %{n: 4}, %{n: 5}]
    assert Events.recent(2, ev) == [%{n: 4}, %{n: 5}]
    assert Events.stats(ev) == %{size: 3, capacity: 3, dropped: 2}
  end

  test "record never fails when the buffer is not running" do
    assert Events.record(%{n: 1}, :no_such_events_buffer) == :ok
  end

  test "rejects a bad capacity" do
    assert_raise ArgumentError, fn -> Events.start_link(capacity: 0, name: :bad_events) end
  end
end
