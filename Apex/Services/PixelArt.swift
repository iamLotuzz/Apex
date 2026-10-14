import UIKit
import Vision
import CoreImage

/// Turns photos into pixel-art cars: background removal, cropping, pixelation.
enum PixelArt {
    /// Redraws the image upright in RGBA so CoreGraphics can read its pixels.
    static func normalized(_ image: UIImage) -> CGImage? {
        let width = Int(image.size.width * image.scale)
        let height = Int(image.size.height * image.scale)
        guard width > 0, height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        let upright = renderer.image { _ in
            image.draw(in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return upright.cgImage
    }

    /// Cuts out the main subject with Vision. Works on device, not in the simulator.
    static func removeBackground(_ image: CGImage) -> CGImage? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
            guard let result = request.results?.first else { return nil }
            let buffer = try result.generateMaskedImage(
                ofInstances: result.allInstances,
                from: handler,
                croppedToInstancesExtent: true
            )
            let ciImage = CIImage(cvPixelBuffer: buffer)
            return CIContext().createCGImage(ciImage, from: ciImage.extent)
        } catch {
            return nil
        }
    }

    /// Downscales to `columns` pixels wide, reduces the colours and hardens the
    /// alpha edge so the result looks like hand-made pixel art.
    static func pixelate(_ image: CGImage, columns: Int, levels: Int = 6) -> CGImage? {
        let cols = max(8, columns)
        let rows = max(4, Int((Double(image.height) * Double(cols) / Double(image.width)).rounded()))
        guard let context = rgbaContext(width: cols, height: rows) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: cols, height: rows))
        guard let data = context.data else { return nil }
        let pixels = data.bindMemory(to: UInt8.self, capacity: cols * rows * 4)
        let step = 255.0 / Double(max(2, levels) - 1)
        for i in 0..<(cols * rows) {
            let o = i * 4
            let alpha = Double(pixels[o + 3])
            if alpha < 110 {
                pixels[o] = 0
                pixels[o + 1] = 0
                pixels[o + 2] = 0
                pixels[o + 3] = 0
                continue
            }
            // Un-premultiply, quantize, write back fully opaque.
            for c in 0..<3 {
                let value = min(255, Double(pixels[o + c]) * 255 / alpha)
                pixels[o + c] = UInt8(min(255, (value / step).rounded() * step))
            }
            pixels[o + 3] = 255
        }
        return context.makeImage()
    }

    /// Crops fully transparent borders.
    static func trimTransparent(_ image: CGImage) -> CGImage? {
        let width = image.width
        let height = image.height
        guard let context = rgbaContext(width: width, height: height) else { return image }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return image }
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 8 {
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return image }
        // The bitmap context's rows run top to bottom in memory, like the CGImage.
        let rect = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        return image.cropping(to: rect) ?? image
    }

    /// Shrinks very large PNGs with nearest-neighbour sampling to keep pixels crisp.
    static func limitSize(_ image: CGImage, maxSide: Int = 1024) -> CGImage {
        let longest = max(image.width, image.height)
        guard longest > maxSide else { return image }
        let factor = Double(maxSide) / Double(longest)
        let w = max(1, Int(Double(image.width) * factor))
        let h = max(1, Int(Double(image.height) * factor))
        guard let context = rgbaContext(width: w, height: h) else { return image }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return context.makeImage() ?? image
    }

    static func png(_ image: CGImage) -> Data? {
        UIImage(cgImage: image).pngData()
    }

    private static func rgbaContext(width: Int, height: Int) -> CGContext? {
        CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }
}
