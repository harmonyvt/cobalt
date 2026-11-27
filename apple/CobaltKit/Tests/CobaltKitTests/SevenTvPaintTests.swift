import Foundation
import Testing
@testable import CobaltKit

@Suite struct SevenTvPaintTests {
    @Test func decodesRadialShapeCircleAndEllipseFromWire() throws {
        let circleJSON = """
        {"op":0,"d":{"type":"cosmetic.create","body":{"object":{"id":"p-circ","kind":"PAINT","data":{
          "id":"p-circ","name":"Ice & Snow","function":"RADIAL_GRADIENT","repeat":false,"angle":0,"shape":"circle",
          "stops":[{"at":0.2,"color":1354680575},{"at":0.8,"color":-252645121}],
          "shadows":[
            {"x_offset":-1,"y_offset":0,"radius":0.7,"color":102},
            {"x_offset":1,"y_offset":0,"radius":0.7,"color":102},
            {"x_offset":0,"y_offset":-1,"radius":0.7,"color":102},
            {"x_offset":0,"y_offset":1,"radius":0.7,"color":102}
          ]
        }}}}}
        """
        let circleEnv = try SevenTvChatWire.decoder().decode(SevenTvChatWire.Envelope.self, from: Data(circleJSON.utf8))
        let circleData = try #require(circleEnv.d?.body?.object?.data)
        let circlePaint = try #require(SevenTvChatWire.paint(circleData, id: "p-circ"))
        #expect(circlePaint.kind == .radial)
        #expect(circlePaint.shape == .circle)
        #expect(circlePaint.shadows.count == 4)

        let ellipseJSON = """
        {"op":0,"d":{"type":"cosmetic.create","body":{"object":{"id":"p-ell","kind":"PAINT","data":{
          "id":"p-ell","name":"Solar Flare","function":"RADIAL_GRADIENT","repeat":true,"angle":0,"shape":"ellipse",
          "stops":[{"at":0.72,"color":-2925313},{"at":0.87,"color":-7864065},{"at":0.95,"color":-103119105}],
          "shadows":[{"x_offset":0,"y_offset":0,"radius":1.0,"color":-861929217},{"x_offset":0,"y_offset":0,"radius":3.5,"color":-1303705857}]
        }}}}}
        """
        let ellEnv = try SevenTvChatWire.decoder().decode(SevenTvChatWire.Envelope.self, from: Data(ellipseJSON.utf8))
        let ellData = try #require(ellEnv.d?.body?.object?.data)
        let ellPaint = try #require(SevenTvChatWire.paint(ellData, id: "p-ell"))
        #expect(ellPaint.kind == .radial)
        #expect(ellPaint.shape == .ellipse)
        #expect(ellPaint.repeats)
        #expect(ellPaint.animation.mode == .drift)

        let circleUniforms = SevenTvPaintShaderUniforms(paint: circlePaint)
        let ellipseUniforms = SevenTvPaintShaderUniforms(paint: ellPaint)
        #expect(circleUniforms.layerFloats[0] == 2)   // radial circle
        #expect(ellipseUniforms.layerFloats[0] == 3)  // radial ellipse
        #expect(ellipseUniforms.layerFloats[2] == 1)  // repeats == true
        #expect(circleUniforms.shadowCount == 4)
        #expect(ellipseUniforms.shadowCount == 2)
    }

    @Test func repeatingStopsTileBackwardAndForwardAcrossUnitRange() {
        // Candy Cane style: stops in 0.1...0.3 must tile backward into [0, 0.1) and forward into (0.3, 1.0].
        let candyCane = SevenTvPaint(
            id: "candy",
            name: "Candy Cane",
            kind: .linear,
            angle: 45,
            repeats: true,
            stops: [
                .init(at: 0.1, rgba: 0xFF0000FF),
                .init(at: 0.2, rgba: 0xFF0000FF),
                .init(at: 0.2, rgba: 0xFFFFFFFF),
                .init(at: 0.3, rgba: 0xFFFFFFFF),
            ]
        )
        let resolved = candyCane.resolvedStops
        #expect((resolved.first?.at ?? 1) <= 0.001)
        #expect((resolved.last?.at ?? 0) >= 0.999)
        #expect(resolved.count >= 12)
        // Must remain monotonically non-decreasing.
        for pair in zip(resolved, resolved.dropFirst()) {
            #expect(pair.0.at <= pair.1.at + 1e-9)
        }

        // Solar Flare style: stops starting late (0.72...0.95) still cover [0, 1].
        let solar = SevenTvPaint(
            id: "solar",
            name: "Solar Flare",
            kind: .radial,
            shape: .ellipse,
            repeats: true,
            stops: [
                .init(at: 0.72, rgba: 0xFFD93BFF),
                .init(at: 0.88, rgba: 0xFF2A4BFF),
                .init(at: 0.95, rgba: 0xFFD93BFF),
            ]
        )
        let solarStops = solar.resolvedStops
        #expect((solarStops.first?.at ?? 1) <= 0.001)
        #expect((solarStops.last?.at ?? 0) >= 0.999)
    }

    @Test func decodesMultiLayerV4AndFlatLayersWithHexColorsAndShadows() throws {
        // 7TV v4 style layers with union `ty`, hex color objects, and offset_x/blur shadow aliases.
        let v4JSON = """
        {"op":0,"d":{"type":"cosmetic.create","body":{"object":{"id":"p-v4","kind":"PAINT","data":{
          "id":"p-v4","name":"Opal Prism",
          "layers":[
            {"id":"l1","opacity":1.0,"ty":{"__typename":"PaintLayerTypeLinearGradient","angle":120,"repeating":false,
              "stops":[{"at":0,"color":{"hex":"#C084FCFF"}},{"at":1,"color":{"hex":"#67E8F9FF"}}]}},
            {"id":"l2","opacity":0.6,"ty":{"__typename":"PaintLayerTypeRadialGradient","repeating":false,"shape":"circle",
              "stops":[{"at":0,"color":"#FFFFFFAA"},{"at":1,"color":"#FFFFFF00"}]}}
          ],
          "shadows":[
            {"offset_x":0,"offset_y":1.5,"blur":2.5,"color":{"hex":"#A855F7CC"}}
          ],
          "animation":{"mode":"iridescent","speed":0.25,"intensity":0.7}
        }}}}}
        """
        let env = try SevenTvChatWire.decoder().decode(SevenTvChatWire.Envelope.self, from: Data(v4JSON.utf8))
        let data = try #require(env.d?.body?.object?.data)
        let paint = try #require(SevenTvChatWire.paint(data, id: "p-v4"))

        #expect(paint.layers.count == 2)
        #expect(paint.resolvedLayers.count == 2)
        #expect(paint.layers[0].kind == .linear)
        #expect(paint.layers[0].angle == 120)
        #expect(paint.layers[0].stops.map(\.rgba) == [0xC084FCFF, 0x67E8F9FF])
        #expect(paint.layers[1].kind == .radial)
        #expect(paint.layers[1].shape == .circle)
        #expect(abs(paint.layers[1].opacity - 0.6) < 0.001)
        #expect(paint.shadows == [.init(xOffset: 0, yOffset: 1.5, radius: 2.5, rgba: 0xA855F7CC)])
        #expect(paint.animation == .init(mode: .iridescent, speed: 0.25, intensity: 0.7))
        #expect(paint.hasAnimatedShader)
        #expect(!paint.hasImageLayer)

        // Pure multi-layer procedural paint collapses into 1 single GPU shader call.
        let uniforms = SevenTvPaintShaderUniforms(paint: paint)
        #expect(uniforms.isPureProcedural)
        #expect(uniforms.layerCount == 2)
        #expect(uniforms.layerFloats.count == 2 * SevenTvPaintShaderUniforms.layerStride)
        #expect(uniforms.stopFloats.count == 4 * SevenTvPaintShaderUniforms.stopStride)
        #expect(uniforms.animMode == 3) // iridescent
    }

    @Test func packsHybridMultiLayerPaintWithImageInExactOrder() throws {
        let hybridJSON = """
        {"op":0,"d":{"type":"cosmetic.create","body":{"object":{"id":"p-hyb","kind":"PAINT","data":{
          "id":"p-hyb","name":"Aurora Sparkle",
          "layers":[
            {"function":"LINEAR_GRADIENT","angle":90,"stops":[{"at":0,"color":-16776961},{"at":1,"color":65535}],"opacity":1},
            {"opacity":0.85,"ty":{"__typename":"PaintLayerTypeImage","images":[
              {"url":"https://cdn.7tv.app/paint/a/1x_static.webp","mime":"image/webp","frame_count":1,"scale":1},
              {"url":"https://cdn.7tv.app/paint/a/2x.webp","mime":"image/webp","frame_count":30,"scale":2}
            ]}},
            {"function":"SINGLE_COLOR","color":"#FFFFFF33","opacity":0.5}
          ],
          "shadows":[]
        }}}}}
        """
        let env = try SevenTvChatWire.decoder().decode(SevenTvChatWire.Envelope.self, from: Data(hybridJSON.utf8))
        let data = try #require(env.d?.body?.object?.data)
        let paint = try #require(SevenTvChatWire.paint(data, id: "p-hyb"))

        #expect(paint.hasImageLayer)
        #expect(paint.resolvedLayers.count == 3)
        #expect(paint.resolvedLayers[1].kind == .image)
        #expect(paint.resolvedLayers[1].imageURL?.absoluteString == "https://cdn.7tv.app/paint/a/2x.webp")
        #expect(paint.resolvedLayers[1].animatedImage)

        let uniforms = SevenTvPaintShaderUniforms(paint: paint)
        #expect(!uniforms.isPureProcedural)
        #expect(uniforms.steps.count == 3)
        if case let .procedural(_, _, count) = uniforms.steps[0] {
            #expect(count == 1)
        } else {
            Issue.record("expected procedural base layer first")
        }
        if case let .image(url, _, opacity, animated) = uniforms.steps[1] {
            #expect(url.absoluteString == "https://cdn.7tv.app/paint/a/2x.webp")
            #expect(abs(opacity - 0.85) < 0.001)
            #expect(animated)
        } else {
            Issue.record("expected image middle layer")
        }
        if case let .procedural(_, _, count) = uniforms.steps[2] {
            #expect(count == 1)
        } else {
            Issue.record("expected procedural top layer")
        }
    }

    @Test func packsTwentyEightStopsAndTenShadowsWithUnclippedPadding() {
        let stops = (0..<28).map { i in
            SevenTvPaint.Stop(at: Double(i) / 27.0, rgba: 0xFF0000FF)
        }
        let shadows = (0..<12).map { i in
            SevenTvPaint.Shadow(
                xOffset: Double(i - 5),
                yOffset: i == 0 ? -1.0 : 0.5,
                radius: i == 9 ? 4.0 : 0.0,
                rgba: 0x000000CC
            )
        }
        let paint = SevenTvPaint(
            id: "arcade",
            name: "Arcade yx",
            kind: .radial,
            shape: .circle,
            repeats: false,
            stops: stops.reversed(), // intentionally unsorted
            shadows: shadows
        )

        let uniforms = SevenTvPaintShaderUniforms(paint: paint)
        #expect(uniforms.isPureProcedural)
        #expect(uniforms.stopFloats.count == 28 * SevenTvPaintShaderUniforms.stopStride)
        // Stops must be sorted ascending by `at`.
        for i in 0..<27 {
            let a = uniforms.stopFloats[i * SevenTvPaintShaderUniforms.stopStride]
            let b = uniforms.stopFloats[(i + 1) * SevenTvPaintShaderUniforms.stopStride]
            #expect(a <= b)
        }
        // Capped cleanly at 10 shadows.
        #expect(uniforms.shadowCount == SevenTvPaintShaderUniforms.maxShadows)
        #expect(uniforms.shadowFloats.count == 10 * SevenTvPaintShaderUniforms.shadowStride)
        #expect(uniforms.shadowPadX >= 7)
        #expect(uniforms.shadowPadY >= 7)
        // 28-stop non-repeating paint gets subtle default shimmer.
        #expect(paint.animation.mode == .shimmer)
    }

    @Test func simpleTwoStopAndPlainPaintsStayStaticWithoutClockOverhead() {
        let twoStop = SevenTvPaint(
            id: "simple",
            name: "Sunset",
            kind: .linear,
            angle: 45,
            repeats: false,
            stops: [.init(at: 0, rgba: 0xFF0000FF), .init(at: 1, rgba: 0x00FF00FF)]
        )
        #expect(!twoStop.hasAnimatedShader)
        #expect(twoStop.animation == .none)

        let plain = SevenTvPaint(id: "plain", name: "Gold", kind: .plain, color: 0xFFD700FF)
        #expect(!plain.hasAnimatedShader)

        let staticImg = SevenTvPaint.Layer.inferAnimatedImage(
            url: URL(string: "https://cdn.7tv.app/paint/abc/1x_static.webp")
        )
        let animImg = SevenTvPaint.Layer.inferAnimatedImage(
            url: URL(string: "https://cdn.7tv.app/paint/abc/1x.webp")
        )
        #expect(!staticImg)
        #expect(animImg)
    }

    @Test func showcasePresetsAreWellFormed() {
        #expect(SevenTvPaint.showcaseSamples.count >= 6)
        for sample in SevenTvPaint.showcaseSamples {
            let uniforms = SevenTvPaintShaderUniforms(paint: sample)
            #expect(!uniforms.steps.isEmpty)
            #expect(!uniforms.layerFloats.isEmpty)
            #expect(!uniforms.stopFloats.isEmpty)
            #expect(!uniforms.shadowFloats.isEmpty)
        }
    }

    @MainActor
    @Test func shaderMotionBudgetGrantsAndRespectsLowPowerMode() {
        let budget = MotionBudget(limit: 2, watchPower: false)
        let a = MotionTicket()
        let b = MotionTicket()
        let c = MotionTicket()

        budget.want(a, true)
        budget.want(b, true)
        budget.want(c, true)
        #expect(a.granted && b.granted && !c.granted)

        budget.setLowPower(true)
        #expect(!a.granted && !b.granted && !c.granted)

        budget.setLowPower(false)
        #expect(a.granted && b.granted && !c.granted)

        budget.want(a, false)
        #expect(!a.granted && b.granted && c.granted)
    }
}
