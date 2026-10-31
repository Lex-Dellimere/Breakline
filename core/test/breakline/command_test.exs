defmodule Breakline.CommandTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Breakline.Command
  alias Breakline.Command.Verifier

  @now ~U[2026-10-31 09:00:00Z]

  setup_all do
    {pub_a, priv_a} = Command.generate_keypair()
    {pub_b, priv_b} = Command.generate_keypair()
    %{keys: %{"k1" => {pub_a, priv_a}, "k2" => {pub_b, priv_b}}}
  end

  defp verifier(keys, opts \\ []) do
    public = Map.new(keys, fn {id, {pub, _}} -> {id, pub} end)
    Verifier.new(Keyword.merge([site_id: "site-a", public_keys: public], opts))
  end

  defp command(attrs \\ []) do
    Command.new!(
      Keyword.merge(
        [
          type: "policy",
          site_id: "site-a",
          policy_version: 1,
          issued_at: @now,
          ttl_seconds: 3600,
          payload: %{"mode" => "enforce", "tool_ids" => ["anydesk"], "windows" => []}
        ],
        attrs
      )
    )
  end

  defp signed(keys, attrs \\ [], key_id \\ "k1") do
    {_pub, priv} = keys[key_id]
    Command.sign(command(attrs), key_id, priv)
  end

  defp put_env(wire, key, value), do: put_in(wire, ["envelope", key], value)

  # generators

  def json_term do
    scalar = one_of([constant(nil), boolean(), integer(), string(:printable, max_length: 8)])

    tree(scalar, fn child ->
      one_of([
        list_of(child, max_length: 3),
        map_of(string(:alphanumeric, max_length: 5), child, max_length: 3)
      ])
    end)
  end

  defp paths(term, prefix \\ [])

  defp paths(map, prefix) when is_map(map) do
    [prefix | Enum.flat_map(map, fn {k, v} -> paths(v, prefix ++ [{:key, k}]) end)]
  end

  defp paths(list, prefix) when is_list(list) do
    [
      prefix
      | list
        |> Enum.with_index()
        |> Enum.flat_map(fn {v, i} -> paths(v, prefix ++ [{:idx, i}]) end)
    ]
  end

  defp paths(_, prefix), do: [prefix]

  defp update_at(_term, [], fun), do: fun.(:value)

  defp update_at(map, [{:key, k} | rest], fun) when is_map(map) do
    case rest do
      [] -> fun.({:in_map, map, k})
      _ -> Map.put(map, k, update_at(map[k], rest, fun))
    end
  end

  defp update_at(list, [{:idx, i} | rest], fun) when is_list(list) do
    List.update_at(list, i, &update_at(&1, rest, fun))
  end

  defp get_at(term, []), do: term
  defp get_at(map, [{:key, k} | rest]), do: get_at(map[k], rest)
  defp get_at(list, [{:idx, i} | rest]), do: get_at(Enum.at(list, i), rest)

  # replace a value, delete a map key, add a map key, or flip one byte of a string
  defp mutate(wire, path, op, new_value, extra_key) do
    current = get_at(wire, path)

    replace = fn
      :value -> new_value
      {:in_map, map, k} -> Map.put(map, k, new_value)
    end

    case {op, path} do
      {:replace, _} ->
        update_at(wire, path, replace)

      {:delete, [_ | _]} ->
        update_at(wire, path, fn
          {:in_map, map, k} -> Map.delete(map, k)
          :value -> new_value
        end)

      {:add, _} when is_map(current) ->
        update_at(wire, path, fn
          :value -> Map.put(current, extra_key, new_value)
          {:in_map, map, k} -> Map.put(map, k, Map.put(current, extra_key, new_value))
        end)

      {:flip, _} when is_binary(current) and current != "" ->
        <<first, rest::binary>> = current
        flipped = <<Bitwise.bxor(first, 1), rest::binary>>

        update_at(wire, path, fn
          :value -> flipped
          {:in_map, map, k} -> Map.put(map, k, flipped)
        end)

      _ ->
        update_at(wire, path, replace)
    end
  end

  describe "new/1" do
    test "fills nonce and issued_at, truncates to seconds and shifts to utc" do
      c =
        Command.new!(
          type: "policy",
          site_id: "s",
          policy_version: 3,
          payload: %{mode: "monitor"},
          ttl_seconds: 60
        )

      assert c.issued_at.microsecond == {0, 0}
      assert c.issued_at.time_zone == "Etc/UTC"
      assert DateTime.diff(c.expires_at, c.issued_at) == 60
      assert {:ok, <<_::binary-size(16)>>} = Base.url_decode64(c.nonce, padding: false)
      assert c.payload == %{"mode" => "monitor"}
      assert c.key_id == nil

      c2 =
        command(
          issued_at: ~U[2026-10-31 09:00:00.123456Z],
          expires_at: ~U[2026-10-31 10:00:00.9Z]
        )

      assert c2.issued_at == ~U[2026-10-31 09:00:00Z]
      assert c2.expires_at == ~U[2026-10-31 10:00:00Z]
    end

    test "nonces are fresh" do
      refute command().nonce == command().nonce
    end

    test "rejects missing or invalid attributes" do
      base = [type: "policy", site_id: "s", policy_version: 1, payload: %{}, ttl_seconds: 60]
      assert {:error, {:missing, :expires_at}} = Command.new(Keyword.delete(base, :ttl_seconds))
      assert {:error, {:missing, :site_id}} = Command.new(Keyword.delete(base, :site_id))

      assert {:error, {:invalid, :policy_version}} =
               Command.new(Keyword.put(base, :policy_version, -1))

      assert {:error, {:invalid, :payload}} =
               Command.new(Keyword.put(base, :payload, %{"f" => 1.5}))

      assert {:error, {:invalid, :payload}} = Command.new(Keyword.put(base, :payload, [1]))
      assert {:error, {:invalid, :ttl_seconds}} = Command.new(Keyword.put(base, :ttl_seconds, 0))
      assert {:error, {:invalid, :nonce}} = Command.new(Keyword.put(base, :nonce, "short"))

      assert {:error, {:invalid, :expires_at}} =
               Command.new(
                 base
                 |> Keyword.delete(:ttl_seconds)
                 |> Keyword.merge(issued_at: @now, expires_at: @now)
               )

      assert_raise ArgumentError, fn -> Command.new!(Keyword.delete(base, :type)) end
    end
  end

  describe "sign/3 and wire encoding" do
    test "wire shape", %{keys: keys} do
      wire = signed(keys)
      assert %{"envelope" => env, "signature" => sig} = wire
      assert env["issued_at"] == "2026-10-31T09:00:00Z"
      assert env["expires_at"] == "2026-10-31T10:00:00Z"
      assert env["key_id"] == "k1"
      assert {:ok, <<_::binary-size(64)>>} = Base.url_decode64(sig, padding: false)
      refute String.contains?(sig, "=")
    end

    test "encode_wire and decode_wire round trip", %{keys: keys} do
      wire = signed(keys)
      json = Command.encode_wire(wire)
      assert {:ok, ^wire} = Command.decode_wire(json)
      assert {:error, :malformed} = Command.decode_wire("not json")
      assert {:error, :malformed} = Command.decode_wire("[1]")
    end
  end

  describe "verify/3" do
    test "happy path from a map and from json", %{keys: keys} do
      wire = signed(keys, policy_version: 5)
      v = verifier(keys)

      assert {:ok, %Command{} = c, v2} = Command.verify(wire, v, @now)
      assert c.policy_version == 5
      assert c.key_id == "k1"
      assert c.issued_at == @now
      assert c.payload["tool_ids"] == ["anydesk"]
      assert v2.last_version == 5
      assert v2.seen_nonces == %{c.nonce => c.expires_at}

      assert {:ok, ^c, ^v2} = Command.verify(Command.encode_wire(wire), v, @now)
    end

    test "a non-canonically formatted json with the same envelope still verifies", %{keys: keys} do
      wire = signed(keys)
      pretty = wire |> :json.encode() |> IO.iodata_to_binary() |> then(&(" " <> &1 <> "\n"))
      assert {:ok, _, _} = Command.verify(pretty, verifier(keys), @now)
    end

    test ":malformed", %{keys: keys} do
      wire = signed(keys)
      v = verifier(keys)

      bad = [
        "not json",
        "[]",
        Map.delete(wire, "signature"),
        Map.put(wire, "extra", 1),
        Map.put(wire, "envelope", "x"),
        Map.put(wire, "signature", 1),
        Map.put(wire, "signature", "!!!"),
        Map.put(wire, "signature", Base.url_encode64(<<1, 2, 3>>, padding: false)),
        Map.put(wire, "signature", Base.url_encode64(:binary.copy(<<0>>, 64))),
        put_env(wire, "extra", 1),
        update_in(wire["envelope"], &Map.delete(&1, "nonce")),
        put_env(wire, "type", 1),
        put_env(wire, "type", ""),
        put_env(wire, "site_id", nil),
        put_env(wire, "key_id", ""),
        put_env(wire, "policy_version", -1),
        put_env(wire, "policy_version", "1"),
        put_env(wire, "policy_version", 1.0),
        put_env(wire, "payload", [1]),
        put_env(wire, "payload", %{"x" => 1.5}),
        put_env(wire, "issued_at", "2026-10-31T09:00:00+00:00"),
        put_env(wire, "issued_at", "2026-10-31T09:00:00.000Z"),
        put_env(wire, "issued_at", "2026-10-31T19:00:00+10:00"),
        put_env(wire, "expires_at", "tomorrow"),
        put_env(wire, "expires_at", "2026-10-31T09:00:00Z"),
        put_env(wire, "nonce", "abc"),
        put_env(wire, "nonce", Base.url_encode64(:crypto.strong_rand_bytes(16))),
        put_env(
          wire,
          "nonce",
          Base.encode64(<<0xFB, 0xFF>> <> :crypto.strong_rand_bytes(14), padding: false)
        ),
        42
      ]

      for input <- bad do
        assert Command.verify(input, v, @now) == {:error, :malformed}, inspect(input)
      end
    end

    test "verify never creates atoms from input", %{keys: keys} do
      wire = signed(keys) |> put_env("brand_new_key_#{System.unique_integer([:positive])}", 1)
      name = wire["envelope"] |> Map.keys() |> Enum.find(&String.starts_with?(&1, "brand_new"))

      assert {:error, :malformed} =
               Command.verify(Command.encode_wire(wire), verifier(keys), @now)

      assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
    end

    test ":unknown_key", %{keys: keys} do
      wire = signed(keys)
      v = verifier(Map.take(keys, ["k2"]))
      assert Command.verify(wire, v, @now) == {:error, :unknown_key}
    end

    test ":bad_signature from the wrong key under a known key id", %{keys: keys} do
      {_, priv_b} = keys["k2"]
      wire = Command.sign(command(), "k1", priv_b)
      assert Command.verify(wire, verifier(keys), @now) == {:error, :bad_signature}
    end

    test "flipping any single envelope field gives :bad_signature", %{keys: keys} do
      wire = signed(keys)
      env = wire["envelope"]
      v = verifier(keys)

      flips = %{
        "type" => "policy2",
        "site_id" => "site-b",
        "policy_version" => env["policy_version"] + 1,
        "issued_at" => "2026-10-31T09:00:01Z",
        "expires_at" => "2026-10-31T09:59:59Z",
        "nonce" => Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false),
        "payload" => Map.put(env["payload"], "mode", "monitor"),
        "key_id" => "k2"
      }

      assert Map.keys(flips) |> Enum.sort() == Map.keys(env) |> Enum.sort()

      for {field, value} <- flips do
        assert Command.verify(put_env(wire, field, value), v, @now) == {:error, :bad_signature},
               field
      end
    end

    test "flipping any bit of the signature gives :bad_signature", %{keys: keys} do
      wire = signed(keys)
      {:ok, sig} = Base.url_decode64(wire["signature"], padding: false)
      v = verifier(keys)

      for bit <- 0..(64 * 8 - 1) do
        <<pre::bitstring-size(bit), b::1, post::bitstring>> = sig
        flipped = <<pre::bitstring, 1 - b::1, post::bitstring>>
        tampered = Map.put(wire, "signature", Base.url_encode64(flipped, padding: false))
        assert Command.verify(tampered, v, @now) == {:error, :bad_signature}
      end
    end

    test ":wrong_site: a command for site a fails on a site b verifier", %{keys: keys} do
      wire = signed(keys)

      assert Command.verify(wire, verifier(keys, site_id: "site-b"), @now) ==
               {:error, :wrong_site}

      assert {:ok, _, _} = Command.verify(wire, verifier(keys), @now)
    end

    test ":not_yet_valid respects max_skew_seconds", %{keys: keys} do
      v = verifier(keys)
      wire = signed(keys, issued_at: DateTime.add(@now, 301))
      assert Command.verify(wire, v, @now) == {:error, :not_yet_valid}

      wire = signed(keys, issued_at: DateTime.add(@now, 300))
      assert {:ok, _, _} = Command.verify(wire, v, @now)

      wire = signed(keys, issued_at: DateTime.add(@now, 10))

      assert Command.verify(wire, verifier(keys, max_skew_seconds: 0), @now) ==
               {:error, :not_yet_valid}
    end

    test ":expired when now >= expires_at", %{keys: keys} do
      wire = signed(keys)
      v = verifier(keys)
      assert Command.verify(wire, v, ~U[2026-10-31 10:00:00Z]) == {:error, :expired}
      assert Command.verify(wire, v, ~U[2026-11-01 00:00:00Z]) == {:error, :expired}
      assert {:ok, _, _} = Command.verify(wire, v, ~U[2026-10-31 09:59:59Z])
    end

    test ":ttl_too_long", %{keys: keys} do
      v = verifier(keys)
      assert {:ok, _, _} = Command.verify(signed(keys, ttl_seconds: 86_400), v, @now)
      assert Command.verify(signed(keys, ttl_seconds: 86_401), v, @now) == {:error, :ttl_too_long}

      assert Command.verify(
               signed(keys, ttl_seconds: 61),
               verifier(keys, max_ttl_seconds: 60),
               @now
             ) ==
               {:error, :ttl_too_long}
    end

    test ":stale_version: versions must strictly increase", %{keys: keys} do
      v = verifier(keys)
      assert Command.verify(signed(keys, policy_version: 0), v, @now) == {:error, :stale_version}

      {:ok, _, v} = Command.verify(signed(keys, policy_version: 3), v, @now)
      assert Command.verify(signed(keys, policy_version: 3), v, @now) == {:error, :stale_version}
      assert Command.verify(signed(keys, policy_version: 2), v, @now) == {:error, :stale_version}
      assert {:ok, _, v} = Command.verify(signed(keys, policy_version: 4), v, @now)

      assert {:ok, _, %{last_version: 10}} =
               Command.verify(signed(keys, policy_version: 10), v, @now)
    end

    test "an exact replay is rejected (stale version is checked first)", %{keys: keys} do
      wire = signed(keys)
      {:ok, _, v} = Command.verify(wire, verifier(keys), @now)
      assert Command.verify(wire, v, @now) == {:error, :stale_version}
    end

    test ":replayed_nonce", %{keys: keys} do
      wire = signed(keys, policy_version: 2)
      {:ok, c, v} = Command.verify(wire, verifier(keys), @now)

      # a fresh version reusing an accepted nonce
      reused = signed(keys, policy_version: 3, nonce: c.nonce)
      assert Command.verify(reused, v, @now) == {:error, :replayed_nonce}

      # the same command against state that lost its version but kept the nonce cache
      assert Command.verify(wire, %{v | last_version: 1}, @now) == {:error, :replayed_nonce}
    end

    test "expired nonces are pruned on every verify", %{keys: keys} do
      old = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
      live = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)

      v =
        verifier(keys,
          seen_nonces: %{old => ~U[2026-10-31 08:59:59Z], live => ~U[2026-10-31 12:00:00Z]}
        )

      {:ok, c, v2} = Command.verify(signed(keys), v, @now)
      assert Map.keys(v2.seen_nonces) |> Enum.sort() == Enum.sort([live, c.nonce])

      # a pruned nonce no longer blocks a command
      assert {:ok, _, _} = Command.verify(signed(keys, policy_version: 2, nonce: old), v2, @now)
    end

    test "key rotation: both key ids verify, and state carries across", %{keys: keys} do
      v = verifier(keys)
      {:ok, c1, v} = Command.verify(signed(keys, [policy_version: 1], "k1"), v, @now)
      {:ok, c2, v} = Command.verify(signed(keys, [policy_version: 2], "k2"), v, @now)
      assert {c1.key_id, c2.key_id} == {"k1", "k2"}
      assert v.last_version == 2

      # once k1 is retired its commands stop verifying
      retired = %{v | public_keys: Map.delete(v.public_keys, "k1")}

      assert Command.verify(signed(keys, [policy_version: 3], "k1"), retired, @now) ==
               {:error, :unknown_key}

      assert {:ok, _, _} = Command.verify(signed(keys, [policy_version: 3], "k2"), retired, @now)
    end

    test "errors come back in the documented order", %{keys: keys} do
      # expired, stale and for another site, signed with an unknown key: unknown_key wins
      wire =
        signed(keys, site_id: "site-b", policy_version: 0, issued_at: ~U[2020-01-01 00:00:00Z])

      assert Command.verify(wire, verifier(Map.take(keys, ["k2"])), @now) ==
               {:error, :unknown_key}

      assert Command.verify(wire, verifier(keys), @now) == {:error, :wrong_site}
      assert Command.verify(wire, verifier(keys, site_id: "site-b"), @now) == {:error, :expired}

      wire = signed(keys, policy_version: 0, ttl_seconds: 90_000)
      assert Command.verify(wire, verifier(keys), @now) == {:error, :ttl_too_long}
    end

    property "random mutations of the wire map never verify", %{keys: keys} do
      wire = signed(keys)
      v = verifier(keys)
      all_paths = paths(wire)

      check all(
              path <- member_of(all_paths),
              op <- member_of([:replace, :delete, :add, :flip]),
              new_value <- json_term(),
              extra_key <- string(:alphanumeric, min_length: 1, max_length: 6),
              max_runs: 500
            ) do
        mutated = mutate(wire, path, op, new_value, extra_key)

        if mutated != wire do
          assert {:error, _} = Command.verify(mutated, v, @now)
          assert {:error, _} = Command.verify(Breakline.CanonicalJSON.encode!(mutated), v, @now)
        end
      end
    end

    property "every honestly signed command verifies once", %{keys: keys} do
      check all(
              version <- positive_integer(),
              ttl <- integer(1..86_400),
              skew <- integer(-3600..300),
              payload <- map_of(string(:alphanumeric, max_length: 6), json_term(), max_length: 4),
              key_id <- member_of(["k1", "k2"])
            ) do
        issued_at = DateTime.add(@now, skew)
        now = if DateTime.diff(DateTime.add(issued_at, ttl), @now) > 0, do: @now, else: issued_at

        wire =
          signed(
            keys,
            [policy_version: version, issued_at: issued_at, ttl_seconds: ttl, payload: payload],
            key_id
          )

        assert {:ok, c, v} = Command.verify(wire, verifier(keys), now)
        assert c.payload == payload
        assert {:error, _} = Command.verify(wire, v, now)
      end
    end
  end
end
