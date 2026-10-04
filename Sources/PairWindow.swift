import AppKit
import CoreImage.CIFilterBuiltins

/// Shows the QR code the Agent Mode phone app scans to pair with this Mac's Pro bridge.
final class PairWindowController {
    private var window: NSWindow?

    struct Pairing {
        let host: String
        let port: Int
        let token: String
        var link: String { "agentmode://pair?host=\(host)&port=\(port)&token=\(token)" }
    }

    static func currentPairing() -> Pairing? {
        let path = NSHomeDirectory() + "/.agentmode-pro/config.json"
        guard let data = FileManager.default.contents(atPath: path),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let token = json["token"] as? String,
              let host = lanAddress() else { return nil }
        return Pairing(host: host, port: 8787, token: token)
    }

    /// This Mac's IPv4 address on the local network (Wi-Fi or Ethernet).
    static func lanAddress() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        var fallback: String?
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let iface = ptr.pointee
            guard let addr = iface.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  iface.ifa_flags & UInt32(IFF_UP) != 0, iface.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            let address = String(cString: host)
            if String(cString: iface.ifa_name) == "en0" { return address }
            if fallback == nil { fallback = address }
        }
        return fallback
    }

    static func qrImage(for text: String, size: CGFloat) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scale = size / output.extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }

    func show() {
        window?.close()
        let pairing = Self.currentPairing()

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 28, bottom: 24, right: 28)

        let title = NSTextField(labelWithString: "Pair your phone")
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        stack.addArrangedSubview(title)

        if let pairing, let qr = Self.qrImage(for: pairing.link, size: 260) {
            stack.addArrangedSubview(label("In the Agent Mode phone app, scan this code.\nYour phone needs to be on the same Wi-Fi as this Mac."))
            let imageView = NSImageView(image: qr)
            imageView.imageScaling = .scaleNone
            let frame = NSView()
            frame.wantsLayer = true
            frame.layer?.backgroundColor = NSColor.white.cgColor
            frame.layer?.cornerRadius = 12
            imageView.translatesAutoresizingMaskIntoConstraints = false
            frame.addSubview(imageView)
            NSLayoutConstraint.activate([
                frame.widthAnchor.constraint(equalToConstant: 284), frame.heightAnchor.constraint(equalToConstant: 284),
                imageView.centerXAnchor.constraint(equalTo: frame.centerXAnchor),
                imageView.centerYAnchor.constraint(equalTo: frame.centerYAnchor),
            ])
            stack.addArrangedSubview(frame)
            let manual = label("Or enter it by hand:  \(pairing.host)  ·  port \(pairing.port)")
            manual.textColor = .secondaryLabelColor
            stack.addArrangedSubview(manual)
            let copy = NSButton(title: "Copy Token", target: nil, action: nil)
            copy.bezelStyle = .rounded
            let token = pairing.token
            copy.target = CopyTarget.shared
            copy.action = #selector(CopyTarget.copy(_:))
            CopyTarget.shared.text = token
            stack.addArrangedSubview(copy)
            stack.addArrangedSubview(label("Anyone with this code can run agents on this Mac. Don't share it."))
        } else {
            stack.addArrangedSubview(label("Agent Mode Pro isn't set up on this Mac yet.\nStart the bridge once to create a pairing code:\n\ncd ~/Documents/AI/agent-mode-pro/bridge && npm start"))
        }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 480),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Pair Phone"
        window.contentView = stack
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.alignment = .center
        field.preferredMaxLayoutWidth = 320
        field.font = .systemFont(ofSize: 13)
        return field
    }
}

private final class CopyTarget: NSObject {
    static let shared = CopyTarget()
    var text = ""

    @objc func copy(_ sender: NSButton) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        sender.title = "Copied"
    }
}
