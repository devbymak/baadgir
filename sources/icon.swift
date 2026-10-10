// Package the resized PNG representations into an ICNS container.
// Uses Foundation only; image resizing is handled by macOS sips in build.sh.
import Foundation

func word(_ value: UInt32) -> Data {
    var bigEndian = value.bigEndian
    return withUnsafeBytes(of: &bigEndian) { Data($0) }
}
let directory = URL(fileURLWithPath: CommandLine.arguments[1])
let entries = [
    ("icp4", "icon_16x16.png"), ("icp5", "icon_32x32.png"),
    ("ic07", "icon_128x128.png"), ("ic08", "icon_256x256.png"),
    ("ic09", "icon_512x512.png"), ("ic10", "icon_512x512@2x.png"),
    ("ic11", "icon_16x16@2x.png"), ("ic12", "icon_32x32@2x.png"),
    ("ic13", "icon_128x128@2x.png"), ("ic14", "icon_256x256@2x.png")
]
var chunks = Data()
for (type, name) in entries {
    let png = try Data(contentsOf: directory.appendingPathComponent(name))
    chunks.append(Data(type.utf8))
    chunks.append(word(UInt32(png.count + 8)))
    chunks.append(png)
}
var output = Data("icns".utf8)
output.append(word(UInt32(chunks.count + 8)))
output.append(chunks)
try output.write(to: URL(fileURLWithPath: CommandLine.arguments[2]), options: .atomic)
