import SwiftUI

enum CommitGraph {
    struct Row: Identifiable {
        var commit: CommitInfo
        var lane: Int
        var columnCount: Int
        var incoming: [String]
        var outgoing: [String]
        var merges: [(Int, Int)]
        var continuesFromAbove: Bool
        var id: String { commit.id }
    }

    static func rows(from commits: [CommitInfo]) -> [Row] {
        var waiting: [String] = []
        var result: [Row] = []
        for commit in commits {
            let continuesFromAbove = waiting.contains(commit.id)
            var incoming = waiting
            let lane: Int
            if let index = incoming.firstIndex(of: commit.id) {
                lane = index
            } else {
                lane = incoming.count
                incoming.append(commit.id)
            }
            var outgoing = incoming
            for index in outgoing.indices where outgoing[index] == commit.id {
                outgoing[index] = ""
            }
            var merges: [(Int, Int)] = []
            if let parent = commit.parents.first {
                if let existing = outgoing.firstIndex(of: parent) {
                    merges.append((lane, existing))
                } else if lane < outgoing.count {
                    outgoing[lane] = parent
                }
            }
            for parent in commit.parents.dropFirst() {
                if let existing = outgoing.firstIndex(of: parent) {
                    merges.append((lane, existing))
                } else if let free = outgoing.firstIndex(of: "") {
                    outgoing[free] = parent
                    merges.append((lane, free))
                } else {
                    outgoing.append(parent)
                    merges.append((lane, outgoing.count - 1))
                }
            }
            while outgoing.last == "" { outgoing.removeLast() }
            result.append(Row(
                commit: commit,
                lane: lane,
                columnCount: max(incoming.count, outgoing.count, 1),
                incoming: incoming,
                outgoing: outgoing,
                merges: merges,
                continuesFromAbove: continuesFromAbove
            ))
            waiting = outgoing
        }
        let width = result.map(\.columnCount).max() ?? 1
        return result.map { row in
            var copy = row
            copy.columnCount = width
            return copy
        }
    }
}

struct CommitGraphMark: View {
    var row: CommitGraph.Row

    static func drawingWidth(columnCount: Int) -> CGFloat {
        // Keep the same scale for every row while leaving room for commit text
        // in a narrow split-view detail column. Canvas scales all lane positions.
        min(CGFloat(max(columnCount, 1)) * 14, 84)
    }

    var body: some View {
        Canvas { context, size in
            let columns = CGFloat(max(row.columnCount, 1))
            let slot = size.width / columns
            let midY = size.height / 2
            func center(_ lane: Int) -> CGFloat { slot * (CGFloat(lane) + 0.5) }

            for lane in 0..<row.columnCount {
                let arrives = lane < row.incoming.count && !row.incoming[lane].isEmpty && (lane != row.lane || row.continuesFromAbove)
                let leaves = lane < row.outgoing.count && !row.outgoing[lane].isEmpty
                guard arrives || leaves || lane == row.lane else { continue }
                if arrives {
                    var path = Path()
                    path.move(to: CGPoint(x: center(lane), y: 0))
                    path.addLine(to: CGPoint(x: center(lane), y: leaves ? size.height : midY))
                    context.stroke(path, with: .color(color(lane)), lineWidth: 2)
                } else if leaves && lane == row.lane {
                    // A lane that is born at this commit (for example the second parent
                    // of a merge) is connected by the merge curve. Drawing a second
                    // vertical segment from midY here leaves a blue stub above the curve.
                    var path = Path()
                    path.move(to: CGPoint(x: center(lane), y: midY))
                    path.addLine(to: CGPoint(x: center(lane), y: size.height))
                    context.stroke(path, with: .color(color(lane)), lineWidth: 2)
                }
            }
            for (from, to) in row.merges {
                var path = Path()
                path.move(to: CGPoint(x: center(from), y: midY))
                path.addQuadCurve(
                    to: CGPoint(x: center(to), y: size.height),
                    control: CGPoint(x: center(to), y: midY)
                )
                context.stroke(path, with: .color(color(to)), lineWidth: 2)
            }
            let dot = CGRect(x: center(row.lane) - 4, y: midY - 4, width: 8, height: 8)
            context.fill(Path(ellipseIn: dot), with: .color(color(row.lane)))
        }
        .frame(width: Self.drawingWidth(columnCount: row.columnCount))
        .accessibilityHidden(true)
    }

    private func color(_ lane: Int) -> Color {
        let palette: [Color] = [.green, .blue, .orange, .purple, .pink, .teal]
        return palette[abs(lane) % palette.count]
    }
}
