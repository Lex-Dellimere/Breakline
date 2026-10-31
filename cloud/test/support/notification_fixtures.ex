defmodule Cloud.NotificationFixtures do
  @moduledoc """
  Test helpers for notifications: example targets, channels and a
  `Req.Test` stub for the webhooks that reports each request to the test
  process as `{:webhook, host, path, query, json}`.
  """

  @slack_secret "XyZ0aBcD1eFgH2iJkL3mNoPq"
  @teams_sig "Zx9SIGsecretValue0123456789abcdef"

  def slack_secret, do: @slack_secret
  def teams_sig, do: @teams_sig

  def slack_url, do: "https://hooks.slack.com/services/T0ABC1234/B0DEF5678/#{@slack_secret}"

  def teams_url do
    "https://default0123456789abcdef0123456789.ab.environment.api.powerplatform.com" <>
      "/powerautomate/automations/direct/workflows/0a1b2c3d4e5f/triggers/manual/paths/invoke" <>
      "?api-version=1&sp=%2Ftriggers%2Fmanual%2Frun&sv=1.0&sig=#{@teams_sig}"
  end

  def target_for(:slack), do: slack_url()
  def target_for(:teams), do: teams_url()
  def target_for(:email), do: "alerts-#{System.unique_integer([:positive])}@example.test"
  def target_for(:sms), do: "+61412345678"

  @doc "Creates a channel as `admin`. `attrs` may override kind, name, target, event types."
  def channel!(tenant, admin, attrs \\ %{}) do
    kind = Map.get(attrs, :kind, :slack)

    Cloud.Notifications.create_channel!(
      Map.merge(%{kind: kind, name: "#{kind} channel", target: target_for(kind)}, attrs),
      actor: admin,
      tenant: tenant
    )
  end

  @doc """
  Stubs the webhooks. `status` is the status every request answers, or a
  function of the request count (1-based) returning one.
  """
  def stub_webhooks(status \\ 200) do
    test = self()
    counter = :counters.new(1, [])

    Req.Test.stub(Cloud.Notifications.Webhook, fn conn ->
      :counters.add(counter, 1, 1)
      n = :counters.get(counter, 1)
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:webhook, conn.host, conn.request_path, conn.query_string, Jason.decode!(body)})
      code = if is_function(status), do: status.(n), else: status
      Plug.Conn.send_resp(conn, code, "ok")
    end)
  end
end
