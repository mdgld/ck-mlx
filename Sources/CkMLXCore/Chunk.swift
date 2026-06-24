import Foundation

public struct Chunker {
    public let maxLines: Int
    public let overlapLines: Int

    public init(maxLines: Int = 50, overlapLines: Int = 10) {
        self.maxLines = maxLines
        self.overlapLines = overlapLines
    }

    public struct Chunk {
        public let content: String
        public let startLine: Int
        public let endLine: Int

        public init(content: String, startLine: Int, endLine: Int) {
            self.content = content
            self.startLine = startLine
            self.endLine = endLine
        }
    }

    public func chunk(content: String) -> [Chunk] {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let lines = trimmed.components(separatedBy: .newlines)

        var chunks: [Chunk] = []
        var currentStart = 0

        while currentStart < lines.count {
            let end = min(currentStart + maxLines, lines.count)
            let chunkLines = lines[currentStart..<end]
            let chunkContent = chunkLines.joined(separator: "\n")

            chunks.append(Chunk(
                content: chunkContent,
                startLine: currentStart + 1,
                endLine: end
            ))

            if end >= lines.count { break }

            currentStart = end - overlapLines
            if currentStart >= lines.count { break }
            if currentStart <= chunks.last.map({ $0.startLine }) ?? 0 {
                currentStart = end
            }
        }

        return chunks
    }
}
