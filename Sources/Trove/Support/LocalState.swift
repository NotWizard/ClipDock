import Combine
import SwiftUI

/// Drop-in replacement for `@State`.
///
/// The SwiftUI `State` macro needs the SwiftUI macro plugin that ships inside a
/// full Xcode toolchain; building with Command Line Tools only, the plugin is
/// missing. This wrapper provides the same ergonomics (value + `$` binding)
/// using `StateObject`, which is a plain property wrapper.
@propertyWrapper
struct LocalState<Value>: DynamicProperty {
    final class Box: ObservableObject {
        @Published var value: Value
        init(_ value: Value) { self.value = value }
    }

    @StateObject private var box: Box

    init(wrappedValue: Value) {
        _box = StateObject(wrappedValue: Box(wrappedValue))
    }

    var wrappedValue: Value {
        get { box.value }
        nonmutating set { box.value = newValue }
    }

    var projectedValue: Binding<Value> {
        Binding(get: { box.value }, set: { box.value = $0 })
    }
}