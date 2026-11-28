import CoreGraphics

/// An integer pixel rectangle in remote framebuffer coordinates.
public struct PixelRect: Sendable, Equatable {
    public var x, y, width, height: Int
    public init(x: Int, y: Int, width: Int, height: Int) { self.x = x; self.y = y; self.width = width; self.height = height }
    public static func full(width: Int, height: Int) -> PixelRect { PixelRect(x: 0, y: 0, width: width, height: height) }
    public var isEmpty: Bool { width <= 0 || height <= 0 }
    public func union(_ other: PixelRect) -> PixelRect {
        if isEmpty { return other }
        if other.isEmpty { return self }
        let minX = min(x, other.x), minY = min(y, other.y)
        let maxX = max(x + width, other.x + other.width), maxY = max(y + height, other.y + other.height)
        return PixelRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
    /// Clips to a `width` x `height` surface; returns an empty rect when nothing overlaps.
    public func clamped(width surfaceWidth: Int, height surfaceHeight: Int) -> PixelRect {
        let minX = max(0, x), minY = max(0, y)
        let maxX = min(surfaceWidth, x + width), maxY = min(surfaceHeight, y + height)
        guard maxX > minX, maxY > minY else { return PixelRect(x: 0, y: 0, width: 0, height: 0) }
        return PixelRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

/// Maps between the local view and the remote framebuffer. Pure so it can be unit tested.
public struct DisplayGeometry: Equatable {
    public var bounds: CGRect
    public var remoteWidth: Int
    public var remoteHeight: Int
    public var fitToWindow: Bool
    public var backingScale: CGFloat
    public init(bounds: CGRect, remoteWidth: Int, remoteHeight: Int, fitToWindow: Bool, backingScale: CGFloat) {
        self.bounds = bounds; self.remoteWidth = remoteWidth; self.remoteHeight = remoteHeight
        self.fitToWindow = fitToWindow; self.backingScale = backingScale
    }

    /// Where the remote image is drawn: aspect-fit, or 1:1 device pixels, centred in `bounds`.
    public var contentRect: CGRect {
        guard remoteWidth > 0, remoteHeight > 0 else { return bounds }
        let scale = fitToWindow
            ? min(bounds.width / CGFloat(remoteWidth), bounds.height / CGFloat(remoteHeight))
            : 1 / max(backingScale, 1)
        let size = CGSize(width: CGFloat(remoteWidth) * scale, height: CGFloat(remoteHeight) * scale)
        return CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    /// Remote pixel under a view point (flipped coordinates), or nil outside the image.
    public func remotePoint(_ p: CGPoint) -> (x: Int, y: Int)? {
        let rect = contentRect
        guard remoteWidth > 0, remoteHeight > 0, rect.contains(p) else { return nil }
        return (min(remoteWidth - 1, max(0, Int((p.x - rect.minX) / rect.width * CGFloat(remoteWidth)))),
                min(remoteHeight - 1, max(0, Int((p.y - rect.minY) / rect.height * CGFloat(remoteHeight)))))
    }
}
