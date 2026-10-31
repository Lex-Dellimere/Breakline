defmodule Cloud.AuditConcurrencyTest do
  # real concurrent transactions: the sandbox would serialise them on one connection,
  # so this test commits for real and cleans up after itself
  use ExUnit.Case, async: false

  import Cloud.Fixtures

  alias Ecto.Adapters.SQL.Sandbox

  setup do
    :ok = Sandbox.checkout(Cloud.Repo, sandbox: false)
    Sandbox.mode(Cloud.Repo, {:shared, self()})

    tenant = tenant!()
    other = tenant!()
    user = user!()

    on_exit(fn ->
      :ok = Sandbox.checkout(Cloud.Repo, sandbox: false)
      # entries and heads cascade from the tenants
      Cloud.Repo.query!("delete from tenants where id = any($1)", [
        Enum.map([tenant.id, other.id], &Ecto.UUID.dump!/1)
      ])

      Cloud.Repo.query!("delete from users where id = $1", [Ecto.UUID.dump!(user.id)])
    end)

    %{tenant: tenant, other: other, user: user}
  end

  test "concurrent appends get consecutive seqs and a valid chain", ctx do
    n = 24

    # the head row does not exist yet, so the first appends also race to create it
    1..n
    |> Task.async_stream(
      fn i ->
        tenant = if rem(i, 3) == 0, do: ctx.other, else: ctx.tenant
        {:ok, _} = Cloud.Audit.record(tenant.id, "test.concurrent", %{i: i}, actor: ctx.user)
      end,
      max_concurrency: n,
      timeout: 30_000
    )
    |> Enum.each(fn {:ok, {:ok, _}} -> :ok end)

    for {tenant, count} <- [{ctx.tenant, n - div(n, 3)}, {ctx.other, div(n, 3)}] do
      entries = Cloud.Audit.audit_chain!(tenant: tenant, authorize?: false)
      assert Enum.map(entries, & &1.seq) == Enum.to_list(0..(count - 1))
      assert :ok = Cloud.Audit.verify(tenant.id)
    end
  end
end
