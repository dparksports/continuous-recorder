import Foundation

/// A value that is read from one thread and written from another.
///
/// Used for the two settings the audio thread needs (profile, power limits): reading
/// them from the audio callback must never touch the main actor, so they live behind a
/// plain lock instead of in the view model.
final class Locked<Value> {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    var current: Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ newValue: Value) {
        lock.lock()
        value = newValue
        lock.unlock()
    }
}
