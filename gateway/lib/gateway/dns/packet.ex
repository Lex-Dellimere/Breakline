defmodule Gateway.DNS.Packet do
  @moduledoc """
  Byte-level helpers for DNS messages that do not need a full decode: reading
  the header, and building error and NXDOMAIN replies that echo the client's
  question exactly as sent (including any 0x20 case randomisation).
  """

  import Bitwise

  @formerr 1
  @servfail 2
  @nxdomain 3
  @notimp 4

  @doc "Returns the message id, or nil if the packet is shorter than a header."
  @spec id(binary()) :: non_neg_integer() | nil
  def id(<<id::16, _::binary>>), do: id
  def id(_), do: nil

  @doc "True if the packet has a full header and the QR bit says it is a query."
  @spec query?(binary()) :: boolean()
  def query?(<<_id::16, 0::1, _::15, _counts::binary-size(8), _::binary>>), do: true
  def query?(_), do: false

  @doc "True if the TC (truncated) bit is set."
  @spec truncated?(binary()) :: boolean()
  def truncated?(<<_id::16, _::6, 1::1, _::9, _::binary>>), do: true
  def truncated?(_), do: false

  @doc "Builds a FORMERR reply for a query packet."
  @spec formerr(binary()) :: binary()
  def formerr(query), do: reply(query, @formerr)

  @doc "Builds a SERVFAIL reply for a query packet."
  @spec servfail(binary()) :: binary()
  def servfail(query), do: reply(query, @servfail)

  @doc "Builds an NXDOMAIN reply for a query packet."
  @spec nxdomain(binary()) :: binary()
  def nxdomain(query), do: reply(query, @nxdomain)

  @doc "Builds a NOTIMP reply for a query packet."
  @spec notimp(binary()) :: binary()
  def notimp(query), do: reply(query, @notimp)

  @doc """
  Builds a reply with the given rcode: same id and opcode, QR and RA set, RD and
  CD copied, no records. The question is echoed when the query has exactly one
  well-formed question, otherwise the reply has none.
  """
  @spec reply(binary(), 0..15) :: binary()
  def reply(
        <<id::16, _qr::1, opcode::4, _aa::1, _tc::1, rd::1, _::3, cd::1, _::4, rest::binary>>,
        rcode
      ) do
    question = question_bytes(rest)
    qdcount = if question == <<>>, do: 0, else: 1

    <<id::16, 1::1, opcode::4, 0::1, 0::1, rd::1, 1::1, 0::1, 0::1, cd::1, rcode::4, qdcount::16,
      0::16, 0::16, 0::16, question::binary>>
  end

  # rest starts at the counts; returns the raw single question or <<>>
  defp question_bytes(<<1::16, _an::16, _ns::16, _ar::16, body::binary>>) do
    case name_length(body, 0) do
      {:ok, len} when byte_size(body) >= len + 4 -> binary_part(body, 0, len + 4)
      _ -> <<>>
    end
  end

  defp question_bytes(_), do: <<>>

  defp name_length(body, offset) when offset < 256 do
    case body do
      <<_::binary-size(offset), 0, _::binary>> ->
        {:ok, offset + 1}

      <<_::binary-size(offset), len, _::binary>> when (len &&& 0xC0) == 0xC0 ->
        if byte_size(body) >= offset + 2, do: {:ok, offset + 2}, else: :error

      <<_::binary-size(offset), len, _::binary>> when len < 64 ->
        name_length(body, offset + 1 + len)

      _ ->
        :error
    end
  end

  defp name_length(_body, _offset), do: :error
end
