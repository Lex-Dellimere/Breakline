defmodule Breakline do
  @moduledoc """
  Pure domain logic shared by the cloud and the gateway: policy, schedule,
  tool catalog, signed commands and the audit chain.

  No processes, no IO, no global config. Time zone lookups pass
  `time_zone_database/0` explicitly so callers don't need to configure
  `:elixir, :time_zone_database`.
  """

  @doc "The time zone database every core function uses."
  @spec time_zone_database() :: module()
  def time_zone_database, do: Tz.TimeZoneDatabase
end
