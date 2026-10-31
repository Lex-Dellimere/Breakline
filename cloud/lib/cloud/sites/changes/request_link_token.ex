defmodule Cloud.Sites.Changes.RequestLinkToken do
  @moduledoc """
  Gives a new `Cloud.Sites.RequestLink` its token and expiry: stores only the
  token's hash and puts the raw token in the created record's `:token`
  metadata, the one place it is ever handed back.
  """

  use Ash.Resource.Change

  alias Cloud.Sites.RequestLinks

  @impl true
  def change(changeset, _opts, _context) do
    {token, token_hash} = RequestLinks.new_token()
    expires_at = DateTime.add(DateTime.utc_now(), RequestLinks.ttl_days() * 86_400, :second)

    changeset
    |> Ash.Changeset.force_change_attributes(token_hash: token_hash, expires_at: expires_at)
    |> Ash.Changeset.after_action(fn _changeset, record ->
      {:ok, Ash.Resource.put_metadata(record, :token, token)}
    end)
  end
end
