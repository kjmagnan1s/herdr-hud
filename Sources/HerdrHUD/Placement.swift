import Foundation

func notificationFrame(bubble: NSRect, size: NSSize, visibleFrame: NSRect, gap: CGFloat = 10) -> NSRect {
    // Keep a small margin from the screen edge, like the gap from H.
    let visibleFrame = visibleFrame.insetBy(dx:min(8,max(0,(visibleFrame.width-size.width)/2)),dy:min(8,max(0,(visibleFrame.height-size.height)/2)))
    let size = NSSize(width:min(size.width,visibleFrame.width),height:min(size.height,visibleFrame.height))
    func fit(_ origin: NSPoint) -> NSRect {
        NSRect(x:min(max(origin.x,visibleFrame.minX),visibleFrame.maxX-size.width),
               y:min(max(origin.y,visibleFrame.minY),visibleFrame.maxY-size.height),width:size.width,height:size.height)
    }
    // Cocoa coordinates increase upward. Try above and below before either side.
    let candidates = [
        NSPoint(x:bubble.midX-size.width/2,y:bubble.maxY+gap),
        NSPoint(x:bubble.midX-size.width/2,y:bubble.minY-size.height-gap),
        NSPoint(x:bubble.maxX+gap,y:bubble.midY-size.height/2),
        NSPoint(x:bubble.minX-size.width-gap,y:bubble.midY-size.height/2)
    ].map(fit)
    let clearance = bubble.insetBy(dx:-gap,dy:-gap)
    return candidates.first(where:{ !$0.intersects(clearance) }) ?? candidates.min(by: {
        let a = $0.intersection(bubble), b = $1.intersection(bubble)
        return max(0,a.width)*max(0,a.height) < max(0,b.width)*max(0,b.height)
    })!
}

// The agent strip sits beside the H on the side facing the screen's center,
// vertically centered on it, and never leaves the visible frame.
func stripFrame(bubble: NSRect, size: NSSize, visibleFrame: NSRect, gap: CGFloat = 8) -> NSRect {
    let width = min(size.width,visibleFrame.width), height = min(size.height,visibleFrame.height)
    let x = bubble.midX > visibleFrame.midX ? bubble.minX-gap-width : bubble.maxX+gap
    let y = bubble.midY-height/2
    return NSRect(x:min(max(x,visibleFrame.minX),visibleFrame.maxX-width),y:min(max(y,visibleFrame.minY),visibleFrame.maxY-height),width:width,height:height)
}
