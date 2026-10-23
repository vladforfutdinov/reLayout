// Saves the system arrow cursor for render.swift: OUT.png at 4x and OUT.json
// (size and hot spot in points). Run in a GUI session: elsewhere the image is empty.
// usage: demo-cursor OUT   (writes OUT.png, OUT.json)
import AppKit

_ = NSApplication.shared
let out = CommandLine.arguments.dropFirst().first ?? "cursor"
let cursor = NSCursor.arrow, size = cursor.image.size, scale = 4
guard size.width > 0, size.height > 0 else { print("empty cursor image"); exit(1) }
let w = Int(size.width) * scale, h = Int(size.height) * scale
let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
cursor.image.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
NSGraphicsContext.current = nil
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out + ".png") as CFURL, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
guard CGImageDestinationFinalize(dest) else { print("png write failed"); exit(1) }
let meta: [String: Double] = ["w": size.width, "h": size.height, "hx": cursor.hotSpot.x, "hy": cursor.hotSpot.y]
try JSONSerialization.data(withJSONObject: meta).write(to: URL(fileURLWithPath: out + ".json"))
print(meta)
