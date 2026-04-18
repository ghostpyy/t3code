import AppKit
import CoreGraphics

struct SimulatorWindow: Equatable {
    let windowID: CGWindowID
    let pid: pid_t
    let bounds: CGRect
    let title: String
}

enum WindowFinder {
    static func locateActiveSimulatorWindow() -> SimulatorWindow? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        var bestArea: CGFloat = 0
        var best: SimulatorWindow?

        for entry in info {
            guard let owner = entry[kCGWindowOwnerName as String] as? String else { continue }
            guard owner == "Simulator" else { continue }
            guard let layer = entry[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let pid = entry[kCGWindowOwnerPID as String] as? Int else { continue }
            guard let windowID = entry[kCGWindowNumber as String] as? CGWindowID else { continue }
            guard let boundsDict = entry[kCGWindowBounds as String] as? [String: Any] else { continue }
            guard let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else { continue }
            let area = bounds.width * bounds.height
            if area < 200 * 200 { continue }
            let title = (entry[kCGWindowName as String] as? String) ?? "Simulator"
            if area > bestArea {
                bestArea = area
                best = SimulatorWindow(windowID: windowID, pid: pid_t(pid), bounds: bounds, title: title)
            }
        }
        return best
    }

    static func bootedDeviceInfo() -> BridgeProtocol.SimInfo? {
        guard let output = runShell("/usr/bin/xcrun", ["simctl", "list", "devices", "booted", "--json"]) else {
            return nil
        }
        guard let data = output.data(using: .utf8),
              let any = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = any["devices"] as? [String: [[String: Any]]]
        else { return nil }

        for (_, list) in devices {
            for d in list {
                guard let state = d["state"] as? String, state == "Booted" else { continue }
                let udid = (d["udid"] as? String) ?? ""
                let name = (d["name"] as? String) ?? "Simulator"
                let device = (d["deviceTypeIdentifier"] as? String) ?? ""
                let model = device.components(separatedBy: ".").last ?? "iPhone"
                let (w, h) = inferScreenSize(model: model)
                return BridgeProtocol.SimInfo(
                    udid: udid,
                    name: name,
                    model: model,
                    status: "booted",
                    screenW: w,
                    screenH: h
                )
            }
        }
        return nil
    }

    private static func inferScreenSize(model: String) -> (Int, Int) {
        let lowered = model.lowercased()
        if lowered.contains("iphone-17") || lowered.contains("iphone-16-pro") { return (1206, 2622) }
        if lowered.contains("iphone-16") { return (1179, 2556) }
        if lowered.contains("iphone-15-pro-max") || lowered.contains("iphone-14-pro-max") { return (1290, 2796) }
        if lowered.contains("ipad") { return (2048, 2732) }
        return (1179, 2556)
    }

    @discardableResult
    static func runShell(_ launchPath: String, _ args: [String]) -> String? {
        let p = Process()
        p.launchPath = launchPath
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do {
            try p.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
