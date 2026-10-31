defmodule Breakline.AuditExportTest do
  use ExUnit.Case, async: true

  alias Breakline.{AuditExport, AuditLog}

  defp chain(n) do
    Enum.reduce(1..n//1, AuditLog.new(), fn i, chain ->
      AuditLog.append(chain, %{"action" => "test.#{i}", "at" => "2026-10-#{10 + i}T00:00:00Z"})
    end)
  end

  defp head(chain) do
    case AuditLog.head(chain) do
      nil -> nil
      {seq, hash} -> %{"seq" => seq, "hash" => hash}
    end
  end

  defp cloud_item(record),
    do: Map.merge(record, %{"at" => record["entry"]["at"], "action" => record["entry"]["action"]})

  defp gateway_item(record),
    do: %{
      "seq" => record["seq"],
      "prev_hash" => record["prev_hash"],
      "hash" => record["hash"],
      "record" => record
    }

  # the slice [first, last] of the chain, as an export segment
  defp segment(chain, first, last, to_item) do
    records = AuditLog.records(chain)
    previous = if first > 0, do: to_item.(Enum.at(records, first - 1))

    %{
      "head" => head(chain),
      "previous_record" => previous,
      "records" => records |> Enum.slice(first..last//1) |> Enum.map(to_item),
      "from_genesis" => first == 0,
      "to_head" => last == length(records) - 1
    }
  end

  defp export(cloud, gateways \\ []) do
    %{
      "format" => "breakline-audit-export/1",
      "cloud_audit" => cloud,
      "gateway_audit" => gateways
    }
  end

  test "a whole chain from genesis to head is intact" do
    c = chain(5)

    assert {:ok, [result]} = AuditExport.verify(export(segment(c, 0, 4, &cloud_item/1)))
    assert result.result == :ok
    assert result.records == 5
    assert result.head_checked?
  end

  test "an empty chain is intact" do
    empty = %{
      "head" => nil,
      "previous_record" => nil,
      "records" => [],
      "from_genesis" => true,
      "to_head" => true
    }

    assert {:ok, [%{result: :ok}]} = AuditExport.verify(export(empty))
  end

  test "a period that starts mid-chain verifies from the record before it" do
    c = chain(8)
    gateway = segment(chain(6), 2, 5, &gateway_item/1) |> Map.put("site_name", "Clinic")

    assert {:ok, [cloud, gw]} =
             AuditExport.verify(export(segment(c, 3, 5, &cloud_item/1), [gateway]))

    # the previous record is checked too
    assert cloud.records == 4
    refute cloud.head_checked?
    assert gw.head_checked?
    assert AuditExport.describe(gw) =~ "gateway audit chain of Clinic: intact"
  end

  test "an edited entry is reported at its seq" do
    c = chain(6)
    seg = segment(c, 2, 5, &cloud_item/1)
    seg = update_in(seg, ["records", Access.at(1), "entry", "action"], fn _ -> "forged" end)

    assert {:error, [%{result: {:broken_at, 3, :hash_mismatch}}]} =
             AuditExport.verify(export(seg))
  end

  test "an edited previous record is reported" do
    seg = segment(chain(6), 2, 5, &cloud_item/1)
    seg = put_in(seg, ["previous_record", "entry", "action"], "forged")

    assert {:error, [%{result: {:broken_at, 1, :hash_mismatch}}]} =
             AuditExport.verify(export(seg))
  end

  test "a removed record breaks the chain" do
    seg = segment(chain(6), 0, 5, &cloud_item/1)
    seg = Map.update!(seg, "records", &List.delete_at(&1, 2))

    assert {:error, [%{result: {:broken_at, 2, :seq_gap}}]} = AuditExport.verify(export(seg))
  end

  test "a cut-off tail is reported when the segment claims to reach the head" do
    seg = segment(chain(6), 0, 5, &cloud_item/1)
    seg = Map.update!(seg, "records", &Enum.take(&1, 4))

    assert {:error, [%{result: {:broken_at, 4, :truncated}}]} = AuditExport.verify(export(seg))
  end

  test "a head that does not match the last record is reported" do
    seg = segment(chain(3), 0, 2, &cloud_item/1)
    seg = put_in(seg, ["head", "hash"], String.duplicate("0", 64))

    assert {:error, [%{result: {:broken_at, 2, :head_mismatch}}]} =
             AuditExport.verify(export(seg))
  end

  test "a gateway record whose copies disagree with it is malformed" do
    gateway = segment(chain(3), 0, 2, &gateway_item/1)
    gateway = put_in(gateway, ["records", Access.at(1), "hash"], String.duplicate("a", 64))
    cloud = segment(chain(1), 0, 0, &cloud_item/1)

    assert {:error, [%{result: :ok}, %{result: {:broken_at, 1, :malformed}}]} =
             AuditExport.verify(export(cloud, [gateway]))
  end

  test "anything else is not an export" do
    assert {:error, :not_an_export} = AuditExport.verify(%{"format" => "other"})
    assert {:error, :not_an_export} = AuditExport.verify(%{"format" => AuditExport.format()})
  end

  describe "mix breakline.audit.verify" do
    @describetag :tmp_dir

    defp run_task(path) do
      Mix.shell(Mix.Shell.Process)

      try do
        Mix.Tasks.Breakline.Audit.Verify.run([path])
        0
      catch
        :exit, {:shutdown, status} -> status
      after
        Mix.shell(Mix.Shell.IO)
      end
    end

    defp messages do
      receive do
        {:mix_shell, _kind, [line]} -> [line | messages()]
      after
        0 -> []
      end
    end

    test "exits 0 for an intact file", %{tmp_dir: dir} do
      path = Path.join(dir, "export.json")
      File.write!(path, JSON.encode!(export(segment(chain(4), 0, 3, &cloud_item/1))))

      assert run_task(path) == 0
      assert "all chains intact" in messages()
    end

    test "exits 1 with the first break for a tampered file", %{tmp_dir: dir} do
      seg = segment(chain(4), 0, 3, &cloud_item/1)
      seg = put_in(seg, ["records", Access.at(2), "entry", "action"], "forged")
      path = Path.join(dir, "export.json")
      File.write!(path, JSON.encode!(export(seg)))

      assert run_task(path) == 1
      assert "first break: cloud audit chain: broken at seq 2: hash_mismatch" in messages()
    end

    test "exits 2 for a missing or foreign file", %{tmp_dir: dir} do
      assert run_task(Path.join(dir, "missing.json")) == 2
      path = Path.join(dir, "other.json")
      File.write!(path, "{}")
      assert run_task(path) == 2
    end
  end
end
