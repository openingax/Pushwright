import Darwin
import Foundation

/// One request per connection: the client writes JSON, shuts down its write side, then reads JSON until EOF.
enum Socket {
    static func address(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let fits = withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            path.utf8CString.withUnsafeBytes { source in
                guard source.count <= buffer.count else { return false }
                buffer.copyMemory(from: source)
                return true
            }
        }
        return fits ? address : nil
    }

    static func make() -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var on: Int32 = 1
        // A peer that hangs up must not kill us with SIGPIPE.
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    static func connect(_ path: String) -> Int32? {
        guard var address = address(path), let fd = make() else { return nil }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    static func readAll(_ fd: Int32) -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count > 0 { data.append(buffer, count: count) } else if count < 0, errno == EINTR { continue } else { break }
        }
        return data
    }

    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if count > 0 { offset += count } else if count < 0, errno == EINTR { continue } else { return false }
            }
            return true
        }
    }
}

public enum IPCClient {
    /// Sends a request to Pushwright.app, launching it in the background if it isn't running.
    public static func call(_ request: IPCRequest) throws -> Data {
        let path = Store.socketPath
        guard let fd = Socket.connect(path) ?? launchAndConnect(path) else {
            throw ErrorInfo.config("APP_NOT_RUNNING", "Could not reach Pushwright.app (\(path)). Open the app once, then retry.")
        }
        defer { close(fd) }
        // Generous: a push waits on APNs, and later milestones wait for receipts.
        var timeout = timeval(tv_sec: 120, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        guard Socket.writeAll(fd, try JSON.encode(request)) else {
            throw ErrorInfo.config("APP_NOT_RUNNING", "Pushwright.app closed the connection.")
        }
        shutdown(fd, SHUT_WR)
        let response = Socket.readAll(fd)
        guard !response.isEmpty else { throw ErrorInfo.config("APP_NOT_RUNNING", "Pushwright.app sent no response.") }
        return response
    }

    static func launchAndConnect(_ path: String) -> Int32? {
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        // When this CLI runs from inside the app bundle, open that copy of the app; otherwise ask Launch Services
        // for Pushwright.app by name, so a build with a different bundle ID still works.
        let executable = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
            .resolvingSymlinksInPath().path(percentEncoded: false)
        if let range = executable.range(of: ".app/Contents/Helpers/") {
            open.arguments = ["-g", String(executable[..<range.lowerBound]) + ".app"]
        } else {
            open.arguments = ["-g", "-a", "Pushwright"]
        }
        guard (try? open.run()) != nil else { return nil }
        open.waitUntilExit()
        for _ in 0..<25 {
            usleep(200_000)
            if let fd = Socket.connect(path) { return fd }
        }
        return nil
    }
}

/// The app's end of the socket. The file is mode 0600, so only this user's processes can connect.
public final class SocketServer: @unchecked Sendable {
    let path: String
    let handler: @Sendable (Data) async -> Data

    public init(path: String, handler: @escaping @Sendable (Data) async -> Data) {
        self.path = path
        self.handler = handler
    }

    public func start() throws {
        if let existing = Socket.connect(path) {
            close(existing)
            throw ErrorInfo.config("ALREADY_RUNNING", "Another Pushwright instance is already listening.")
        }
        try FileManager.default.createDirectory(at: Store.directory, withIntermediateDirectories: true)
        unlink(path)
        guard var address = Socket.address(path), let fd = Socket.make() else {
            throw ErrorInfo.config("SOCKET_FAILED", "Socket path is too long: \(path)")
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 16) == 0 else {
            let message = String(cString: strerror(errno))
            close(fd)
            throw ErrorInfo.config("SOCKET_FAILED", "Could not listen on \(path): \(message)")
        }
        let handler = handler
        Thread.detachNewThread {
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 {
                    if errno == EINTR { continue }
                    break
                }
                var on: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                DispatchQueue.global().async {
                    let request = Socket.readAll(client)
                    Task {
                        _ = Socket.writeAll(client, await handler(request))
                        close(client)
                    }
                }
            }
        }
    }
}
