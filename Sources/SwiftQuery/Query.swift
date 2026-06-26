//
//  Query.swift
//  SwiftQuery
//
//  Created by Angel Rada on 06/26/26.
//
import SwiftUI

public protocol QueryFunc {
    associatedtype Value
    associatedtype Variables: Hashable = QueryVoid

    func run(_ variables: Variables) async throws -> Value
}

public enum QueryState<Value> {
    case stale
    case fetching
    case error(Error)
    case success(Value)
}

@propertyWrapper
public struct Query<F: QueryFunc>: DynamicProperty where F.Variables: Hashable {
    @Environment(\.queryClient) private var client
    @State private var state: QueryState<F.Value> = .fetching
    private let fn: F

    public var wrappedValue: QueryState<F.Value> { state }
    public var projectedValue: Query<F> { self }

    init(_ fn: F) { self.fn = fn }

    func fetch(_ variables: F.Variables) async {
        let key = QueryCacheKey<F>(variables: variables)

        if let cached: F.Value = client.get(key) {
            state = .success(cached)
            return
        }

        state = .fetching
        do {
            let value = try await fn.run(variables)
            client.set(value, for: key)
            state = .success(value)
        } catch {
            state = .error(error)
        }
    }
}

public struct QueryVoid: Hashable, Sendable {
    static let value = QueryVoid()
}
