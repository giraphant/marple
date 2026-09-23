import Foundation
import Dispatch

// Deliberately racy, standalone sanitizer positive control. Never linked to Marple.
final class Shared: @unchecked Sendable {
    var value = 0
}
let shared = Shared()
DispatchQueue.concurrentPerform(iterations: 1000) { _ in shared.value += 1 }
print(shared.value)
