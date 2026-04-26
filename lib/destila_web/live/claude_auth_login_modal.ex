defmodule DestilaWeb.ClaudeAuthLoginModal do
  @moduledoc """
  Stateless function component for the in-app Claude CLI auth login flow.

  The modal's body adapts based on the `state` assign:

    * `:awaiting_token` — show the OAuth authorization URL with a
      copy-to-clipboard control and an input for the authorization code
    * `:verifying` — spinner while the code is exchanged for tokens and
      the credentials are persisted
    * `:invalid_token` / `:cli_failed` — show the error and a Restart
      button (the field is still labeled "token" in events for UX
      continuity)
    * `:succeeded` — brief transitional spinner while the parent retries
      the failed turn and closes the modal

  All events are dispatched directly to the parent LiveView:

    * `close_claude_login_modal`
    * `submit_claude_token` (form submit with `claude_login[token]`)
    * `restart_claude_login`
  """

  use DestilaWeb, :html

  attr :open?, :boolean, default: false
  attr :state, :atom, default: :idle
  attr :url, :string, default: nil
  attr :error_message, :string, default: nil
  attr :form, :any, required: true
  attr :target_message_id, :any, default: nil

  def claude_auth_login_modal(assigns) do
    ~H"""
    <%= if @open? do %>
      <div
        id="claude-auth-login-modal"
        class="fixed inset-0 z-50 flex items-center justify-center"
        role="dialog"
        aria-modal="true"
        aria-labelledby="claude-auth-login-modal-title"
        phx-window-keydown="close_claude_login_modal"
        phx-key="escape"
      >
        <div
          class="modal-backdrop-enter absolute inset-0 bg-black/70 backdrop-blur-sm"
          phx-click="close_claude_login_modal"
        />
        <div class="modal-panel-enter relative z-10 w-full max-w-lg mx-4">
          <button
            id="claude-auth-login-modal-close-x"
            phx-click="close_claude_login_modal"
            class="absolute -top-10 right-0 text-white/70 hover:text-white transition-colors focus-visible:outline-none focus-visible:text-white"
            aria-label="Close"
          >
            <.icon name="hero-x-mark" class="size-6" />
          </button>
          <div class="rounded-xl bg-base-100 shadow-2xl ring-1 ring-base-300/40 overflow-hidden">
            <div class="px-6 pt-5 pb-4 border-b border-base-300/60">
              <h2
                id="claude-auth-login-modal-title"
                class="text-[15px] font-semibold text-base-content tracking-tight"
              >
                Login to Claude
              </h2>
              <p class="text-xs text-base-content/60 mt-1 leading-relaxed">
                {subtitle_for(@state)}
              </p>
            </div>

            <div class="px-6 py-5 min-h-[140px]">
              <%= cond do %>
                <% @state == :awaiting_token -> %>
                  <div class="space-y-4">
                    <div>
                      <p class="text-xs font-medium text-base-content/60 uppercase tracking-wider mb-2">
                        Authentication URL
                      </p>
                      <div
                        id="claude-login-url"
                        phx-hook=".UrlActions"
                        data-clipboard={@url}
                        class="flex items-center gap-2 rounded-lg bg-base-200 px-3 py-2 ring-1 ring-base-300/60"
                      >
                        <button
                          type="button"
                          data-role="open"
                          class="flex-1 min-w-0 text-left text-xs text-primary font-mono truncate hover:underline focus-visible:outline-none"
                        >
                          {@url}
                        </button>
                        <button
                          id="claude-login-copy-url"
                          type="button"
                          data-role="copy"
                          class="btn btn-ghost btn-xs shrink-0"
                          aria-label="Copy URL to clipboard"
                        >
                          <.icon name="hero-clipboard-document-micro" class="size-4" />
                        </button>
                      </div>
                    </div>

                    <.form
                      for={@form}
                      id="claude-login-token-form"
                      phx-submit="submit_claude_token"
                      class="space-y-2"
                    >
                      <.input
                        field={@form[:token]}
                        type="text"
                        label="Authorization code"
                        id="claude-login-token-input"
                        placeholder="abcd1234#xyz5678"
                        autocomplete="off"
                      />
                      <p class="text-xs text-base-content/60 -mt-1">
                        Copy the entire string shown by claude.com — it has a
                        <code class="font-mono">#</code>
                        in the middle.
                      </p>
                      <div class="flex justify-end">
                        <button
                          id="claude-login-submit"
                          type="submit"
                          class="btn btn-primary btn-sm"
                        >
                          Submit code
                        </button>
                      </div>
                    </.form>
                  </div>
                <% @state == :verifying -> %>
                  <div
                    id="claude-login-verifying"
                    class="flex items-center gap-3 text-sm text-base-content/70"
                  >
                    <span class="loading loading-spinner loading-sm shrink-0" />
                    <span>Exchanging code with Anthropic...</span>
                  </div>
                <% @state in [:invalid_token, :cli_failed] -> %>
                  <div class="space-y-4">
                    <div id="claude-login-error" class="alert alert-error" role="alert">
                      <.icon name="hero-exclamation-triangle-micro" class="size-5" />
                      <span class="text-sm">
                        {@error_message || default_error_for(@state)}
                      </span>
                    </div>
                    <div class="flex justify-end">
                      <button
                        id="claude-login-restart"
                        type="button"
                        phx-click="restart_claude_login"
                        class="btn btn-primary btn-sm"
                      >
                        <.icon name="hero-arrow-path-micro" class="size-4" /> Restart
                      </button>
                    </div>
                  </div>
                <% @state == :succeeded -> %>
                  <div
                    id="claude-login-succeeded"
                    class="flex items-center gap-3 text-sm text-base-content/70"
                  >
                    <span class="loading loading-spinner loading-sm shrink-0" />
                    <span>Logged in! Retrying your last message...</span>
                  </div>
                <% true -> %>
                  <div class="text-sm text-base-content/60">Initializing...</div>
              <% end %>
            </div>

            <div
              :if={@state in [:awaiting_token, :verifying]}
              class="px-6 py-4 border-t border-base-300/60 flex justify-end"
            >
              <button
                id="claude-login-cancel"
                type="button"
                phx-click="cancel_claude_login"
                class="btn btn-ghost btn-sm"
              >
                Cancel
              </button>
            </div>
          </div>
        </div>
      </div>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".UrlActions">
        export default {
          mounted() {
            this.el.addEventListener("click", (event) => {
              const trigger = event.target.closest("[data-role]")
              if (!trigger || !this.el.contains(trigger)) return
              event.preventDefault()
              event.stopPropagation()
              const url = this.el.dataset.clipboard
              if (!url) return
              if (trigger.dataset.role === "open") {
                window.open(url, "_blank", "noopener,noreferrer")
              } else if (trigger.dataset.role === "copy") {
                navigator.clipboard?.writeText(url).catch(() => {})
              }
            })
          }
        }
      </script>
    <% end %>
    """
  end

  defp subtitle_for(:awaiting_token),
    do: "Open the URL below, authorize, then paste the code from claude.com."

  defp subtitle_for(:verifying), do: "Exchanging the code with Anthropic..."
  defp subtitle_for(:invalid_token), do: "The code was rejected. Restart to try again."
  defp subtitle_for(:cli_failed), do: "The OAuth flow failed. Restart to try again."
  defp subtitle_for(:succeeded), do: "Authenticated. Picking up where you left off."
  defp subtitle_for(_), do: "Re-authenticate Claude without leaving the app."

  defp default_error_for(:invalid_token), do: "Authorization code rejected by Anthropic."

  defp default_error_for(:cli_failed),
    do: "The OAuth flow failed before completing."

  defp default_error_for(_), do: "An unknown error occurred."
end
