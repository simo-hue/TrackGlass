/// IDs are returned only after the frame carrying the terminal phase is emitted. The free list is a FIFO ring
/// (§4.4, §5.2): `release` appends at the tail and `acquire` takes from the head, so the least recently released ID
/// is reused first and a just-lifted finger's ID comes back only after the 255 others. When the datagrams around a
/// lift are lost, the next finger then arrives under a fresh ID and the Mac ends the old one (§4.7) instead of
/// continuing it as a pointer jump. Fixed storage; never hands out a live ID.
struct ContactIDPool {
    private var ring = Array((0...255).map(UInt8.init))
    private var allocated = Array(repeating: false, count: 256)
    private var head = 0
    private var count = 256

    mutating func acquire() -> UInt8? {
        guard count > 0 else { return nil }
        let id = ring[head]
        head = (head + 1) & 255
        count -= 1
        allocated[Int(id)] = true
        return id
    }

    mutating func release(_ id: UInt8) {
        guard allocated[Int(id)] else { return }
        allocated[Int(id)] = false
        ring[(head + count) & 255] = id   // count < 256 here: only an allocated ID gets this far
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
