#!/usr/bin/env python3
"""Render the app icon (a 🎤 on a dark rounded square) → app/clawd-dictate.icns.
Run with the venv python (needs pyobjc): .venv/bin/python app/icon.py"""
import os, subprocess, sys, tempfile
from AppKit import (NSImage, NSBitmapImageRep, NSColor, NSBezierPath, NSString, NSFont,
                    NSFontAttributeName, NSGraphicsContext, NSPNGFileType, NSMakeRect, NSMakeSize)
from Foundation import NSPoint

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "clawd-dictate.icns")


def render(size):
    img = NSImage.alloc().initWithSize_(NSMakeSize(size, size))
    img.lockFocus()
    NSColor.clearColor().set()
    NSBezierPath.fillRect_(NSMakeRect(0, 0, size, size))
    r = size * 0.22
    path = NSBezierPath.bezierPathWithRoundedRect_xRadius_yRadius_(NSMakeRect(size * 0.04, size * 0.04, size * 0.92, size * 0.92), r, r)
    NSColor.colorWithCalibratedRed_green_blue_alpha_(0.11, 0.11, 0.13, 1).set()
    path.fill()
    s = NSString.stringWithString_("🎤")
    attrs = {NSFontAttributeName: NSFont.systemFontOfSize_(size * 0.62)}
    sz = s.sizeWithAttributes_(attrs)
    s.drawAtPoint_withAttributes_(NSPoint((size - sz.width) / 2, (size - sz.height) / 2 - size * 0.02), attrs)
    img.unlockFocus()
    tiff = img.TIFFRepresentation()
    rep = NSBitmapImageRep.imageRepWithData_(tiff)
    return rep.representationUsingType_properties_(NSPNGFileType, None)


def main():
    tmp = tempfile.mkdtemp(prefix="dictate-icon-")
    iconset = os.path.join(tmp, "clawd-dictate.iconset")
    os.mkdir(iconset)
    for base in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            px = base * scale
            name = f"icon_{base}x{base}" + ("@2x" if scale == 2 else "") + ".png"
            render(px).writeToFile_atomically_(os.path.join(iconset, name), True)
    subprocess.run(["iconutil", "-c", "icns", iconset, "-o", OUT], check=True)
    print("wrote", OUT)


if __name__ == "__main__":
    main()
