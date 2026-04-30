import AppKit
import Foundation
import Metal
import QuartzCore
import SceneKit

// Mirror of CRTUniforms in crt.metal — must stay byte-for-byte in sync.
private struct CRTUniforms {
    var rgbSplit: Float          = 0.003
    var rollOffset: Float        = 0
    var scanlines: Float         = 0.06
    var scanlineFrequency: Float = 540
}

/// Full-framebuffer CRT post-process via SCNTechnique:
///   scene → DRAW_SCENE render target
///   crt   → DRAW_QUAD that samples the render target through crtFragment
///
/// Compiles crt.metal from source at first enable (one-time ~10ms cost on Apple Silicon).
@MainActor
final class CRTTechnique {

    let technique: SCNTechnique

    init?(device: MTLDevice) {
        guard let t = Self.build(device: device) else { return nil }
        technique = t
    }

    private static func build(device: MTLDevice) -> SCNTechnique? {
        guard
            let url = Bundle.module.url(forResource: "crt", withExtension: "metal"),
            let src = try? String(contentsOf: url, encoding: .utf8),
            let lib = try? device.makeLibrary(source: src, options: nil)
        else { return nil }

        let dict: [String: Any] = [
            "sequence": ["scene", "crt"],
            "passes": [
                "scene": [
                    "draw": "DRAW_SCENE",
                    "colorAttachments": [
                        "color": ["name": "scene_color", "format": "rgba8"]
                    ]
                ],
                "crt": [
                    "draw": "DRAW_QUAD",
                    "colorAttachments": [
                        "color": ["name": "COLOR"]
                    ],
                    "inputs": [
                        "colorTex": "scene_color"
                    ]
                ]
            ]
        ]

        guard let technique = SCNTechnique(dictionary: dict) else { return nil }

        let program = SCNProgram()
        program.library = lib
        program.vertexFunctionName = "crtVertex"
        program.fragmentFunctionName = "crtFragment"

        // Per-frame uniform buffer binding — called from the render thread, no actor isolation needed.
        // rollOffset advances at 0.012 units/sec → one full roll cycle every ~83 s (subtle tape-warp).
        // scanlineFrequency tracks the main screen's backingScaleFactor so a
        // Retina display shows roughly the same physical band thickness as
        // a 1x display — without this, Retina users saw near-invisible
        // 1-pixel bands. Read per-frame so multi-display drag just works.
        program.handleBinding(ofBufferNamed: "u", frequency: .perFrame) { stream, _, _, _ in
            let t = Float(CACurrentMediaTime())
            let scale = Float(NSScreen.main?.backingScaleFactor ?? 1.0)
            var u = CRTUniforms(
                rgbSplit: 0.003,
                rollOffset: (t * 0.012).truncatingRemainder(dividingBy: 1.0),
                scanlines: 0.06,
                scanlineFrequency: 540 * scale
            )
            withUnsafeBytes(of: &u) { ptr in
                stream.writeBytes(ptr.baseAddress!, count: ptr.count)
            }
        }

        technique.setValue(program, forKey: "passes[crt].program")
        return technique
    }
}
