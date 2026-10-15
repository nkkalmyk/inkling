import AppKit
import Testing
@testable import Inkling

@MainActor
struct ContinuityCameraTests {
    @Test(arguments: ["public.jpeg", "public.png", "public.heic", "public.tiff", "com.adobe.pdf"])
    func acceptsPhotosAndScans(_ type: String) {
        #expect(ContinuityCamera.accepts(sendType: nil, returnType: NSPasteboard.PasteboardType(type)))
        #expect(ContinuityCamera.returnTypes.contains(NSPasteboard.PasteboardType(type)))
    }

    @Test func rejectsTextAndSending() {
        #expect(!ContinuityCamera.accepts(sendType: nil, returnType: .string))
        #expect(!ContinuityCamera.accepts(sendType: .tiff, returnType: .tiff))
        #expect(!ContinuityCamera.accepts(sendType: nil, returnType: nil))
    }
}
