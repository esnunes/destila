defmodule DestilaWeb.ProjectFormLive do
  use DestilaWeb, :live_component

  alias Destila.Projects
  alias Destila.Projects.Project

  def update(assigns, socket) do
    project = assigns[:project] || %Project{}
    mode = assigns[:mode]
    submit_label = assigns[:submit_label] || if(mode == :create, do: "Create", else: "Save")

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:project, project)
     |> assign(:submit_label, submit_label)
     |> assign_new(:form, fn ->
       to_form(%{
         "name" => project.name || "",
         "git_repo_url" => project.git_repo_url || "",
         "local_folder" => project.local_folder || "",
         "setup_command" => project.setup_command || "",
         "run_command" => project.run_command || ""
       })
     end)
     |> assign_new(:port_definitions, fn -> project.port_definitions || [] end)
     |> assign_new(:errors, fn -> %{} end)
     |> assign_new(:inner_block, fn -> [] end)}
  end

  def handle_event("validate", params, socket) do
    port_definitions =
      params
      |> Enum.filter(fn {k, _} -> String.starts_with?(k, "port_def_") end)
      |> Enum.sort_by(fn {k, _} -> k end)
      |> Enum.map(fn {_, v} -> v end)

    port_definitions =
      if port_definitions == [], do: socket.assigns.port_definitions, else: port_definitions

    {:noreply,
     socket
     |> assign(:form, to_form(params))
     |> assign(:port_definitions, port_definitions)}
  end

  def handle_event("save", params, socket) do
    port_defs = Enum.reject(socket.assigns.port_definitions, &(&1 == ""))

    attrs = %{
      name: String.trim(params["name"] || ""),
      git_repo_url: non_blank(params["git_repo_url"]),
      local_folder: non_blank(params["local_folder"]),
      setup_command: non_blank(params["setup_command"]),
      run_command: non_blank(params["run_command"]),
      port_definitions: port_defs
    }

    result =
      case socket.assigns.mode do
        :create -> Projects.create_project(attrs)
        :edit -> Projects.update_project(socket.assigns.project, attrs)
      end

    case result do
      {:ok, project} ->
        send(self(), {:project_saved, project})
        {:noreply, socket}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(:form, to_form(params))
         |> assign(:errors, changeset_to_errors(changeset))}
    end
  end

  def handle_event("add_port", _params, socket) do
    {:noreply, assign(socket, :port_definitions, socket.assigns.port_definitions ++ [""])}
  end

  def handle_event("remove_port", %{"index" => index}, socket) do
    index = String.to_integer(index)

    {:noreply,
     assign(socket, :port_definitions, List.delete_at(socket.assigns.port_definitions, index))}
  end

  def handle_event("update_port", params, socket) do
    index = String.to_integer(params["index"])
    value = params["value"] || ""

    {:noreply,
     assign(
       socket,
       :port_definitions,
       List.replace_at(socket.assigns.port_definitions, index, value)
     )}
  end

  defp non_blank(nil), do: nil
  defp non_blank(""), do: nil
  defp non_blank(str), do: str

  defp changeset_to_errors(%Ecto.Changeset{} = changeset) do
    Enum.reduce(changeset.errors, %{}, fn
      {:name, {msg, _}}, acc -> Map.put(acc, :name, msg)
      {:git_repo_url, {msg, _}}, acc -> Map.put(acc, :location, msg)
      {:port_definitions, {msg, _}}, acc -> Map.put(acc, :port_definitions, msg)
      _, acc -> acc
    end)
  end

  def render(assigns) do
    ~H"""
    <form
      phx-submit="save"
      phx-change="validate"
      phx-target={@myself}
      class="space-y-3"
      id={"#{@id}-form"}
      phx-hook="FocusFirstError"
    >
      <fieldset class="fieldset">
        <label class="fieldset-label text-xs font-medium" for={"#{@id}-name"}>
          Name <span class="text-error">*</span>
        </label>
        <input
          type="text"
          id={"#{@id}-name"}
          name="name"
          value={@form["name"].value}
          placeholder="My Project"
          aria-invalid={@errors[:name] && "true"}
          phx-mounted={JS.focus()}
          class={[
            "input input-bordered w-full input-sm",
            @errors[:name] && "input-error"
          ]}
        />
        <p :if={@errors[:name]} class="text-xs text-error mt-1">{@errors[:name]}</p>
      </fieldset>

      <div class={[
        "rounded-lg p-3 space-y-3",
        if(@errors[:location], do: "ring-1 ring-error/30 bg-error/5", else: "bg-base-200/50")
      ]}>
        <div class="flex items-center gap-2">
          <span class="text-xs font-medium text-base-content/50">Location</span>
          <span class="text-xs text-base-content/30">at least one required</span>
        </div>

        <fieldset class="fieldset">
          <label class="fieldset-label text-xs font-medium" for={"#{@id}-git-repo-url"}>
            Git repository URL
          </label>
          <input
            type="url"
            id={"#{@id}-git-repo-url"}
            name="git_repo_url"
            value={@form["git_repo_url"].value}
            placeholder="https://github.com/org/repo"
            aria-invalid={@errors[:location] && "true"}
            class={[
              "input input-bordered w-full input-sm",
              @errors[:location] && "input-error"
            ]}
          />
        </fieldset>

        <div class="flex items-center gap-3">
          <div class="flex-1 h-px bg-base-300" />
          <span class="text-xs text-base-content/30">or</span>
          <div class="flex-1 h-px bg-base-300" />
        </div>

        <fieldset class="fieldset">
          <label class="fieldset-label text-xs font-medium" for={"#{@id}-local-folder"}>
            Local folder
          </label>
          <input
            type="text"
            id={"#{@id}-local-folder"}
            name="local_folder"
            value={@form["local_folder"].value}
            placeholder="/path/to/project"
            aria-invalid={@errors[:location] && "true"}
            class={[
              "input input-bordered w-full input-sm",
              @errors[:location] && "input-error"
            ]}
          />
        </fieldset>

        <p :if={@errors[:location]} class="text-xs text-error">{@errors[:location]}</p>
      </div>

      <div class="rounded-lg p-3 space-y-3 bg-base-200/50">
        <div class="flex items-center gap-2">
          <span class="text-xs font-medium text-base-content/50">Service</span>
          <span class="text-xs text-base-content/30">optional</span>
        </div>

        <fieldset class="fieldset">
          <label class="fieldset-label text-xs font-medium" for={"#{@id}-setup-command"}>
            Setup command
          </label>
          <input
            type="text"
            id={"#{@id}-setup-command"}
            name="setup_command"
            value={@form["setup_command"].value}
            placeholder="mix deps.get && mix assets.build"
            class="input input-bordered w-full input-sm"
          />
        </fieldset>

        <fieldset class="fieldset">
          <label class="fieldset-label text-xs font-medium" for={"#{@id}-run-command"}>
            Run command
          </label>
          <input
            type="text"
            id={"#{@id}-run-command"}
            name="run_command"
            value={@form["run_command"].value}
            placeholder="mix phx.server"
            class="input input-bordered w-full input-sm"
          />
        </fieldset>

        <div>
          <div class="flex items-center justify-between mb-2">
            <label class="text-xs font-medium text-base-content/70">Port definitions</label>
            <button
              type="button"
              phx-click="add_port"
              phx-target={@myself}
              class="btn btn-ghost btn-xs"
              id={"#{@id}-add-port-btn"}
            >
              <.icon name="hero-plus-micro" class="size-3" /> Add port
            </button>
          </div>

          <div :if={@port_definitions != []} class="space-y-2">
            <div
              :for={{pd, idx} <- Enum.with_index(@port_definitions)}
              class="flex items-center gap-2"
              id={"#{@id}-port-def-#{idx}"}
            >
              <input
                type="text"
                name={"port_def_#{idx}"}
                value={pd}
                placeholder="PORT"
                phx-blur="update_port"
                phx-target={@myself}
                phx-value-index={idx}
                class={[
                  "input input-bordered w-full input-sm font-mono uppercase",
                  @errors[:port_definitions] && "input-error"
                ]}
                id={"#{@id}-port-input-#{idx}"}
              />
              <button
                type="button"
                phx-click="remove_port"
                phx-target={@myself}
                phx-value-index={idx}
                class="btn btn-ghost btn-xs text-error/60 hover:text-error"
                id={"#{@id}-remove-port-#{idx}"}
              >
                <.icon name="hero-x-mark-micro" class="size-4" />
              </button>
            </div>
          </div>

          <p :if={@errors[:port_definitions]} class="text-xs text-error mt-1">
            {@errors[:port_definitions]}
          </p>
        </div>
      </div>

      <div class="flex gap-2">
        <button type="submit" class="btn btn-primary btn-sm flex-1">
          {@submit_label}
        </button>
        <%= if @inner_block != [] do %>
          {render_slot(@inner_block)}
        <% end %>
      </div>
    </form>
    """
  end
end
