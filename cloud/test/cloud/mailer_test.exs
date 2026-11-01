defmodule Cloud.MailerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Swoosh.Email

  alias Cloud.Mailer.NotConfigured

  test "every email goes out from the configured sender" do
    assert {name, address} = Cloud.Mailer.from()
    assert is_binary(name) and address =~ "@"
  end

  describe "without a mail provider" do
    setup do
      email =
        new()
        |> from(Cloud.Mailer.from())
        |> to({"Pat", "pat@example.test"})
        |> subject("Confirm your email address")
        |> html_body(~s(<a href="https://cloud.test/confirm_new_user/secret-token">confirm</a>))

      %{email: email}
    end

    test "nothing is sent and the caller is told so", %{email: email} do
      capture_log(fn ->
        assert {:error, :no_mail_provider} = NotConfigured.deliver(email, [])
      end)
    end

    test "the log names the recipient and subject, never the body", %{email: email} do
      log = capture_log(fn -> NotConfigured.deliver(email, []) end)

      assert log =~ "pat@example.test"
      assert log =~ "Confirm your email address"
      assert log =~ "POSTMARK_API_KEY"
      refute log =~ "secret-token"
    end
  end
end
