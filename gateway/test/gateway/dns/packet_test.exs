defmodule Gateway.DNS.PacketTest do
  use ExUnit.Case, async: true

  alias Gateway.DNS.Packet

  doctest Gateway.DNS.Snapshot

  # id 0xabcd, rd + cd set, one question for "Ab.c" type a class in
  @question <<2, "Ab", 1, "c", 0, 1::16, 1::16>>
  @query <<0xABCD::16, 0::1, 0::4, 0::2, 1::1, 0::3, 1::1, 0::4, 1::16, 0::48, @question::binary>>

  test "nxdomain echoes id, question and rd/cd, sets qr and ra" do
    assert <<0xABCD::16, 1::1, 0::4, 0::1, 0::1, 1::1, 1::1, 0::2, 1::1, 3::4, 1::16, 0::48,
             rest::binary>> = Packet.nxdomain(@query)

    assert rest == @question
  end

  test "servfail and formerr carry their rcodes" do
    assert <<_::28, 2::4, _::binary>> = Packet.servfail(@query)
    assert <<_::28, 1::4, _::binary>> = Packet.formerr(@query)
  end

  test "a broken question is dropped from the reply" do
    broken = <<0xABCD::16, 0x0100::16, 1::16, 0::48, 40, "abc">>
    assert <<0xABCD::16, _::16, 0::16, 0::48>> = Packet.formerr(broken)
  end

  test "two questions are not echoed" do
    two = <<1::16, 0x0100::16, 2::16, 0::48, @question::binary, @question::binary>>
    assert <<1::16, _::16, 0::16, 0::48>> = Packet.formerr(two)
  end

  test "query? needs a full header with qr clear" do
    assert Packet.query?(@query)
    refute Packet.query?(binary_part(@query, 0, 11))
    refute Packet.query?(Packet.nxdomain(@query))
  end

  test "truncated? reads the tc bit" do
    refute Packet.truncated?(@query)
    assert Packet.truncated?(<<1::16, 0::6, 1::1, 0::9, 0::64>>)
  end

  test "random bytes never raise" do
    for _ <- 1..500 do
      bin = <<0::16, 0::1, 0::15>> <> :crypto.strong_rand_bytes(:rand.uniform(100))
      assert is_binary(Packet.servfail(bin))
    end
  end
end
