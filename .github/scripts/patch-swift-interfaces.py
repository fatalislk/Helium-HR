#!/usr/bin/env python3
"""Make the theos iPhoneOS16.5 SDK readable by a Swift 6 compiler.

The SDK's SwiftUI.swiftinterface was produced by Swift 5.8 and contains

    os_log(.fault, log: Log.runtimeIssuesLog, \"\"\"
        Accessing Environment<\\(Value.self)>'s value outside of ...
        \"\"\")

Swift 6 rejects an interpolated string literal in that position ("string
interpolation cannot be used in this context"), the interface fails to load,
and every file that imports SwiftUI dies with the misleading "this SDK is not
supported by the compiler". The log message is only a runtime diagnostic, so
replacing the interpolation with a plain literal is enough to build.

Usage: patch-swift-interfaces.py <sdk-root>
"""
import glob
import os
import sys

def patch(text):
    out = []
    i = 0
    changed = False
    while True:
        j = text.find('"""', i)
        if j == -1:
            out.append(text[i:])
            break
        k = text.find('"""', j + 3)
        if k == -1:
            out.append(text[i:])
            break
        block = text[j:k]
        head = text[max(0, j - 240):j]
        if "os_log(" in head and "\\(" in block:
            out.append(text[i:j])
            out.append('"(runtime issue)"')
            changed = True
        else:
            out.append(text[i:k + 3])
        i = k + 3
    return "".join(out), changed

def main():
    sdk = sys.argv[1]
    total = 0
    for path in glob.glob(os.path.join(sdk, "**", "*.swiftinterface"), recursive=True):
        with open(path, encoding="utf-8", errors="surrogateescape") as f:
            src = f.read()
        new, changed = patch(src)
        if changed:
            with open(path, "w", encoding="utf-8", errors="surrogateescape") as f:
                f.write(new)
            print("patched", path)
            total += 1
    print("swiftinterfaces patched:", total)
    if total == 0:
        print("note: nothing matched (SDK already clean or layout changed)")

if __name__ == "__main__":
    main()
