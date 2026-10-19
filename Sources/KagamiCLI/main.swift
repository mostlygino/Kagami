import Foundation
import KagamiCore

// kagami: the command-line side of Kagami. Prints JSON (or plain text where asked), exit codes:
// 0 ok, 1 runtime error, 2 usage, 3 Wireshark missing, 4 invalid display filter.

let version = "1.0"

let help = """
kagami \(version): read packet captures with Wireshark's engine. JSON on stdout.

USAGE
  kagami interfaces
  kagami capture -i <interface> [-d <seconds>] [-c <count>] [-f <bpf>] [-w <out.pcapng>] [--force]
  kagami packets <file> [--filter <display filter>] [--offset N] [--limit N]
  kagami packet <file> <frame> [--bytes] [--text]
  kagami anatomy <file> <frame>                 RFC-style header diagrams, as text
  kagami follow <file> <stream> [--udp] [--format text|hex|base64] [--max-bytes N]
  kagami stats <file> [--filter <display filter>]
  kagami flows <file> [--port N[,N]] [--limit N]       NetFlow/IPFIX in a capture, or an nfdump/CSV/JSON/Zeek flow file
  kagami export <file> -o <out> [--filter <display filter>] [--pcap] [--force]
  kagami check <display filter>
  kagami mcp                                     MCP server on stdio

OPTIONS
  --pretty    indent JSON
  --version   print the version

Exit codes: 0 ok, 1 error, 2 usage, 3 Wireshark not found, 4 invalid display filter.
"""

struct Args {
    var positional: [String] = []
    var options: [String: String] = [:]
    var flags: Set<String> = []

    static let valued: Set<String> = ["--filter", "-Y", "--offset", "--limit", "-i", "-d", "-c", "-f", "-w", "-o", "--format", "--max-bytes", "--port"]

    init(_ raw: [String]) throws {
        var i = 0
        while i < raw.count {
            let a = raw[i]
            if Self.valued.contains(a) {
                guard i + 1 < raw.count else { throw Commands.Failure.usage("\(a) needs a value.") }
                options[a] = raw[i + 1]
                i += 2
            } else if a.hasPrefix("-") && a.count > 1 && Double(a) == nil {
                flags.insert(a)
                i += 1
            } else {
                positional.append(a)
                i += 1
            }
        }
    }

    func int(_ key: String, default d: Int) throws -> Int {
        guard let v = options[key] else { return d }
        guard let n = Int(v) else { throw Commands.Failure.usage("\(key) needs a whole number.") }
        return n
    }

    func positional(_ i: Int, _ name: String) throws -> String {
        guard i < positional.count else { throw Commands.Failure.usage("Missing \(name). Run `kagami help`.") }
        return positional[i]
    }
}

func emit(_ object: Any, pretty: Bool) {
    var opts: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
    if pretty { opts.insert(.prettyPrinted) }
    if let data = try? JSONSerialization.data(withJSONObject: object, options: opts) {
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}

func fail(_ f: Commands.Failure) -> Never {
    FileHandle.standardError.write(Data("kagami: \(f.message)\n".utf8))
    exit(f.code)
}

func run() async {
    let raw = Array(CommandLine.arguments.dropFirst())
    guard let command = raw.first else { print(help); exit(2) }
    if command == "--version" { print("kagami \(version)"); exit(0) }
    if command == "help" || command == "--help" || command == "-h" { print(help); exit(0) }

    do {
        let a = try Args(Array(raw.dropFirst()))
        let pretty = a.flags.contains("--pretty")
        let filter = a.options["--filter"] ?? a.options["-Y"]
        switch command {
        case "interfaces":
            emit(try await Commands.interfaces(), pretty: pretty)
        case "capture":
            guard let iface = a.options["-i"] else { throw Commands.Failure.usage("capture needs -i <interface>.") }
            let out = try a.options["-w"].map { try Commands.outputFile($0, overwrite: a.flags.contains("--force")) }
            emit(try await Commands.capture(interface: iface, seconds: try a.int("-d", default: 10),
                                            count: try a.options["-c"].map { _ in try a.int("-c", default: 0) }, bpf: a.options["-f"],
                                            output: out), pretty: pretty)
        case "packets":
            emit(try await Commands.packets(file: try a.positional(0, "capture file"), filter: filter,
                                            offset: try a.int("--offset", default: 0), limit: try a.int("--limit", default: 100)), pretty: pretty)
        case "packet":
            guard let frame = Int(try a.positional(1, "frame number")) else { throw Commands.Failure.usage("Frame must be a number.") }
            let d = try await Commands.detail(file: try a.positional(0, "capture file"), frame: frame)
            if a.flags.contains("--text") { print(Commands.treeText(d)) }
            else { emit(Commands.tree(d, bytes: a.flags.contains("--bytes")), pretty: pretty) }
        case "anatomy":
            guard let frame = Int(try a.positional(1, "frame number")) else { throw Commands.Failure.usage("Frame must be a number.") }
            print(Commands.anatomyText(try await Commands.detail(file: try a.positional(0, "capture file"), frame: frame)))
        case "follow":
            guard let stream = Int(try a.positional(1, "stream number")) else { throw Commands.Failure.usage("Stream must be a number.") }
            let format = a.options["--format"] ?? "text"
            guard ["text", "hex", "base64"].contains(format) else { throw Commands.Failure.usage("--format is text, hex or base64.") }
            emit(try await Commands.follow(file: try a.positional(0, "capture file"), stream: stream, udp: a.flags.contains("--udp"),
                                           format: format, maxBytes: try a.int("--max-bytes", default: 1_000_000)), pretty: pretty)
        case "flows":
            let ports = try (a.options["--port"] ?? "").split(separator: ",").map { s -> Int in
                guard let p = Int(s), (1...65535).contains(p) else { throw Commands.Failure.usage("--port takes UDP ports 1 to 65535.") }
                return p
            }
            emit(try await Commands.flows(file: try a.positional(0, "capture file"), ports: ports, limit: try a.int("--limit", default: 500)), pretty: pretty)
        case "stats":
            emit(try await Commands.stats(file: try a.positional(0, "capture file"), filter: filter), pretty: pretty)
        case "export":
            guard let out = a.options["-o"] else { throw Commands.Failure.usage("export needs -o <output file>.") }
            emit(try await Commands.export(file: try a.positional(0, "capture file"), output: try Commands.outputFile(out, overwrite: a.flags.contains("--force")),
                                           filter: filter, pcap: a.flags.contains("--pcap")), pretty: pretty)
        case "check":
            try Commands.requireWireshark()
            let f = a.positional.joined(separator: " ")
            guard !f.isEmpty else { throw Commands.Failure.usage("check needs a display filter.") }
            try await Commands.checkFilter(f)
            emit(["filter": f, "valid": true], pretty: pretty)
        case "mcp":
            TShark.timeout = 120
            Commands.maxFileBytes = (Int(ProcessInfo.processInfo.environment["KAGAMI_MAX_FILE_MB"] ?? "") ?? 2048) * 1_048_576
            await MCPServer().run()
        default:
            throw Commands.Failure.usage("Unknown command \(command). Run `kagami help`.")
        }
        exit(0)
    } catch let f as Commands.Failure {
        fail(f)
    } catch {
        fail(.runtime(error.localizedDescription))
    }
}

await run()
