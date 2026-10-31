defmodule CloudWeb.TotpQrTest do
  use ExUnit.Case, async: true

  test "draws only rect modules from an otpauth uri" do
    uri = "otpauth://totp/Breakline:a%40example.test?secret=JBSWY3DPEHPK3PXP&issuer=Breakline"
    svg = uri |> CloudWeb.TotpQr.svg() |> Phoenix.HTML.safe_to_string()

    assert svg =~ ~r/\A<svg [^>]*id="totp-qr-svg"/
    assert svg =~ "<rect "
    refute svg =~ "JBSWY3DPEHPK3PXP"
    refute svg =~ "<?xml"
    # only svg and rect elements
    assert Regex.scan(~r/<([a-z]+)/, svg) |> Enum.map(&List.last/1) |> Enum.uniq() == [
             "svg",
             "rect"
           ]
  end

  test "draws nothing for anything but an otpauth uri" do
    assert CloudWeb.TotpQr.svg("<script>alert(1)</script>") == nil
    assert CloudWeb.TotpQr.svg("https://example.test") == nil
    assert CloudWeb.TotpQr.svg("otpauth://" <> String.duplicate("x", 5_000)) == nil
  end
end
