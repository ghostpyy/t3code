// Design tokens for the sim pane. These live here, not in the app's Tailwind
// config, because the pane package ships standalone and can't depend on the
// host app's theme. Keep the palette restrained — the simulator is the hero;
// chrome is a whispered scientific instrument.
export const tokens = {
  color: {
    ink: "#06070A", // near-black, faintly blue-cold
    panel: "#0B0D11", // rail background
    layer: "#0F1116", // elevated layer (toolbar, drawer headers)
    hairline: "rgba(255,255,255,0.06)", // default stroke
    hairlineStrong: "rgba(255,255,255,0.09)",
    text: "#EDECE7", // warm off-white — never pure white
    textMuted: "#8A8A93",
    textFaint: "#5A5A62",
    accentLive: "#8EFF9A", // phosphor green — the one signature note
    accentLiveDim: "rgba(142,255,154,0.18)",
    accentBoot: "#FFBE5C", // warm amber during transitions
    accentError: "#FF7A8A",
    accentInfo: "#8BA1FF",
  },
  font: {
    prose: `'DM Sans', -apple-system, BlinkMacSystemFont, 'Segoe UI', system-ui, sans-serif`,
    mono: `'JetBrains Mono', ui-monospace, SFMono-Regular, 'SF Mono', Menlo, monospace`,
  },
  radius: {
    sm: 4,
    md: 6,
    lg: 10,
  },
  shadow: {
    well: "inset 0 1px 0 rgba(255,255,255,0.02), 0 1px 0 rgba(0,0,0,0.4)",
    deviceDrop:
      "0 1px 0 rgba(255,255,255,0.05), 0 18px 42px -18px rgba(0,0,0,0.9), 0 2px 0 rgba(0,0,0,0.35)",
  },
} as const;

export type Tokens = typeof tokens;
