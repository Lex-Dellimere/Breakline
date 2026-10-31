defmodule CloudWeb.AuthLive.Helpers do
  @moduledoc """
  Shared plumbing for the mishka based auth liveviews.

  Mirrors what ash_authentication_phoenix's built-in password components do
  (strategy lookup, ash_phoenix forms for strategy actions, strategy route paths)
  without rendering any of its ui.
  """

  alias AshAuthentication.{Info, Strategy}
  alias AshPhoenix.Form

  @resource Cloud.Accounts.User
  # must match the `path:` given to `auth_routes` in the router
  @auth_routes_prefix "/auth"

  @doc "the password strategy for users."
  def password_strategy, do: Info.strategy!(@resource, :password)

  @doc "the email confirmation add-on strategy for users."
  def confirm_strategy, do: Info.strategy!(@resource, :confirm_new_user)

  @doc "the param key the forms submit under (e.g. `\"user\"`)."
  def subject_name, do: @resource |> Info.authentication_subject_name!() |> to_string()

  @doc "pulls the subject's params out of a form submit."
  def subject_params(params), do: Map.get(params, subject_name(), %{})

  @doc """
  builds the path of a strategy phase route, e.g. `/auth/user/password/sign_in`.
  """
  def auth_path(strategy, phase, query \\ %{}) do
    {path, _phase} =
      strategy
      |> Strategy.routes()
      |> Enum.find(&(elem(&1, 1) == phase))

    uri = %URI{path: Path.join(@auth_routes_prefix, path)}

    uri =
      if query == %{} or query == [],
        do: uri,
        else: %URI{uri | query: URI.encode_query(query)}

    URI.to_string(uri)
  end

  @doc """
  an ash_phoenix form for one of the strategy's actions, with the context
  ash_authentication expects when the action is run through a strategy.
  """
  def form(strategy, action_name, context \\ %{}) do
    context =
      Ash.Helpers.deep_merge_maps(context, %{
        strategy: strategy,
        private: %{ash_authentication?: true}
      })

    @resource
    |> Form.for_action(action_name,
      domain: Info.authentication_domain!(@resource),
      as: subject_name(),
      id:
        "#{subject_name()}-#{Strategy.name(strategy)}-#{action_name}" |> String.replace("_", "-"),
      context: context
    )
    |> Phoenix.Component.to_form()
  end
end
