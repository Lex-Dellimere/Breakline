defmodule CloudWeb.TotpQr do
  @moduledoc """
  The QR code of a TOTP setup's `otpauth://` uri, as an inline SVG drawn on
  the server with eqrcode (D39), so the setup step needs no client JS.

  The SVG is built from the uri alone (the uri `Cloud.Accounts.Totp.begin_setup/1`
  returns), with fixed colours and size. eqrcode's SVG holds only `<rect>`
  elements for the modules, never the encoded text. It is checked to be
  exactly that shape before it is marked safe, so `Phoenix.HTML.raw/1` only
  ever sees eqrcode's own output.
  """

  # an svg element whose children are only self-closing rect elements
  @shape ~r/\A<svg [^<>]*>(\s*<rect [^<>]*\/>)*\s*<\/svg>\z/

  @doc """
  The QR code of `uri` as safe inline SVG, or nil when the uri is not an
  `otpauth://` uri or cannot be encoded.
  """
  @spec svg(String.t()) :: Phoenix.HTML.safe() | nil
  def svg("otpauth://" <> _ = uri) do
    svg =
      uri
      |> EQRCode.encode(:m)
      |> EQRCode.svg(
        viewbox: true,
        color: "#000",
        background_color: "#FFF",
        id: "totp-qr-svg",
        class: "size-full"
      )
      # the xml prolog belongs to a standalone file, not to inline html
      |> String.replace(~r/\A<\?xml[^>]*\?>\s*/, "")
      |> String.trim()

    if Regex.match?(@shape, svg), do: Phoenix.HTML.raw(svg)
  rescue
    _ -> nil
  end

  def svg(_uri), do: nil
end
