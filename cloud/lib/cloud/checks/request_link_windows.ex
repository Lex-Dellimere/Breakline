defmodule Cloud.Checks.RequestLinkWindows do
  @moduledoc """
  Policy filter for reading windows as a `Cloud.Sites.RequestLink`: a usable
  link sees only the windows its own contact requested for its own site, so
  the request page can show the contact's requests and nothing else. Any
  other actor gets nothing from this check.
  """

  use Ash.Policy.FilterCheck

  alias Cloud.Sites.{RequestLink, RequestLinks}

  @impl true
  def describe(_opts), do: "the window was requested by the link's contact for its site"

  @impl true
  def filter(%RequestLink{} = link, _context, _opts) do
    if RequestLinks.usable?(link) do
      expr(
        tenant_id == ^link.tenant_id and site_id == ^link.site_id and
          requested_by_id == ^link.msp_contact_id
      )
    else
      expr(false)
    end
  end

  def filter(_actor, _context, _opts), do: expr(false)
end
