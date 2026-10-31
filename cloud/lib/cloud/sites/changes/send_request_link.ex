defmodule Cloud.Sites.Changes.SendRequestLink do
  @moduledoc """
  Emails a new `Cloud.Sites.RequestLink` to its contact once the link is
  committed (`Cloud.Sites.RequestLinkEmail`), so a rolled-back link is never
  sent. The record's `:email_sent?` metadata says whether delivery worked; a
  failed delivery leaves the link in place for an admin to revoke and send
  again.
  """

  use Ash.Resource.Change

  require Logger

  alias Cloud.Sites
  alias Cloud.Sites.RequestLinkEmail

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_transaction(changeset, fn
      _changeset, {:ok, record} ->
        {:ok, Ash.Resource.put_metadata(record, :email_sent?, send(record))}

      _changeset, other ->
        other
    end)
  end

  # trusted reads of the contact and site the action just authorised
  defp send(record) do
    with token when is_binary(token) <- record.__metadata__[:token],
         {:ok, contact} <-
           Sites.get_msp_contact(record.msp_contact_id,
             tenant: record.tenant_id,
             authorize?: false
           ),
         {:ok, site} <- Sites.get_site(record.site_id, authorize?: false),
         :ok <- RequestLinkEmail.deliver(contact, site, token, record.expires_at) do
      true
    else
      error ->
        Logger.error("request link #{record.id} was not emailed: #{inspect(error)}")
        false
    end
  end
end
