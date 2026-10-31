defmodule Breakline.CanonicalJSONTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Breakline.CanonicalJSON

  # generators

  def json_string do
    one_of([
      string(:utf8, max_length: 12),
      string(:printable, max_length: 12),
      string(Enum.concat([0..0x1F, [?", ?\\, ?/, 0x7F]]), max_length: 6)
    ])
  end

  def json_scalar do
    one_of([constant(nil), boolean(), integer(), big_integer(), json_string()])
  end

  defp big_integer, do: map(integer(), &(&1 * 1_000_000_000_000_000_000))

  def json_term do
    tree(json_scalar(), fn child ->
      one_of([
        list_of(child, max_length: 4),
        map_of(json_string(), child, max_length: 4)
      ])
    end)
  end

  defp strip_ws_outside_strings(bin) do
    # drop string contents so only structural bytes remain
    Regex.replace(~r/"(?:[^"\\]|\\.)*"/, bin, "\"\"")
  end

  describe "encode/1 vectors" do
    test "scalars" do
      assert CanonicalJSON.encode!(nil) == "null"
      assert CanonicalJSON.encode!(true) == "true"
      assert CanonicalJSON.encode!(false) == "false"
      assert CanonicalJSON.encode!(0) == "0"
      assert CanonicalJSON.encode!(-42) == "-42"
      assert CanonicalJSON.encode!(12_345_678_901_234_567_890) == "12345678901234567890"
    end

    test "objects are sorted by utf-8 bytes with no whitespace" do
      assert CanonicalJSON.encode!(%{"b" => 1, "a" => [1, 2, %{}], "B" => []}) ==
               ~s({"B":[],"a":[1,2,{}],"b":1})

      # "é" (0xc3 0xa9) sorts after "z" (0x7a)
      assert CanonicalJSON.encode!(%{"é" => 1, "z" => 2, "" => 3}) == ~s({"":3,"z":2,"é":1})
    end

    test "atom keys become strings" do
      assert CanonicalJSON.encode!(%{b: 1, a: %{c: nil}}) == ~s({"a":{"c":null},"b":1})
    end

    test "minimal string escaping" do
      assert CanonicalJSON.encode!(~s(a"b\\c)) == ~S("a\"b\\c")
      assert CanonicalJSON.encode!("\b\f\n\r\t") == ~S("\b\f\n\r\t")
      assert CanonicalJSON.encode!(<<0, 1, 0x1F>>) == ~S("\u0000\u0001\u001f")
      assert CanonicalJSON.encode!(<<0x0B, 0x1A>>) == ~S("\u000b\u001a")
      assert CanonicalJSON.encode!("/") == ~S("/")
      assert CanonicalJSON.encode!(<<0x7F>>) == <<?", 0x7F, ?">>
      assert CanonicalJSON.encode!("é€😀") == ~s("é€😀")
      assert CanonicalJSON.encode!(" ") == ~s(" ")
    end
  end

  describe "encode/1 rejects" do
    test "floats" do
      assert {:error, {:unsupported, 1.0}} = CanonicalJSON.encode(1.0)
      assert {:error, {:unsupported, 0.5}} = CanonicalJSON.encode(%{"a" => [0.5]})
    end

    test "atoms as values" do
      assert {:error, {:unsupported, :foo}} = CanonicalJSON.encode(:foo)
      assert {:error, {:unsupported, :foo}} = CanonicalJSON.encode(%{"a" => :foo})
    end

    test "tuples, structs, pids, refs, funs and improper lists" do
      assert {:error, {:unsupported, _}} = CanonicalJSON.encode({1, 2})
      assert {:error, {:unsupported, _}} = CanonicalJSON.encode(~U[2026-10-31 09:00:00Z])
      assert {:error, {:unsupported, _}} = CanonicalJSON.encode(%{"t" => ~D[2026-10-31]})
      assert {:error, {:unsupported, _}} = CanonicalJSON.encode(self())
      assert {:error, {:unsupported, _}} = CanonicalJSON.encode(make_ref())
      assert {:error, {:unsupported, _}} = CanonicalJSON.encode(fn -> :ok end)
      assert {:error, {:unsupported, _}} = CanonicalJSON.encode([1 | 2])
    end

    test "invalid utf-8 in values and keys" do
      assert {:error, {:invalid_utf8, <<0xFF>>}} = CanonicalJSON.encode(<<0xFF>>)
      assert {:error, {:invalid_utf8, _}} = CanonicalJSON.encode(%{<<0xC3>> => 1})
    end

    test "non-string keys and colliding atom and string keys" do
      assert {:error, {:invalid_key, 1}} = CanonicalJSON.encode(%{1 => 1})
      assert {:error, {:duplicate_key, "a"}} = CanonicalJSON.encode(%{:a => 1, "a" => 2})
    end

    test "encode! raises" do
      assert_raise ArgumentError, fn -> CanonicalJSON.encode!(1.5) end
    end
  end

  describe "properties" do
    property "decode(encode(x)) == x" do
      check all(x <- json_term()) do
        assert {:ok, ^x} = x |> CanonicalJSON.encode!() |> CanonicalJSON.decode()
      end
    end

    property "encoding does not depend on map construction order" do
      # up to 40 keys so large (hash) maps are covered as well as small sorted ones
      check all(
              pairs <-
                uniq_list_of({json_string(), json_term()}, uniq_fun: &elem(&1, 0), max_length: 40),
              seed <- integer()
            ) do
        build = fn list -> Enum.reduce(list, %{}, fn {k, v}, m -> Map.put(m, k, v) end) end
        :rand.seed(:exsss, {seed, 1, 2})
        shuffled = Enum.shuffle(pairs)

        expected =
          pairs
          |> Enum.sort()
          |> Enum.map(fn {k, v} ->
            CanonicalJSON.encode!(k) <> ":" <> CanonicalJSON.encode!(v)
          end)
          |> Enum.join(",")

        for list <- [pairs, Enum.reverse(pairs), shuffled] do
          assert CanonicalJSON.encode!(build.(list)) == "{" <> expected <> "}"
        end
      end
    end

    property "output has no whitespace outside strings" do
      check all(x <- json_term()) do
        refute x |> CanonicalJSON.encode!() |> strip_ws_outside_strings() =~ ~r/\s/
      end
    end

    property "output is valid utf-8 and contains no raw control characters" do
      check all(x <- json_term()) do
        out = CanonicalJSON.encode!(x)
        assert String.valid?(out)
        refute out =~ ~r/[\x00-\x1f]/
      end
    end

    property "atom keys encode the same as their string keys" do
      check all(m <- map_of(atom(:alphanumeric), json_scalar(), max_length: 6)) do
        stringified = Map.new(m, fn {k, v} -> {Atom.to_string(k), v} end)
        assert CanonicalJSON.encode!(m) == CanonicalJSON.encode!(stringified)
      end
    end
  end
end
