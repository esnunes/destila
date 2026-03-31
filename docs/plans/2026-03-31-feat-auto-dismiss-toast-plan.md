# Auto-dismiss Toast Messages After 5 Seconds

## Goal

Make toast (flash) messages automatically disappear after 5 seconds, improving UX by not requiring manual dismissal while still allowing users to click to dismiss early.

## Current State

- Flash messages are rendered by `flash/1` in `lib/destila_web/components/core_components.ex` (lines 50–80)
- They use daisyUI `toast` and `alert` classes, positioned top-right
- Dismissal is manual only: clicking the toast triggers `JS.push("lv:clear-flash")` and `hide("#flash-{kind}")`
- No auto-dismiss or timeout logic exists
- JS hooks are defined in `assets/js/app.js` and registered via the `Hooks` object

## Approach

Use a **LiveView JS Hook** (`AutoDismiss`) that starts a 5-second timer on mount, then hides the element and pushes the `lv:clear-flash` event. This is the standard Phoenix LiveView pattern for timed behavior on elements.

### Why a Hook (not pure JS.hide with transition)?

`Phoenix.LiveView.JS` commands don't support delayed execution (no `setTimeout` equivalent). A hook gives us clean timer management with proper cleanup if the user dismisses early or the element is removed.

## Implementation Steps

### Step 1 — Create `AutoDismiss` hook in `assets/js/app.js`

Add a new hook before the `Hooks` object:

```javascript
const AutoDismissHook = {
  mounted() {
    this.timeout = setTimeout(() => {
      this.pushEvent("lv:clear-flash", {key: this.el.dataset.kind})
      this.el.style.display = "none"
    }, 5000)
  },
  destroyed() {
    clearTimeout(this.timeout)
  }
}
```

Register it in the `Hooks` object:

```javascript
const Hooks = {
  ...colocatedHooks,
  ScrollBottom: ScrollBottomHook,
  FocusFirstError: FocusFirstErrorHook,
  AutoDismiss: AutoDismissHook,
}
```

### Step 2 — Attach the hook to the flash component in `core_components.ex`

In the `flash/1` component (`lib/destila_web/components/core_components.ex`, line 54), add `phx-hook` and `data-kind` attributes to the outer `<div>`:

```heex
<div
  :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
  id={@id}
  phx-hook="AutoDismiss"
  data-kind={@kind}
  phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
  role="alert"
  class="toast toast-top toast-end z-50"
  {@rest}
>
```

**Important**: The `id` attribute is already present (required for hooks). The `data-kind` attribute passes the flash kind (`:info` or `:error`) to the JS hook so it can push the correct clear event.

### Step 3 — Exclude client/server error flashes from auto-dismiss

The `client-error` and `server-error` flashes in `flash_group/1` (`lib/destila_web/components/layouts.ex`, lines 160–182) should **not** auto-dismiss — they represent ongoing connection issues and are managed by `phx-disconnected`/`phx-connected`.

To handle this, add an `autoclose` attr to the `flash/1` component (default `true`), and only attach the hook when `autoclose` is true:

```elixir
attr :autoclose, :boolean, default: true
```

Then conditionally apply the hook:

```heex
<div
  :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
  id={@id}
  phx-hook={@autoclose && "AutoDismiss"}
  data-kind={@kind}
  ...
>
```

In `flash_group/1`, pass `autoclose={false}` to the client-error and server-error flashes:

```heex
<.flash id="client-error" kind={:error} autoclose={false} ... >
<.flash id="server-error" kind={:error} autoclose={false} ... >
```

## Files Changed

| File | Change |
|---|---|
| `assets/js/app.js` | Add `AutoDismissHook` and register in `Hooks` |
| `lib/destila_web/components/core_components.ex` | Add `autoclose` attr, attach `phx-hook="AutoDismiss"` and `data-kind` |
| `lib/destila_web/components/layouts.ex` | Pass `autoclose={false}` to client/server error flashes |

## Testing

- Trigger an info flash (e.g., archive a session) → verify it disappears after ~5 seconds
- Trigger an error flash → verify it disappears after ~5 seconds
- Click a flash before 5 seconds → verify it dismisses immediately without JS errors
- Disconnect the server → verify client-error toast stays visible (does not auto-dismiss)
