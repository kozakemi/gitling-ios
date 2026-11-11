import SwiftUI

struct CommitHistoryLabel<References: View>: View {
    let row: CommitGraph.Row
    let minimumHeight: CGFloat
    @ViewBuilder var references: () -> References

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(String(row.commit.id.prefix(7)))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Text(row.commit.summary)
                    .font(.body)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
            Text("\(row.commit.author) · \(row.commit.date.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            references()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 7)
        .padding(.leading, CommitGraphMark.drawingWidth(columnCount: row.columnCount) + 8)
        .frame(minHeight: minimumHeight, alignment: .leading)
        .background(alignment: .leading) {
            GeometryReader { geometry in
                CommitGraphMark(row: row).frame(height: geometry.size.height)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
