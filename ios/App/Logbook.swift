import Foundation

/// Log do protocolo em memória (exibido e compartilhável no app).
final class Logbook: ObservableObject {
    static let shared = Logbook()

    @Published private(set) var lines: [String] = []

    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var text: String { lines.joined(separator: "\n") }

    func add(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)"
        if Thread.isMainThread {
            append(line)
        } else {
            DispatchQueue.main.async { self.append(line) }
        }
    }

    func clear() { lines = [] }

    private func append(_ line: String) {
        lines.append(line)
        if lines.count > 800 { lines.removeFirst(lines.count - 800) }
    }
}
