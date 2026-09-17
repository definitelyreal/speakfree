// ai-suggestion:unverified · session:01a081f3-bd8e-71d1-a126-f9fcd04b00f8 · 2026-09-08
import Foundation

/// Transfers ownership before scheduling work, so even a worker that finishes immediately
/// cannot leave the caller holding the last reference. Call only after all temporary
/// references on the caller's stack have gone out of scope.
enum BackgroundDisposal {
    static func retire<Resource: AnyObject>(
        _ resource: inout Resource?,
        linger: TimeInterval = 0,
        prepare: @escaping (Resource) -> Void = { _ in },
        completion: @escaping () -> Void = {}
    ) {
        let ownership = resource.map { Unmanaged.passRetained($0) }
        resource = nil
        DispatchQueue.global(qos: .utility).async {
            if let ownership {
                let value = ownership.takeRetainedValue()
                prepare(value)
                if linger > 0 {
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + linger) {
                        withExtendedLifetime(value) {}
                    }
                }
                // No resource reference is passed into a main-queue completion.
                completion()
                withExtendedLifetime(value) {}
            } else {
                completion()
            }
        }
    }
}
