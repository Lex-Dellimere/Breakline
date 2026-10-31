defmodule Cloud.AuditExportTest do
  use Cloud.DataCase, async: true

  import Cloud.Fixtures
  import Cloud.AuditFixtures

  alias Cloud.AuditExport

  setup do
    %{tenant: tenant, admin: admin} = org = org!()
    site = site!(tenant, admin, %{name: "Parramatta clinic"})
    {site, _der} = gateway!(site)
    Map.put(org, :site, site)
  end

  # the export as a downloaded file reads it back
  defp roundtrip(export),
    do: export |> AuditExport.encode() |> IO.iodata_to_binary() |> JSON.decode!()

  test "an intact tenant verifies, with every chain's head", ctx do
    for i <- 1..3, do: cloud_entry!(ctx.site, "test.#{i}", actor: ctx.admin)
    gateway_chain!(ctx.site, [days_ago(2), days_ago(1), DateTime.utc_now()])

    assert {:ok, export} = AuditExport.build(ctx.tenant.id, actor: ctx.admin)

    assert export["format"] == "breakline-audit-export/1"
    assert export["tenant"]["name"] == ctx.tenant.name
    assert export["exported_by"]["email"] == to_string(ctx.admin.email)
    assert export["verification"]["scope"] == "whole_chain"

    cloud = export["verification"]["cloud"]
    assert cloud["status"] == "intact"
    assert cloud["break"] == nil
    assert %{"seq" => head_seq} = cloud["head"]
    assert cloud["entries"] == head_seq + 1

    assert [gateway] = export["verification"]["gateways"]
    assert gateway["status"] == "intact"
    assert gateway["records"] == 3
    assert gateway["anchored_head"]["seq"] == 2
    assert gateway["chain_resets"] == 0

    # the entries name their actor
    assert Enum.any?(
             export["cloud_audit"]["records"],
             &(&1["actor_email"] == to_string(ctx.admin.email))
           )

    # and the file verifies offline, from genesis to head
    assert {:ok, results} = Breakline.AuditExport.verify(roundtrip(export))
    assert Enum.all?(results, & &1.head_checked?)

    model = AuditExport.to_render_model(export)

    assert [%{ok?: true, summary: "Cloud audit chain: intact, " <> _} | _] = model.verification

    assert Enum.any?(
             model.verification,
             &(&1.summary =~ "Gateway chain of Parramatta clinic: intact, 3 records, head seq 2")
           )

    assert [%{title: "Cloud audit entries"}, %{title: "Gateway audit: Parramatta clinic"}] =
             model.sections
  end

  test "a tampered cloud entry is reported at its seq", ctx do
    for i <- 1..4, do: cloud_entry!(ctx.site, "test.#{i}")
    {:ok, before} = AuditExport.build(ctx.tenant.id, actor: ctx.admin)
    seq = before["verification"]["cloud"]["head"]["seq"] - 1

    tamper_cloud_entry!(ctx.tenant.id, seq)

    {:ok, export} = AuditExport.build(ctx.tenant.id, actor: ctx.admin)

    assert export["verification"]["cloud"]["status"] == "broken"

    assert export["verification"]["cloud"]["break"] == %{
             "seq" => seq,
             "reason" => "hash_mismatch"
           }

    assert [%{ok?: false, summary: summary} | _] =
             AuditExport.to_render_model(export).verification

    assert summary ==
             "Cloud audit chain: broken at seq #{seq}: a record does not match its hash (hash_mismatch)"

    # the offline check finds the same break
    assert {:error, [%{result: {:broken_at, ^seq, :hash_mismatch}} | _]} =
             Breakline.AuditExport.verify(roundtrip(export))
  end

  test "a tampered gateway record is reported at its seq", ctx do
    gateway_chain!(ctx.site, [days_ago(3), days_ago(2), days_ago(1), DateTime.utc_now()])
    tamper_gateway_record!(ctx.site.id, 2)

    {:ok, export} = AuditExport.build(ctx.tenant.id, actor: ctx.admin)

    assert export["verification"]["cloud"]["status"] == "intact"
    assert [gateway] = export["verification"]["gateways"]
    assert gateway["status"] == "broken"
    assert gateway["break"] == %{"seq" => 2, "reason" => "hash_mismatch"}

    assert {:error, [%{result: :ok}, %{result: {:broken_at, 2, :hash_mismatch}}]} =
             Breakline.AuditExport.verify(roundtrip(export))
  end

  test "a site without a gateway chain has nothing to verify", ctx do
    bare = site!(ctx.tenant, ctx.admin, %{name: "Bare site"})
    {:ok, export} = AuditExport.build(ctx.tenant.id, actor: ctx.admin, site_ids: [bare.id])

    assert [%{"status" => "no_chain", "site_id" => site_id}] = export["verification"]["gateways"]
    assert site_id == bare.id
    assert {:ok, _} = Breakline.AuditExport.verify(roundtrip(export))
  end

  test "the period limits the records but not the verification", ctx do
    old = cloud_entry!(ctx.site, "test.old", at: days_ago(10))
    middle = cloud_entry!(ctx.site, "test.middle", at: days_ago(3))
    recent = cloud_entry!(ctx.site, "test.recent", at: days_ago(1))
    gateway_chain!(ctx.site, [days_ago(20), days_ago(9), days_ago(5), days_ago(2)])

    {:ok, export} =
      AuditExport.build(ctx.tenant.id, actor: ctx.admin, from: days_ago(7), to: days_ago(0.5))

    cloud = export["cloud_audit"]
    assert Enum.map(cloud["records"], & &1["seq"]) == [middle.seq, recent.seq]
    assert cloud["previous_record"]["seq"] == old.seq
    refute cloud["from_genesis"]
    # the head is the recent entry, so the period reaches it
    assert cloud["to_head"]
    # the whole chain was verified
    assert export["verification"]["cloud"]["entries"] == recent.seq + 1

    [gateway] = export["gateway_audit"]
    assert Enum.map(gateway["records"], & &1["seq"]) == [2, 3]
    assert gateway["previous_record"]["seq"] == 1
    assert gateway["to_head"]

    # the mid-chain period still verifies offline from the record before it
    assert {:ok, [_, _]} = Breakline.AuditExport.verify(roundtrip(export))

    # a period that ends before the head
    {:ok, early} =
      AuditExport.build(ctx.tenant.id, actor: ctx.admin, from: days_ago(30), to: days_ago(4))

    assert Enum.map(hd(early["gateway_audit"])["records"], & &1["seq"]) == [0, 1, 2]
    assert hd(early["gateway_audit"])["from_genesis"]
    refute hd(early["gateway_audit"])["to_head"]
    assert {:ok, [_, %{head_checked?: false}]} = Breakline.AuditExport.verify(roundtrip(early))
  end

  test "site_ids picks the gateway chains", ctx do
    other = site!(ctx.tenant, ctx.admin, %{name: "Other"})
    foreign = org!()
    hidden = site!(foreign.tenant, foreign.admin)

    {:ok, export} =
      AuditExport.build(ctx.tenant.id, actor: ctx.admin, site_ids: [other.id, hidden.id])

    assert Enum.map(export["sites"], & &1["id"]) == [other.id]
  end

  test "approvers may export, anyone else may not", ctx do
    assert {:ok, _} = AuditExport.build(ctx.tenant.id, actor: ctx.approver)

    stranger = user!()
    assert {:error, :forbidden} = AuditExport.build(ctx.tenant.id, actor: stranger)

    foreign = org!()
    assert {:error, :forbidden} = AuditExport.build(ctx.tenant.id, actor: foreign.admin)
    assert {:error, :forbidden} = AuditExport.export(ctx.tenant.id, actor: foreign.admin)

    assert {:error, :invalid_period} =
             AuditExport.build(ctx.tenant.id,
               actor: ctx.admin,
               from: days_ago(1),
               to: days_ago(2)
             )
  end

  test "an export is recorded in the cloud audit chain, without the data", ctx do
    from = days_ago(7)
    to = DateTime.utc_now()

    {:ok, export} = AuditExport.export(ctx.tenant.id, actor: ctx.approver, from: from, to: to)

    entry = Cloud.Audit.audit_chain!(tenant: ctx.tenant.id, authorize?: false) |> List.last()
    assert entry.entry["action"] == "audit.exported"
    assert entry.entry["actor_id"] == ctx.approver.id
    assert entry.entry["from"] == export["period"]["from"]
    assert entry.entry["to"] == export["period"]["to"]
    assert entry.entry["site_ids"] == [ctx.site.id]
    refute Map.has_key?(entry.entry, "records")
    assert Cloud.Audit.verify(ctx.tenant.id) == :ok
  end

  test "the filename names the tenant and the period's days", ctx do
    {:ok, export} =
      AuditExport.build(ctx.tenant.id,
        actor: ctx.admin,
        from: ~U[2026-10-01 00:00:00Z],
        to: ~U[2026-11-01 00:00:00Z]
      )

    assert AuditExport.filename(export) ==
             "breakline-audit-#{ctx.tenant.slug}-2026-10-01-2026-10-31.json"
  end

  describe "mix breakline.audit.verify on a real export" do
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

    test "passes the file and fails a tampered copy", %{tmp_dir: dir} = ctx do
      for i <- 1..3, do: cloud_entry!(ctx.site, "test.#{i}", at: days_ago(4 - i))
      gateway_chain!(ctx.site, [days_ago(8), days_ago(3), days_ago(1)])

      {:ok, export} =
        AuditExport.export(ctx.tenant.id,
          actor: ctx.admin,
          from: days_ago(2.5),
          to: DateTime.utc_now()
        )

      path = Path.join(dir, AuditExport.filename(export))
      File.write!(path, AuditExport.encode(export))
      assert run_task(path) == 0

      tampered = Path.join(dir, "tampered.json")

      File.read!(path)
      |> JSON.decode!()
      |> update_in(
        ["gateway_audit", Access.at(0), "records", Access.at(0), "record", "entry", "type"],
        fn _ -> "forged" end
      )
      |> JSON.encode!()
      |> then(&File.write!(tampered, &1))

      assert run_task(tampered) == 1
    end
  end
end
