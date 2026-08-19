import XCTest
@testable import SpeakFreeLib

final class WhisperBackendTests: XCTestCase {
    /// ggml >= 0.10 ships CPU/Metal/BLAS as runtime-loaded plugins; without an explicit
    /// ggml_backend_load_all() the registry is empty and whisper_init_* ABORTS the process
    /// (2026-08-19 crash loop: two SIGABRTs at "WhisperEngine: loading model").
    /// This asserts the engine's preflight both loads the plugins and sees >= 1 device;
    /// pre-fix, in a dynamic-backend environment, it fails instead of crashing later.
    func testComputeBackendsAreAvailableBeforeWhisperInit() {
        XCTAssertTrue(
            WhisperEngine.computeBackendsAvailable(),
            "ggml backend registry is empty — whisper_init would abort the process")
    }
}
