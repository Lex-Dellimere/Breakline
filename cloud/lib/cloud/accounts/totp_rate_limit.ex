defmodule Cloud.Accounts.TotpRateLimit do
  @moduledoc """
  Brute-force protection for the TOTP strategy's verify and confirm-setup
  actions: refuses the check while the user has too many recent failures
  (`Cloud.Accounts.Totp.locked?/1`). `Cloud.Accounts.Totp.check_code/2`
  counts the failures.
  """

  use Ash.Resource.Preparation

  alias Ash.ActionInput
  alias Cloud.Accounts.{Totp, User}

  @impl true
  def supports(_opts), do: [Ash.Query, Ash.ActionInput, Ash.Changeset]

  @impl true
  def prepare(%ActionInput{} = input, _opts, _context) do
    with %User{id: id} <- ActionInput.get_argument(input, :user),
         {:ok, user} <- Ash.get(User, id, authorize?: false),
         true <- Totp.locked?(user) do
      ActionInput.add_error(input, "too many wrong codes, wait a few minutes")
    else
      _ -> input
    end
  end

  # confirm_setup: the user is the changeset's data
  def prepare(%Ash.Changeset{data: %User{id: id}} = changeset, _opts, _context) do
    case Ash.get(User, id, authorize?: false) do
      {:ok, user} ->
        if Totp.locked?(user),
          do: Ash.Changeset.add_error(changeset, "too many wrong codes, wait a few minutes"),
          else: changeset

      _ ->
        changeset
    end
  end

  def prepare(query, _opts, _context), do: query
end
