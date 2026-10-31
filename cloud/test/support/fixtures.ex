defmodule Cloud.Fixtures do
  @moduledoc """
  Test data builders. Identity fields get globally unique values so async
  tests never collide.
  """

  alias Cloud.Accounts
  alias Cloud.Sites

  def unique, do: System.unique_integer([:positive])

  def user!(attrs \\ %{}) do
    Ash.Seed.seed!(
      Cloud.Accounts.User,
      Map.merge(
        %{email: "user-#{unique()}@example.test", hashed_password: "not-a-real-hash"},
        attrs
      )
    )
  end

  def tenant!(attrs \\ %{}) do
    n = unique()

    Accounts.create_tenant!(Map.merge(%{name: "Tenant #{n}", slug: "t-#{n}"}, attrs),
      authorize?: false
    )
  end

  def member!(user, tenant, role) do
    Accounts.create_membership!(user.id, tenant.id, role, authorize?: false)
  end

  @doc "A tenant with an admin and an approver."
  def org! do
    tenant = tenant!()
    admin = user!()
    approver = user!()
    member!(admin, tenant, :admin)
    member!(approver, tenant, :approver)
    %{tenant: tenant, admin: admin, approver: approver}
  end

  def site!(tenant, admin, attrs \\ %{}) do
    Sites.create_site!(
      Map.merge(
        %{
          name: "Site #{unique()}",
          time_zone: "Australia/Sydney",
          mode: :enforce,
          tool_ids: ["anydesk", "screenconnect"],
          site_hosts: ["rmm.example.com.au", "203.0.113.0/24"]
        },
        attrs
      ),
      actor: admin,
      tenant: tenant
    )
  end

  def recurring_attrs(site, attrs \\ %{}) do
    Map.merge(
      %{
        site_id: site.id,
        kind: :recurring,
        days: [1, 2, 3, 4, 5],
        starts: ~T[22:00:00],
        ends: ~T[02:00:00]
      },
      attrs
    )
  end

  def one_off_attrs(site, attrs \\ %{}) do
    Map.merge(
      %{
        site_id: site.id,
        kind: :one_off,
        starts_at: ~N[2030-01-01 09:00:00],
        ends_at: ~N[2030-01-01 11:00:00]
      },
      attrs
    )
  end

  @doc """
  Pins a random stand-in certificate on the site's gateway. Returns
  `{site, der}`; the der only has to fingerprint the same, it is never parsed.
  """
  def gateway!(site) do
    der = :crypto.strong_rand_bytes(200)

    site =
      Sites.assign_gateway!(site, Cloud.Gateways.cert_fingerprint(der), authorize?: false)

    {site, der}
  end

  @doc """
  A verified step-up seeded straight into the database, for tests that are
  about something other than the ceremony. `params` are the action's params
  (see `Cloud.Accounts.StepUps.payload_hash/1`). Options: `:tenant`,
  `:expires_at`, `:verified_at` (nil for an unverified one).
  """
  def verified_step_up!(user, purpose, subject_id, params, opts \\ []) do
    now = DateTime.utc_now()

    Ash.Seed.seed!(Cloud.Accounts.StepUp, %{
      user_id: user.id,
      tenant_id: tenant_id(opts[:tenant]),
      purpose: purpose,
      subject_id: subject_id,
      payload_hash: Cloud.Accounts.StepUps.payload_hash(params),
      challenge: :crypto.strong_rand_bytes(32),
      allowed_credential_ids: [],
      expires_at: Keyword.get(opts, :expires_at, DateTime.add(now, 120, :second)),
      verified_at: Keyword.get(opts, :verified_at, now)
    })
  end

  @doc "The id of a seeded verified step-up for opening `site` for `minutes`."
  def open_step_up!(user, site, minutes) do
    params = Cloud.Access.step_up_params(site.id, {:open, minutes})
    verified_step_up!(user, :open_window, site.id, params, tenant: site.tenant_id).id
  end

  @doc "The id of a seeded verified step-up for unlocking `site`."
  def unlock_step_up!(user, site) do
    params = Cloud.Access.step_up_params(site.id, :unlock)
    verified_step_up!(user, :lift_lock, site.id, params, tenant: site.tenant_id).id
  end

  @doc "Step-up params for approving `window`."
  def approve_params(window), do: %{id: window.id, site_id: window.site_id}

  @doc "The id of a seeded verified step-up for approving `window`."
  def approve_step_up!(user, window) do
    verified_step_up!(user, :approve_window, window.id, approve_params(window),
      tenant: window.tenant_id
    ).id
  end

  @shape_fields [:site_id, :kind, :days, :starts, :ends, :starts_at, :ends_at]

  @doc "The id of a seeded verified step-up for booking an approved window with `attrs`."
  def book_step_up!(user, attrs, tenant) do
    verified_step_up!(user, :open_window, attrs.site_id, Map.take(attrs, @shape_fields),
      tenant: tenant
    ).id
  end

  @doc "The id of a seeded verified step-up for a break-glass on `site_id` until `until`."
  def break_glass_step_up!(user, site_id, until, tenant) do
    verified_step_up!(user, :break_glass, site_id, %{site_id: site_id, until: until},
      tenant: tenant
    ).id
  end

  @doc "The id of a seeded verified step-up for lifting `lock`."
  def lift_step_up!(user, lock) do
    verified_step_up!(user, :lift_lock, lock.id, %{id: lock.id}, tenant: lock.tenant_id).id
  end

  @doc "Approves `window` as `user` with a seeded step-up."
  def approve!(window, user) do
    Sites.approve_window!(window, %{step_up_id: approve_step_up!(user, window)},
      actor: user,
      tenant: window.tenant_id
    )
  end

  @doc "Books an approved window with `attrs` as `user` in `tenant`, with a seeded step-up."
  def book!(attrs, user, tenant) do
    Sites.create_approved_window!(
      Map.put(attrs, :step_up_id, book_step_up!(user, attrs, tenant)),
      actor: user,
      tenant: tenant
    )
  end

  @doc "Opens a break-glass on `site` until `until` as `user`, with a seeded step-up."
  def break_glass!(site, until, user) do
    Sites.create_break_glass!(
      %{
        site_id: site.id,
        until: until,
        step_up_id: break_glass_step_up!(user, site.id, until, site.tenant_id)
      },
      actor: user,
      tenant: site.tenant_id
    )
  end

  @doc "Lifts `lock` as `user` with a seeded step-up."
  def lift!(lock, user) do
    Sites.lift_advisory_lock!(lock, %{step_up_id: lift_step_up!(user, lock)},
      actor: user,
      tenant: lock.tenant_id
    )
  end

  @doc """
  Registers a passkey for `user` through the real ceremony with a software
  authenticator. Returns `{authenticator, passkey}`. Pass `step_up_id:` when
  the user already has a passkey.
  """
  def passkey!(user, opts \\ []) do
    authenticator = Cloud.SoftAuthenticator.new()
    {challenge, options} = Cloud.Accounts.Passkeys.registration_options(user)
    attestation = Cloud.SoftAuthenticator.attest(authenticator, options)
    {:ok, passkey} = Cloud.Accounts.Passkeys.register(user, challenge, attestation, opts)
    {authenticator, passkey}
  end

  @doc """
  Runs a real step-up: begins it, signs it with `authenticator` and verifies
  it. Returns `{authenticator, step_up}` (the authenticator's counter moved).
  """
  def step_up!(user, authenticator, purpose, subject_id, params, opts \\ []) do
    {:ok, step_up, options} =
      Cloud.Accounts.begin_step_up(user, purpose, subject_id, params, opts)

    {authenticator, assertion} = Cloud.SoftAuthenticator.assert(authenticator, options)
    {:ok, step_up} = Cloud.Accounts.verify_step_up(step_up.id, assertion, actor: user)
    {authenticator, step_up}
  end

  defp tenant_id(nil), do: nil
  defp tenant_id(%{id: id}), do: id
  defp tenant_id(id) when is_binary(id), do: id
end
