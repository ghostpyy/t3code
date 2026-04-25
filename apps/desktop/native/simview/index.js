const path = require("path");
const fs = require("fs");

function resolveNativeAddon() {
  const candidates = [
    // Dev: built by node-gyp alongside this file
    path.join(__dirname, "build", "Release", "simview.node"),
  ];
  // Packaged Electron: electron-builder's `extraResources` lands files at process.resourcesPath
  if (process.resourcesPath) {
    candidates.push(path.join(process.resourcesPath, "simview.node"));
  }
  for (const candidate of candidates) {
    if (fs.existsSync(candidate)) {
      return candidate;
    }
  }
  return null;
}

// Lazy load: the native addon is not always present (non-darwin builds,
// ongoing dev without node-gyp). Importing this module must NEVER crash the
// main process. Callers get a clear error only when they try to construct.
let nativeModule = null;
let resolveError = null;

function loadNative() {
  if (nativeModule) return nativeModule;
  if (resolveError) throw resolveError;
  const addonPath = resolveNativeAddon();
  if (!addonPath) {
    resolveError = new Error(
      "simview native addon not found. Run 'bun run build' in apps/desktop/native/simview " +
        "to produce the dev binary. This addon is macOS-only.",
    );
    throw resolveError;
  }
  try {
    nativeModule = require(addonPath);
    return nativeModule;
  } catch (err) {
    resolveError = err;
    throw err;
  }
}

class SimView {
  constructor(contextId) {
    const native = loadNative();
    return new native.SimView(contextId);
  }
}

module.exports = { SimView, isAvailable: () => resolveNativeAddon() !== null };
