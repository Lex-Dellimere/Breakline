defmodule Gateway.Traffic.RouterTest do
  # real packets through the prod release, router topology. see Gateway.TrafficCase
  use Gateway.TrafficCase, topology: :router
end
