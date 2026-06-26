//
//  Mutation.swift
//  SwiftQuery
//
//  Created by Angel Rada on 06/26/26.
//
import SwiftUI

public protocol MutationFunc {
    associatedtype Value
    associatedtype Variables
    
    func run(variables: Variables) async throws -> Value
}

public enum MutationState<Value> {
    case stale
    case pending
    case error(Error)
    case success(Value)
}

@propertyWrapper
public struct Mutation<T: MutationFunc>: DynamicProperty {
    @Environment(\.queryClient) private var client

    @State private var state: MutationState<T.Value> = .stale

    private var fn: T

    public var wrappedValue: MutationState<T.Value> { state }
    public var projectedValue: Mutation<T> { self }

    init(_ fn: T) {
        self.fn = fn
    }

    /// - Parameters:
    ///   - optimistic: Receives the client so you can speculatively update the cache.
    ///                 Return a rollback closure; it's called automatically on error.
    ///   - invalidating: Cache keys to drop after a successful mutation.
    func mutate(
        with variables: T.Variables,
        optimistic: ((QueryClient) -> () -> Void)? = nil,
        invalidating keys: [AnyHashable] = []
    ) async {
        let rollback = optimistic?(client)

        state = .pending
        do {
            let result = try await fn.run(variables: variables)
            keys.forEach { client.invalidate($0) }
            state = .success(result)
        } catch {
            rollback?()
            state = .error(error)
        }
    }
}

public extension Mutation where T.Variables == QueryVoid {
    func mutate(
        optimistic: ((QueryClient) -> () -> Void)? = nil,
        invalidating keys: [AnyHashable] = []
    ) async {
        await mutate(with: .value, optimistic: optimistic, invalidating: keys)
    }
}
