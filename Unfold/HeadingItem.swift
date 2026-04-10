import Foundation

struct HeadingItem: Identifiable {
    let id: String
    let text: String
    let depth: Int
    var children: [HeadingItem]
    var isExpanded: Bool = true
}

func buildHeadingTree(from flat: [(text: String, depth: Int, slug: String)]) -> [HeadingItem] {
    var root: [HeadingItem] = []
    var stack: [(depth: Int, index: [Int])] = []

    for entry in flat {
        let item = HeadingItem(id: entry.slug, text: entry.text, depth: entry.depth, children: [])

        // Pop stack until we find a parent with smaller depth
        while let last = stack.last, last.depth >= entry.depth {
            stack.removeLast()
        }

        if stack.isEmpty {
            root.append(item)
            stack.append((depth: entry.depth, index: [root.count - 1]))
        } else {
            let parentPath = stack.last!.index
            insertChild(item, at: parentPath, in: &root)
            let childCount = childCountAt(parentPath, in: root)
            var childPath = parentPath
            childPath.append(childCount - 1)
            stack.append((depth: entry.depth, index: childPath))
        }
    }

    return root
}

private func insertChild(_ item: HeadingItem, at path: [Int], in items: inout [HeadingItem]) {
    if path.count == 1 {
        items[path[0]].children.append(item)
    } else {
        var rest = path
        let first = rest.removeFirst()
        insertChild(item, at: rest, in: &items[first].children)
    }
}

private func childCountAt(_ path: [Int], in items: [HeadingItem]) -> Int {
    if path.count == 1 {
        return items[path[0]].children.count
    } else {
        var rest = path
        let first = rest.removeFirst()
        return childCountAt(rest, in: items[first].children)
    }
}

func preserveExpansionState(in newItems: inout [HeadingItem], from oldItems: [HeadingItem]) {
    let oldState = collectExpansionState(oldItems)
    applyExpansionState(&newItems, oldState)
}

private func collectExpansionState(_ items: [HeadingItem]) -> [String: Bool] {
    var state: [String: Bool] = [:]
    for item in items {
        state[item.id] = item.isExpanded
        let childState = collectExpansionState(item.children)
        state.merge(childState) { _, new in new }
    }
    return state
}

private func applyExpansionState(_ items: inout [HeadingItem], _ state: [String: Bool]) {
    for i in items.indices {
        if let expanded = state[items[i].id] {
            items[i].isExpanded = expanded
        }
        applyExpansionState(&items[i].children, state)
    }
}
