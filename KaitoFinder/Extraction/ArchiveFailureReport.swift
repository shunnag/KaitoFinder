import Foundation

/// Bound both alert layout and text allocation; archive names/reasons may contain newlines.
nonisolated enum ArchiveFailureReport {
    static let displayedLineLimit = 20

    static func describe<S: Sequence>(_ failures: S, name: (S.Element) -> String,
                                     reason: (S.Element) -> String, bundle: Bundle = .main,
                                     line: (String) -> String = { $0 }) -> String {
        // 先頭 20 件はそのまま列挙し、名前を落とさない。超過分だけを理由ごとにまとめて件数で示す。
        let items = Array(failures)
        let locale = bundle.bundleURL.pathExtension == "lproj"
            ? Locale(identifier: bundle.bundleURL.deletingPathExtension().lastPathComponent) : Locale.current
        func count(_ value: Int) -> String { value.formatted(.number.locale(locale)) }
        func singleLine(_ text: String) -> String {
            String(text.prefix(1024)).components(separatedBy: .newlines).joined(separator: " ")
        }
        var lines = items.prefix(displayedLineLimit).map { failure in
            let itemName = singleLine(name(failure))
            return line((itemName.isEmpty ? "" : itemName + ": ") + singleLine(reason(failure)))
        }
        let omitted = items.dropFirst(displayedLineLimit)
        if !omitted.isEmpty {
            // 表示済みの理由と同じものが何件省略されたかを添える。
            let displayedReasons = Set(items.prefix(displayedLineLimit).map { reason($0) })
            let sameReason = omitted.filter { displayedReasons.contains(reason($0)) }.count
            lines.append(String(format: String(localized: "…他 %@ 件（同じ理由: %@ 件）", bundle: bundle),
                                count(omitted.count), count(sameReason)))
        }
        return lines.joined(separator: "\n")
    }
}
