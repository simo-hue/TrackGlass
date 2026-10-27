/// IDs are returned only after the frame carrying the terminal phase is emitted.
struct ContactIDPool {
    private var available = Array((0...255).reversed().map(UInt8.init))
    private var allocated = Array(repeating: false, count: 256)
    private var count = 256

    mutating func acquire() -> UInt8? {
        guard count > 0 else { return nil }
        count -= 1
        let id = available[count]
        allocated[Int(id)] = true
        return id
    }

    mutating func release(_ id: UInt8) {
        guard allocated[Int(id)] else { return }
        allocated[Int(id)] = false
        available[count] = id
        count += 1
    }
}

/// Storage is allocated once; slots retain the UIKit touch objects until removal.
final class LiveContactTable<Touch: AnyObject> {
    struct Entry {
        let touch: Touch
        let contactID: UInt8
    }

    static var capacity: Int { 10 }
    private var slots: [Entry?] = Array(repeating: nil, count: 10)
    private var ids = ContactIDPool()
    private(set) var count = 0

    subscript(index: Int) -> Entry? { slots[index] }

    @discardableResult
    func insert(_ touch: Touch) -> UInt8? {
        var empty: Int?
        for index in slots.indices {
            if let entry = slots[index] {
                if entry.touch === touch { return entry.contactID }
            } else if empty == nil {
                empty = index
            }
        }
        guard let index = empty, let id = ids.acquire() else { return nil }
        slots[index] = Entry(touch: touch, contactID: id)
        count += 1
        return id
    }

    func removeAll() {
        for index in slots.indices {
            if let entry = slots[index] { ids.release(entry.contactID); slots[index] = nil }
        }
        count = 0
    }

    func remove(_ touch: Touch) {
        for index in slots.indices {
            guard let entry = slots[index], entry.touch === touch else { continue }
            ids.release(entry.contactID)
            slots[index] = nil
            count -= 1
            return
        }
    }
}
