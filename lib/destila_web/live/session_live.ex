defmodule DestilaWeb.SessionLive do
  use DestilaWeb, :live_view

  def mount(_params, session, socket) do
    if session["current_user"] do
      {:ok, push_navigate(socket, to: ~p"/")}
    else
      {:ok, assign(socket, page_title: "Sign in")}
    end
  end

  def render(assigns) do
    ~H"""
    <div class="min-h-screen flex items-center justify-center bg-base-200">
      <div class="card w-full max-w-sm bg-base-100 shadow-lg border border-base-300">
        <div class="card-body">
          <div class="text-center mb-4">
            <h1 class="text-2xl font-bold tracking-tight">Destila</h1>
            <p class="text-sm text-base-content/60 mt-1">Sign in to your account</p>
          </div>

          <form action={~p"/login"} method="post">
            <input
              type="hidden"
              name="_csrf_token"
              value={Plug.CSRFProtection.get_csrf_token_for("/login")}
            />

            <fieldset class="fieldset">
              <label class="fieldset-label text-xs font-medium" for="email">Email</label>
              <input
                type="email"
                id="email"
                name="email"
                value="demo@destila.dev"
                class="input input-bordered w-full"
                required
              />
            </fieldset>

            <fieldset class="fieldset mt-3">
              <label class="fieldset-label text-xs font-medium" for="password">Password</label>
              <input
                type="password"
                id="password"
                name="password"
                value="password"
                class="input input-bordered w-full"
              />
            </fieldset>

            <button type="submit" class="btn btn-primary w-full mt-6">
              Sign in
            </button>
          </form>

          <p class="text-xs text-center text-base-content/40 mt-4">
            Prototype mode &mdash; any credentials will work
          </p>
        </div>
      </div>
    </div>
    """
  end
end
