defmodule Cloud.Sites.Changes.NormaliseSiteHosts do
  @moduledoc """
  Trims and lowercases `site_hosts` and drops repeats, so the gateway sees
  each host once in its canonical spelling.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.fetch_change(changeset, :site_hosts) do
      {:ok, hosts} when is_list(hosts) ->
        normalised =
          hosts
          |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
          |> Enum.uniq()

        Ash.Changeset.force_change_attribute(changeset, :site_hosts, normalised)

      _ ->
        changeset
    end
  end
end
