import Foundation

/// What the extraction pipeline has learned **this session** about which route
/// actually produces a file.
///
/// Every strategy in the pipeline — the native extractor, the default yt-dlp
/// extraction, each forced player client — is tried in a fixed order, and each
/// one that fails costs real seconds before the next gets its turn. That order
/// is the right *opening* guess, but it is only ever a guess: which routes work
/// is decided by YouTube's current gating for this device, IP and session, and
/// once a route has failed for that reason it will keep failing for every track
/// in the queue. An album of thirty tracks pays the same dead prefix thirty
/// times.
///
/// This is the memory that stops that. It records the outcomes the log already
/// shows — a native resolve that came back with no stream URLs, a stream URL
/// rejected before its first byte, a player client that actually delivered a
/// file — and answers three questions with them:
///
/// - **Is the native extractor worth trying right now?** (`nativeSkipReason`)
/// - **Is the default yt-dlp extraction worth trying right now?**
///   (`shouldSkipDefaultPath`)
/// - **Which player client should the forced sweep lead with?** (`ordered`)
///
/// Every verdict is *soft*: nothing is disabled permanently, each skip re-arms
/// on a timer or after a fixed number of jobs, and a single success clears the
/// streak that produced it. The memory is deliberately session-scoped (never
/// persisted) — YouTube's gating changes between launches, and a stale verdict
/// read off disk would be worse than no memory at all.
final class ExtractionMemory: @unchecked Sendable {
    static let shared = ExtractionMemory()

    private let lock = NSLock()

    // MARK: Native (YouTubeKit) extractor

    /// Consecutive resolves that returned formats with **no URL on any of
    /// them**. That is the session-level signature — YouTube handing this
    /// client a format list it won't serve — as opposed to a video that
    /// happens to offer only webm audio, which still comes back with URLs.
    private var nativeURLlessResolves = 0
    /// When the native extractor becomes eligible again.
    private var nativeSkipUntil: Date?

    /// Consecutive URL-less resolves before the native extractor is rested.
    /// Three is enough to separate the session-wide condition from a run of
    /// odd videos, and cheap enough to pay once.
    private let nativeURLlessThreshold = 3
    /// How long a rested native extractor stays rested. Long enough to save a
    /// whole album's worth of doomed resolves, short enough that a session
    /// whose gating lifts picks the fast native route back up.
    private let nativeRestInterval: TimeInterval = 10 * 60

    // MARK: yt-dlp routes

    /// Forced-client labels that produced a verified file, most recent first.
    private var winningClients: [DownloadMode: [String]] = [:]
    /// Forced-client labels whose stream URLs were rejected before a byte
    /// landed. They go to the back of the sweep, not out of it.
    private var rejectedClients: [DownloadMode: Set<String>] = [:]
    /// Whether the winning client's audio only ever arrives as a **muxed
    /// video + extraction** — the expensive shape, since it downloads the
    /// picture too and then transcodes.
    private var winnerNeedsExtraction: [DownloadMode: Bool] = [:]
    /// Modes whose route warm-up has been claimed this session.
    private var warmupClaimed: Set<DownloadMode> = []
    /// Modes whose one "is there a cheaper route?" probe has been spent.
    private var directAudioProbeSpent: Set<DownloadMode> = []
    /// Consecutive default-path downloads rejected at their first byte.
    private var defaultRejections: [DownloadMode: Int] = [:]
    /// Jobs that have skipped the default path since it was last probed.
    private var defaultSkips: [DownloadMode: Int] = [:]

    /// How many winning clients to remember. The sweep only ever needs a
    /// couple of leaders; a longer list would just re-impose a stale order.
    private let winningClientLimit = 3
    /// Byte-zero rejections of the default path before it is stepped over.
    /// Two, because one can be a single unlucky video.
    private let defaultRejectionThreshold = 2
    /// Jobs to skip the default path for before probing it once more, so a
    /// session whose gating lifts returns to the better route (a dedicated
    /// audio-only stream, no extraction step) on its own.
    private let defaultProbeInterval = 8

    // MARK: Native verdicts

    /// A resolve that produced at least one usable stream URL. Clears the
    /// streak — and any rest — outright.
    func recordNativeResolve(hadStreamURLs: Bool) {
        lock.lock(); defer { lock.unlock() }
        if hadStreamURLs {
            nativeURLlessResolves = 0
            nativeSkipUntil = nil
            return
        }
        nativeURLlessResolves += 1
        guard nativeURLlessResolves >= nativeURLlessThreshold, nativeSkipUntil == nil else { return }
        nativeSkipUntil = Date().addingTimeInterval(nativeRestInterval)
    }

    /// Non-nil while the native extractor is rested — the string says why, for
    /// the log line the composite writes in place of the attempt.
    func nativeSkipReason() -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let until = nativeSkipUntil else { return nil }
        guard Date() < until else {
            // Rest served: re-arm and let the next job pay for a fresh answer.
            nativeSkipUntil = nil
            nativeURLlessResolves = 0
            return nil
        }
        let minutes = max(1, Int((until.timeIntervalSinceNow / 60).rounded(.up)))
        return "its last \(nativeURLlessResolves) resolves returned formats with no stream URLs at all (YouTube isn't serving them to this client right now) — trying again in ~\(minutes) min"
    }

    // MARK: yt-dlp verdicts

    /// The default extraction's chosen stream was rejected (403/410) before a
    /// single byte arrived — the rendition is gated for this client, and every
    /// track in the queue will hit the same wall.
    func recordDefaultRejectedAtStart(mode: DownloadMode) {
        lock.lock(); defer { lock.unlock() }
        defaultRejections[mode, default: 0] += 1
    }

    /// Claims the session's route warm-up for `mode`, spending it. Returns
    /// false when the route is already known (or another warm-up has the
    /// claim), so the work is never done twice or done pointlessly.
    func claimWarmup(mode: DownloadMode) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard (winningClients[mode] ?? []).isEmpty,
              !warmupClaimed.contains(mode) else { return false }
        warmupClaimed.insert(mode)
        return true
    }

    /// The warm-up probed the default route deliberately and the host rejected
    /// it. That single, purposeful answer is worth as much as the two
    /// accidental ones the download path has to collect, so it sets the streak
    /// outright rather than incrementing it — the point of warming is that the
    /// first track shouldn't have to learn this the slow way.
    func recordDefaultGatedByProbe(mode: DownloadMode) {
        lock.lock(); defer { lock.unlock() }
        defaultRejections[mode] = defaultRejectionThreshold
    }

    /// The default path delivered. Clears the streak so a recovered session
    /// keeps the better route.
    func recordDefaultSuccess(mode: DownloadMode) {
        lock.lock(); defer { lock.unlock() }
        defaultRejections[mode] = 0
        defaultSkips[mode] = 0
    }

    /// Whether to step over the default extraction and go straight to the
    /// player clients that have been working.
    ///
    /// Only ever true when there *is* a remembered winner: without one the
    /// forced sweep is a shot in the dark that costs more than the default
    /// attempt it would replace. Consumes a skip credit, so every
    /// `defaultProbeInterval` jobs one attempt goes back through the default
    /// path and re-answers the question.
    func shouldSkipDefaultPath(mode: DownloadMode) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !(winningClients[mode] ?? []).isEmpty,
              defaultRejections[mode, default: 0] >= defaultRejectionThreshold else { return false }
        let skips = defaultSkips[mode, default: 0]
        guard skips < defaultProbeInterval else {
            defaultSkips[mode] = 0
            return false
        }
        defaultSkips[mode] = skips + 1
        return true
    }

    /// How a client's audio actually arrived: a dedicated audio-only stream,
    /// or the muxed video with its audio extracted. The distinction is worth
    /// a whole session's bookkeeping because the second shape downloads the
    /// picture as well — around 40% more bytes on a typical track — and pays
    /// an AVFoundation pass on top.
    func recordAudioRoute(_ label: String, neededExtraction: Bool, mode: DownloadMode) {
        lock.lock(); defer { lock.unlock() }
        winnerNeedsExtraction[mode] = neededExtraction
        // A route that turned out cheap answers the question the probe was
        // for, so the probe is no longer owed.
        if !neededExtraction { directAudioProbeSpent.insert(mode) }
    }

    /// Claims the session's single attempt at finding a client that serves a
    /// **direct audio-only** stream, spending it.
    ///
    /// The sweep leads with whatever has been working, which is right — but
    /// when the incumbent only ever yields muxed video, "working" is costing
    /// every track the picture it throws away. Exactly once per session, and
    /// only once something *has* worked (so there's always a fallback), the
    /// order is inverted to give the untried clients first refusal. If one of
    /// them serves audio-only, every later track is cheaper; if none does, the
    /// cost was a single extra resolve and the incumbent still finishes the
    /// job.
    func claimDirectAudioProbe(mode: DownloadMode) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !(winningClients[mode] ?? []).isEmpty,
              winnerNeedsExtraction[mode] == true,
              !directAudioProbeSpent.contains(mode) else { return false }
        directAudioProbeSpent.insert(mode)
        return true
    }

    /// A forced client produced a verified file. It leads the sweep from here.
    func recordClientSuccess(_ label: String, mode: DownloadMode) {
        lock.lock(); defer { lock.unlock() }
        var winners = winningClients[mode] ?? []
        winners.removeAll { $0 == label }
        winners.insert(label, at: 0)
        winningClients[mode] = Array(winners.prefix(winningClientLimit))
        rejectedClients[mode]?.remove(label)
    }

    /// A forced client's stream URL was rejected before a byte landed. It
    /// moves to the back of the sweep — still tried, last, in case the gating
    /// that rejected it lifts.
    func recordClientRejectedAtStart(_ label: String, mode: DownloadMode) {
        lock.lock(); defer { lock.unlock() }
        guard !(winningClients[mode] ?? []).contains(label) else { return }
        rejectedClients[mode, default: []].insert(label)
    }

    /// The forced sweep's client order, re-sorted by what this session has
    /// seen: proven winners first (most recent first), then clients nothing is
    /// known about — in their hand-tuned order — then the ones whose URLs were
    /// rejected at the first byte. A three-way partition, so the opening order
    /// still decides everything the memory has no opinion about.
    /// `probingForDirectAudio` hoists **one** untried client ahead of the
    /// proven ones for a single job (see `claimDirectAudioProbe`). One, not
    /// all of them: the point is to spend a single resolve finding out whether
    /// something cheaper exists, and a client that has never answered is as
    /// likely to be gated as to be the answer — leading with the whole
    /// untried tail would put five doomed resolves in front of the client
    /// that works.
    func ordered(_ sets: [[String]], mode: DownloadMode,
                 probingForDirectAudio: Bool = false) -> [[String]] {
        lock.lock()
        let winners = winningClients[mode] ?? []
        let rejected = rejectedClients[mode] ?? []
        lock.unlock()
        guard !winners.isEmpty || !rejected.isEmpty else { return sets }

        func label(_ set: [String]) -> String { set.joined(separator: ",") }
        var leaders: [[String]] = []
        for winner in winners {
            if let set = sets.first(where: { label($0) == winner }) { leaders.append(set) }
        }
        let remaining = sets.filter { set in !leaders.contains(where: { label($0) == label(set) }) }
        let untried = remaining.filter { !rejected.contains(label($0)) }
        let sunk = remaining.filter { rejected.contains(label($0)) }
        return probingForDirectAudio
            ? Array(untried.prefix(1)) + leaders + Array(untried.dropFirst()) + sunk
            : leaders + untried + sunk
    }

    /// A one-line account of what the memory currently believes, for the log
    /// when it changes the plan.
    func summary(mode: DownloadMode) -> String {
        lock.lock(); defer { lock.unlock() }
        let winners = winningClients[mode] ?? []
        let rejected = (rejectedClients[mode] ?? []).sorted()
        var parts: [String] = []
        if !winners.isEmpty { parts.append("working: \(winners.joined(separator: ", "))") }
        if !rejected.isEmpty { parts.append("rejected at byte 0: \(rejected.joined(separator: ", "))") }
        return parts.isEmpty ? "nothing learned yet" : parts.joined(separator: " · ")
    }
}
