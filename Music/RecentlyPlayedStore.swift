import Foundation
import Combine

final class RecentlyPlayedStore: ObservableObject {
	static let shared = RecentlyPlayedStore()
	@Published private(set) var items: [UUID] = []
	private let key = "recently_played_ids"

	private init() {
		if let data = UserDefaults.standard.array(forKey: key) as? [String] {
			items = data.compactMap { UUID(uuidString: $0) }
		}
	}

	func record(_ id: UUID?) {
		guard let id else { return }
		var set = LinkedHashSet(items)
		set.prependUnique(id)
		items = Array(set.prefix(50))
		UserDefaults.standard.set(items.map { $0.uuidString }, forKey: key)
	}
}

private struct LinkedHashSet<Element: Hashable>: Sequence {
	private var order: [Element]
	private var seen: Set<Element>
	init(_ arr: [Element] = []) { order = []; seen = []; arr.forEach { append($0) } }
	mutating func append(_ e: Element) { if seen.insert(e).inserted { order.append(e) } }
	mutating func prependUnique(_ e: Element) { if let idx = order.firstIndex(of: e) { order.remove(at: idx) } ; order.insert(e, at: 0); seen.insert(e) }
	func makeIterator() -> IndexingIterator<[Element]> { order.makeIterator() }
	func prefix(_ n: Int) -> ArraySlice<Element> { order.prefix(n) }
} 