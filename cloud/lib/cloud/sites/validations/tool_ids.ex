defmodule Cloud.Sites.Validations.ToolIds do
  @moduledoc """
  Validates that every entry of `tool_ids` is a `Breakline.Catalog` tool id
  and that none repeats (`Breakline.Policy.new/1` rejects duplicates).
  """

  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    ids = Ash.Changeset.get_attribute(changeset, :tool_ids) || []
    unknown = Enum.reject(ids, &(&1 in Breakline.Catalog.ids()))

    cond do
      unknown != [] ->
        {:error, field: :tool_ids, message: "unknown tool ids: #{Enum.join(unknown, ", ")}"}

      Enum.uniq(ids) != ids ->
        {:error, field: :tool_ids, message: "must not repeat"}

      true ->
        :ok
    end
  end
end
