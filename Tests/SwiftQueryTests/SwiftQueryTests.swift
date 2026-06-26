import Foundation
import Testing
@testable import SwiftQuery

// MARK: - Test helpers

actor CallLog<V: Sendable> {
    private(set) var entries: [V] = []
    func record(_ v: V) { entries.append(v) }
    var count: Int { entries.count }
}

struct BoomError: Error, Equatable {}

// MARK: - QueryFunc mocks

struct EchoQuery: QueryFunc {
    func run(_ variables: Int) async throws -> String { "echo:\(variables)" }
}

struct VoidQuery: QueryFunc {
    func run(_ variables: QueryVoid) async throws -> Int { 42 }
}

struct ThrowingQuery: QueryFunc {
    func run(_ variables: QueryVoid) async throws -> Int { throw BoomError() }
}

struct CountingQuery: QueryFunc {
    let log: CallLog<Int>
    func run(_ variables: Int) async throws -> String {
        await log.record(variables)
        return "value:\(variables)"
    }
}

// MARK: - MutationFunc mocks

struct AdderMutation: MutationFunc {
    struct Input { let a: Int; let b: Int }
    func run(variables: Input) async throws -> Int { variables.a + variables.b }
}

struct VoidMutation: MutationFunc {
    func run(variables: QueryVoid) async throws -> String { "done" }
}

struct ThrowingMutation: MutationFunc {
    func run(variables: QueryVoid) async throws -> String { throw BoomError() }
}

// MARK: - InfiniteQueryFunc mocks

struct PagerQuery: InfiniteQueryFunc {
    let initialPageParam = 1

    func run(variables: QueryVoid, pageParam: Int) async throws -> [Int] {
        [pageParam * 10, pageParam * 10 + 1]
    }

    func nextPageParam(
        lastPage: [Int],
        allPages: [[Int]],
        lastPageParam: Int,
        allPageParams: [Int]
    ) -> Int? {
        allPageParams.count < 3 ? lastPageParam + 1 : nil
    }
}

struct BoundedPagerQuery: InfiniteQueryFunc {
    let initialPageParam = 0

    func run(variables: Int, pageParam: Int) async throws -> String {
        "page:\(variables):\(pageParam)"
    }

    func nextPageParam(
        lastPage: String,
        allPages: [String],
        lastPageParam: Int,
        allPageParams: [Int]
    ) -> Int? {
        lastPageParam < 2 ? lastPageParam + 1 : nil
    }
}

struct StringPagerQuery: InfiniteQueryFunc {
    let initialPageParam = "first"

    func run(variables: QueryVoid, pageParam: String) async throws -> String {
        "page:\(pageParam)"
    }

    func nextPageParam(
        lastPage: String,
        allPages: [String],
        lastPageParam: String,
        allPageParams: [String]
    ) -> String? {
        allPageParams.count < 2 ? "page-\(allPageParams.count + 1)" : nil
    }
}

struct ThrowingPagerQuery: InfiniteQueryFunc {
    let initialPageParam = 0

    func run(variables: QueryVoid, pageParam: Int) async throws -> Int {
        throw BoomError()
    }

    func nextPageParam(
        lastPage: Int,
        allPages: [Int],
        lastPageParam: Int,
        allPageParams: [Int]
    ) -> Int? { nil }
}

// MARK: - QueryClient

@Suite struct QueryClientTests {
    @Test func getReturnsNilForMissingKey() {
        let c = QueryClient()
        let v: String? = c.get("missing")
        #expect(v == nil)
    }

    @Test func setAndGetRoundTrip() {
        let c = QueryClient()
        c.set("hello", for: "k")
        let v: String? = c.get("k")
        #expect(v == "hello")
    }

    @Test func setOverwritesValue() {
        let c = QueryClient()
        c.set(1, for: "k")
        c.set(2, for: "k")
        let v: Int? = c.get("k")
        #expect(v == 2)
    }

    @Test func updateMutatesExistingValue() {
        let c = QueryClient()
        c.set([1, 2], for: "k")
        c.update("k") { (a: inout [Int]) in a.append(3) }
        let v: [Int]? = c.get("k")
        #expect(v == [1, 2, 3])
    }

    @Test func updateOnMissingKeyIsNoOp() {
        let c = QueryClient()
        c.update("missing") { (a: inout [Int]) in a.append(99) }
        let v: [Int]? = c.get("missing")
        #expect(v == nil)
    }

    @Test func updateWithMismatchedTypeIsNoOp() {
        let c = QueryClient()
        c.set("string-value", for: "k")
        c.update("k") { (a: inout [Int]) in a.append(99) }
        let v: String? = c.get("k")
        #expect(v == "string-value")
    }

    @Test func invalidateRemovesKey() {
        let c = QueryClient()
        c.set(42, for: "k")
        c.invalidate("k")
        let v: Int? = c.get("k")
        #expect(v == nil)
    }

    @Test func invalidateMissingDoesNotCrash() {
        let c = QueryClient()
        c.invalidate("missing")
        let v: Int? = c.get("missing")
        #expect(v == nil)
    }

    @Test func getWithWrongTypeReturnsNil() {
        let c = QueryClient()
        c.set("string", for: "k")
        let v: Int? = c.get("k")
        #expect(v == nil)
    }

    @Test func independentKeysDoNotInterfere() {
        let c = QueryClient()
        c.set("a", for: "k1")
        c.set("b", for: "k2")
        let v1: String? = c.get("k1")
        let v2: String? = c.get("k2")
        #expect(v1 == "a")
        #expect(v2 == "b")
    }

    @Test func sharedInstanceIsSingleton() {
        let a = QueryClient.shared
        let b = QueryClient.shared
        #expect(a === b)
    }

    @Test func environmentDefaultIsSharedClient() {
        #expect(QueryClientKey.defaultValue === QueryClient.shared)
    }
}

// MARK: - QueryCacheKey

@Suite struct QueryCacheKeyTests {
    @Test func sameTypeAndVariablesAreEqual() {
        let a = QueryCacheKey<EchoQuery>(variables: 1)
        let b = QueryCacheKey<EchoQuery>(variables: 1)
        #expect(a == b)
        #expect(a.hashValue == b.hashValue)
    }

    @Test func differentVariablesAreNotEqual() {
        let a = QueryCacheKey<EchoQuery>(variables: 1)
        let b = QueryCacheKey<EchoQuery>(variables: 2)
        #expect(a != b)
    }

    @Test func differentFuncTypesDoNotCollideInCache() {
        let c = QueryClient()
        c.set("from-echo", for: QueryCacheKey<EchoQuery>(variables: 0))
        c.set(7, for: QueryCacheKey<VoidQuery>(variables: .value))

        let echo: String? = c.get(QueryCacheKey<EchoQuery>(variables: 0))
        let voidv: Int? = c.get(QueryCacheKey<VoidQuery>(variables: .value))
        #expect(echo == "from-echo")
        #expect(voidv == 7)
    }
}

// MARK: - InfiniteQueryCacheKey

@Suite struct InfiniteQueryCacheKeyTests {
    @Test func sameTypeAndVariablesAreEqual() {
        let a = InfiniteQueryCacheKey<PagerQuery>(variables: .value)
        let b = InfiniteQueryCacheKey<PagerQuery>(variables: .value)
        #expect(a == b)
        #expect(a.hashValue == b.hashValue)
    }

    @Test func differentVariablesAreNotEqual() {
        let a = InfiniteQueryCacheKey<BoundedPagerQuery>(variables: 1)
        let b = InfiniteQueryCacheKey<BoundedPagerQuery>(variables: 2)
        #expect(a != b)
    }

    @Test func differentFuncTypesDoNotCollide() {
        let c = QueryClient()
        let a = InfiniteQueryCacheKey<PagerQuery>(variables: .value)
        let b = InfiniteQueryCacheKey<StringPagerQuery>(variables: .value)
        c.set("from-pager", for: a)
        c.set("from-string-pager", for: b)

        let aVal: String? = c.get(a)
        let bVal: String? = c.get(b)
        #expect(aVal == "from-pager")
        #expect(bVal == "from-string-pager")
    }

    @Test func doesNotCollideWithQueryCacheKey() {
        let c = QueryClient()
        let q = QueryCacheKey<EchoQuery>(variables: 0)
        let i = InfiniteQueryCacheKey<BoundedPagerQuery>(variables: 0)
        c.set("query", for: q)
        c.set("infinite", for: i)

        let qVal: String? = c.get(q)
        let iVal: String? = c.get(i)
        #expect(qVal == "query")
        #expect(iVal == "infinite")
    }
}

// MARK: - InfiniteQueryData

@Suite struct InfiniteQueryDataTests {
    @Test func storesPagesAndParams() {
        let d = InfiniteQueryData(pages: ["a", "b"], pageParams: [1, 2])
        #expect(d.pages == ["a", "b"])
        #expect(d.pageParams == [1, 2])
    }

    @Test func canBeEmpty() {
        let d = InfiniteQueryData<String, Int>(pages: [], pageParams: [])
        #expect(d.pages.isEmpty)
        #expect(d.pageParams.isEmpty)
    }
}

// MARK: - QueryVoid

@Suite struct QueryVoidTests {
    @Test func valueIsHashableAndUnique() {
        var seen: Set<QueryVoid> = []
        seen.insert(.value)
        seen.insert(QueryVoid())
        #expect(seen.count == 1)
    }

    @Test func valueEquality() {
        #expect(QueryVoid.value == QueryVoid())
    }
}

// MARK: - QueryFunc direct invocation

@Suite struct QueryFuncTests {
    @Test func runReturnsValue() async throws {
        let r = try await EchoQuery().run(7)
        #expect(r == "echo:7")
    }

    @Test func voidVariantReturnsValue() async throws {
        let r = try await VoidQuery().run(.value)
        #expect(r == 42)
    }

    @Test func throwsPropagated() async {
        await #expect(throws: BoomError.self) {
            _ = try await ThrowingQuery().run(.value)
        }
    }
}

// MARK: - MutationFunc direct invocation

@Suite struct MutationFuncTests {
    @Test func runReturnsSum() async throws {
        let r = try await AdderMutation().run(variables: .init(a: 2, b: 3))
        #expect(r == 5)
    }

    @Test func voidVariantReturnsValue() async throws {
        let r = try await VoidMutation().run(variables: .value)
        #expect(r == "done")
    }

    @Test func throwsPropagated() async {
        await #expect(throws: BoomError.self) {
            _ = try await ThrowingMutation().run(variables: .value)
        }
    }
}

// MARK: - InfiniteQueryFunc direct invocation

@Suite struct InfiniteQueryFuncTests {
    @Test func initialPageParamIsExposed() {
        #expect(PagerQuery().initialPageParam == 1)
        #expect(BoundedPagerQuery().initialPageParam == 0)
        #expect(StringPagerQuery().initialPageParam == "first")
    }

    @Test func runReturnsPage() async throws {
        let p = try await PagerQuery().run(variables: .value, pageParam: 3)
        #expect(p == [30, 31])
    }

    @Test func nextPageParamReturnsNext() {
        let next = PagerQuery().nextPageParam(
            lastPage: [10, 11],
            allPages: [[10, 11]],
            lastPageParam: 1,
            allPageParams: [1]
        )
        #expect(next == 2)
    }

    @Test func nextPageParamReturnsNilAtEnd() {
        let next = PagerQuery().nextPageParam(
            lastPage: [30, 31],
            allPages: [[10, 11], [20, 21], [30, 31]],
            lastPageParam: 3,
            allPageParams: [1, 2, 3]
        )
        #expect(next == nil)
    }

    @Test func supportsCustomPageParamTypes() async throws {
        let q = StringPagerQuery()
        let page = try await q.run(variables: .value, pageParam: "first")
        #expect(page == "page:first")

        let next = q.nextPageParam(
            lastPage: page,
            allPages: [page],
            lastPageParam: "first",
            allPageParams: ["first"]
        )
        #expect(next == "page-2")
    }

    @Test func throwsPropagated() async {
        await #expect(throws: BoomError.self) {
            _ = try await ThrowingPagerQuery().run(variables: .value, pageParam: 0)
        }
    }
}

// MARK: - Property wrapper integration (cache side-effects via the shared client)
//
// `@State` / `@Environment` storage inside a `DynamicProperty` only takes
// effect when the property wrapper is hosted in a SwiftUI view tree. In a
// unit-test context, `@Environment(\.queryClient)` still resolves to its
// default (`QueryClient.shared`), so we can verify side-effects on the cache
// even though the in-struct `state` is not observable from outside SwiftUI.
//
// We wrap all three integration suites in one parent `.serialized` suite so
// every test runs sequentially. This avoids two distinct races:
//   1. SwiftUI's `@State` backing storage is not thread-safe when accessed
//      outside a view tree — concurrent reads/writes from parallel tests
//      crash with invalid memory access.
//   2. `QueryClient`'s underlying dictionary is not thread-safe; parallel
//      tests writing to `QueryClient.shared` can corrupt it.

@Suite(.serialized)
struct PropertyWrapperIntegrationTests {

@Suite struct QueryIntegrationTests {
    @Test func fetchPopulatesCacheOnSuccess() async {
        let key = QueryCacheKey<EchoQuery>(variables: 1_100)
        QueryClient.shared.invalidate(key)
        defer { QueryClient.shared.invalidate(key) }

        let q = Query(EchoQuery())
        await q.fetch(1_100)

        let cached: String? = QueryClient.shared.get(key)
        #expect(cached == "echo:1100")
    }

    @Test func fetchDoesNotPopulateOnError() async {
        let key = QueryCacheKey<ThrowingQuery>(variables: .value)
        QueryClient.shared.invalidate(key)
        defer { QueryClient.shared.invalidate(key) }

        let q = Query(ThrowingQuery())
        await q.fetch(.value)

        let cached: Int? = QueryClient.shared.get(key)
        #expect(cached == nil)
    }

    @Test func fetchHitsCacheOnSecondCall() async {
        let log = CallLog<Int>()
        let key = QueryCacheKey<CountingQuery>(variables: 1_200)
        QueryClient.shared.invalidate(key)
        defer { QueryClient.shared.invalidate(key) }

        let q = Query(CountingQuery(log: log))
        await q.fetch(1_200)
        let first = await log.count
        #expect(first == 1)

        await q.fetch(1_200)
        let second = await log.count
        #expect(second == 1)
    }

    @Test func fetchSeparatesCacheByVariables() async {
        let log = CallLog<Int>()
        let key1 = QueryCacheKey<CountingQuery>(variables: 1_301)
        let key2 = QueryCacheKey<CountingQuery>(variables: 1_302)
        QueryClient.shared.invalidate(key1)
        QueryClient.shared.invalidate(key2)
        defer {
            QueryClient.shared.invalidate(key1)
            QueryClient.shared.invalidate(key2)
        }

        let q = Query(CountingQuery(log: log))
        await q.fetch(1_301)
        await q.fetch(1_302)

        let count = await log.count
        #expect(count == 2)
        let c1: String? = QueryClient.shared.get(key1)
        let c2: String? = QueryClient.shared.get(key2)
        #expect(c1 == "value:1301")
        #expect(c2 == "value:1302")
    }

    @Test func fetchRefetchesAfterInvalidate() async {
        let log = CallLog<Int>()
        let key = QueryCacheKey<CountingQuery>(variables: 1_400)
        QueryClient.shared.invalidate(key)
        defer { QueryClient.shared.invalidate(key) }

        let q = Query(CountingQuery(log: log))
        await q.fetch(1_400)
        QueryClient.shared.invalidate(key)
        await q.fetch(1_400)

        let count = await log.count
        #expect(count == 2)
    }
}

// MARK: - Mutation integration

@Suite struct MutationIntegrationTests {
    @Test func mutateInvalidatesKeysOnSuccess() async {
        let key = QueryCacheKey<EchoQuery>(variables: 2_100)
        QueryClient.shared.set("seeded", for: key)
        defer { QueryClient.shared.invalidate(key) }

        let m = Mutation(VoidMutation())
        await m.mutate(invalidating: [key])

        let after: String? = QueryClient.shared.get(key)
        #expect(after == nil)
    }

    @Test func mutateOptimisticStaysAppliedOnSuccess() async {
        let key = QueryCacheKey<EchoQuery>(variables: 2_200)
        QueryClient.shared.invalidate(key)
        defer { QueryClient.shared.invalidate(key) }

        let m = Mutation(VoidMutation())
        await m.mutate(
            optimistic: { c in
                c.set("optimistic", for: key)
                return { c.invalidate(key) }
            },
            invalidating: []
        )

        let after: String? = QueryClient.shared.get(key)
        #expect(after == "optimistic")
    }

    @Test func mutateRollsBackOptimisticOnError() async {
        let key = QueryCacheKey<EchoQuery>(variables: 2_300)
        QueryClient.shared.set("original", for: key)
        defer { QueryClient.shared.invalidate(key) }

        let m = Mutation(ThrowingMutation())
        await m.mutate(
            optimistic: { c in
                c.set("optimistic", for: key)
                return { c.set("original", for: key) }
            },
            invalidating: []
        )

        let after: String? = QueryClient.shared.get(key)
        #expect(after == "original")
    }

    @Test func mutateOnErrorDoesNotInvalidate() async {
        let key = QueryCacheKey<EchoQuery>(variables: 2_400)
        QueryClient.shared.set("seeded", for: key)
        defer { QueryClient.shared.invalidate(key) }

        let m = Mutation(ThrowingMutation())
        await m.mutate(invalidating: [key])

        let after: String? = QueryClient.shared.get(key)
        #expect(after == "seeded")
    }

    @Test func mutateWithVariablesOverloadCompilesAndRuns() async {
        let m = Mutation(AdderMutation())
        await m.mutate(with: .init(a: 4, b: 5))
    }
}

// MARK: - InfiniteQuery integration

@Suite struct InfiniteQueryIntegrationTests {
    @Test func fetchPopulatesFirstPage() async {
        let key = InfiniteQueryCacheKey<PagerQuery>(variables: .value)
        QueryClient.shared.invalidate(key)
        defer { QueryClient.shared.invalidate(key) }

        let q = InfiniteQuery(PagerQuery())
        await q.fetch()

        let cached: InfiniteQueryData<[Int], Int>? = QueryClient.shared.get(key)
        #expect(cached?.pages == [[10, 11]])
        #expect(cached?.pageParams == [1])
    }

    @Test func fetchDoesNotPopulateOnError() async {
        let key = InfiniteQueryCacheKey<ThrowingPagerQuery>(variables: .value)
        QueryClient.shared.invalidate(key)
        defer { QueryClient.shared.invalidate(key) }

        let q = InfiniteQuery(ThrowingPagerQuery())
        await q.fetch()

        let cached: InfiniteQueryData<Int, Int>? = QueryClient.shared.get(key)
        #expect(cached == nil)
    }

    @Test func fetchPreservesExistingCachedPages() async {
        let key = InfiniteQueryCacheKey<PagerQuery>(variables: .value)
        QueryClient.shared.invalidate(key)
        defer { QueryClient.shared.invalidate(key) }

        let seeded = InfiniteQueryData(pages: [[10, 11], [20, 21]], pageParams: [1, 2])
        QueryClient.shared.set(seeded, for: key)

        let q = InfiniteQuery(PagerQuery())
        await q.fetch()

        let cached: InfiniteQueryData<[Int], Int>? = QueryClient.shared.get(key)
        #expect(cached?.pages == [[10, 11], [20, 21]])
        #expect(cached?.pageParams == [1, 2])
    }

    @Test func fetchSeparatesCacheByVariables() async {
        let key1 = InfiniteQueryCacheKey<BoundedPagerQuery>(variables: 1)
        let key2 = InfiniteQueryCacheKey<BoundedPagerQuery>(variables: 2)
        QueryClient.shared.invalidate(key1)
        QueryClient.shared.invalidate(key2)
        defer {
            QueryClient.shared.invalidate(key1)
            QueryClient.shared.invalidate(key2)
        }

        let q = InfiniteQuery(BoundedPagerQuery())
        await q.fetch(1)
        await q.fetch(2)

        let c1: InfiniteQueryData<String, Int>? = QueryClient.shared.get(key1)
        let c2: InfiniteQueryData<String, Int>? = QueryClient.shared.get(key2)
        #expect(c1?.pages == ["page:1:0"])
        #expect(c2?.pages == ["page:2:0"])
    }

    @Test func fetchUsesInitialPageParamFromFunc() async {
        let key = InfiniteQueryCacheKey<StringPagerQuery>(variables: .value)
        QueryClient.shared.invalidate(key)
        defer { QueryClient.shared.invalidate(key) }

        let q = InfiniteQuery(StringPagerQuery())
        await q.fetch()

        let cached: InfiniteQueryData<String, String>? = QueryClient.shared.get(key)
        #expect(cached?.pages == ["page:first"])
        #expect(cached?.pageParams == ["first"])
    }

    @Test func hasNextPageIsFalseBeforeFirstFetch() {
        let q = InfiniteQuery(PagerQuery())
        #expect(q.hasNextPage == false)
    }

    @Test func fetchNextPageBeforeSuccessIsNoOp() async {
        let key = InfiniteQueryCacheKey<PagerQuery>(variables: .value)
        QueryClient.shared.invalidate(key)
        defer { QueryClient.shared.invalidate(key) }

        let q = InfiniteQuery(PagerQuery())
        await q.fetchNextPage()

        let cached: InfiniteQueryData<[Int], Int>? = QueryClient.shared.get(key)
        #expect(cached == nil)
    }
}
}
