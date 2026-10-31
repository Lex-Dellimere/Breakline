defmodule CloudWeb.PasskeyCeremony do
  @moduledoc """
  The browser half of every passkey ceremony, as one hidden element with a
  colocated hook. Render it once on a LiveView that uses passkeys:

      <CloudWeb.PasskeyCeremony.hook id="passkey-ceremony" />

  The LiveView drives it with `push_event/3`:

  - `"passkey:get"` with request options (`challenge`, `rp_id`, `timeout`,
    `user_verification`, `allow_credentials`, and a `ref` naming the
    ceremony) runs `navigator.credentials.get` and pushes
    `"passkey_assertion"` back with base64url `raw_id`,
    `authenticator_data`, `signature`, `client_data_json` and `user_handle`.
  - `"passkey:create"` with creation options (see
    `Cloud.Accounts.Passkeys.registration_options/1`) runs
    `navigator.credentials.create` and pushes `"passkey_attestation"` back
    with `raw_id`, `attestation_object` and `client_data_json`.

  A cancelled or failed prompt pushes `"passkey_error"` with the error's
  `name` and `message`. Every reply carries the `ref` it was asked with.

  The challenge and everything that decides the outcome stay on the server;
  the hook only moves bytes between the server and the authenticator.
  """

  use Phoenix.Component

  attr :id, :string, required: true

  def hook(assigns) do
    ~H"""
    <div id={@id} phx-hook=".PasskeyCeremony" phx-update="ignore" class="hidden"></div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".PasskeyCeremony">
      const fromB64 = (value) => {
        const base64 = value.replace(/-/g, "+").replace(/_/g, "/")
        const padded = base64 + "=".repeat((4 - (base64.length % 4)) % 4)
        return Uint8Array.from(atob(padded), (c) => c.charCodeAt(0))
      }

      const toB64 = (buffer) => {
        let binary = ""
        new Uint8Array(buffer).forEach((byte) => { binary += String.fromCharCode(byte) })
        return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
      }

      const supported = () =>
        typeof window.PublicKeyCredential !== "undefined" && !!navigator.credentials

      export default {
        mounted() {
          this.handleEvent("passkey:get", (options) => this.get(options))
          this.handleEvent("passkey:create", (options) => this.create(options))
        },

        fail(ref, error) {
          this.pushEvent("passkey_error", {
            ref: ref,
            name: (error && error.name) || "Error",
            message: (error && error.message) || "the passkey prompt failed"
          })
        },

        async get(options) {
          if (!supported()) {
            return this.fail(options.ref, { name: "NotSupportedError", message: "this browser cannot use passkeys" })
          }

          try {
            const credential = await navigator.credentials.get({
              publicKey: {
                challenge: fromB64(options.challenge),
                rpId: options.rp_id,
                timeout: options.timeout,
                userVerification: options.user_verification,
                allowCredentials: (options.allow_credentials || []).map((c) => ({
                  id: fromB64(c.id),
                  type: "public-key"
                }))
              }
            })

            if (!credential) {
              return this.fail(options.ref, { name: "NullCredential", message: "no passkey was returned" })
            }

            const response = credential.response

            this.pushEvent("passkey_assertion", {
              ref: options.ref,
              raw_id: toB64(credential.rawId),
              authenticator_data: toB64(response.authenticatorData),
              signature: toB64(response.signature),
              client_data_json: toB64(response.clientDataJSON),
              user_handle: response.userHandle ? toB64(response.userHandle) : null
            })
          } catch (error) {
            this.fail(options.ref, error)
          }
        },

        async create(options) {
          if (!supported()) {
            return this.fail(options.ref, { name: "NotSupportedError", message: "this browser cannot use passkeys" })
          }

          try {
            const credential = await navigator.credentials.create({
              publicKey: {
                challenge: fromB64(options.challenge),
                rp: { id: options.rp.id, name: options.rp.name },
                user: {
                  id: fromB64(options.user.id),
                  name: options.user.name,
                  displayName: options.user.display_name
                },
                pubKeyCredParams: [
                  { alg: -7, type: "public-key" },
                  { alg: -257, type: "public-key" }
                ],
                timeout: options.timeout,
                attestation: options.attestation,
                authenticatorSelection: {
                  residentKey: options.resident_key,
                  requireResidentKey: options.resident_key === "required",
                  userVerification: options.user_verification
                },
                excludeCredentials: (options.exclude_credentials || []).map((c) => ({
                  id: fromB64(c.id),
                  type: "public-key"
                }))
              }
            })

            if (!credential) {
              return this.fail(options.ref, { name: "NullCredential", message: "no passkey was created" })
            }

            this.pushEvent("passkey_attestation", {
              ref: options.ref,
              raw_id: toB64(credential.rawId),
              attestation_object: toB64(credential.response.attestationObject),
              client_data_json: toB64(credential.response.clientDataJSON)
            })
          } catch (error) {
            this.fail(options.ref, error)
          }
        }
      }
    </script>
    """
  end

  @doc "A readable flash for a `\"passkey_error\"` from the hook."
  @spec error_message(map()) :: String.t()
  def error_message(%{"name" => "NotAllowedError"}),
    do: "The passkey prompt was cancelled or timed out"

  def error_message(%{"name" => "NotSupportedError"}), do: "This browser cannot use passkeys"

  def error_message(%{"name" => "InvalidStateError"}),
    do: "That passkey is already registered here"

  def error_message(%{"name" => "SecurityError"}),
    do: "The browser refused the passkey prompt for this address"

  def error_message(_params), do: "The passkey prompt failed"
end
