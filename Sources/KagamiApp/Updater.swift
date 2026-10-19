import AppKit
import KagamiCore

/// Installs new Kagami releases from GitHub. Releases are read over GitHub's public API; if the repo
/// is private, through the `gh` CLI and its login instead, so the app never stores a token. A release
/// is installed only when its zip carries a good signature by the release key bundled in the app.
@MainActor
final class Updater {
    static let shared = Updater()

    static let repo = "mostlygino/Kagami"
    /// Gino de Graaff's release key; scripts/release.sh signs with it.
    private static let releaseKey = "4C49B6E8DC9F50C80A1A20B805BE68B6158B9E08"
    /// GUI apps do not inherit the shell PATH.
    private static let ghPaths = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"]
    /// The signature check uses Homebrew's gpg only, never a path from the environment.
    private static let gpgPaths = ["/opt/homebrew/bin/gpg", "/usr/local/bin/gpg"]
    private static let lastCheckKey = "lastUpdateCheck"
    private static let checkInterval: TimeInterval = 24 * 60 * 60

    private(set) var isBusy = false

    /// Where a release comes from: GitHub's public API, or the gh CLI for a private repo.
    private enum Source {
        case web(assets: [String: URL])
        case gh(URL)
    }

    enum UpdateError: LocalizedError {
        case noGitHubCLI, noGPG
        case tool(String, String)
        case badRelease(String)

        var errorDescription: String? {
            switch self {
            case .noGitHubCLI: "Kagami's releases are not public. Install the GitHub CLI (“brew install gh”) and run “gh auth login” to reach them."
            case .noGPG: "Updates are checked with GnuPG. Install it with “brew install gnupg”."
            case .tool(let name, let message): "\(name) failed: \(message)"
            case .badRelease(let reason): "The update was refused: \(reason) Nothing was installed."
            }
        }
    }

    /// Once a day at most, quietly; only a newer release shows anything.
    func checkInBackground() {
        guard BuildInfo.current.channel != .development else { return }
        let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > Self.checkInterval else { return }
        Task { await check(interactive: false) }
    }

    /// "Check for Updates…": also reports "up to date" and errors.
    func check(interactive: Bool) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        var accepted = false
        do {
            let (tag, source) = try await Self.latest()
            UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
            let current = BuildInfo.current.version
            guard let latest = Version(tag: tag), let installed = Version(current), installed < latest else {
                if interactive { Self.alert("Kagami is up to date.", "You have version \(current).") }
                return
            }
            guard Self.ask(version: latest.description, current: current) else { return }
            accepted = true
            try await install(tag: tag, version: latest.description, source: source)
        } catch {
            // Once you said yes, a failure is always reported, even from the background check.
            if interactive || accepted { Self.alert("Could not update Kagami.", error.localizedDescription) }
        }
    }

    /// The newest published release (betas included): its tag ("" when there is none yet) and where to fetch it.
    private static func latest() async throws -> (String, Source) {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases?per_page=20")!, timeoutInterval: 30)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Kagami/\(BuildInfo.current.version)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 {
            // Private repo (or gone): only a signed-in gh can see it.
            let gh = try locate(ghPaths, or: .noGitHubCLI)
            return (try await latestTag(gh), .gh(gh))
        }
        guard status == 200, let releases = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw UpdateError.tool("GitHub", "HTTP \(status)")
        }
        guard let newest = releases.first(where: { ($0["draft"] as? Bool) != true }), let tag = newest["tag_name"] as? String else {
            return ("", .web(assets: [:]))
        }
        var assets: [String: URL] = [:]
        for a in newest["assets"] as? [[String: Any]] ?? [] {
            // Only GitHub's own download hosts, over HTTPS; the signature check still decides what is installed.
            guard let name = a["name"] as? String, let s = a["browser_download_url"] as? String, let url = URL(string: s),
                  url.scheme == "https", let host = url.host, host == "github.com" || host.hasSuffix(".githubusercontent.com") else { continue }
            assets[name] = url
        }
        return (tag, .web(assets: assets))
    }

    private static func latestTag(_ gh: URL) async throws -> String {
        let o = try await TShark.run(["api", "repos/\(repo)/releases?per_page=20",
                                      "--jq", "[.[] | select(.draft | not)][0].tag_name // \"\""], tool: gh, limit: 60)
        if o.status != 0 {
            if o.err.contains("HTTP 404") { return "" }
            throw UpdateError.tool("GitHub", o.err.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return String(decoding: o.out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func install(tag: String, version: String, source: Source) async throws {
        let target = Bundle.main.bundleURL
        guard target.pathExtension == "app", !target.path.contains("/AppTranslocation/"), !target.path.contains("/.build/") else {
            throw UpdateError.badRelease("this copy does not run from an install folder. Move Kagami.app to /Applications first.")
        }
        guard FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
            throw UpdateError.badRelease("Kagami cannot write to \(target.deletingLastPathComponent().path).")
        }
        let work = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: target, create: true)
        do {
            let app = try await download(tag: tag, version: version, source: source, into: work)
            try Self.launchInstaller(newApp: app, target: target, work: work)
        } catch {
            try? FileManager.default.removeItem(at: work)
            throw error
        }
        NSApp.terminate(nil)
    }

    /// Downloads, verifies and unpacks the release. Returns the checked Kagami.app.
    private func download(tag: String, version: String, source: Source, into work: URL) async throws -> URL {
        let zipName = "Kagami-\(version).zip"
        switch source {
        case .gh(let gh):
            try await Self.run(gh, ["release", "download", tag, "--repo", Self.repo,
                                    "--pattern", zipName, "--pattern", zipName + ".sig", "--dir", work.path], name: "Download")
        case .web(let assets):
            for name in [zipName, zipName + ".sig"] {
                guard let url = assets[name] else { throw UpdateError.badRelease("the release has no \(name).") }
                let (file, response) = try await URLSession.shared.download(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.tool("Download", "HTTP error for \(name)") }
                try FileManager.default.moveItem(at: file, to: work.appendingPathComponent(name))
            }
        }
        let zip = work.appendingPathComponent(zipName)
        guard let key = Bundle.main.url(forResource: "release-key", withExtension: "asc") else {
            throw UpdateError.badRelease("the release key is missing from this copy of Kagami.")
        }
        try await ReleaseSignature.verify(file: zip, signature: work.appendingPathComponent(zipName + ".sig"), publicKey: key,
                                          fingerprint: Self.releaseKey, gpg: try Self.locate(Self.gpgPaths, or: .noGPG))

        let unpacked = work.appendingPathComponent("unpacked")
        try await Self.run(URL(fileURLWithPath: "/usr/bin/ditto"), ["-x", "-k", zip.path, unpacked.path], name: "Unzip")
        let app = unpacked.appendingPathComponent("Kagami.app")
        let entries = try FileManager.default.contentsOfDirectory(atPath: unpacked.path)
        let kind = try app.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard entries == ["Kagami.app"], kind.isDirectory == true, kind.isSymbolicLink == false else {
            throw UpdateError.badRelease("the download does not hold just Kagami.app.")
        }
        // The tag is only trusted once the signed bundle says the same: an old, validly signed zip
        // can't be offered again under a newer tag.
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        guard info?["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
              info?["CFBundleShortVersionString"] as? String == version else {
            throw UpdateError.badRelease("the app in the download is not Kagami \(version).")
        }
        // Ad-hoc signed: a quarantine flag would make Gatekeeper refuse to open it.
        try await Self.run(URL(fileURLWithPath: "/usr/bin/xattr"), ["-cr", app.path], name: "xattr")
        try await Self.run(URL(fileURLWithPath: "/usr/bin/codesign"), ["--verify", "--deep", "--strict", app.path], name: "Code signature check")
        return app
    }

    /// Swaps the bundle by rename once this process has quit, then opens Kagami again. A failed
    /// swap puts the old copy back. Paths go in as arguments; nothing from GitHub enters the script.
    private static func launchInstaller(newApp: URL, target: URL, work: URL) throws {
        let script = """
        i=0
        while kill -0 "$1" 2>/dev/null; do
          i=$((i + 1)); [ "$i" -gt 300 ] && { rm -rf "$4"; exit 1; }
          sleep 0.2
        done
        if mv "$3" "$4/old" && mv "$2" "$3"; then
          /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$3"
          /usr/bin/open "$3"
          # Keep the old copy until the new one is up; put it back if it never starts.
          sleep 8
          if pgrep -f "$3/Contents/MacOS/" >/dev/null; then rm -rf "$4"; exit 0; fi
          rm -rf "$3" && mv "$4/old" "$3"
        else
          [ -e "$3" ] || mv "$4/old" "$3"
        fi
        rm -rf "$4"
        /usr/bin/open "$3"
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, "kagami-update", String(ProcessInfo.processInfo.processIdentifier), newApp.path, target.path, work.path]
        try p.run()
    }

    private static func locate(_ paths: [String], or error: UpdateError) throws -> URL {
        guard let path = paths.first(where: FileManager.default.isExecutableFile(atPath:)) else { throw error }
        return URL(fileURLWithPath: path)
    }

    @discardableResult
    private static func run(_ tool: URL, _ args: [String], name: String) async throws -> String {
        let o = try await TShark.run(args, tool: tool, limit: 300)
        guard o.status == 0 else { throw UpdateError.tool(name, o.err.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return String(decoding: o.out, as: UTF8.self)
    }

    private static func ask(version: String, current: String) -> Bool {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Kagami \(version) is available."
        alert.informativeText = "You have \(current). Kagami quits, installs the update and opens again. A capture in progress is stopped first."
        alert.addButton(withTitle: "Install and Relaunch")
        alert.addButton(withTitle: "Later")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func alert(_ title: String, _ text: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }
}

/// Checks a downloaded release against the one key allowed to sign releases, in a throwaway
/// keyring so the user's own keys and trust settings play no part.
enum ReleaseSignature {
    struct NotSigned: LocalizedError {
        var errorDescription: String? { "The update is not signed by the Kagami release key. Nothing was installed." }
    }

    static func verify(file: URL, signature: URL, publicKey: URL, fingerprint: String, gpg: URL) async throws {
        // Short path in /tmp: gpg puts its agent sockets in the home directory.
        let home = URL(fileURLWithPath: "/tmp/kagami-release-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer {
            let gpgconf = gpg.deletingLastPathComponent().appendingPathComponent("gpgconf")
            _ = try? Process.run(gpgconf, arguments: ["--homedir", home.path, "--kill", "all"]).waitUntilExit()
            try? FileManager.default.removeItem(at: home)
        }
        let base = ["--homedir", home.path, "--batch", "--no-auto-key-retrieve"]
        _ = try await TShark.run(base + ["--import", publicKey.path], tool: gpg, limit: 60)
        let o = try await TShark.run(base + ["--status-fd", "1", "--verify", "--", signature.path, file.path], tool: gpg, limit: 60)
        guard o.status == 0, ReleaseStatus.signedBy(fingerprint, status: String(decoding: o.out, as: UTF8.self)) else { throw NotSigned() }
    }

}

/// What this copy of Kagami is. make-app.sh stamps the commit, date and channel into Info.plist.
struct BuildInfo {
    enum Channel: String { case development = "Development", beta = "Beta", release = "Release" }

    let version: String
    let number: String
    let channel: Channel
    let commit: String?
    let date: Date?

    static let current: BuildInfo = {
        let info = Bundle.main.infoDictionary ?? [:]
        let commit = info["KagamiCommit"] as? String
        return BuildInfo(
            version: info["CFBundleShortVersionString"] as? String ?? "?",
            number: info["CFBundleVersion"] as? String ?? "?",
            channel: Channel(rawValue: info["KagamiChannel"] as? String ?? "") ?? .development,
            commit: commit == "unknown" || commit?.isEmpty == true ? nil : commit,
            date: (info["KagamiBuildDate"] as? String).flatMap { try? Date($0, strategy: .iso8601) })
    }()

    static var macOS: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return v.patchVersion > 0 ? "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)" : "\(v.majorVersion).\(v.minorVersion)"
    }

    static var architecture: String {
        #if arch(arm64)
        "Apple silicon"
        #else
        "Intel"
        #endif
    }

    /// Plain text for a bug report.
    func report(wireshark: String?) -> String {
        var lines = ["Kagami \(version)\(channel == .release ? "" : " \(channel.rawValue)") (build \(number))"]
        if let commit { lines.append("Commit \(commit)") }
        if let date { lines.append("Built \(date.formatted(.iso8601))") }
        lines.append(wireshark ?? "Wireshark not found")
        lines.append("macOS \(Self.macOS), \(Self.architecture)")
        return lines.joined(separator: "\n")
    }
}
