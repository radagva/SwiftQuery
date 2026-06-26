//
//  InfiniteQuery.swift
//  SwiftQuery
//
//  Created by Angel Rada on 06/26/26.
//
import SwiftUI

public protocol InfiniteQueryFunc {
    associatedtype Value
    associatedtype PageParam: Hashable
    associatedtype Variables: Hashable = QueryVoid

    var initialPageParam: PageParam { get }

    func run(variables: Variables, pageParam: PageParam) async throws -> Value

    func nextPageParam(
        lastPage: Value,
        allPages: [Value],
        lastPageParam: PageParam,
        allPageParams: [PageParam]
    ) -> PageParam?
}

public struct InfiniteQueryData<Value, PageParam: Hashable> {
    public let pages: [Value]
    public let pageParams: [PageParam]

    public init(pages: [Value], pageParams: [PageParam]) {
        self.pages = pages
        self.pageParams = pageParams
    }
}

public enum InfiniteQueryState<Value, PageParam: Hashable> {
    case stale
    case fetching
    case fetchingNextPage(InfiniteQueryData<Value, PageParam>)
    case error(Error)
    case success(InfiniteQueryData<Value, PageParam>)
}

@propertyWrapper
public struct InfiniteQuery<F: InfiniteQueryFunc>: DynamicProperty where F.Variables: Hashable {
    @Environment(\.queryClient) private var client
    @State private var state: InfiniteQueryState<F.Value, F.PageParam> = .fetching
    private let fn: F

    public var wrappedValue: InfiniteQueryState<F.Value, F.PageParam> { state }
    public var projectedValue: InfiniteQuery<F> { self }

    public init(_ fn: F) { self.fn = fn }

    public func fetch(_ variables: F.Variables) async {
        let key = InfiniteQueryCacheKey<F>(variables: variables)

        if let cached: InfiniteQueryData<F.Value, F.PageParam> = client.get(key) {
            state = .success(cached)
            return
        }

        state = .fetching

        do {
            let page = try await fn.run(variables: variables, pageParam: fn.initialPageParam)
            let data = InfiniteQueryData(pages: [page], pageParams: [fn.initialPageParam])
            client.set(data, for: key)
            state = .success(data)
        } catch {
            state = .error(error)
        }
    }

    public func fetchNextPage(_ variables: F.Variables) async {
        let current: InfiniteQueryData<F.Value, F.PageParam>
        switch state {
        case .success(let data):
            current = data
        case .fetchingNextPage:
            return
        case .stale, .fetching, .error:
            return
        }

        guard let lastPage = current.pages.last,
              let lastPageParam = current.pageParams.last,
              let nextParam = fn.nextPageParam(
                  lastPage: lastPage,
                  allPages: current.pages,
                  lastPageParam: lastPageParam,
                  allPageParams: current.pageParams
              )
        else { return }

        state = .fetchingNextPage(current)
        let key = InfiniteQueryCacheKey<F>(variables: variables)

        do {
            let page = try await fn.run(variables: variables, pageParam: nextParam)
            let newData = InfiniteQueryData(
                pages: current.pages + [page],
                pageParams: current.pageParams + [nextParam]
            )
            client.set(newData, for: key)
            state = .success(newData)
        } catch {
            state = .error(error)
        }
    }

    public var hasNextPage: Bool {
        let current: InfiniteQueryData<F.Value, F.PageParam>
        switch state {
        case .success(let data), .fetchingNextPage(let data):
            current = data
        case .stale, .fetching, .error:
            return false
        }

        guard let lastPage = current.pages.last,
              let lastPageParam = current.pageParams.last
        else { return false }

        return fn.nextPageParam(
            lastPage: lastPage,
            allPages: current.pages,
            lastPageParam: lastPageParam,
            allPageParams: current.pageParams
        ) != nil
    }
}

public extension InfiniteQuery where F.Variables == QueryVoid {
    func fetch() async {
        await fetch(.value)
    }

    func fetchNextPage() async {
        await fetchNextPage(.value)
    }
}

public struct InfiniteQueryCacheKey<F: InfiniteQueryFunc>: Hashable where F.Variables: Hashable {
    let variables: F.Variables

    public init(variables: F.Variables) {
        self.variables = variables
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(String(reflecting: F.self))
        hasher.combine(variables)
    }
}
