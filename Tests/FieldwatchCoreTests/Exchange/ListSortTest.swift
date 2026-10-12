import Foundation
import Testing
@testable import FieldwatchCore

// Port of ListSortTest.kt.

@Suite struct ListSortTest {
    @Test func newestAlertPutsMostRecentFirstAndNeverAlertedLast() {
        let alerts: [String: Int] = ["a": 10, "b": 30, "c": 20]
        let keys = ["a", "never", "c", "b"]
        // compareByDescending { alerts[it] ?: 0 }.thenBy { it }
        let sorted = keys.sortedWithComparator { x, y in
            let c = compareValues(alerts[y] ?? 0, alerts[x] ?? 0)
            return c != 0 ? c : compareValues(x, y)
        }
        #expect(sorted == ["b", "c", "a", "never"])
    }
}
