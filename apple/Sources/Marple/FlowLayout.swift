import SwiftUI

/// Wrapping flow layout: every subview keeps its natural size and wraps to the
/// next line when it would overflow the available width (spec §6). Unlike
/// `LazyVGrid(.adaptive)`, which fixes a column width and can clip or stretch a
/// chip, this sizes each chip to its text and wraps *between* chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = Space.s2
    var lineSpacing: CGFloat = Space.s2

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = computeRows(maxWidth: maxWidth, subviews: subviews)
        let height = rows.reduce(CGFloat.zero) { $0 + $1.height }
            + CGFloat(max(0, rows.count - 1)) * lineSpacing
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: maxWidth.isFinite ? maxWidth : width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = computeRows(maxWidth: bounds.width, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                                      proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func computeRows(maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let projected = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if !current.indices.isEmpty, projected > maxWidth {
                rows.append(current)
                current = Row(indices: [index], width: size.width, height: size.height)
            } else {
                current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
                current.indices.append(index)
                current.height = max(current.height, size.height)
            }
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
