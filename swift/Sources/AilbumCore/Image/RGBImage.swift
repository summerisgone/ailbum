public struct RGBImage: Equatable {
    public let width: Int
    public let height: Int
    public var pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(pixels.count == width * height * 3, "RGBImage pixel count must be width * height * 3")
        self.width = width
        self.height = height
        self.pixels = pixels
    }
}
