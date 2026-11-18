import Testing
import WovenMatterClient

struct RemoteRuntimeFailureTests {
    @Test func fixedHostCodesReadAsSentences() {
        let codes = [
            "runtime_active_stop_conversations_or_server_first", "adapter_version_below_minimum",
            "latest_engine_version_unavailable", "confirmation_required", "runtime_maintenance_in_progress",
            "update_failed", "installer_failed", "update_timed_out", "install_timed_out", "update_verification_failed",
            "installation_verification_failed", "runtime_active_or_operation_in_progress", "runtime_lock_unavailable",
            "installer_download_failed", "installer_download_timed_out", "invalid_installer_size", "installer_https_required",
            "runtime_preferences_save_failed", "system_install_update_forbidden", "opencode_v1_replacement_confirmation_required",
            "opencode_service_restart_failed", "native_installer_unavailable", "native_update_unavailable",
            "latest_protocol_sdk_version_unavailable", "runtime_operation_failed",
        ]
        for code in codes {
            let text = RemoteRuntimeFailure.describe(code)
            #expect(RemoteRuntimeFailure.isKnown(code), "\(code)")
            #expect(!text.contains("_"), "\(code) reads as \(text)")
            #expect(text.hasSuffix("."), "\(code) reads as \(text)")
        }
    }

    @Test func unknownCodesStayReadableAndOlderMessagesPassThrough() {
        #expect(!RemoteRuntimeFailure.isKnown("source_digest_required"))
        #expect(RemoteRuntimeFailure.describe("source_digest_required") == "It didn't finish (source digest required).")
        #expect(RemoteRuntimeFailure.describe("Update exited 1. network down") == "Update exited 1. network down")
    }
}
