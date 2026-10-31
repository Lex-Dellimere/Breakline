defmodule Cloud.Sites.Validations.TimeZone do
  @moduledoc """
  Validates that an attribute names an IANA time zone known to
  `Tz.TimeZoneDatabase`, the same database core and the gateway use.
  """

  use Ash.Resource.Validation

  @impl true
  def init(opts), do: {:ok, Keyword.put_new(opts, :attribute, :time_zone)}

  @impl true
  def validate(changeset, opts, _context) do
    field = opts[:attribute]

    case Ash.Changeset.get_attribute(changeset, field) do
      nil ->
        :ok

      zone ->
        if known?(zone),
          do: :ok,
          else: {:error, field: field, message: "is not a known IANA time zone"}
    end
  end

  @doc "Whether `zone` is a time zone `Tz.TimeZoneDatabase` knows."
  @spec known?(String.t()) :: boolean()
  def known?(zone) when is_binary(zone) do
    # any fixed wall time works: an unknown zone fails before periods are looked up
    match?(
      {:ok, _},
      DateTime.from_naive(~N[2000-01-01 12:00:00], zone, Tz.TimeZoneDatabase)
    )
  end
end
