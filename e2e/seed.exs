# full-stack check seed, run inside the cloud release with `bin/cloud rpc`: one tenant, an
# admin with a password and one enforcing site. the passkey, the enrolment code and every
# access change go through the browser.
#
# the user is seeded with the bcrypt hash the password strategy makes, as
# mix cloud.dev.demo_password does: registering through the strategy would send a
# confirmation email, and the check runs without a mail provider
require Ash.Query

alias Cloud.Accounts
alias Cloud.Accounts.User
alias Cloud.Sites

password = "/tmp/demo_password" |> File.read!() |> String.trim()
email = "e2e@breakline.test"

tenant =
  case Accounts.get_tenant_by_slug("demo-clinic", authorize?: false, not_found_error?: false) do
    {:ok, %{} = tenant} -> tenant
    _ -> Accounts.create_tenant!(%{name: "Demo clinic", slug: "demo-clinic"}, authorize?: false)
  end

user =
  case User |> Ash.Query.filter(email == ^email) |> Ash.read_one!(authorize?: false) do
    %User{} = user ->
      user

    nil ->
      {:ok, hash} = AshAuthentication.BcryptProvider.hash(password)

      Ash.Seed.seed!(User, %{
        email: email,
        hashed_password: hash,
        confirmed_at: DateTime.utc_now()
      })
  end

case Accounts.membership_for(user.id, tenant.id, authorize?: false) do
  {:ok, _} -> :ok
  {:error, _} -> Accounts.create_membership!(user.id, tenant.id, :admin, authorize?: false)
end

site =
  case Sites.list_sites!(actor: user, tenant: tenant, query: [filter: [name: "Front office"]]) do
    [site | _] ->
      site

    [] ->
      Sites.create_site!(
        %{name: "Front office", time_zone: "Australia/Sydney", mode: :enforce, tool_ids: ["anydesk"]},
        actor: user,
        tenant: tenant
      )
  end

IO.puts("SITE=#{site.id}")
