import SwiftUI
import MarpleKit

@main
struct MarpleiOSApp: App {
    var body: some Scene {
        WindowGroup {
            // Minimal scaffold entry (Task 6). The phase router + reader UI land in
            // later tasks. Importing MarpleKit here proves the library links for iOS.
            Text("Marple")
        }
    }
}
