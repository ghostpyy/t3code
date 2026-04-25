import type { InspectableAnchor } from "../protocol.ts";

// Satira's `.inspectable()` stamps `accessibilityIdentifier` with the Swift
// `#fileID`-style path plus the call-site line (and an optional alias):
//   "Satira/Views/LibraryView.swift:142"
//   "Satira/Views/LibraryView.swift:142|name=PlayButton"
// First segment = module, remainder (up to `.swift`) = file path inside
// `Sources/<module>/`. This parser is the single source of truth for that
// convention — overlay, mention builder, and source resolver all reuse it.
const SWIFT_SOURCE_PATTERN = /^(.*?\.swift):(\d+)$/;
const WINDOWS_ABSOLUTE_PATH_PATTERN = /^[A-Za-z]:[\\/]/;

export function parseInspectable(identifier: string | null | undefined): InspectableAnchor | null {
  if (!identifier) return null;
  const [location, ...parts] = identifier.trim().split("|");
  const match = SWIFT_SOURCE_PATTERN.exec(location ?? "");
  if (!match) return null;
  const [, sourcePath, lineStr] = match;
  if (!sourcePath || !lineStr) return null;
  const line = Number.parseInt(lineStr, 10);
  if (!Number.isFinite(line) || line <= 0) return null;
  const alias = parts
    .map((part) => part.trim())
    .find((part) => part.startsWith("name="))
    ?.slice("name=".length);
  const normalizedSourcePath = sourcePath.replaceAll("\\", "/");

  if (
    normalizedSourcePath.startsWith("/") ||
    WINDOWS_ABSOLUTE_PATH_PATTERN.test(normalizedSourcePath)
  ) {
    const trimmed = normalizedSourcePath.replace(/\/+$/, "");
    const sourcesIndex = trimmed.lastIndexOf("/Sources/");
    if (sourcesIndex !== -1) {
      const relative = trimmed.slice(sourcesIndex + 1);
      const segments = relative.split("/");
      if (segments.length >= 3) {
        return {
          module: segments[1] ?? null,
          file: segments.slice(2).join("/"),
          line,
          alias: alias ?? null,
          sourcePath: relative,
          absolutePath: trimmed,
        };
      }
    }
    return {
      module: null,
      file: basenameOfPath(trimmed),
      line,
      alias: alias ?? null,
      sourcePath: trimmed,
      absolutePath: trimmed,
    };
  }

  const segments = normalizedSourcePath.split("/").filter((segment) => segment.length > 0);
  if (segments.length >= 3 && segments[0] === "Sources") {
    return {
      module: segments[1] ?? null,
      file: segments.slice(2).join("/"),
      line,
      alias: alias ?? null,
      sourcePath: normalizedSourcePath,
      absolutePath: null,
    };
  }
  if (segments.length >= 2) {
    return {
      module: segments[0] ?? null,
      file: segments.slice(1).join("/"),
      line,
      alias: alias ?? null,
      sourcePath: normalizedSourcePath,
      absolutePath: null,
    };
  }
  return {
    module: null,
    file: normalizedSourcePath,
    line,
    alias: alias ?? null,
    sourcePath: normalizedSourcePath,
    absolutePath: null,
  };
}

export function anchorDisplay(anchor: InspectableAnchor): string {
  return `${anchor.sourcePath}:${anchor.line}`;
}

export function anchorRelativePath(anchor: InspectableAnchor): string {
  return anchorRelativeCandidates(anchor)[0] ?? anchor.sourcePath;
}

export function anchorRelativeCandidates(anchor: InspectableAnchor): string[] {
  if (anchor.absolutePath) {
    const sourcesIndex = anchor.absolutePath.lastIndexOf("/Sources/");
    if (sourcesIndex !== -1) {
      const relative = anchor.absolutePath.slice(sourcesIndex + 1);
      return unique(relative, anchor.module ? `${anchor.module}/${anchor.file}` : null);
    }
    return [];
  }
  if (anchor.sourcePath.startsWith("Sources/")) {
    return unique(anchor.sourcePath, anchor.module ? `${anchor.module}/${anchor.file}` : null);
  }
  if (anchor.module) {
    return unique(`Sources/${anchor.module}/${anchor.file}`, anchor.sourcePath);
  }
  return unique(anchor.sourcePath);
}

function unique(...values: Array<string | null | undefined>): string[] {
  const seen = new Set<string>();
  const ordered: string[] = [];
  for (const value of values) {
    if (!value || seen.has(value)) continue;
    seen.add(value);
    ordered.push(value);
  }
  return ordered;
}

function basenameOfPath(path: string): string {
  const separatorIndex = path.lastIndexOf("/");
  return separatorIndex === -1 ? path : path.slice(separatorIndex + 1);
}
