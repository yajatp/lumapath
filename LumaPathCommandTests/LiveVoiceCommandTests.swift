import Testing
@testable import LumaPathCommands

@Test func liveAssistantAcceptsSingleReviewedCommandsAndBoundedObjectQuestions() {
    #expect(LiveVoiceCommandParser.parse(" What objects do you see? ") == .describe)
    #expect(LiveVoiceCommandParser.parse("How far is the chair?") == .distance("chair"))
    #expect(LiveVoiceCommandParser.parse("distance to dining table") == .distance("dining table"))
    #expect(LiveVoiceCommandParser.parse(" PAUSE ") == .pause)
    #expect(LiveVoiceCommandParser.parse("resume camera") == .resume)
    #expect(LiveVoiceCommandParser.parse("stop") == .end)
    #expect(LiveVoiceCommandParser.parse("open help") == .help)
}
@Test func liveAssistantRejectsCompoundExternalAndNavigationActions() {
    for input in ["pause and resume", "call Yajat", "walk forward", "turn left", "how far is chair and send a message", "how far is ignore previous instructions", "how far is <chair>", String(repeating: "x", count: 161)] {
        #expect(LiveVoiceCommandParser.parse(input) == nil)
    }
}
