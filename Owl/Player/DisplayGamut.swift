import AppKit

/// Which of mpv's named gamuts a screen shows colours in.
///
/// mpv draws into an OpenGL surface that macOS does not colour match: whatever
/// numbers mpv writes go to the panel as they are. Left to itself mpv writes
/// BT.709 values, which a wide-gamut panel stretches across its own, wider
/// primaries — every video oversaturated, a BT.709 red drawn as the panel's
/// reddest red. Told the panel's primaries, mpv maps the picture into them and
/// its colours match QuickTime's.
///
/// Primaries rather than the screen's ICC profile, which is what IINA hands
/// mpv. A profile goes through mpv's 3D lookup table, and through libmpv's
/// OpenGL renderer on an M1 Pro that table drew red as white and every other
/// colour as one flat grey, whatever its size and with its cache off. The
/// transfer curve is left as mpv's own BT.1886, which keeps the picture as
/// bright as it has always been in Owl; only the gamut changes.
enum DisplayGamut {
    /// mpv's names for the gamuts a Mac display can have, alongside the colour
    /// space each one is measured against.
    private nonisolated(unsafe) static let candidates: [(mpvName: String, colorSpace: CFString)] = [
        ("bt.709", CGColorSpace.sRGB),
        ("display-p3", CGColorSpace.displayP3),
        ("adobe", CGColorSpace.adobeRGB1998),
        ("bt.2020", CGColorSpace.itur_2020),
    ]

    /// How far apart, in chromaticity summed over the three primaries, a
    /// screen may be from a named gamut and still be taken for it. Enough for
    /// a calibrated profile of a P3 panel to count as P3; far short of the
    /// gap between any two of the candidates.
    private static let tolerance = 0.03

    /// The mpv `target-prim` value for a screen, or nil when its colour space
    /// is none of the gamuts mpv knows, which leaves mpv to its default.
    static func mpvPrimaries(for colorSpace: NSColorSpace?) -> String? {
        guard let screen = colorSpace?.cgColorSpace,
              let screenPrimaries = primaries(of: screen)
        else {
            return nil
        }
        let nearest = candidates
            .compactMap { candidate -> (name: String, distance: Double)? in
                guard let space = CGColorSpace(name: candidate.colorSpace),
                      let reference = primaries(of: space)
                else {
                    return nil
                }
                return (candidate.mpvName, distance(screenPrimaries, reference))
            }
            .min { $0.distance < $1.distance }
        guard let nearest, nearest.distance <= tolerance else { return nil }
        return nearest.name
    }

    /// The xy chromaticities of a colour space's red, green and blue.
    ///
    /// Measured through ColorSync's own XYZ, so the screen and every candidate
    /// are converted the same way and white-point adaptation affects them all
    /// alike. Nil for a colour space that is not RGB.
    private static func primaries(of space: CGColorSpace) -> [(x: Double, y: Double)]? {
        guard space.model == .rgb,
              let xyz = CGColorSpace(name: CGColorSpace.genericXYZ)
        else {
            return nil
        }
        var result: [(x: Double, y: Double)] = []
        for components in [[1.0, 0, 0, 1], [0, 1.0, 0, 1], [0, 0, 1.0, 1]] {
            let rgb = components.map { CGFloat($0) }
            guard let color = CGColor(colorSpace: space, components: rgb),
                  let converted = color.converted(to: xyz, intent: .absoluteColorimetric, options: nil),
                  let values = converted.components,
                  values.count >= 3
            else {
                return nil
            }
            let sum = Double(values[0] + values[1] + values[2])
            guard sum > 0 else { return nil }
            result.append((Double(values[0]) / sum, Double(values[1]) / sum))
        }
        return result
    }

    private static func distance(
        _ lhs: [(x: Double, y: Double)],
        _ rhs: [(x: Double, y: Double)]
    ) -> Double {
        zip(lhs, rhs).reduce(0) { total, pair in
            total + hypot(pair.0.x - pair.1.x, pair.0.y - pair.1.y)
        }
    }
}
