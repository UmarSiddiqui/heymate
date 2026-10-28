import Foundation
#if canImport(ImagePlayground)
import ImagePlayground
import SwiftUI
#endif

enum ImagePlaygroundAvailability {
    static var isAvailable: Bool {
        #if canImport(ImagePlayground)
        if #available(macOS 15.1, *) {
            return ImagePlaygroundViewController.isAvailable
        }
        #endif
        return false
    }
}

#if canImport(ImagePlayground)
struct ImagePlaygroundGate: ViewModifier {
    @Binding var concept: String?
    var onComplete: (URL) -> Void

    func body(content: Content) -> some View {
        if #available(macOS 15.1, *), ImagePlaygroundViewController.isAvailable {
            content.imagePlaygroundSheet(
                isPresented: Binding(
                    get: { concept != nil },
                    set: { isPresented in
                        if !isPresented { concept = nil }
                    }
                ),
                concept: concept ?? ""
            ) { url in
                onComplete(url)
                concept = nil
            }
        } else {
            content
        }
    }
}
#endif
