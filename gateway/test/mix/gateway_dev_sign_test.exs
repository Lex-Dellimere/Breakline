defmodule Mix.Tasks.Gateway.Dev.SignTest do
  use ExUnit.Case, async: true

  alias Breakline.Policy
  alias Mix.Tasks.Gateway.Dev.Sign

  @examples Path.expand("../../priv/dev/examples", __DIR__)

  for name <- ~w(locked open_now monitor) do
    test "example #{name}.exs builds a valid policy" do
      path = Path.join(@examples, "#{unquote(name)}.exs")
      assert {:ok, %Policy{site_id: "s", version: 9}} = Sign.build_policy(path, "s", 9)
    end
  end

  test "open_now is open when signed" do
    {:ok, policy} = Sign.build_policy(Path.join(@examples, "open_now.exs"), "s", 1)
    assert Breakline.Schedule.state_at(policy, DateTime.utc_now()) == :open
  end

  test "locked is locked" do
    {:ok, policy} = Sign.build_policy(Path.join(@examples, "locked.exs"), "s", 1)
    assert Breakline.Schedule.state_at(policy, DateTime.utc_now()) == :locked
    assert policy.tool_ids == ["anydesk", "n_central"]
  end

  test "json policies use the wire form" do
    {:ok, policy} = Sign.build_policy(Path.join(@examples, "locked.exs"), "s", 1)
    dir = Gateway.TestSupport.tmp_dir("sign")
    path = Path.join(dir, "p.json")
    File.write!(path, policy |> Policy.to_map() |> Map.delete("site_id") |> JSON.encode!())

    assert {:ok, %Policy{site_id: "t", version: 2}} = Sign.build_policy(path, "t", 2)
  end
end
