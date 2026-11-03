import AppKit
import Security

// All instance state belongs to the main queue. Download/unpack/signature work runs off the UI thread.
final class Updater {
    var isIdle: () -> Bool = { false }
    var onChange: () -> Void = {}
    private(set) var installing = false
    private var checking = false
    private var processing = false
    private var stopped = false
    private var requested = false
    private var timers: [Timer] = []
    private var available: Offer?
    private var fallback: Failure?
    private var prepared: Package?
    private let current = ReleaseVersion(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
    private let repo = Bundle.main.object(forInfoDictionaryKey: "HollerUpdateRepo") as? String ?? ""
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 600
        return URLSession(configuration: configuration)
    }()
    private struct Offer {
        let version: ReleaseVersion
        let asset: ReleaseAsset?
        let page: URL
    }
    private struct Package {
        let directory: URL
        let app: URL
    }
    private enum Failure: String, Error {
        case download, unpack, bundle, signature, sourceBuild, permissions, quarantine, copy, replace, relaunch
        var event: String { self == .sourceBuild ? "signature" : rawValue }
    }
    var menuTitle: String? {
        guard let offer = available else { return nil }
        if fallback == .sourceBuild {
            return "Holler \(offer.version) is out. You built Holler yourself: git pull && ./build.sh --open"
        }
        if fallback != nil { return "Download Holler \(offer.version)…" }
        return "Update to Holler \(offer.version)"
    }
    func start() {
        schedule(after: 60, repeats: false) { $0.check() }
        schedule(after: 6 * 60 * 60, repeats: true) { $0.check() }
        schedule(after: 30, repeats: true) { $0.attemptInstall() }
    }
    private func schedule(after interval: TimeInterval, repeats: Bool, action: @escaping (Updater) -> Void) {
        let timer = Timer(timeInterval: interval, repeats: repeats) { [weak self] _ in
            if let self, !self.stopped { action(self) }
        }
        RunLoop.main.add(timer, forMode: .common); timers.append(timer)
    }
    func stop() {
        stopped = true; timers.forEach { $0.invalidate() }; timers.removeAll()
        session.invalidateAndCancel()
        if !installing, let prepared { try? FileManager.default.removeItem(at: prepared.directory); self.prepared = nil }
    }
    func check() {
        guard !stopped, !checking, !processing, !installing, let current,
              repo.range(of: #"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil,
              let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { return }
        checking = true
        var request = URLRequest(url: url)
        request.setValue("Holler/\(current)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        session.dataTask(with: request) { [weak self] data, response, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.checking = false
                // Offline, missing releases and rate limiting are deliberately quiet.
                guard !self.stopped, !self.processing, !self.installing, (response as? HTTPURLResponse)?.statusCode == 200, let data,
                      let release = try? JSONDecoder().decode(GitHubRelease.self, from: data),
                      let version = UpdatePlan.newerVersion(release, than: current),
                      let page = URL(string: "https://github.com/\(self.repo)/releases/tag/\(release.tag_name)") else { return }
                // Do not silently retry a rejected version every six hours.
                if let existing = self.available, existing.version >= version { return }
                if let prepared = self.prepared { try? FileManager.default.removeItem(at: prepared.directory); self.prepared = nil }
                self.available = Offer(version: version, asset: UpdatePlan.asset(for: version, in: release.assets), page: page)
                self.fallback = nil; self.requested = false
                Log.event("update available"); self.onChange(); self.attemptInstall()
            }
        }.resume()
    }
    func activate() {
        guard let offer = available else { return }
        if fallback != nil { NSWorkspace.shared.open(offer.page); return }
        requested = true; attemptInstall()
    }
    func settingsChanged() { attemptInstall() }
    private func attemptInstall() {
        guard !stopped, !installing, !processing, fallback == nil, let offer = available,
              requested || UserDefaults.standard.bool(forKey: "autoUpdate"), isIdle() else { return }
        if let prepared { commit(prepared, offer: offer); return }
        guard let asset = offer.asset, asset.browser_download_url.scheme == "https",
              asset.browser_download_url.user == nil, asset.browser_download_url.password == nil else { reject(.download); return }
        processing = true
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Holler-update-\(UUID().uuidString)", isDirectory: true)
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        catch { processing = false; reject(.download); return }
        var request = URLRequest(url: asset.browser_download_url)
        request.setValue("Holler/\(current?.description ?? "unknown")", forHTTPHeaderField: "User-Agent")
        session.downloadTask(with: request) { [weak self] file, response, _ in
            var result: Result<Package, Failure>
            do {
                guard let file, (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.download }
                let zip = directory.appendingPathComponent("release.zip")
                do { try FileManager.default.moveItem(at: file, to: zip) } catch { throw Failure.download }
                result = .success(try Self.unpack(zip, directory: directory, version: offer.version))
            } catch { result = .failure(error as? Failure ?? .unpack) }
            DispatchQueue.main.async {
                guard let self, !self.stopped else { try? FileManager.default.removeItem(at: directory); return }
                self.processing = false
                switch result {
                case .success(let package): self.prepared = package; self.attemptInstall()
                case .failure(let failure): try? FileManager.default.removeItem(at: directory); self.reject(failure)
                }
            }
        }.resume()
    }
    private func reject(_ failure: Failure) {
        fallback = failure; requested = false
        Log.event("update rejected: \(failure.event)"); onChange()
    }
    private static func run(_ executable: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        do { try process.run(); process.waitUntilExit(); return process.terminationStatus == 0 } catch { return false }
    }
    private static func unpack(_ zip: URL, directory: URL, version: ReleaseVersion) throws -> Package {
        let fm = FileManager.default, expanded = directory.appendingPathComponent("expanded", isDirectory: true)
        try fm.createDirectory(at: expanded, withIntermediateDirectories: false)
        guard run("/usr/bin/ditto", ["-x", "-k", zip.path, expanded.path]) else { throw Failure.unpack }
        guard let enumerator = fm.enumerator(at: expanded, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey]) else { throw Failure.bundle }
        var apps: [URL] = []
        for case let url as URL in enumerator where url.lastPathComponent == "Holler.app" {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            guard values.isSymbolicLink != true, values.isDirectory == true,
                  url.resolvingSymlinksInPath().path.hasPrefix(expanded.resolvingSymlinksInPath().path + "/") else { throw Failure.bundle }
            apps.append(url)
        }
        guard apps.count == 1, let app = apps.first else { throw Failure.bundle }
        try validateBundle(app, version: version)
        try validateSignature(app)
        guard run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path]) else { throw Failure.quarantine }
        return Package(directory: directory, app: app)
    }
    private static func validateBundle(_ app: URL, version: ReleaseVersion) throws {
        let plist = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              let ownID = Bundle.main.bundleIdentifier, info["CFBundleIdentifier"] as? String == ownID,
              let value = info["CFBundleShortVersionString"] as? String, ReleaseVersion(value) == version else { throw Failure.bundle }
    }
    private static func validateSignature(_ app: URL) throws {
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures)
        var candidate: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &candidate) == errSecSuccess, let candidate,
              SecStaticCodeCheckValidity(candidate, flags, nil) == errSecSuccess else { throw Failure.signature }
        var running: SecCode?
        var runningStatic: SecStaticCode?
        var info: CFDictionary?
        var requirement: SecRequirement?
        guard SecCodeCopySelf([], &running) == errSecSuccess, let running,
              SecCodeCopyStaticCode(running, [], &runningStatic) == errSecSuccess, let runningStatic,
              SecCodeCopySigningInformation(runningStatic, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let details = info as? [String: Any], let certificates = details[kSecCodeInfoCertificates as String] as? [SecCertificate],
              !certificates.isEmpty,
              SecCodeCopyDesignatedRequirement(runningStatic, [], &requirement) == errSecSuccess, let requirement,
              SecStaticCodeCheckValidity(candidate, flags, requirement) == errSecSuccess else { throw Failure.sourceBuild }
    }
    private func commit(_ package: Package, offer: Offer) {
        // Reserve the idle app on the main queue before doing any replacement work.
        installing = true; onChange()
        let destination = Bundle.main.bundleURL
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default, parent = destination.deletingLastPathComponent()
            let staged = parent.appendingPathComponent(".Holler-update-\(UUID().uuidString).app", isDirectory: true)
            var failure: Failure?
            do {
                guard fm.isWritableFile(atPath: parent.path) else { throw Failure.permissions }
                do { try fm.copyItem(at: package.app, to: staged) } catch { throw Failure.copy }
                // Recheck the actual same-volume copy immediately before replacing the installed app.
                try Self.validateBundle(staged, version: offer.version)
                try Self.validateSignature(staged)
                do { _ = try fm.replaceItemAt(destination, withItemAt: staged, backupItemName: nil, options: .usingNewMetadataOnly) }
                catch { throw Failure.replace }
            } catch { failure = error as? Failure ?? .replace }
            try? fm.removeItem(at: staged); try? fm.removeItem(at: package.directory)
            DispatchQueue.main.async {
                self.prepared = nil
                if let failure { self.installing = false; self.reject(failure); return }
                Log.event("update installed")
                let relaunch = Process()
                relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
                // Wait (up to 15 s) for this process to finish its clean-up and exit: `open` on a still-running copy
                // would only activate it, leaving no Holler once it quits. Positional args keep odd paths safe.
                relaunch.arguments = ["-c", "i=0; while /bin/kill -0 \"$2\" 2>/dev/null && [ $i -lt 75 ]; do sleep 0.2; i=$((i+1)); done; /usr/bin/open \"$1\"",
                                      "holler-relaunch", destination.path, String(getpid())]
                relaunch.standardInput = FileHandle.nullDevice; relaunch.standardOutput = FileHandle.nullDevice; relaunch.standardError = FileHandle.nullDevice
                do { try relaunch.run(); RunLoop.main.perform { NSApp.terminate(nil) } }
                catch { self.installing = false; self.reject(.relaunch) }
            }
        }
    }
}
