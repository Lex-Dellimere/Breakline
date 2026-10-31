defmodule Cloud.Notifications.TargetTest do
  use ExUnit.Case, async: true

  import Cloud.NotificationFixtures

  alias Cloud.Notifications.Target

  describe "slack" do
    test "accepts an incoming webhook url" do
      assert {:ok, url} = Target.validate(:slack, slack_url())
      assert url == slack_url()
      assert {:ok, _} = Target.validate(:slack, "  " <> slack_url() <> " ")
      assert {:ok, _} = Target.validate(:slack, String.replace(slack_url(), "hooks", "HOOKS"))
      assert {:ok, _} = Target.validate(:slack, String.replace(slack_url(), ".com/", ".com:443/"))
    end

    test "refuses anything else" do
      path = "/services/T0ABC1234/B0DEF5678/secret"

      for url <- [
            "http://hooks.slack.com" <> path,
            "https://hooks.slack.com.evil.example" <> path,
            "https://evil.example/hooks.slack.com" <> path,
            "https://evilhooks.slack.com" <> path,
            "https://hooks.slack.com." <> path,
            "https://slack.com" <> path,
            "https://hooks.slack.com@evil.example" <> path,
            "https://user:pass@hooks.slack.com" <> path,
            "https://evil.example#@hooks.slack.com" <> path,
            "https://evil.example\\@hooks.slack.com" <> path,
            "https://hooks.slack.com%2eevil.example" <> path,
            "https://hooks.slack.com:8443" <> path,
            "https://54.0.0.1" <> path,
            "https://[::1]" <> path,
            "https://127.0.0.1" <> path,
            "https://2130706433" <> path,
            "https://hooks.slack.com/api/chat.postMessage",
            "https://hooks.slack.com/services/T0/B0",
            "https://hooks.slack.com/services/T0/B0/x/../../../admin",
            "https://hooks.slack.com" <> path <> "?redirect=http://169.254.169.254",
            "https://hooks.slack.com" <> path <> "#x",
            "https://hooks.slack.com" <> path <> "\nHost: evil",
            "file:///etc/passwd",
            "gopher://hooks.slack.com" <> path,
            "",
            nil
          ] do
        assert {:error, _} = Target.validate(:slack, url), "accepted #{inspect(url)}"
      end
    end
  end

  describe "teams" do
    test "accepts a workflows webhook url, with or without a scale unit" do
      assert {:ok, _} = Target.validate(:teams, teams_url())

      assert {:ok, _} =
               Target.validate(
                 :teams,
                 String.replace(teams_url(), "/direct/workflows/", "/direct/cu/20/workflows/")
               )
    end

    test "refuses retired and lookalike hosts" do
      path = "/powerautomate/automations/direct/workflows/abc/triggers/manual/paths/invoke?sig=x"

      for url <- [
            # retired office 365 connector and logic apps trigger hosts
            "https://contoso.webhook.office.com/webhookb2/abc",
            "https://prod-12.australiaeast.logic.azure.com/workflows/abc/triggers/manual/paths/invoke?sig=x",
            "http://default01.ab.environment.api.powerplatform.com" <> path,
            "https://environment.api.powerplatform.com" <> path,
            "https://default01.ab.environment.api.powerplatform.com.evil.example" <> path,
            "https://default01.ab.environment-api.powerplatform.com" <> path,
            "https://evil.example/default01.ab.environment.api.powerplatform.com" <> path,
            "https://a@default01.ab.environment.api.powerplatform.com" <> path,
            "https://default01.ab.environment.api.powerplatform.com:444" <> path,
            "https://default01.ab.environment.api.powerplatform.com/api/other",
            "https://default01.ab.environment.api.powerplatform.com/powerautomate/automations/direct/../../admin",
            "https://-bad.environment.api.powerplatform.com" <> path,
            "https://10.0.0.1" <> path,
            "https://make.powerautomate.com" <> path
          ] do
        assert {:error, _} = Target.validate(:teams, url), "accepted #{inspect(url)}"
      end
    end

    test "a slack url is not a teams url and the other way round" do
      assert {:error, _} = Target.validate(:teams, slack_url())
      assert {:error, _} = Target.validate(:slack, teams_url())
    end
  end

  test "email and sms targets" do
    assert {:ok, "ops@example.com"} = Target.validate(:email, " Ops@Example.com ")
    assert {:error, _} = Target.validate(:email, "not an email")
    assert {:error, _} = Target.validate(:email, "a@b")
    assert {:error, _} = Target.validate(:email, "a@b.com, c@d.com")
    assert {:ok, "+61412345678"} = Target.validate(:sms, "+61412345678")
    assert {:error, _} = Target.validate(:sms, "0412345678")
    assert {:error, _} = Target.validate(:sms, "+61 412 345 678")
    assert {:error, _} = Target.validate(:sms, "+0412345678")
  end

  test "masks never show the webhook secret" do
    slack = Target.mask(:slack, slack_url())
    assert slack =~ "hooks.slack.com"
    refute slack =~ slack_secret()
    refute slack =~ "T0ABC1234"

    teams = Target.mask(:teams, teams_url())
    assert teams =~ "environment.api.powerplatform.com"
    refute teams =~ teams_sig()

    assert Target.mask(:email, "ops@example.com") == "o•••@example.com"
    assert Target.mask(:sms, "+61412345678") == "+61•••••678"
  end
end
