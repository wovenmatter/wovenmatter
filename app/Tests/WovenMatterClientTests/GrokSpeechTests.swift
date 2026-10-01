import Foundation
import Testing
@testable import WovenMatterClient

@Suite struct GrokSpeechTests {
    @Test func subscriptionOnlyRequestNeverFallsBackToAnAPIKey() throws {
        #expect(throws: GrokSpeechError.signInRequired) { try GrokSpeechClient.request(credential: .init(type: "api_key", key: "fixture-key")) }
        var credential = DefaultAgentCredential(type: "oauth"); credential.access = "fixture-access"
        let request = try GrokSpeechClient.request(credential: credential)
        #expect(request.url?.host == "api.x.ai")
        #expect(request.url?.query?.contains("grok-voice-transcribe-2.0") == true)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-access")
        #expect(request.value(forHTTPHeaderField: "x-grok-client-identifier") == "wovenmatter")
    }
    @Test func errorsKeepAuthenticationEntitlementAndAllowanceDistinct() {
        #expect(GrokSpeechError.classify(status: 401) == .signInRequired)
        #expect(GrokSpeechError.classify(status: 403) == .restricted)
        #expect(GrokSpeechError.classify(status: 429, message: "insufficient credits") == .exhausted)
        #expect(GrokSpeechError.classify(status: 429) == .throttled)
    }
    @Test func protocolRequiresFinalTranscript() throws {
        #expect(try GrokSpeechEvent.decode(Data(#"{"type":"transcript.created"}"#.utf8)) == .ready)
        #expect(try GrokSpeechEvent.decode(Data(#"{"type":"transcript.partial","text":"partial"}"#.utf8)) == .partial("partial"))
        #expect(try GrokSpeechEvent.decode(Data(#"{"type":"transcript.done","text":"Whole recording","duration":4.2}"#.utf8)) == .done("Whole recording", duration: 4.2))
    }
}
