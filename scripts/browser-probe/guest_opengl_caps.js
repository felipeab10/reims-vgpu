// Read the guest Metal device's OpenGL capability without Python or Xcode.
// Run inside macOS with: osascript -l JavaScript guest_opengl_caps.js
//
// A stock macOS installation may ship /usr/bin/python3 as an xcode-select shim,
// so the Python/ctypes probe cannot be assumed to run on a clean guest. JXA's
// Objective-C bridge is part of macOS and asks the same MTLDevice directly.
ObjC.import("Foundation");
ObjC.import("Metal");

const device = $.MTLCreateSystemDefaultDevice();
if (!device) {
  "MTLCreateSystemDefaultDevice=nil";
} else {
  const selector = $.NSSelectorFromString("supportsOpenGL");
  const available = Boolean(device.respondsToSelector(selector));
  const result = {
    device: ObjC.unwrap(device.name),
    supportsOpenGLSelectorAvailable: available,
    supportsOpenGL: available ? Boolean(device.supportsOpenGL) : null,
  };
  JSON.stringify(result);
}
