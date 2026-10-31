defmodule CloudWeb.ChannelCase do
  @moduledoc """
  The case for channel tests, with `Phoenix.ChannelTest` against
  `CloudWeb.GatewayEndpoint` and the SQL sandbox.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import Phoenix.ChannelTest
      import CloudWeb.ChannelCase

      @endpoint CloudWeb.GatewayEndpoint
    end
  end

  setup tags do
    Cloud.DataCase.setup_sandbox(tags)
    :ok
  end
end
