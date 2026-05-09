import CoreImage
import Foundation
import Metal

enum RenderContextFactory {
    static func hazeMetalBacked() -> CIContext {
        let options: [CIContextOption: Any] = [.workingColorSpace: NSNull()]
        guard let device = MTLCreateSystemDefaultDevice() else {
            return CIContext(options: options)
        }
        return CIContext(mtlDevice: device, options: options)
    }
}
