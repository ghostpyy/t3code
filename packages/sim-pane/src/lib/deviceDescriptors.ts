export type ChromeFamily =
  | "dynamic-island"
  | "notch"
  | "home-button"
  | "ipad"
  | "ipad-home"
  | "generic";

export type HardwareButton =
  | "home-button"
  | "side"
  | "lock"
  | "volume-up"
  | "volume-down"
  | "siri"
  | "apple-pay";

export interface DeviceDescriptor {
  model: string;
  family: ChromeFamily;
  buttons: HardwareButton[];
  /** CSS px for the outer corner of the chrome. */
  cornerRadius: number;
  /** CSS px thickness of the titanium bezel around the screen. */
  bezelThickness: number;
}

const TABLE: Record<string, DeviceDescriptor> = {
  // iPhone 17 / 16 Pro render in Xcode with an almost-invisible frame —
  // the screen corners come within a few pixels of the chassis outside,
  // so bezels are aggressive (≤ 6 CSS px) and corner radii generous.
  "iPhone18,1": {
    model: "iPhone 17 Pro",
    family: "dynamic-island",
    buttons: ["side", "volume-up", "volume-down", "siri"],
    cornerRadius: 60,
    bezelThickness: 6,
  },
  "iPhone18,2": {
    model: "iPhone 17 Pro Max",
    family: "dynamic-island",
    buttons: ["side", "volume-up", "volume-down", "siri"],
    cornerRadius: 60,
    bezelThickness: 6,
  },
  "iPhone18,3": {
    model: "iPhone 17",
    family: "dynamic-island",
    buttons: ["side", "volume-up", "volume-down"],
    cornerRadius: 56,
    bezelThickness: 6,
  },
  "iPhone18,4": {
    model: "iPhone 17 Plus",
    family: "dynamic-island",
    buttons: ["side", "volume-up", "volume-down"],
    cornerRadius: 58,
    bezelThickness: 6,
  },
  // iPhone 16 family
  "iPhone17,1": {
    model: "iPhone 16 Pro",
    family: "dynamic-island",
    buttons: ["side", "volume-up", "volume-down", "siri"],
    cornerRadius: 58,
    bezelThickness: 7,
  },
  "iPhone17,2": {
    model: "iPhone 16 Pro Max",
    family: "dynamic-island",
    buttons: ["side", "volume-up", "volume-down", "siri"],
    cornerRadius: 58,
    bezelThickness: 7,
  },
  "iPhone17,3": {
    model: "iPhone 16",
    family: "dynamic-island",
    buttons: ["side", "volume-up", "volume-down"],
    cornerRadius: 54,
    bezelThickness: 7,
  },
  "iPhone17,4": {
    model: "iPhone 16 Plus",
    family: "dynamic-island",
    buttons: ["side", "volume-up", "volume-down"],
    cornerRadius: 56,
    bezelThickness: 7,
  },
  // iPhone 15
  "iPhone16,1": {
    model: "iPhone 15 Pro",
    family: "dynamic-island",
    buttons: ["side", "volume-up", "volume-down"],
    cornerRadius: 58,
    bezelThickness: 9,
  },
  "iPhone16,2": {
    model: "iPhone 15 Pro Max",
    family: "dynamic-island",
    buttons: ["side", "volume-up", "volume-down"],
    cornerRadius: 58,
    bezelThickness: 9,
  },
  "iPhone15,4": {
    model: "iPhone 15",
    family: "notch",
    buttons: ["side", "volume-up", "volume-down"],
    cornerRadius: 48,
    bezelThickness: 10,
  },
  "iPhone15,5": {
    model: "iPhone 15 Plus",
    family: "notch",
    buttons: ["side", "volume-up", "volume-down"],
    cornerRadius: 50,
    bezelThickness: 10,
  },
  // iPhone SE
  "iPhone14,6": {
    model: "iPhone SE (3rd gen)",
    family: "home-button",
    buttons: ["home-button", "side", "volume-up", "volume-down"],
    cornerRadius: 18,
    bezelThickness: 22,
  },
  // iPad
  "iPad14,3": {
    model: "iPad Pro 11",
    family: "ipad",
    buttons: ["lock", "volume-up", "volume-down"],
    cornerRadius: 36,
    bezelThickness: 18,
  },
  "iPad14,5": {
    model: "iPad Pro 12.9",
    family: "ipad",
    buttons: ["lock", "volume-up", "volume-down"],
    cornerRadius: 36,
    bezelThickness: 18,
  },
};

const GENERIC: DeviceDescriptor = {
  model: "iOS device",
  family: "generic",
  buttons: ["side", "volume-up", "volume-down"],
  cornerRadius: 36,
  bezelThickness: 10,
};

export function getDeviceDescriptor(modelId: string): DeviceDescriptor {
  return TABLE[modelId] ?? GENERIC;
}
