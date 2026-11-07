public enum AilbumError: Error, Equatable {
    case sqlite(String)
    case schemaTooOld(Int)
    case decode(String)
    case metal(String)
}

public struct NotImplemented: Error, CustomStringConvertible {
    public let task: String
    public init(task: String) { self.task = task }
    public var description: String { "not implemented: \(task)" }
}
