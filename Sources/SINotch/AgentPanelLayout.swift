import Foundation

/// Groups keep their full-width headers. Profile rows can share a line within each group.
struct AgentPanelLayout {
    static let rowHeight: CGFloat = 32
    static let columnSpacing: CGFloat = 12
    private static let minimumColumnWidth: CGFloat = 160
    private static let horizontalInsets: CGFloat = 84

    struct Content {
        let chromeHeight: CGFloat
        let fullWidthRows: Int
        let profilesPerGroup: [Int]
        var detailRowsPerGroup: [[Int]] = []

        func height(columns: Int) -> CGFloat {
            let profileRows = profilesPerGroup.reduce(0) { $0 + ($1 + columns - 1) / columns }
            let detailRows = detailRowsPerGroup.reduce(0) { total, group in
                total + stride(from: 0, to: group.count, by: columns).reduce(0) { rows, start in
                    rows + (group[start..<min(start + columns, group.count)].max() ?? 0)
                }
            }
            let rows = fullWidthRows + profileRows + detailRows
            return chromeHeight + (rows == 0 ? 56 : CGFloat(rows) * AgentPanelLayout.rowHeight)
        }
    }

    let size: CGSize
    let columns: Int
    let fits: Bool

    static func fit(_ content: Content, preferred: CGSize, available: CGSize) -> Self {
        let baseWidth = min(preferred.width, available.width)
        let baseColumns = columnLimit(for: baseWidth)
        func layout(width: CGFloat, columns: Int) -> Self {
            let height = content.height(columns: columns)
            return Self(size: CGSize(width: width, height: min(height, available.height)),
                        columns: columns, fits: height <= available.height)
        }

        // Honor the configured footprint first, then use more of the current display.
        let baseLayouts = (1...baseColumns).map { layout(width: baseWidth, columns: $0) }
        if let compact = baseLayouts.first(where: { $0.fits && $0.size.height <= preferred.height }) { return compact }
        if let taller = baseLayouts.first(where: \.fits) { return taller }

        let maximumColumns = columnLimit(for: available.width)
        for columns in baseColumns..<maximumColumns {
            let count = columns + 1
            let width = horizontalInsets + CGFloat(count) * minimumColumnWidth + CGFloat(columns) * columnSpacing
            let wider = layout(width: width, columns: count)
            if wider.fits { return wider }
        }
        return layout(width: available.width, columns: maximumColumns)
    }

    private static func columnLimit(for width: CGFloat) -> Int {
        max(1, Int((width - horizontalInsets + columnSpacing) / (minimumColumnWidth + columnSpacing)))
    }
}
