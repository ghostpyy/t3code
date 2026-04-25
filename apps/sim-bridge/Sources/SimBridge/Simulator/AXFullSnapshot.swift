import Foundation

/// Flat node representation emitted to the pane. Parent/child links are
/// preserved via `parentId` so the renderer can rebuild the topology without
/// shipping nested `AXElement` trees (keeps the wire format cheap, lets the
/// renderer filter/outlines/gaps operate on a single array).
public struct AXNode: Codable, Equatable, Sendable {
    public let id: String
    public let parentId: String?
    public let role: String
    public let label: String?
    public let value: String?
    public let identifier: String?
    public let frame: AXFrame
    public let enabled: Bool
    public let selected: Bool

    public init(
        id: String,
        parentId: String?,
        role: String,
        label: String?,
        value: String?,
        identifier: String?,
        frame: AXFrame,
        enabled: Bool,
        selected: Bool
    ) {
        self.id = id
        self.parentId = parentId
        self.role = role
        self.label = label
        self.value = value
        self.identifier = identifier
        self.frame = frame
        self.enabled = enabled
        self.selected = selected
    }
}

enum AXFullSnapshot {
    /// Breadth-first flatten of a live AX tree. Drops zero-area / off-screen
    /// stubs so the outline overlay doesn't paint phantom rects. Preserves
    /// the root regardless of size so the pane always has one anchor.
    static func flatten(
        tree: AXElement,
        displayBounds: AXFrame? = nil,
        minSide: Double = 2
    ) -> [AXNode] {
        let root = displayBounds ?? tree.frame
        var out: [AXNode] = []
        var queue: [(AXElement, String?)] = [(tree, nil)]
        var isFirst = true

        while !queue.isEmpty {
            let (element, parentId) = queue.removeFirst()
            let keep = isFirst || isVisible(
                frame: element.frame, root: root, minSide: minSide
            )
            if keep {
                out.append(node(from: element, parentId: parentId))
            }
            let nextParent = keep ? element.id : parentId
            for child in element.children ?? [] {
                queue.append((child, nextParent))
            }
            isFirst = false
        }
        return out
    }

    private static func node(from element: AXElement, parentId: String?) -> AXNode {
        AXNode(
            id: element.id,
            parentId: parentId,
            role: element.role,
            label: element.label,
            value: element.value,
            identifier: element.identifier,
            frame: element.frame,
            enabled: element.enabled,
            selected: element.selected
        )
    }

    private static func isVisible(
        frame: AXFrame, root: AXFrame, minSide: Double
    ) -> Bool {
        guard frame.width >= minSide, frame.height >= minSide else { return false }
        let rootMaxX = root.x + max(root.width, 0)
        let rootMaxY = root.y + max(root.height, 0)
        let frameMaxX = frame.x + frame.width
        let frameMaxY = frame.y + frame.height
        return frame.x <= rootMaxX &&
            frame.y <= rootMaxY &&
            frameMaxX >= root.x &&
            frameMaxY >= root.y
    }
}
