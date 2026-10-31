defmodule Gateway.Clock do
  @moduledoc """
  The wall clock the Enforcer evaluates the schedule against.

  `now/0` is the current UTC time in whole seconds. `synced?/0` says whether the
  clock is known to be synchronised. The Enforcer treats an unsynchronised clock as
  locked, because a skewed clock could move the site into a window it is not in
  (threat model T11).

  Implementations are `Gateway.Clock.System` (the host clock and systemd's NTP
  status) and `Gateway.Clock.Fake` (an Agent tests can move).
  """

  @doc "Returns the current UTC time, truncated to whole seconds."
  @callback now() :: DateTime.t()

  @doc "Returns whether the clock is known to be synchronised."
  @callback synced?() :: boolean()
end
