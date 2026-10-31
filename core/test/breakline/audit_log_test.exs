defmodule Breakline.AuditLogTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Breakline.AuditLog
  alias Breakline.CanonicalJSON

  # generators

  def json_value do
    scalar = one_of([constant(nil), boolean(), integer(), string(:printable, max_length: 10)])

    tree(scalar, fn child ->
      one_of([
        list_of(child, max_length: 3),
        map_of(string(:alphanumeric, max_length: 5), child, max_length: 3)
      ])
    end)
  end

  def entry do
    gen all(
          event <- member_of(["window_opened", "window_closed", "policy_applied", "lock"]),
          extra <-
            map_of(string(:alphanumeric, min_length: 1, max_length: 6), json_value(),
              max_length: 3
            )
        ) do
      extra |> Map.delete("seq") |> Map.put("event", event)
    end
  end

  def chain_records(min_length \\ 0) do
    gen all(entries <- list_of(entry(), min_length: min_length, max_length: 15)) do
      chain = Enum.reduce(entries, AuditLog.new(), &AuditLog.append(&2, &1))
      {AuditLog.records(chain), AuditLog.head(chain)}
    end
  end

  def hex_hash, do: map(binary(length: 32), &Base.encode16(&1, case: :lower))

  defp sha256_hex(bin), do: :crypto.hash(:sha256, bin) |> Base.encode16(case: :lower)

  describe "building a chain" do
    test "first record matches an independently computed hash" do
      chain = AuditLog.append(AuditLog.new(), %{"a" => 1})
      [record] = AuditLog.records(chain)

      assert record == %{
               "seq" => 0,
               "prev_hash" => String.duplicate("0", 64),
               "hash" => sha256_hex(<<0::256>> <> ~s({"a":1,"seq":0})),
               "entry" => %{"a" => 1}
             }

      assert AuditLog.head(chain) == {0, record["hash"]}
    end

    test "second record chains on the first" do
      chain = AuditLog.new() |> AuditLog.append(%{"a" => 1}) |> AuditLog.append(%{"b" => "x"})
      [r0, r1] = AuditLog.records(chain)
      {:ok, prev} = Base.decode16(r0["hash"], case: :lower)
      assert r1["prev_hash"] == r0["hash"]
      assert r1["hash"] == sha256_hex(prev <> ~s({"b":"x","seq":1}))
      assert AuditLog.head(chain) == {1, r1["hash"]}
      assert chain.next_seq == 2
    end

    test "empty chain" do
      assert AuditLog.head(AuditLog.new()) == nil
      assert AuditLog.records(AuditLog.new()) == []
      assert AuditLog.verify_chain([]) == :ok
    end

    test "append_record from a head matches append on the chain" do
      chain = AuditLog.new() |> AuditLog.append(%{"a" => 1}) |> AuditLog.append(%{"b" => 2})
      [r0, r1] = AuditLog.records(chain)
      assert AuditLog.append_record(nil, %{"a" => 1}) == r0
      assert AuditLog.append_record({0, r0["hash"]}, %{"b" => 2}) == r1
    end

    test "atom keys are normalised to strings" do
      record = AuditLog.append_record(nil, %{event: "lock", detail: %{tool: "anydesk"}})
      assert record["entry"] == %{"event" => "lock", "detail" => %{"tool" => "anydesk"}}
      assert AuditLog.verify_chain([record]) == :ok
    end

    test "rejects reserved, non-json and invalid inputs" do
      assert_raise ArgumentError, fn -> AuditLog.append_record(nil, %{"seq" => 1}) end
      assert_raise ArgumentError, fn -> AuditLog.append_record(nil, %{seq: 1}) end
      assert_raise ArgumentError, fn -> AuditLog.append_record(nil, %{"f" => 1.5}) end
      assert_raise ArgumentError, fn -> AuditLog.append_record(nil, [1]) end
      assert_raise ArgumentError, fn -> AuditLog.append_record({0, "nothex"}, %{}) end

      assert_raise ArgumentError, fn ->
        AuditLog.append_record({0, String.duplicate("A", 64)}, %{})
      end
    end

    test "records survive a json round trip and still verify" do
      chain = Enum.reduce(1..5, AuditLog.new(), &AuditLog.append(&2, %{"n" => &1, "s" => "é\n"}))
      json = chain |> AuditLog.records() |> CanonicalJSON.encode!()
      {:ok, decoded} = CanonicalJSON.decode(json)
      assert AuditLog.verify_chain(decoded, expected_head: AuditLog.head(chain)) == :ok
    end
  end

  describe "verify_chain/2" do
    setup do
      chain = Enum.reduce(0..4, AuditLog.new(), &AuditLog.append(&2, %{"n" => &1}))
      %{records: AuditLog.records(chain), head: AuditLog.head(chain)}
    end

    test "reasons", %{records: rs, head: head} do
      assert AuditLog.verify_chain(rs, expected_head: head) == :ok

      edited = List.update_at(rs, 2, &put_in(&1, ["entry", "n"], 99))
      assert AuditLog.verify_chain(edited) == {:error, {:broken_at, 2, :hash_mismatch}}

      bad_prev = List.update_at(rs, 3, &Map.put(&1, "prev_hash", String.duplicate("1", 64)))
      assert AuditLog.verify_chain(bad_prev) == {:error, {:broken_at, 3, :prev_mismatch}}

      bad_hash = List.update_at(rs, 1, &Map.put(&1, "hash", String.duplicate("f", 64)))
      assert AuditLog.verify_chain(bad_hash) == {:error, {:broken_at, 1, :hash_mismatch}}

      assert AuditLog.verify_chain(List.delete_at(rs, 1)) == {:error, {:broken_at, 1, :seq_gap}}
      assert AuditLog.verify_chain(tl(rs)) == {:error, {:broken_at, 0, :seq_gap}}
    end

    test "malformed records", %{records: rs} do
      for bad <- [
            nil,
            "x",
            %{},
            Map.delete(hd(rs), "entry"),
            Map.put(hd(rs), "extra", 1),
            Map.put(hd(rs), "entry", [1]),
            Map.put(hd(rs), "hash", 1),
            put_in(hd(rs), ["entry", "seq"], 0),
            put_in(hd(rs), ["entry", "f"], 1.5)
          ] do
        assert AuditLog.verify_chain([bad | tl(rs)]) == {:error, {:broken_at, 0, :malformed}},
               inspect(bad)
      end
    end

    test "expected_head detects truncation and head mismatch", %{
      records: rs,
      head: {4, hash} = head
    } do
      assert AuditLog.verify_chain(Enum.take(rs, 3), expected_head: head) ==
               {:error, {:broken_at, 3, :truncated}}

      assert AuditLog.verify_chain([], expected_head: head) ==
               {:error, {:broken_at, 0, :truncated}}

      assert AuditLog.verify_chain(rs, expected_head: {4, String.duplicate("0", 64)}) ==
               {:error, {:broken_at, 4, :head_mismatch}}

      longer = rs ++ [AuditLog.append_record(head, %{"forged" => true})]
      assert AuditLog.verify_chain(longer) == :ok

      assert AuditLog.verify_chain(longer, expected_head: {4, hash}) ==
               {:error, {:broken_at, 5, :head_mismatch}}
    end
  end

  describe "verify_segment/2" do
    setup do
      chain = Enum.reduce(0..5, AuditLog.new(), &AuditLog.append(&2, %{"n" => &1}))
      %{records: AuditLog.records(chain), head: AuditLog.head(chain)}
    end

    test "a whole chain from genesis", %{records: rs, head: head} do
      assert AuditLog.verify_segment(rs, after: nil) == {:ok, head}
      assert AuditLog.verify_segment([], after: nil) == {:ok, nil}
    end

    test "batches continue from the head before them", %{records: rs, head: head} do
      {first, rest} = Enum.split(rs, 2)
      assert {:ok, {1, _} = mid} = AuditLog.verify_segment(first, after: nil)
      assert AuditLog.verify_segment(rest, after: mid) == {:ok, head}
      assert AuditLog.verify_segment([], after: mid) == {:ok, mid}

      # one record at a time
      final =
        Enum.reduce(rs, nil, fn r, h ->
          {:ok, h} = AuditLog.verify_segment([r], after: h)
          h
        end)

      assert final == head
    end

    test "a gap, an overlap or another head is refused", %{records: rs} do
      mid = {1, Enum.at(rs, 1)["hash"]}

      # skips seq 2
      assert AuditLog.verify_segment(Enum.drop(rs, 3), after: mid) ==
               {:error, {:broken_at, 2, :seq_gap}}

      # starts again at seq 1
      assert AuditLog.verify_segment(Enum.drop(rs, 1), after: mid) ==
               {:error, {:broken_at, 2, :seq_gap}}

      # the right seq after a head with another hash
      assert AuditLog.verify_segment(Enum.drop(rs, 2), after: {1, String.duplicate("a", 64)}) ==
               {:error, {:broken_at, 2, :prev_mismatch}}

      # a chain from genesis does not continue a head
      assert AuditLog.verify_segment(rs, after: mid) == {:error, {:broken_at, 2, :seq_gap}}

      assert AuditLog.verify_segment(Enum.drop(rs, 2), after: nil) ==
               {:error, {:broken_at, 0, :seq_gap}}
    end

    test "edits inside the batch are reported at their seq", %{records: rs} do
      mid = {1, Enum.at(rs, 1)["hash"]}
      batch = Enum.drop(rs, 2)

      edited = List.update_at(batch, 2, &put_in(&1, ["entry", "n"], 99))

      assert AuditLog.verify_segment(edited, after: mid) ==
               {:error, {:broken_at, 4, :hash_mismatch}}

      assert AuditLog.verify_segment(List.delete_at(batch, 1), after: mid) ==
               {:error, {:broken_at, 3, :seq_gap}}

      assert AuditLog.verify_segment([nil | batch], after: mid) ==
               {:error, {:broken_at, 2, :malformed}}
    end

    test "a missing or invalid head raises", %{records: rs} do
      assert_raise ArgumentError, fn -> AuditLog.verify_segment(rs, []) end
      assert_raise ArgumentError, fn -> AuditLog.verify_segment(rs, after: {1, "xyz"}) end
      assert_raise ArgumentError, fn -> AuditLog.verify_segment(rs, after: {-1, "00"}) end
    end
  end

  describe "properties" do
    property "an untouched chain verifies, with and without its head" do
      check all({records, head} <- chain_records()) do
        assert AuditLog.verify_chain(records) == :ok
        assert AuditLog.verify_chain(records, expected_head: head) == :ok
      end
    end

    property "a chain split anywhere verifies batch by batch" do
      check all(
              {records, head} <- chain_records(),
              cuts <- list_of(integer(0..max(length(records), 1)), max_length: 4)
            ) do
        {batches, last} =
          cuts
          |> Enum.sort()
          |> Enum.reduce({[], {records, 0}}, fn cut, {acc, {rest, done}} ->
            {batch, rest} = Enum.split(rest, max(cut - done, 0))
            {[batch | acc], {rest, done + length(batch)}}
          end)

        batches = Enum.reverse([elem(last, 0) | batches])

        final =
          Enum.reduce(batches, nil, fn batch, h ->
            assert {:ok, h} = AuditLog.verify_segment(batch, after: h)
            h
          end)

        assert final == head
      end
    end

    property "editing any entry value is detected" do
      check all(
              {records, _head} <- chain_records(1),
              i <- integer(0..(length(records) - 1)),
              key <- member_of(Map.keys(Enum.at(records, i)["entry"])),
              value <- json_value(),
              value != Enum.at(records, i)["entry"][key]
            ) do
        tampered = List.update_at(records, i, &put_in(&1, ["entry", key], value))
        assert AuditLog.verify_chain(tampered) == {:error, {:broken_at, i, :hash_mismatch}}
      end
    end

    property "editing any hash or prev_hash is detected" do
      check all(
              {records, _head} <- chain_records(1),
              i <- integer(0..(length(records) - 1)),
              field <- member_of(["hash", "prev_hash"]),
              forged <- hex_hash(),
              forged != Enum.at(records, i)[field]
            ) do
        tampered = List.update_at(records, i, &Map.put(&1, field, forged))
        assert {:error, {:broken_at, ^i, _}} = AuditLog.verify_chain(tampered)
      end
    end

    property "inserting a forged record anywhere is detected" do
      check all(
              {records, head} <- chain_records(),
              i <- integer(0..length(records)),
              entry <- entry(),
              kind <- member_of([:random, :well_formed]),
              seq <- integer(0..20),
              prev <- hex_hash(),
              hash <- hex_hash()
            ) do
        forged =
          case kind do
            :random ->
              %{"seq" => seq, "prev_hash" => prev, "hash" => hash, "entry" => entry}

            # correctly chained onto the record before it
            :well_formed ->
              prev_head = if i == 0, do: nil, else: {i - 1, Enum.at(records, i - 1)["hash"]}
              AuditLog.append_record(prev_head, entry)
          end

        tampered = List.insert_at(records, i, forged)

        # a well formed record appended at the tail is only caught by the anchored head
        if i < length(records) or kind == :random do
          assert {:error, {:broken_at, _, _}} = AuditLog.verify_chain(tampered)
        end

        assert {:error, {:broken_at, _, _}} = AuditLog.verify_chain(tampered, expected_head: head)
      end
    end

    property "deleting any record is detected" do
      check all(
              {records, head} <- chain_records(1),
              i <- integer(0..(length(records) - 1))
            ) do
        tampered = List.delete_at(records, i)

        if i < length(records) - 1 do
          assert AuditLog.verify_chain(tampered) == {:error, {:broken_at, i, :seq_gap}}
        end

        assert {:error, {:broken_at, ^i, reason}} =
                 AuditLog.verify_chain(tampered, expected_head: head)

        assert reason in [:seq_gap, :truncated]
      end
    end

    property "swapping any two records is detected" do
      check all(
              {records, _head} <- chain_records(2),
              i <- integer(0..(length(records) - 2)),
              j <- integer((i + 1)..(length(records) - 1))
            ) do
        a = Enum.at(records, i)
        b = Enum.at(records, j)
        tampered = records |> List.replace_at(i, b) |> List.replace_at(j, a)
        assert AuditLog.verify_chain(tampered) == {:error, {:broken_at, i, :seq_gap}}
      end
    end

    property "tail truncation is detected against the expected head" do
      check all(
              {records, head} <- chain_records(1),
              keep <- integer(0..(length(records) - 1))
            ) do
        truncated = Enum.take(records, keep)
        assert AuditLog.verify_chain(truncated) == :ok

        assert AuditLog.verify_chain(truncated, expected_head: head) ==
                 {:error, {:broken_at, keep, :truncated}}
      end
    end
  end
end
