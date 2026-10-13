import XCTest

final class GoogleEventIDTests: XCTestCase {
    private static let base32hex = Set("0123456789abcdefghijklmnopqrstuv")

    /// Expected values come from `event_id` in scripts/validate_schema.py (SHA-256 → first 16 bytes →
    /// base32hex with a zero-padded final group → "ss" prefix), so Swift and the Python reference stay in lockstep.
    func testMatchesPythonReference() {
        let expected = [
            "demoplan|session|0": "ssguk2q4a7um9cmol1tbfm0brns0",
            "demoplan|session|5": "ss6t3atbopbt0f8711qk3ivcg3cg",
            "demoplan|milestone|0": "ss5hkgrblhs8k8lht0gmho4ludn0",
            "s": "ss0gt731rkolpbr2h5lmvb3fudbg",
            "hello": "ss5jp4reivm2hgs9n87clcbef2jo",
            "": "ssseoc8gkovge196nruj49irtp4g",
            "計畫|session|0": "ssu1m70gnujnu1f4oqmgvo0fk4hs" // UTF-8 bytes are hashed
        ]
        for (seed, id) in expected {
            XCTAssertEqual(GoogleEventID.make(seed: seed), id, "seed \(seed)")
        }
    }

    func testShapeIsValidGoogleEventID() {
        for seed in ["a", "demoplan|session|0", UUID().uuidString, String(repeating: "x", count: 5000)] {
            let id = GoogleEventID.make(seed: seed)
            // 128 bits → 26 base32hex digits, plus the "ss" prefix. Google allows 5–1024 characters.
            XCTAssertEqual(id.count, 28)
            XCTAssertTrue(id.hasPrefix("ss"))
            XCTAssertTrue(Set(id).isSubset(of: Self.base32hex), id)
        }
    }

    func testFinalGroupIsZeroPadded() {
        // The 26th digit carries only 3 data bits, so its 2 low bits are always zero.
        let paddedDigits = Set("048cgkos")
        for seed in ["a", "b", "c", "demoplan|session|1", "demoplan|milestone|3"] {
            let last = GoogleEventID.make(seed: seed).last!
            XCTAssertTrue(paddedDigits.contains(last), "seed \(seed) ended in \(last)")
        }
    }

    func testDeterministicAndSeedSensitive() {
        XCTAssertEqual(GoogleEventID.make(seed: "plan|session|0"), GoogleEventID.make(seed: "plan|session|0"))
        XCTAssertNotEqual(GoogleEventID.make(seed: "plan|session|0"), GoogleEventID.make(seed: "plan|session|1"))
    }

    func testNewPlanIDShape() {
        let planID = GoogleEventID.newPlanID()
        XCTAssertEqual(planID.count, 12)
        XCTAssertTrue(planID.hasPrefix("ss"))
        XCTAssertTrue(Set(planID).isSubset(of: Self.base32hex), planID)
    }
}
