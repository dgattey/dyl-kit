import DylToolSupport
import Foundation

extension ReleaseChecks {
    /// `check --live`: what users' updaters see. With `expectedVersion`, waits up to `wait` for the deploy to serve
    /// it. The live feed must not be ahead of the committed one, its newest archive must download and verify against
    /// the committed public key, and the site page must show the same version.
    public func live(expectedVersion: String? = nil, wait: Duration = .zero) async -> CheckReport {
        var report = CheckReport()
        report.checked = ["live_site"]
        let manifest = workspace.manifest
        let feedURL = manifest.release.feedURL
        func fail(_ message: String, file: String? = nil) {
            report.findings.append(
                CheckFinding(rule: "live_site", severity: .error, file: file ?? feedURL, message: message))
        }

        let deadline = ContinuousClock.now + wait
        var live: AppcastItem?
        while !Task.isCancelled {
            live = await LiveFeed.download(feedURL, timeout: 20).flatMap { Appcast.items(in: $0).first }
            let served = live.map { expectedVersion == nil || $0.displayVersion == expectedVersion } ?? false
            if served || ContinuousClock.now >= deadline { break }
            Log.step("waiting for \(feedURL) to serve \(expectedVersion ?? "a release")")
            do { try await Task.sleep(for: .seconds(15)) } catch { break }
        }
        guard let live else {
            fail("can't fetch the live appcast, or it has no items")
            return report
        }
        if let expectedVersion, live.displayVersion != expectedVersion {
            fail("serves \(live.displayVersion), not \(expectedVersion), after waiting \(wait)")
        }

        let committed = Appcast.items(at: workspace.artifactsDir.appending(path: "appcast.xml")).first
        if let committedBuild = committed?.build.flatMap({ Int($0) }), let liveBuild = live.build.flatMap({ Int($0) }),
            liveBuild > committedBuild
        {
            fail("live build \(liveBuild) is ahead of the committed build \(committedBuild); pull before releasing")
        }
        if expectedVersion == nil, let committed, committed.displayVersion != live.displayVersion {
            report.findings.append(
                CheckFinding(
                    rule: "live_site", severity: .warning, file: feedURL,
                    message:
                        "serves \(live.displayVersion) while \(committed.displayVersion) is committed (deploy pending?)"
                ))
        }

        guard let enclosure = live.enclosureURL, let signature = live.edSignature else {
            fail("the newest live item has no enclosure or edSignature")
            return report
        }
        if let archive = await LiveFeed.download(enclosure, timeout: 120) {
            let key = (try? String(contentsOf: workspace.url(manifest.release.sparklePublicKey), encoding: .utf8)) ?? ""
            switch EdSignature.verify(archive: archive, signature: signature, publicKey: key) {
            case .valid: break
            case .invalid(let reason): fail(reason, file: enclosure)
            case .unverifiable: fail("can't verify edSignature on this platform; run from macOS", file: enclosure)
            }
        } else {
            fail("can't download the archive", file: enclosure)
        }

        let site = manifest.release.siteUrl
        if let page = await LiveFeed.download(site, timeout: 20) {
            if !String(decoding: page, as: UTF8.self).contains("v\(live.displayVersion)") {
                fail("the download page doesn't show v\(live.displayVersion)", file: site)
            }
        } else {
            fail("can't fetch the download page", file: site)
        }
        return report
    }
}
