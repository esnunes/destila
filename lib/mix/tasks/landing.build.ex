defmodule Mix.Tasks.Landing.Build do
  @shortdoc "Builds the landing page JSX bundle via esbuild"

  @moduledoc """
  Concatenates the JSX source files in `landing/src/` and transpiles the
  result to `landing/docs/assets/app.js` using the `:landing` esbuild
  profile (configured in `config/config.exs`).

  The landing page source files are not ES modules — they share globals
  (like `React`, `ReactDOM`, and a `window.VariationMinimal`). Real
  bundling would break that contract, so this task just concatenates the
  files in a fixed order into `landing/.build/combined.jsx` and hands
  that single file to esbuild for JSX transpilation.

  Each source file declares its own `const { useState, ... } = React;`
  line. Concatenating raw would cause "already declared" errors, so we
  strip those lines from each file and emit a single superset at the top
  of the combined output.

  ## Usage

      mix landing.build
  """

  use Mix.Task

  @source_root "landing/src"
  @build_root "landing/.build"
  @combined_file "combined.jsx"

  # Files are concatenated in this exact order. Keep `mocks.jsx` and
  # `shot.jsx` first (they define helpers used by variations), then
  # variations, then `app.jsx` last (it mounts the React root).
  @sources [
    "mocks.jsx",
    "shot.jsx",
    "variation-minimal.jsx",
    "app.jsx"
  ]

  @react_destructure_re ~r/^\s*const\s*\{[^}]+\}\s*=\s*React;\s*$/m

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.config")

    File.mkdir_p!(@build_root)
    File.mkdir_p!("landing/docs/assets")

    combined =
      @sources
      |> Enum.map(fn name ->
        path = Path.join(@source_root, name)

        "/* ==== src/#{name} ==== */\n" <>
          (path |> File.read!() |> String.replace(@react_destructure_re, ""))
      end)
      |> Enum.join("\n")

    preamble = "const { useState, useEffect, useRef } = React;\n"

    combined_path = Path.join(@build_root, @combined_file)
    File.write!(combined_path, preamble <> combined)

    Mix.shell().info("Transpiling #{combined_path} via esbuild(:landing)")
    Esbuild.install_and_run(:landing, [])
  end
end
