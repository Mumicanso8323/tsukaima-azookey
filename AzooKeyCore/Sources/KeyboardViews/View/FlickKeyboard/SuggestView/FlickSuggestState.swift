import struct CustardKit.GridFitPositionSpecifier

struct FlickSuggestState: Equatable, Hashable, Sendable {
    /// 位置：サジェストタイプ
    var items: [GridFitPositionSpecifier: FlickSuggestType] = [:]
}
