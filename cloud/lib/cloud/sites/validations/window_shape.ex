defmodule Cloud.Sites.Validations.WindowShape do
  @moduledoc """
  Validates a window's fields for its `kind`, using the same rules as the
  policy it will end up in:

  - `:recurring` needs `days`, `starts` and `ends`, checked by
    `Breakline.Policy.RecurringWindow.new/1`, and no one-off fields.
  - `:one_off` needs `starts_at` and `ends_at`, checked by
    `Breakline.Policy.OneOffWindow.new/1`, and no recurring fields.
  """

  use Ash.Resource.Validation

  alias Breakline.Policy.{OneOffWindow, RecurringWindow}

  @recurring [:days, :starts, :ends]
  @one_off [:starts_at, :ends_at]

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :kind) do
      :recurring -> check(changeset, @recurring, @one_off, &RecurringWindow.new/1)
      :one_off -> check(changeset, @one_off, @recurring, &OneOffWindow.new/1)
      _ -> :ok
    end
  end

  defp check(changeset, fields, foreign, build) do
    values = Map.new(fields, &{&1, Ash.Changeset.get_attribute(changeset, &1)})
    set_foreign = Enum.reject(foreign, &is_nil(Ash.Changeset.get_attribute(changeset, &1)))
    missing = for {field, nil} <- values, do: field

    cond do
      set_foreign != [] ->
        errors(Enum.map(set_foreign, &{&1, "must be empty for this kind of window"}))

      missing != [] ->
        errors(Enum.map(missing, &{&1, "is required for this kind of window"}))

      true ->
        # the id is assigned later; any placeholder satisfies the policy rules
        case build.(Map.put(values, :id, "new")) do
          {:ok, _} -> :ok
          {:error, reasons} -> errors(Enum.map(reasons, &policy_error/1))
        end
    end
  end

  defp policy_error({[field | _], reason}), do: {field, message(reason)}
  defp policy_error({[], reason}), do: {:kind, message(reason)}

  defp message(:invalid), do: "is invalid (times must be whole minutes, days 1 to 7, unique)"
  defp message(:required), do: "is required"
  defp message(:equals_starts), do: "must differ from starts"
  defp message(:not_after_starts_at), do: "must be after starts_at"
  defp message(other), do: to_string(other)

  defp errors(list) do
    {:error,
     Enum.map(list, fn {field, msg} ->
       Ash.Error.Changes.InvalidAttribute.exception(field: field, message: msg)
     end)}
  end
end
