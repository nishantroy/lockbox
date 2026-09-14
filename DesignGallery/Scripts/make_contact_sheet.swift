import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".")
let reference = root.appendingPathComponent("Reference")
let output = reference.appendingPathComponent("gallery_contact_sheet.png")
let themes = [("midnight", "Midnight Sanctuary"), ("circadian", "Circadian Calm"), ("lantern", "Soft Lantern")]
let fixtures = [("home", "Home · unlocked"), ("rest", "Get some rest · active"), ("focus", "Focus time · active")]
let tileWidth = 300
let tileHeight = 652
let labelHeight = 42
let gap = 20
let canvasWidth = tileWidth * 3 + gap * 4
let canvasHeight = (tileHeight + labelHeight) * 3 + gap * 4

let canvas = NSImage(size: NSSize(width: canvasWidth, height: canvasHeight))
canvas.lockFocus()
NSColor(calibratedWhite: 0.10, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight).fill()

let titleFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
let subtitleFont = NSFont.systemFont(ofSize: 11, weight: .regular)
let paragraph = NSMutableParagraphStyle()
paragraph.alignment = .left

for row in 0..<3 {
    for column in 0..<3 {
        let theme = themes[row]
        let fixture = fixtures[column]
        let name = "\(theme.0)_\(fixture.0).png"
        let imageURL = reference.appendingPathComponent(name)
        guard let image = NSImage(contentsOf: imageURL) else {
            fatalError("Missing \(imageURL.path)")
        }
        let x = gap + column * (tileWidth + gap)
        let y = canvasHeight - gap - labelHeight - (row + 1) * tileHeight - row * labelHeight - row * gap
        let tileRect = NSRect(x: x, y: y, width: tileWidth, height: tileHeight)
        NSColor.white.setFill()
        tileRect.fill()
        image.draw(in: tileRect, from: .zero, operation: .copy, fraction: 1)

        let labelRect = NSRect(x: x, y: y + tileHeight + 8, width: tileWidth, height: labelHeight - 8)
        let label = NSMutableAttributedString(string: theme.1 + "\n", attributes: [
            .font: titleFont,
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph
        ])
        label.append(NSAttributedString(string: fixture.1, attributes: [
            .font: subtitleFont,
            .foregroundColor: NSColor(calibratedWhite: 0.72, alpha: 1),
            .paragraphStyle: paragraph
        ]))
        label.draw(in: labelRect)
    }
}
canvas.unlockFocus()

let rep = NSBitmapImageRep(data: canvas.tiffRepresentation!)!
let png = rep.representation(using: .png, properties: [:])!
try png.write(to: output)
print(output.path)
