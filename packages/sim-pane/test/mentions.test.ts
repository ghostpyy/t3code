import { describe, it, expect } from "vitest";
import { buildSimElementMention, renderMentionMarkdown } from "../src/lib/mentions";
import type { AXElement } from "../src/protocol";

function mk(
  label: string | null,
  identifier: string | null,
  overrides: Partial<AXElement> = {},
): AXElement {
  return {
    id: overrides.id ?? label ?? "anon",
    role: overrides.role ?? "button",
    label,
    value: overrides.value ?? null,
    frame: overrides.frame ?? { x: 0, y: 0, width: 100, height: 44 },
    identifier,
    enabled: overrides.enabled ?? true,
    selected: overrides.selected ?? false,
    children: overrides.children ?? null,
    appContext: overrides.appContext ?? null,
    sourceHints: overrides.sourceHints ?? null,
  };
}

describe("buildSimElementMention", () => {
  it("parses a Satira .inspectable() identifier into an anchor", () => {
    const el = mk("Play", "Satira/Views/LibraryView.swift:142|name=PlayButton");
    const m = buildSimElementMention(el, [el]);
    expect(m.kind).toBe("sim-element");
    expect(m.anchor).toEqual({
      module: "Satira",
      file: "Views/LibraryView.swift",
      line: 142,
      alias: "PlayButton",
      sourcePath: "Satira/Views/LibraryView.swift",
      absolutePath: null,
    });
    expect(m.label).toBe("Play");
    expect(m.role).toBe("button");
  });

  it("leaves anchor null for unparseable identifiers", () => {
    const el = mk("OK", "raw_accessibility_id");
    const m = buildSimElementMention(el, [el]);
    expect(m.anchor).toBeNull();
    expect(m.identifier).toBe("raw_accessibility_id");
  });

  it("returns empty ancestors for a lone hit", () => {
    const el = mk("A", null);
    expect(buildSimElementMention(el, [el]).ancestors).toEqual([]);
  });

  it("maps ancestors leaf→root and parses their anchors", () => {
    const leaf = mk("Tap", null);
    const mid = mk("Container", null);
    const root = mk("Home", "Satira/Views/HomeView.swift:7|name=HomeView");
    const m = buildSimElementMention(leaf, [leaf, mid, root]);
    expect(m.ancestors).toHaveLength(2);
    expect(m.ancestors[0]).toMatchObject({ role: "button", label: "Container", anchor: null });
    expect(m.ancestors[1]).toMatchObject({
      role: "button",
      label: "Home",
      anchor: { module: "Satira", file: "Views/HomeView.swift", line: 7, alias: "HomeView" },
    });
  });

  it("inherits appContext from the chain when the target lacks it", () => {
    const leaf = mk("Tap", null);
    const root = mk("Home", null, {
      appContext: {
        bundleId: "com.example.demo",
        name: "Demo",
        pid: 42,
        bundlePath: null,
        dataContainer: null,
        executablePath: null,
        projectPath: "/Users/me/Demo",
      },
    });
    const m = buildSimElementMention(leaf, [leaf, root]);
    expect(m.appContext?.bundleId).toBe("com.example.demo");
  });
});

describe("renderMentionMarkdown", () => {
  it("leads with an unlinked bold file:line when no bridge-verified hint is present", () => {
    const el = mk("Play", "Satira/Views/LibraryView.swift:142|name=PlayButton");
    const md = renderMentionMarkdown(buildSimElementMention(el, [el]));
    expect(md).toContain("<!-- @here:sim-element:start -->");
    expect(md).toContain("<!-- @here:sim-element:end -->");
    expect(md).toContain("**Satira/Views/LibraryView.swift:142**");
    expect(md).toContain("· PlayButton");
    expect(md).not.toContain("[Open →]");
    expect(md).not.toContain("`.inspectable()`");
  });

  it("renders the role+label as a backticked element summary when no anchor resolves", () => {
    const el = mk("Tap", "accessibility_id_foo");
    const md = renderMentionMarkdown(buildSimElementMention(el, [el]));
    expect(md).not.toContain("`.inspectable()`");
    expect(md).toContain("`button`");
    expect(md).toContain('"Tap"');
  });

  it("appends the app name as a mid-dot-separated identity part", () => {
    const el = mk("Tap", "Satira/Views/Foo.swift:1", {
      appContext: {
        bundleId: "com.example.demo",
        name: "Demo",
        pid: 42,
        bundlePath: null,
        dataContainer: null,
        executablePath: null,
        projectPath: "/Users/me/Demo",
      },
    });
    const md = renderMentionMarkdown(buildSimElementMention(el, [el]));
    expect(md).toContain(" · Demo");
    expect(md).not.toContain("pid 42");
  });

  it("omits the noisy label-chain Path block", () => {
    const leaf = mk("Play", null);
    const mid = mk("Row", null);
    const root = mk("List", null);
    const md = renderMentionMarkdown(buildSimElementMention(leaf, [leaf, mid, root]));
    expect(md).not.toContain("**Path**");
    expect(md).not.toContain("Row ← List");
    expect(md).not.toContain("Parents:");
  });

  it("does not repeat the header anchor as a parent", () => {
    const leaf = mk("Play", null);
    const root = mk("Home", "Satira/Views/HomeView.swift:7");
    const md = renderMentionMarkdown(buildSimElementMention(leaf, [leaf, root]));
    expect(md).toContain("**Satira/Views/HomeView.swift:7**");
    expect(md).not.toContain("Ancestors:");
    expect(md).not.toContain("Parents:");
  });

  it("deduplicates parents that share a file:line", () => {
    const leaf = mk("Play", null);
    const a = mk("A", "Satira/Views/HomeView.swift:7");
    const b = mk("B", "Satira/Views/HomeView.swift:7");
    const c = mk("C", "Satira/Views/Other.swift:9");
    const md = renderMentionMarkdown(buildSimElementMention(leaf, [leaf, a, b, c]));
    const occurrences = md.split("Satira/Views/HomeView.swift:7").length - 1;
    expect(occurrences).toBe(1);
    expect(md).toContain("`Satira/Views/Other.swift:9`");
    expect(md).toContain("Parents:");
    expect(md).not.toContain("Ancestors:");
  });

  it("caps parents at two anchors", () => {
    const leaf = mk("Close", "Satira/ReadingExperience.swift:235");
    const chain = [
      leaf,
      mk("Style", "Satira/ReadingExperience.swift:479"),
      mk("Wrapper", "Satira/ReadingExperience.swift:236"),
      mk("Reader", "Satira/ReadingExperience.swift:238"),
    ];
    const md = renderMentionMarkdown(buildSimElementMention(leaf, chain));
    expect(md).toContain("Parents:");
    expect(md).toContain("`Satira/ReadingExperience.swift:479`");
    expect(md).toContain("`Satira/ReadingExperience.swift:236`");
    expect(md).not.toContain("`Satira/ReadingExperience.swift:238`");
  });

  it("uses an anchored ancestor as the identity when the leaf has no anchor", () => {
    const leaf = mk(null, null, {
      role: "AXUIElement",
      sourceHints: [
        {
          absolutePath: "/Users/me/Satira/Sources/Satira/Views/LibraryView.swift",
          line: 22,
          reason: ".inspectable() — ancestor (Inspectable)",
          confidence: 0.82,
        },
      ],
    });
    const row = mk("Velocity", null);
    const root = mk("Library", "Satira/Views/LibraryView.swift:22|name=LibraryView");
    const md = renderMentionMarkdown(buildSimElementMention(leaf, [leaf, row, root]));
    expect(md).toContain(
      "[`Satira/Views/LibraryView.swift:22`](/Users/me/Satira/Sources/Satira/Views/LibraryView.swift:22)",
    );
  });

  it("does not present inferred hints as verified source", () => {
    const leaf = mk("Velocity", null, {
      sourceHints: [
        {
          absolutePath: "/Users/me/Satira/Sources/Satira/Views/LibraryView.swift",
          line: 426,
          reason: "Matched visible text: Good Afternoon, Last read now",
          confidence: 0.82,
        },
      ],
    });
    const md = renderMentionMarkdown(buildSimElementMention(leaf, [leaf]));
    expect(md).toContain("`button`");
    expect(md).not.toContain("/Users/me/Satira/Sources/Satira/Views/LibraryView.swift:426");
    expect(md).not.toContain("inferred");
    expect(md).not.toContain("[Open →]");
  });

  it("emits exactly one clickable file:line for anchored elements with a verified hint", () => {
    const el = mk("Play", "Satira/Views/LibraryView.swift:142");
    const withApp = {
      ...el,
      appContext: {
        bundleId: "com.example.demo",
        name: "Demo",
        pid: 42,
        bundlePath: null,
        dataContainer: null,
        executablePath: null,
        projectPath: "/Users/me/Satira",
      },
      sourceHints: [
        {
          absolutePath: "/Users/me/Satira/Sources/Satira/Views/LibraryView.swift",
          line: 142,
          reason: ".inspectable() — direct hit",
          confidence: 0.98,
        },
      ],
    } satisfies AXElement;
    const md = renderMentionMarkdown(buildSimElementMention(withApp, [withApp]));
    const hrefMatches =
      md.match(/\]\(\/Users\/me\/Satira\/Sources\/Satira\/Views\/LibraryView\.swift:142\)/g) ?? [];
    expect(hrefMatches.length).toBe(1);
    expect(md).toContain(
      "[`Satira/Views/LibraryView.swift:142`](/Users/me/Satira/Sources/Satira/Views/LibraryView.swift:142)",
    );
    expect(md).not.toContain("[Open →]");
  });

  it("uses the bridge-verified source hint absolutePath for the href", () => {
    const el = mk("Play", "Satira/Views/LibraryView.swift:142", {
      sourceHints: [
        {
          absolutePath: "/Users/me/Satira/Sources/Satira/Views/LibraryView.swift",
          line: 142,
          reason: ".inspectable() — direct hit",
          confidence: 0.98,
        },
      ],
    });
    const md = renderMentionMarkdown(buildSimElementMention(el, [el]));
    const hrefMatches =
      md.match(/\]\(\/Users\/me\/Satira\/Sources\/Satira\/Views\/LibraryView\.swift:142\)/g) ?? [];
    expect(hrefMatches.length).toBe(1);
  });

  it("uses a verified source hint when the runtime element has no source identifier", () => {
    const el = mk("The house", null, {
      role: "StaticText",
      sourceHints: [
        {
          absolutePath: "/Users/me/Satira/Sources/Satira/Views/ReadingExperience.swift",
          line: 323,
          reason: ".inspectable() — direct hit",
          confidence: 0.98,
          snippet: 'Text("The house")',
          snippetStartLine: 323,
        },
      ],
    });
    const md = renderMentionMarkdown(buildSimElementMention(el, [el]));
    expect(md).toContain(
      "[`Satira/Views/ReadingExperience.swift:323`](/Users/me/Satira/Sources/Satira/Views/ReadingExperience.swift:323)",
    );
    expect(md).toContain("```swift");
    expect(md).toMatch(/> 323 │ Text\("The house"\)/);
  });

  it("embeds a fenced swift code block when a hint carries a snippet", () => {
    const el = mk("Play", "Satira/Views/LibraryView.swift:142", {
      sourceHints: [
        {
          absolutePath: "/Users/me/Satira/Sources/Satira/Views/LibraryView.swift",
          line: 142,
          reason: ".inspectable() — direct hit",
          confidence: 0.98,
          snippet:
            'struct LibraryView: View {\n    var body: some View {\n        Text("Hello")\n    }\n}',
          snippetStartLine: 140,
        },
      ],
    });
    const md = renderMentionMarkdown(buildSimElementMention(el, [el]));
    expect(md).toContain("```swift");
    expect(md).toMatch(/> 142 │ +Text\("Hello"\)/);
    expect(md).toMatch(/ {2}140 │ struct LibraryView: View \{/);
  });

  it("omits the code block when no hint carries a snippet", () => {
    const el = mk("Play", null, {
      sourceHints: [
        {
          absolutePath: "/Users/me/Satira/Sources/Satira/Views/LibraryView.swift",
          line: 142,
          reason: "semantic: Play",
          confidence: 0.42,
        },
      ],
    });
    const md = renderMentionMarkdown(buildSimElementMention(el, [el]));
    expect(md).not.toContain("```swift");
  });
});
