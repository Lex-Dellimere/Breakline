defmodule CloudWeb.StepUp do
  @moduledoc """
  The LiveView side of a passkey step-up (`Cloud.Accounts.StepUps`).

  `start/6` begins a step-up for one action and asks the
  `CloudWeb.PasskeyCeremony` hook for an assertion. The pending action is
  kept in the socket (`:step_up` assign), never in the browser. When the hook
  answers with `"passkey_assertion"`, the LiveView calls `verify/2`, which
  verifies the assertion for the pending step-up and hands back the action to
  run with the verified step-up's id. The resource action then consumes the
  step-up itself, so the server never trusts the browser's word that a
  ceremony happened.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [push_event: 3, put_flash: 3]

  alias Cloud.Accounts.StepUps

  @ref "step-up"

  @doc "The `ref` step-up ceremonies are pushed with."
  def ref, do: @ref

  @doc """
  Begins a step-up as the socket's `current_user` and pushes the passkey
  prompt. `action` is any term the LiveView uses to remember what to run
  once verified. Puts an error flash when the step-up cannot begin.
  """
  @spec start(Phoenix.LiveView.Socket.t(), atom(), String.t(), map(), keyword(), term()) ::
          Phoenix.LiveView.Socket.t()
  def start(socket, purpose, subject_id, params, opts, action) do
    user = socket.assigns.current_user

    case StepUps.begin(user, purpose, subject_id, params, opts) do
      {:ok, step_up, options} ->
        socket
        |> assign(:step_up, %{id: step_up.id, action: action})
        |> push_event("passkey:get", Map.put(options, :ref, @ref))

      {:error, reason} ->
        socket
        |> assign(:step_up, nil)
        |> put_flash(:error, sentence(StepUps.message(reason)))
    end
  end

  @doc """
  Verifies the hook's assertion for the pending step-up. Returns
  `{:ok, action, step_up_id, socket}` or `{:error, socket}` with an error
  flash. The pending step-up is cleared either way.
  """
  @spec verify(Phoenix.LiveView.Socket.t(), map()) ::
          {:ok, term(), String.t(), Phoenix.LiveView.Socket.t()}
          | {:error, Phoenix.LiveView.Socket.t()}
  def verify(socket, assertion) do
    case socket.assigns[:step_up] do
      %{id: id, action: action} ->
        socket = assign(socket, :step_up, nil)

        case StepUps.verify(id, assertion, actor: socket.assigns.current_user) do
          {:ok, step_up} ->
            {:ok, action, step_up.id, socket}

          {:error, reason} ->
            {:error, put_flash(socket, :error, sentence(StepUps.message(reason)))}
        end

      _ ->
        {:error, put_flash(socket, :error, "There is no passkey approval waiting")}
    end
  end

  @doc "Drops the pending step-up after the hook reported a failed prompt."
  @spec cancel(Phoenix.LiveView.Socket.t(), map()) :: Phoenix.LiveView.Socket.t()
  def cancel(socket, params) do
    socket
    |> assign(:step_up, nil)
    |> put_flash(:error, CloudWeb.PasskeyCeremony.error_message(params))
  end

  @doc "A flash message for an action that failed because of its step-up, or nil."
  @spec action_error(term()) :: String.t() | nil
  def action_error(error) do
    if StepUps.step_up_error?(error) do
      error
      |> find_message()
      |> sentence()
    end
  end

  defp find_message(%Ash.Error.Changes.InvalidArgument{field: :step_up_id, message: message}),
    do: message

  defp find_message(%{errors: errors}),
    do: Enum.find_value(errors, &(StepUps.step_up_error?(&1) && find_message(&1)))

  defp find_message(_error), do: nil

  defp sentence(nil), do: "The passkey approval did not work"
  defp sentence(<<first::utf8, rest::binary>>), do: String.upcase(<<first::utf8>>) <> rest
end
