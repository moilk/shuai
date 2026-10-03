/// Thin Swift facade over the UniFFI-generated bindings.
public enum ShuaiCore {
    public static func ping() -> String { rustPing() }
    public static func coreVersion() -> String { rustCoreVersion() }
}

// Free-function indirection: inside `ShuaiCore` the unqualified names would
// resolve to the static members and recurse.
private func rustPing() -> String { ping() }
private func rustCoreVersion() -> String { coreVersion() }
