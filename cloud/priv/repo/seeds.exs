# dev demo data. run with `mix run priv/repo/seeds.exs` (also part of `mix setup`).
#
# idempotent: existing records are found and kept. the demo admin's password is
# generated on first run and printed here only; set DEMO_PASSWORD to choose it.

if Mix.env() != :dev do
  IO.puts("seeds are for dev only, skipping")
else
  # keep the sql debug log out of the way of the printed password
  Logger.configure(level: :info)

  require Ash.Query

  alias Cloud.Accounts
  alias Cloud.Accounts.User
  alias Cloud.Sites

  email = "demo@breakline.test"

  tenant =
    case Accounts.get_tenant_by_slug("demo", authorize?: false, not_found_error?: false) do
      {:ok, %{} = tenant} ->
        tenant

      _ ->
        Accounts.create_tenant!(%{name: "Demo Clinics", slug: "demo"}, authorize?: false)
    end

  user =
    case User |> Ash.Query.filter(email == ^email) |> Ash.read_one!(authorize?: false) do
      %User{} = user ->
        IO.puts("user #{email} exists, password unchanged")
        user

      nil ->
        password =
          System.get_env("DEMO_PASSWORD") ||
            Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

        strategy = AshAuthentication.Info.strategy!(User, :password)

        {:ok, user} =
          AshAuthentication.Strategy.action(
            strategy,
            :register,
            %{
              "email" => email,
              "password" => password,
              "password_confirmation" => password
            },
            []
          )

        user = Ash.Seed.update!(user, %{confirmed_at: DateTime.utc_now()})
        IO.puts("created #{email} with password: #{password}")
        user
    end

  case Accounts.membership_for(user.id, tenant.id, authorize?: false) do
    {:ok, _} -> :ok
    {:error, _} -> Accounts.create_membership!(user.id, tenant.id, :admin, authorize?: false)
  end

  opts = [actor: user, tenant: tenant]

  site =
    case Sites.list_sites!(Keyword.put(opts, :query, filter: [name: "Parramatta clinic"])) do
      [site | _] ->
        site

      [] ->
        Sites.create_site!(
          %{
            name: "Parramatta clinic",
            time_zone: "Australia/Sydney",
            mode: :enforce,
            tool_ids: ["anydesk", "n_central", "screenconnect"],
            site_hosts: ["rmm.msp-example.com.au"]
          },
          opts
        )
    end

  contact =
    case Sites.list_msp_contacts!(
           Keyword.put(opts, :query, filter: [email: "noc@msp-example.com.au"])
         ) do
      [contact | _] ->
        contact

      [] ->
        Sites.create_msp_contact!(
          %{name: "MSP Example NOC", email: "noc@msp-example.com.au", phone: "+61 2 5550 0100"},
          opts
        )
    end

  # the nightly window: requested by the msp and marked approved by the demo admin.
  # approving through the action needs a passkey step-up, which a seed script cannot
  # do, so the approval is seeded and published below
  case Sites.list_windows!(
         Keyword.put(opts, :query, filter: [site_id: site.id, kind: :recurring])
       ) do
    [_ | _] ->
      :ok

    [] ->
      window =
        Sites.request_window!(
          %{
            site_id: site.id,
            kind: :recurring,
            days: [1, 2, 3, 4, 5],
            starts: ~T[22:00:00],
            ends: ~T[02:00:00],
            requested_by_id: contact.id
          },
          opts
        )

      Ash.Seed.update!(window, %{
        status: :approved,
        approved_by_id: user.id,
        approved_at: DateTime.utc_now()
      })
  end

  # publishes the seeded window, or anything that existed but was never published
  site = Sites.get_site!(site.id, opts)

  if site.policy_version == 0 do
    {:ok, _} = Cloud.Policies.publish(site.id, published_by: user, reason: "seeded")
  end

  site = Sites.get_site!(site.id, opts)
  IO.puts("site #{site.name} (#{site.id}) at policy version #{site.policy_version}")
end
