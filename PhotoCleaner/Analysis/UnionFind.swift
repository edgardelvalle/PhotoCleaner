/// Disjoint-set structure used to merge "these two photos are alike" links into groups.
struct UnionFind {
    private var parent: [Int]
    private var rank: [UInt8]

    init(count: Int) {
        parent = Array(0..<count)
        rank = Array(repeating: 0, count: count)
    }

    mutating func find(_ element: Int) -> Int {
        var node = element
        while parent[node] != node {
            parent[node] = parent[parent[node]]
            node = parent[node]
        }
        return node
    }

    /// Joins the sets holding `a` and `b`. Returns false if they were already joined.
    @discardableResult
    mutating func union(_ a: Int, _ b: Int) -> Bool {
        let rootA = find(a)
        let rootB = find(b)
        guard rootA != rootB else { return false }
        if rank[rootA] < rank[rootB] {
            parent[rootA] = rootB
        } else if rank[rootA] > rank[rootB] {
            parent[rootB] = rootA
        } else {
            parent[rootB] = rootA
            rank[rootA] += 1
        }
        return true
    }
}
