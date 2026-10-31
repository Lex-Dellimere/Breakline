defmodule Mix.Tasks.Cloud.Dev.DemoPassword do
  @shortdoc "Sets the seeded demo user's password from DEMO_PASSWORD (dev only)"

  @moduledoc """
  Sets the password of the seeded demo user (`demo@breakline.test`, see
  `priv/repo/seeds.exs`) to the value of the `DEMO_PASSWORD` environment
  variable:

      DEMO_PASSWORD='a long passphrase' mix cloud.dev.demo_password

  Dev only. The password is hashed the way registration hashes it and is
  never printed.
  """

  use Mix.Task

  require Ash.Query

  @email "demo@breakline.test"

  @impl true
  def run(_args) do
    if Mix.env() != :dev, do: Mix.raise("cloud.dev.demo_password is for dev only")

    password =
      case System.get_env("DEMO_PASSWORD") do
        p when is_binary(p) and byte_size(p) >= 8 -> p
        _ -> Mix.raise("set DEMO_PASSWORD to the new password (at least 8 characters)")
      end

    Mix.Task.run("app.start")

    user =
      Cloud.Accounts.User
      |> Ash.Query.filter(email == ^@email)
      |> Ash.read_one!(authorize?: false)

    if is_nil(user), do: Mix.raise("no user #{@email}, run `mix run priv/repo/seeds.exs` first")

    {:ok, hash} = AshAuthentication.BcryptProvider.hash(password)
    Ash.Seed.update!(user, %{hashed_password: hash})
    Mix.shell().info("password of #{@email} updated")
  end
end
