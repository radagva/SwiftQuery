# SwiftQuery

A tiny, SwiftUI‑native data fetching and caching library inspired by [TanStack Query](https://tanstack.com/query). SwiftQuery gives you three property wrappers — `@Query`, `@Mutation` and `@InfiniteQuery` — backed by a shared in‑memory cache (`QueryClient`) so your views describe **what** they need, not **how** to fetch or store it.

It is intentionally minimal: no Combine pipelines to wire up, no global singletons to subclass, no network layer of its own. Pair it with whatever HTTP stack you already use — `URLSession`, [Alamofire](https://github.com/Alamofire/Alamofire), or [NetworkAgent](https://github.com/radagva/NetworkAgent).

---

## Features

- `@Query` property wrapper for read operations with automatic caching and `stale / fetching / success / error` state.
- `@Mutation` property wrapper for write operations with optimistic updates and cache invalidation.
- `@InfiniteQuery` property wrapper for paginated reads with `fetchNextPage()` and `hasNextPage` — perfect for infinite scrolls and "load more" buttons.
- Shared `QueryClient` exposed through the SwiftUI environment.
- Strongly typed cache keys derived from the query type **and** its variables.
- Async/await first — no Combine required.
- Network‑library agnostic.

---

## Requirements

- iOS 16+ / macOS 10.15+
- Swift 6.0+ (Swift tools 6.3)
- Xcode 16+

---

## Installation

### Swift Package Manager

In Xcode: **File → Add Package Dependencies…** and use the repository URL:

```
https://github.com/radagva/SwiftQuery
```

Or add it to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/radagva/SwiftQuery", from: "1.0.0"),
],
targets: [
    .target(
        name: "MyApp",
        dependencies: ["SwiftQuery"]
    )
]
```

Then import it:

```swift
import SwiftQuery
```

---

## Core Concepts

### `QueryClient`

The cache. It lives in the SwiftUI environment under `\.queryClient`. A shared default instance (`QueryClient.shared`) is provided automatically, but you can supply your own:

```swift
@main
struct MyApp: App {
    @StateObject private var client = QueryClient()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.queryClient, client)
        }
    }
}
```

### `QueryFunc`

A type that describes how to fetch a value. Conform a struct/class to it, optionally typing the `Variables` it needs:

```swift
public protocol QueryFunc {
    associatedtype Value
    associatedtype Variables: Hashable = QueryVoid
    func run(_ variables: Variables) async throws -> Value
}
```

If your query takes no variables, omit the associated type — it defaults to `QueryVoid`.

### `MutationFunc`

The write‑side counterpart of `QueryFunc`:

```swift
public protocol MutationFunc {
    associatedtype Value
    associatedtype Variables
    func run(variables: Variables) async throws -> Value
}
```

### `@Query`

A property wrapper that holds a `QueryState<Value>` and gives you a `.fetch(variables)` method through its projected value.

```swift
public enum QueryState<Value> {
    case stale
    case fetching
    case error(Error)
    case success(Value)
}
```

### `@Mutation`

The write‑side wrapper with state `stale / pending / success / error` and a `.mutate(with:optimistic:invalidating:)` method.

```swift
public enum MutationState<Value> {
    case stale
    case pending
    case error(Error)
    case success(Value)
}
```

### `InfiniteQueryFunc`

The protocol for paginated reads. You provide an `initialPageParam`, a `run` that takes both your `Variables` and the current `pageParam`, and a `nextPageParam` that derives the next page's parameter from the previous response:

```swift
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
```

Return `nil` from `nextPageParam` to signal "no more pages".

### `@InfiniteQuery`

A property wrapper holding an `InfiniteQueryState<Value, PageParam>` plus `.fetch(...)`, `.fetchNextPage(...)`, and `hasNextPage`:

```swift
public enum InfiniteQueryState<Value, PageParam: Hashable> {
    case stale
    case fetching
    case fetchingNextPage(InfiniteQueryData<Value, PageParam>)
    case error(Error)
    case success(InfiniteQueryData<Value, PageParam>)
}

public struct InfiniteQueryData<Value, PageParam: Hashable> {
    public let pages: [Value]
    public let pageParams: [PageParam]
}
```

`fetchingNextPage` carries the current data so views can keep rendering existing pages while the next one loads.

---

## Quick Start

```swift
import SwiftUI
import SwiftQuery

struct User: Decodable, Hashable {
    let id: Int
    let name: String
}

struct FetchUser: QueryFunc {
    func run(_ id: Int) async throws -> User {
        let url = URL(string: "https://api.example.com/users/\(id)")!
        let (data, _) = try await URLSession.shared.data(from: url)
        return try JSONDecoder().decode(User.self, from: data)
    }
}

struct UserView: View {
    let userID: Int
    @Query(FetchUser()) private var user

    var body: some View {
        Group {
            switch user {
            case .stale, .fetching:
                ProgressView()
            case .success(let user):
                Text(user.name).font(.title)
            case .error(let error):
                Text("Failed: \(error.localizedDescription)")
                    .foregroundStyle(.red)
            }
        }
        .task(id: userID) {
            await $user.fetch(userID)
        }
    }
}
```

That's the whole loop: the view declares what it needs, the cache deduplicates work, and the state drives the UI.

---

## Queries in Depth

### Queries without variables

If your query has no inputs, just conform with the default `QueryVoid`:

```swift
struct FetchCurrentUser: QueryFunc {
    func run(_ variables: QueryVoid) async throws -> User {
        // ...
    }
}

@Query(FetchCurrentUser()) private var me

.task { await $me.fetch(.value) }
```

### Caching

Each result is stored under a key derived from `(QueryFunc type, Variables)`. Calling `.fetch(variables)` again with the **same** variables returns the cached value immediately and does not hit the network. Different variables produce different cache entries.

### Refetching

Trigger a refetch from any user action by calling `await $query.fetch(vars)` again — but note that the cache will short‑circuit if an entry exists. To force a network round‑trip, invalidate the entry first (see “Invalidation” below).

---

## Mutations in Depth

### Basic mutation

```swift
struct CreateTodo: MutationFunc {
    struct Input { let title: String }
    func run(variables: Input) async throws -> Todo {
        // POST /todos
    }
}

struct NewTodoForm: View {
    @State private var title = ""
    @Mutation(CreateTodo()) private var create

    var body: some View {
        Form {
            TextField("Title", text: $title)
            Button("Add") {
                Task { await $create.mutate(with: .init(title: title)) }
            }
            .disabled({
                if case .pending = create { return true } else { return false }
            }())
        }
    }
}
```

### Invalidating cache entries after a mutation

When a mutation succeeds you usually want dependent queries to refetch. Pass their cache keys through `invalidating:`:

```swift
let listKey = QueryCacheKey<FetchTodos>(variables: .value)

await $create.mutate(
    with: .init(title: title),
    invalidating: [listKey]
)
```

The next time a view fetches `FetchTodos`, the cache miss will force a fresh request.

### Optimistic updates

Provide an `optimistic` closure that mutates the cache up front and returns a rollback block. SwiftQuery runs the rollback automatically if the mutation throws.

```swift
await $create.mutate(
    with: .init(title: title),
    optimistic: { client in
        // Speculatively insert into the cache here.
        // Return a closure that undoes the change on failure:
        return { /* rollback */ }
    },
    invalidating: [listKey]
)
```

### Mutations without variables

If `Variables == QueryVoid`, you can call `mutate()` with no arguments:

```swift
struct LogOut: MutationFunc {
    func run(variables: QueryVoid) async throws { /* ... */ }
}

@Mutation(LogOut()) private var logout
// ...
await $logout.mutate()
```

---

## Infinite Queries in Depth

`@InfiniteQuery` powers paginated lists, infinite scrolls, and "load more" buttons. Each call to `fetchNextPage` appends a page to the cached `InfiniteQueryData`; the cache key is derived from the `InfiniteQueryFunc` type **and** its `Variables` — exactly like `@Query`.

### Basic infinite query

```swift
import SwiftUI
import SwiftQuery

struct Todo: Codable, Hashable, Identifiable {
    let id: Int
    let title: String
}

struct FetchTodos: InfiniteQueryFunc {
    let initialPageParam = 1

    func run(variables: QueryVoid, pageParam: Int) async throws -> [Todo] {
        var components = URLComponents(string: "https://api.example.com/todos")!
        components.queryItems = [.init(name: "page", value: "\(pageParam)")]
        let (data, _) = try await URLSession.shared.data(from: components.url!)
        return try JSONDecoder().decode([Todo].self, from: data)
    }

    func nextPageParam(
        lastPage: [Todo],
        allPages: [[Todo]],
        lastPageParam: Int,
        allPageParams: [Int]
    ) -> Int? {
        // Return nil once the API returns an empty page.
        lastPage.isEmpty ? nil : lastPageParam + 1
    }
}

struct TodosScreen: View {
    @InfiniteQuery(FetchTodos()) private var todos

    var body: some View {
        List {
            switch todos {
            case .stale, .fetching:
                ProgressView()

            case .success(let data), .fetchingNextPage(let data):
                ForEach(data.pages.flatMap { $0 }) { todo in
                    Text(todo.title)
                }
                if $todos.hasNextPage {
                    Button("Load more") {
                        Task { await $todos.fetchNextPage() }
                    }
                }

            case .error(let error):
                Text(error.localizedDescription).foregroundStyle(.red)
            }
        }
        .task { await $todos.fetch() }
    }
}
```

### State machine

| State | Carries data? | Meaning |
| --- | --- | --- |
| `.stale` | – | Never fetched |
| `.fetching` | – | Loading the first page |
| `.fetchingNextPage(data)` | yes | Already have pages; fetching another |
| `.success(data)` | yes | All currently loaded pages |
| `.error(error)` | – | A page request failed |

The `data` value carried by `.fetchingNextPage` is the most recent successful set of pages, so you can keep rendering existing rows while the next page loads.

### Variables and per‑query caching

If your paginated endpoint depends on filters (e.g. a search term), express them through `Variables`. Each combination gets its own cache slot:

```swift
struct SearchTodos: InfiniteQueryFunc {
    let initialPageParam = 1

    func run(variables: String, pageParam: Int) async throws -> [Todo] { /* ... */ }

    func nextPageParam(
        lastPage: [Todo],
        allPages: [[Todo]],
        lastPageParam: Int,
        allPageParams: [Int]
    ) -> Int? {
        lastPage.isEmpty ? nil : lastPageParam + 1
    }
}

@InfiniteQuery(SearchTodos()) private var results

.task(id: query) { await $results.fetch(query) }
```

### Invalidating cached pages

When a mutation should drop the cached pages of an infinite query, pass an `InfiniteQueryCacheKey` through `invalidating:`:

```swift
let todosKey = InfiniteQueryCacheKey<FetchTodos>(variables: .value)

await $create.mutate(
    with: input,
    invalidating: [todosKey]
)
```

The next `fetch` will start over from `initialPageParam`.

---

## Networking Examples

The examples below all implement the same two operations:

- `FetchTodos` — `GET /todos`
- `CreateTodo` — `POST /todos`

The only thing that changes is the HTTP layer. Everything wired through `@Query` / `@Mutation` stays identical.

### 1. Raw `URLSession`

```swift
import Foundation
import SwiftQuery

struct Todo: Codable, Hashable, Identifiable {
    let id: Int
    let title: String
    let completed: Bool
}

enum API {
    static let baseURL = URL(string: "https://jsonplaceholder.typicode.com")!
}

// MARK: Query

struct FetchTodos: QueryFunc {
    func run(_ variables: QueryVoid) async throws -> [Todo] {
        let (data, _) = try await URLSession.shared.data(from: API.baseURL.appendingPathComponent("todos"))
        return try JSONDecoder().decode([Todo].self, from: data)
    }
}

// MARK: Mutation

struct CreateTodo: MutationFunc {
    struct Input: Encodable {
        let title: String
        let completed: Bool
    }

    func run(variables: Input) async throws -> Todo {
        var request = URLRequest(url: API.baseURL.appendingPathComponent("todos"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(variables)

        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode(Todo.self, from: data)
    }
}
```

### 2. Alamofire

```swift
import Alamofire
import SwiftQuery

struct FetchTodos: QueryFunc {
    func run(_ variables: QueryVoid) async throws -> [Todo] {
        try await AF.request("https://jsonplaceholder.typicode.com/todos")
            .serializingDecodable([Todo].self)
            .value
    }
}

struct CreateTodo: MutationFunc {
    struct Input: Encodable {
        let title: String
        let completed: Bool
    }

    func run(variables: Input) async throws -> Todo {
        try await AF.request(
            "https://jsonplaceholder.typicode.com/todos",
            method: .post,
            parameters: variables,
            encoder: JSONParameterEncoder.default
        )
        .serializingDecodable(Todo.self)
        .value
    }
}
```

### 3. NetworkAgent

[NetworkAgent](https://github.com/radagva/NetworkAgent) pairs particularly well with SwiftQuery: define your endpoints once as an enum, then write thin `QueryFunc` / `MutationFunc` wrappers around the provider.

```swift
import NetworkAgent
import SwiftQuery

// MARK: Endpoints

enum TodosAPI {
    case list
    case create(title: String, completed: Bool)
}

extension TodosAPI: NetworkAgentEndpoint {
    var baseURL: URL { URL(string: "https://jsonplaceholder.typicode.com")! }

    var path: String {
        switch self {
        case .list, .create: return "/todos"
        }
    }

    var method: HTTPMethod {
        switch self {
        case .list:   return .get
        case .create: return .post
        }
    }

    var headers: [String: String] { [:] }

    var task: HTTPTask {
        switch self {
        case .list:
            return .requestPlain
        case let .create(title, completed):
            return .requestAttributes(
                attributes: ["title": title, "completed": completed],
                encoding: .json
            )
        }
    }
}

// MARK: Provider

private let provider = NetworkAgentProvider<TodosAPI>()

// MARK: Query

struct FetchTodos: QueryFunc {
    func run(_ variables: QueryVoid) async throws -> [Todo] {
        let response: NetworkAgent.Response<[Todo]> = try await provider.request(endpoint: .list)
        return response.data
    }
}

// MARK: Mutation

struct CreateTodo: MutationFunc {
    struct Input {
        let title: String
        let completed: Bool
    }

    func run(variables: Input) async throws -> Todo {
        let response: NetworkAgent.Response<Todo> = try await provider.request(
            endpoint: .create(title: variables.title, completed: variables.completed)
        )
        return response.data
    }
}
```

### Wiring it into a view

The view is the same regardless of which networking layer you picked:

```swift
struct TodosScreen: View {
    @Query(FetchTodos()) private var todos
    @Mutation(CreateTodo()) private var create
    @State private var newTitle = ""

    var body: some View {
        List {
            Section("New todo") {
                TextField("Title", text: $newTitle)
                Button("Add") {
                    Task {
                        await $create.mutate(
                            with: .init(title: newTitle, completed: false),
                            invalidating: [QueryCacheKey<FetchTodos>(variables: .value)]
                        )
                        newTitle = ""
                        await $todos.fetch(.value)
                    }
                }
            }

            Section("Todos") {
                switch todos {
                case .stale, .fetching:
                    ProgressView()
                case .success(let items):
                    ForEach(items) { todo in
                        Text(todo.title)
                    }
                case .error(let error):
                    Text(error.localizedDescription).foregroundStyle(.red)
                }
            }
        }
        .task { await $todos.fetch(.value) }
    }
}
```

---

## Cache Keys

When you need to invalidate something explicitly, build a key with `QueryCacheKey` (or `InfiniteQueryCacheKey` for `@InfiniteQuery`):

```swift
QueryCacheKey<FetchTodos>(variables: .value)
QueryCacheKey<FetchUser>(variables: 42)
InfiniteQueryCacheKey<FetchTodos>(variables: .value)
```

Each key hashes both the function type and the variables, so two different queries that happen to take the same variables never collide — and the `Query` and `InfiniteQuery` namespaces are kept separate too.

---

## Tips

- Drive `.fetch` from `.task(id:)` so navigation/param changes refetch automatically.
- Keep `QueryFunc` / `MutationFunc` types small and free of UI concerns — they are easy to unit‑test that way.
- Treat the `QueryClient` like any other dependency: inject your own instance for previews and tests.

---

## License

MIT — see [LICENSE](./LICENSE).
