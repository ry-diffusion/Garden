import Foundation
import Observation
import SwiftData

/// Pulls Meu Pluggy data through the user's Worker and feeds the ledger (DESIGN §4.1, §13).
/// Only the device holding the ingestion lease writes; others just refresh item status and read
/// what CloudKit brings them.
@Observable
final class SyncEngine {
    static let shared = SyncEngine()

    private(set) var isSyncing = false
    private(set) var items: [GardenServer.ItemStatus] = []
    private(set) var lastError: String?
    private(set) var lastReport: PluggyIngestor.Report?
    private(set) var isFollower = false
    /// Bank behind each Meu Pluggy item (the item itself only says "MeuPluggy").
    private(set) var institutions: [String: String] = UserDefaults.standard.dictionary(forKey: "institutions") as? [String: String] ?? [:] {
        didSet { UserDefaults.standard.set(institutions, forKey: "institutions") }
    }
    private(set) var lastSyncAt: Date? = UserDefaults.standard.object(forKey: "lastSyncAt") as? Date {
        didSet { UserDefaults.standard.set(lastSyncAt, forKey: "lastSyncAt") }
    }

    var isPaired: Bool { GardenServer.current != nil }

    /// Foreground / launch: at most every 15 minutes. Meu Pluggy itself refreshes once a day.
    func syncIfStale() async {
        guard isPaired, (lastSyncAt ?? .distantPast) < Date.now.addingTimeInterval(-15 * 60) else { return }
        await sync()
    }

    func sync() async {
        guard !isSyncing, let server = GardenServer.current else { return }
        isSyncing = true
        defer { isSyncing = false }
        let context = GardenStore.shared.mainContext

        do {
            items = try await server.items()
            guard try await server.acquireLease() else {
                isFollower = true  // another device is writing; CloudKit will bring its rows here
                lastError = nil
                return
            }
            isFollower = false

            var report = PluggyIngestor.Report()
            var earliest = Date.now
            var failures: [String] = []
            for item in items where item.status != "NOT_FOUND" {
                let from = windowStart(for: item.id)
                let snapshot: PluggySnapshot
                do {
                    snapshot = try await server.snapshot(itemId: item.id, from: from)
                } catch {
                    failures.append("\(institutions[item.id] ?? String(item.id.prefix(8))): \(error.localizedDescription)")
                    continue
                }
                report = report + PluggyIngestor(context: context).ingest(snapshot)
                report.skipped += snapshot.skipped
                report.accounts += snapshot.accounts.count
                let bank = institutions[item.id] ?? snapshot.accounts.first?.name.map(Institutions.shortName) ?? String(item.id.prefix(8))
                report.warnings += snapshot.warnings.map { "\(bank) · \($0)" }
                UserDefaults.standard.set(snapshot.fetchedAt, forKey: lastFetchedKey(item.id))
                if let bank = snapshot.accounts.first?.name { institutions[item.id] = Institutions.shortName(bank) }
                earliest = min(earliest, from)
            }
            TransferDetector(context: context).run(since: earliest.addingTimeInterval(-3 * 86_400))
            await Ledger(context: context).enrichPendingMerchants()

            lastReport = report
            lastSyncAt = .now
            lastError = failures.isEmpty ? nil : failures.joined(separator: "\n")
        } catch {
            lastError = error.localizedDescription
        }
    }

    func refreshItems() async {
        guard let server = GardenServer.current else { return }
        do {
            items = try await server.items()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func setItems(_ ids: [String]) async throws {
        guard let server = GardenServer.current else { return }
        items = try await server.setItems(ids)
    }

    func unpair() async {
        await GardenServer.current?.unpair()
        items = []
        lastSyncAt = nil
    }

    /// First sync of an item: 12 months of history. After that: 35 days back from the last fetch,
    /// enough to see late postings, edits and deletions (the Worker clamps either way).
    private func windowStart(for itemId: String) -> Date {
        if let last = UserDefaults.standard.object(forKey: lastFetchedKey(itemId)) as? Date {
            return last.addingTimeInterval(-35 * 86_400)
        }
        return Calendar.brazil.date(byAdding: .month, value: -12, to: .now) ?? .now
    }

    private func lastFetchedKey(_ itemId: String) -> String { "lastFetched." + itemId }
}
