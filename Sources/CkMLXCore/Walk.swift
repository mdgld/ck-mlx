import Foundation

/// Walks a directory tree respecting ignore patterns.
public struct FileWalker {
    public let root: URL
    public let defaultExcludes: Set<String>
    public var customIgnores: [String] = []

    public init(root: URL) {
        self.root = root
        self.defaultExcludes = [
            ".ck-mlx",
            ".git",
            "node_modules",
            ".DS_Store",
            "__pycache__",
            ".venv",
            "dist",
            "build",
            ".mypy_cache",
            ".pytest_cache",
            ".ruff_cache",
            "vendor",
            "target",
        ]
    }

    public func walk() -> [URL] {
        var files: [URL] = []
        let excludes = loadIgnores()

        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return files
        }

        for case let url as URL in enumerator {
            let relativePath = url.path.replacingOccurrences(of: root.path + "/", with: "")

            if isExcluded(relativePath, patterns: excludes) {
                if url.hasDirectoryPath {
                    enumerator.skipDescendants()
                }
                continue
            }

            guard let resourceValues = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                  resourceValues.isRegularFile == true else {
                continue
            }

            files.append(url)
        }

        return files
    }

    // MARK: - Private

    private func loadIgnores() -> [String] {
        var patterns: [String] = []
        patterns.append(contentsOf: defaultExcludes.map { "**/\($0)/**" })

        let ckignore = root.appendingPathComponent(".ckignore")
        if FileManager.default.fileExists(atPath: ckignore.path),
           let content = try? String(contentsOf: ckignore, encoding: .utf8) {
            let lines = content.components(separatedBy: .newlines)
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty && !trimmed.hasPrefix("#") {
                    patterns.append(trimmed)
                }
            }
        }

        let gitignore = root.appendingPathComponent(".gitignore")
        if FileManager.default.fileExists(atPath: gitignore.path),
           let content = try? String(contentsOf: gitignore, encoding: .utf8) {
            let lines = content.components(separatedBy: .newlines)
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty && !trimmed.hasPrefix("#") {
                    patterns.append(trimmed)
                }
            }
        }

        patterns.append(contentsOf: customIgnores)
        return patterns
    }

    private func isExcluded(_ relativePath: String, patterns: [String]) -> Bool {
        for pattern in patterns {
            if matchesGlob(relativePath, pattern: pattern) {
                return true
            }
        }
        return false
    }

    private func matchesGlob(_ path: String, pattern: String) -> Bool {
        let p = pattern.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let normalized = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        if p.hasSuffix("**") {
            let dirName = String(p.dropLast(2)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !dirName.isEmpty && normalized.contains(dirName) {
                return true
            }
        }

        if p.contains("**") {
            let parts = p.components(separatedBy: "**")
            var remaining = normalized
            for (i, part) in parts.enumerated() {
                let trimmed = part.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                if trimmed.isEmpty { continue }
                if i == 0 {
                    guard remaining.hasPrefix(trimmed) else { return false }
                    remaining = String(remaining.dropFirst(trimmed.count))
                } else if i == parts.count - 1 {
                    guard remaining.hasSuffix(trimmed) else { return false }
                } else {
                    guard let range = remaining.range(of: trimmed) else { return false }
                    remaining = String(remaining[range.upperBound...])
                }
            }
            return true
        }

        if p.hasPrefix("*.") {
            return normalized.hasSuffix(String(p.dropFirst(1)))
        }
        if p.hasSuffix("/*") {
            return normalized.hasPrefix(String(p.dropLast(2)))
        }

        return normalized == p || normalized.hasPrefix(p)
    }
}
