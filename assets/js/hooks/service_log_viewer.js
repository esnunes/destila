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
  return window.matchMedia("(prefers-color-scheme: dark)").matches ? DARK_THEME : LIGHT_THEME
}

function decode(data) {
  return Uint8Array.from(atob(data), c => c.charCodeAt(0))
}

export default {
  mounted() {
    const container = this.el.querySelector("[data-terminal-container]")

    this.term = new Terminal({
      cursorBlink: false,
      cursorStyle: "underline",
      disableStdin: true,
      scrollback: 10000,
      fontSize: 12,
      fontWeight: 600,
      fontWeightBold: 700,
      fontFamily: "'JetBrains Mono NF', monospace",
      letterSpacing: 0,
      convertEol: true,
      theme: currentTheme(),
    })

    this.fitAddon = new FitAddon()
    this.term.loadAddon(this.fitAddon)
    this.term.open(container)

    container.querySelector('.xterm-helpers').style.letterSpacing = 0

    document.fonts.ready.then(() => {
      requestAnimationFrame(() => {
        this.fitAddon.fit()
        this.pushEvent("terminal_ready", {})
      })
    })

    this.handleEvent("output", ({ data }) => {
      this.term.write(decode(data))
    })

    this.handleEvent("clear", () => {
      this.term.reset()
    })

    this._resizeTimer = null
    this.resizeObserver = new ResizeObserver(() => {
      clearTimeout(this._resizeTimer)
      this._resizeTimer = setTimeout(() => {
        this.fitAddon.fit()
      }, 150)
    })
    this.resizeObserver.observe(container)

    this._themeListener = () => {
      setTimeout(() => this.term.options.theme = currentTheme(), 50)
    }
    window.addEventListener("phx:set-theme", this._themeListener)
    window.addEventListener("phx:cycle-theme", this._themeListener)
  },

  destroyed() {
    if (this._themeListener) {
      window.removeEventListener("phx:set-theme", this._themeListener)
      window.removeEventListener("phx:cycle-theme", this._themeListener)
      this._themeListener = null
    }
    clearTimeout(this._resizeTimer)
    if (this.resizeObserver) { this.resizeObserver.disconnect(); this.resizeObserver = null }
    if (this.term) { this.term.dispose(); this.term = null }
  }
}
