defmodule Cloud.Accounts.Changes.RequireStepUp do
  @moduledoc """
  Makes an action require a fresh passkey assertion bound to exactly this
  action (threat model T5).

      argument :step_up_id, :uuid
      change {Cloud.Accounts.Changes.RequireStepUp,
              purpose: :open_window, subject: :site_id, params: [:site_id, :minutes]}

  Inside the action's transaction (a `before_action` hook, after the action's
  policies passed) it consumes the `Cloud.Accounts.StepUp` named by the
  `step_up_id` argument. The step-up must belong to the actor, be verified,
  unexpired and unused, and match the action exactly: its `purpose`, its
  `subject_id` (the value of the `:subject` field) and its `payload_hash`
  (`Cloud.Accounts.StepUps.payload_hash/1` of the `:params` fields, read from
  arguments or attributes). Anything else fails the action with an
  `Ash.Error.Changes.InvalidArgument` on `:step_up_id`, and consuming rolls
  back with it, so a failed action never spends the step-up.

  There is no bypass for `authorize?: false` or a nil actor.

  A trusted caller that consumed one step-up for several records itself (for
  example `Cloud.Access.unlock/3`) passes the consumed `%StepUp{}` as the
  changeset context `step_up:`. It is accepted when it is consumed, belongs
  to the actor, has the same purpose, and its subject is the value of the
  `:consumed_subject` field (option, default the `:subject` field).
  """

  use Ash.Resource.Change

  alias Cloud.Accounts.{StepUp, StepUps}

  @impl true
  def init(opts) do
    cond do
      opts[:purpose] not in StepUp.purposes() ->
        {:error, "unknown purpose #{inspect(opts[:purpose])}"}

      not is_atom(opts[:subject]) ->
        {:error, "subject must be a field name"}

      not is_list(opts[:params]) ->
        {:error, "params must be a list of fields"}

      true ->
        {:ok, Keyword.put_new(opts, :consumed_subject, opts[:subject])}
    end
  end

  @impl true
  def change(changeset, opts, context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      case check(changeset, opts, context.actor) do
        {:ok, _step_up} -> changeset
        {:error, reason} -> Ash.Changeset.add_error(changeset, StepUps.error(reason))
      end
    end)
  end

  @impl true
  def atomic(changeset, opts, context), do: {:ok, change(changeset, opts, context)}

  defp check(changeset, opts, actor) do
    case changeset.context[:step_up] do
      %StepUp{} = consumed ->
        StepUps.check_consumed(
          consumed,
          actor,
          opts[:purpose],
          field(changeset, opts[:consumed_subject])
        )

      _ ->
        StepUps.consume(
          Ash.Changeset.get_argument(changeset, :step_up_id),
          actor,
          opts[:purpose],
          field(changeset, opts[:subject]),
          Map.new(opts[:params], &{&1, field(changeset, &1)}),
          changeset.to_tenant
        )
    end
  end

  defp field(changeset, name) do
    case Ash.Changeset.fetch_argument(changeset, name) do
      {:ok, value} -> value
      :error -> Ash.Changeset.get_attribute(changeset, name)
    end
  end
end
