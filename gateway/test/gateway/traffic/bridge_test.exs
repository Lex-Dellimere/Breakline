defmodule Gateway.Traffic.BridgeTest do
  # real packets through the prod release, bridge topology. see Gateway.TrafficCase
  use Gateway.TrafficCase, topology: :bridge
end
