public enum AilbumError: Error, Equatable {
    case sqlite(String)
    case schemaTooOld(Int)
    case decode(String)
    case metal(String)
    case invalid(String)
}

