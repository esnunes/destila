import { Terminal } from "@xterm/xterm"
import { FitAddon } from "@xterm/addon-fit"

const DARK_THEME = {
  background: "#1e1e2e",
  foreground: "#cdd6f4",
  cursor: "#f5e0dc",
  cursorAccent: "#11111b",
  selectionBackground: "#353749",
  selectionForeground: "#cdd6f4",
  black: "#45475a",
  red: "#f38ba8",
  green: "#a6e3a1",
  yellow: "#f9e2af",
  blue: "#89b4fa",
  magenta: "#f5c2e7",
  cyan: "#94e2d5",
  white: "#a6adc8",
  brightBlack: "#585b70",
  brightRed: "#f38ba8",
  brightGreen: "#a6e3a1",
  brightYellow: "#f9e2af",
  brightBlue: "#89b4fa",
  brightMagenta: "#f5c2e7",
  brightCyan: "#94e2d5",
  brightWhite: "#bac2de",
}

const LIGHT_THEME = {
  background: "#eff1f5",
  foreground: "#4c4f69",
  cursor: "#dc8a78",
  cursorAccent: "#eff1f5",
  selectionBackground: "#d8dae1",
  selectionForeground: "#4c4f69",
  black: "#5c5f77",
  red: "#d20f39",
  green: "#40a02b",
  yellow: "#df8e1d",
  blue: "#1e66f5",
  magenta: "#ea76cb",
  cyan: "#179299",
  white: "#acb0be",
  brightBlack: "#6c6f85",
  brightRed: "#d20f39",
  brightGreen: "#40a02b",
  brightYellow: "#df8e1d",
  brightBlue: "#1e66f5",
  brightMagenta: "#ea76cb",
  brightCyan: "#179299",
  brightWhite: "#bcc0cc",
}

function currentTheme() {
  const attr = document.documentElement.getAttribute("data-theme")
  if (attr === "light") return LIGHT_THEME
  if (attr === "dark") return DARK_THEME
  // "system" / no attribute — check prefers-color-scheme
  return window.matchMedia("(prefers-color-scheme: dark)").matches ? DARK_THEME : LIGHT_THEME
}

function cleanup(hook) {
  if (hook._themeListener) {
    window.removeEventListener("phx:set-theme", hook._themeListener)
    window.removeEventListener("phx:cycle-theme", hook._themeListener)
    hook._themeListener = null
  }
  clearTimeout(hook._resizeTimer)
  if (hook.resizeObserver) { hook.resizeObserver.disconnect(); hook.resizeObserver = null }
  if (hook.term) { hook.term.dispose(); hook.term = null }
}

export default {
  mounted() {
    const container = this.el.querySelector("[data-terminal-container]")
    const theme = currentTheme()

    // Create xterm.js instance
    this.term = new Terminal({
      cursorBlink: false,
      scrollback: 0,
      fontSize: 12,
      fontWeight: 600,
      fontWeightBold: 700,
      fontFamily: "'JetBrains Mono NF', monospace",
      letterSpacing: 0,
      theme,
    })

    this.fitAddon = new FitAddon()
    this.term.loadAddon(this.fitAddon)
    this.term.open(container)

    // Wait for fonts to load before fitting so xterm measures glyphs correctly
    document.fonts.ready.then(() => {
      requestAnimationFrame(() => {
        this.fitAddon.fit()
        this.term.focus()
        const dims = this.fitAddon.proposeDimensions()
        if (dims) {
          this.pushEvent("resize", { cols: dims.cols-3, rows: dims.rows })
        }
      })
    })

    // Terminal input -> LiveView
    this.term.onData((data) => {
      this.pushEvent("input", { data })
    })

    // LiveView output -> terminal (Base64-decoded to handle binary data safely)
    this.handleEvent("output", ({ data }) => {
      const bytes = Uint8Array.from(atob(data), c => c.charCodeAt(0))
      this.term.write(bytes)
    })

    // Shell process exited
    this.handleEvent("exited", () => {
      this.term.write("\r\n\x1b[90m[Process exited]\x1b[0m\r\n")
      this.pushEvent("terminal_exited", {})
    })

    // Signal the LiveView that xterm.js is ready to receive output
    this.pushEvent("terminal_ready", {})

    // Handle container resize -> re-fit terminal and notify server of new dimensions
    this._resizeTimer = null
    this.resizeObserver = new ResizeObserver(() => {
      clearTimeout(this._resizeTimer)
      this._resizeTimer = setTimeout(() => {
        this.fitAddon.fit()
        const dims = this.fitAddon.proposeDimensions()
        if (dims) {
          this.pushEvent("resize", { cols: dims.cols-3, rows: dims.rows })
        }
      }, 150)
    })
    this.resizeObserver.observe(container)

    // Listen for theme changes (the app dispatches "phx:set-theme" and "phx:cycle-theme")
    this._themeListener = () => {
      // Small delay to let the data-theme attribute update first
      setTimeout(() => this.term.options.theme = currentTheme(), 50)
    }
    window.addEventListener("phx:set-theme", this._themeListener)
    window.addEventListener("phx:cycle-theme", this._themeListener)
  },

  destroyed() {
    cleanup(this)
  }
}
