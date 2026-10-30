import Foundation

/// Determines region reading order from panel order plus position inside each panel.
///
/// Not a plain Y sort: regions are first grouped by comic panel (panels are already ordered by
/// the panel detector), then read in bands — within a band the reading direction decides.
public enum ReadingOrder {
    public static func assignPanels(_ regions: inout [TextRegion], panels: [ComicPanel]) {
        for i in regions.indices {
            let r = regions[i].bbox
            var best: (Int, Double)?
            for p in panels {
                let a = r.intersection(p.bbox).area
                if a > 0, a > (best?.1 ?? 0) { best = (p.index, a) }
            }
            regions[i].panelIndex = best?.0
        }
    }

    /// Returns regions with `readingIndex` set, ordered.
    public static func order(_ input: [TextRegion], panels: [ComicPanel], direction: ReadingDirection) -> [TextRegion] {
        var regions = input
        assignPanels(&regions, panels: panels)
        let sortedPanels = panels.sorted { $0.index < $1.index }
        // Group per panel; unassigned regions get their own group placed by vertical position.
        var groups: [(key: Double, items: [TextRegion])] = []
        for (i, p) in sortedPanels.enumerated() {
            let items = regions.filter { $0.panelIndex == p.index }
            if !items.isEmpty { groups.append((Double(i), items)) }
        }
        for r in regions where r.panelIndex == nil {
            // Insert before the first panel that starts below this region's centre.
            let firstBelow = sortedPanels.firstIndex { $0.bbox.minY > r.bbox.midY } ?? sortedPanels.count
            groups.append((Double(firstBelow) - 0.5 + r.bbox.midY / 1e9, [r]))
        }
        groups.sort { $0.key < $1.key }
        var result: [TextRegion] = []
        for g in groups { result += orderWithinPanel(g.items, direction: direction) }
        for i in result.indices { result[i].readingIndex = i }
        return result
    }

    static func orderWithinPanel(_ items: [TextRegion], direction: ReadingDirection) -> [TextRegion] {
        var remaining = items
        var out: [TextRegion] = []
        while !remaining.isEmpty {
            guard let top = remaining.min(by: { $0.bbox.minY < $1.bbox.minY }) else { break }
            // Band = regions starting above the top region's vertical middle.
            let limit = top.bbox.minY + top.bbox.height * 0.5
            let band = remaining.filter { $0.bbox.minY <= limit }
            let pick: TextRegion
            switch direction {
            case .rightToLeft: pick = band.max { $0.bbox.maxX < $1.bbox.maxX }!
            case .leftToRight, .topToBottom: pick = band.min { $0.bbox.minX < $1.bbox.minX }!
            }
            out.append(pick)
            remaining.removeAll { $0.id == pick.id }
        }
        return out
    }

    /// Applies a user-chosen order (ids first in the given order, others keep relative order after).
    public static func apply(order ids: [String], to page: inout ComicPage) {
        let original = page.orderedRegions.map(\.id)
        var next = 0
        var seen = Set<String>()
        for id in ids { if let i = page.regionIndex(id), !seen.contains(id) { page.regions[i].readingIndex = next; next += 1; seen.insert(id) } }
        for id in original where !seen.contains(id) {
            if let i = page.regionIndex(id) { page.regions[i].readingIndex = next; next += 1 }
        }
    }
}
