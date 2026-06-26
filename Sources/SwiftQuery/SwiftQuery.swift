// The Swift Programming Language
// https://docs.swift.org/swift-book
import Foundation
import Combine
import SwiftUI


public final class QueryClient: @unchecked Sendable, ObservableObject {
    private var cache: [AnyHashable: Any] = [:]

    func get<Value>(_ key: AnyHashable) -> Value? {
        cache[key] as? Value
    }

    func set<Value>(_ value: Value, for key: AnyHashable) {
        cache[key] = value
        objectWillChange.send()
    }

    func update<Value>(_ key: AnyHashable, _ transform: (inout Value) -> Void) {
        guard var current: Value = get(key) else { return }
        transform(&current)
        set(current, for: key)
    }

    func invalidate(_ key: AnyHashable) {
        cache.removeValue(forKey: key)
        objectWillChange.send()
    }
}

extension QueryClient {
    static let shared = QueryClient()
}

public struct QueryClientKey: EnvironmentKey {
    public static let defaultValue = QueryClient.shared
}

public extension EnvironmentValues {
    var queryClient: QueryClient {
        get { self[QueryClientKey.self] }
        set { self[QueryClientKey.self] = newValue }
    }
}

public struct QueryCacheKey<F: QueryFunc>: Hashable where F.Variables: Hashable {
    let variables: F.Variables

    public func hash(into hasher: inout Hasher) {
        hasher.combine(String(reflecting: F.self))
        hasher.combine(variables)
    }
}
