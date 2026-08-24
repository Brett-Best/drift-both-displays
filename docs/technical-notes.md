# Technical notes

## Confirmed original lifecycle

The following offsets were observed in Apple's macOS 27 Drift executable:

```text
FlowView.prepareToAnimate        0x100006404
FlowView.viewDidMoveToSuperview  0x100006440
FlowView.setFrameSize            0x1000064c4
FlowView.startAnimation          0x1000065a8
FlowView.stopAnimation           0x100006660
Orchestrator.drawInMTKView       0x10000849c
```

The helper used by `prepareToAnimate`, near `0x100005b14`, performs this
source-equivalent sequence:

```objc
hasPreparedToAnimate = YES;

NSWindow *window = self.window;
if (window == nil) return;

NSScreen *screen = window.screen;
if (screen == nil) return;

CGDirectDisplayID displayID =
    [screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue];

id<MTLDevice> device = CGDirectDisplayCopyCurrentMetalDevice(displayID);
if (device == nil) device = MTLCreateSystemDefaultDevice();

// Create the Orchestrator and attach its MTKView.
```

`viewDidMoveToSuperview` and `setFrameSize:` update an existing orchestrator;
they do not create one. `startAnimation` starts the display link but does not
retry preparation. A first preparation with a missing screen therefore leaves
the view permanently black.

## Runtime correction

The loader swizzles only `prepareToAnimate` and `startAnimation` on the private
copied `Drift.FlowView` class.

For the affected Studio Display host, the observed state changes from:

```text
window.screen = nil
reportedDisplay = 0
orchestrator = nil
subviews = 0
```

to:

```text
reportedDisplay = 0
targetDisplay = 3
orchestrator = <non-null>
displayLinker = <non-null>
subviews = 1
```

The actual host `NSWindow` is not replaced. Its Objective-C runtime class is
temporarily changed to a generated subclass whose `screen` and
`backingScaleFactor` methods return the matched physical screen. The original
class is restored in an `@finally` block immediately after Apple's unmodified
preparation implementation returns.

## Complete private clone

Apple ships Drift as an `MH_EXECUTE` extension executable. `NSBundle` requires
the nested private copy to be `MH_BUNDLE`, so each thin slice receives two
checked Mach-O header changes:

```text
filetype: MH_EXECUTE -> MH_BUNDLE
flags:    clear MH_PIE
```

No renderer instruction, Metal shader, resource, animation, or configuration
controller is changed.

## Native registration

A loose user `.appex` is not sufficient. PlugInKit requires the extension to be
sandboxed and discoverable inside a containing app. The final structure is:

```text
Drift Both Displays Dev2.app
└── Contents
    └── PlugIns
        └── Drift-Native-Clone-Dev2.appex
            └── Contents
                └── Resources
                    └── DriftRenderer.bundle
```

The outer extension keeps Apple's native screen-saver and configuration-view
controller metadata. The nested renderer bundle contains the locally copied
Apple classes and assets.
