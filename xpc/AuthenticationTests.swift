import Foundation
import KPasskeyContract
import Testing

@Test @MainActor func hotplugSelectionTracksIdentityAndNeverSwitchesActiveAuthentication() {
  let authentication = Authentication()
  let first = SecurityKey(id: UUID().uuidString, name: "Same product")
  let second = SecurityKey(id: UUID().uuidString, name: "Same product")
  authentication.updateDevices([first])
  #expect(authentication.selectedDevice == first.id)
  authentication.updateDevices([first, second])
  #expect(authentication.selectedDevice == second.id)
  authentication.selectedDevice = first.id
  authentication.updateDevices([second, first])
  #expect(authentication.selectedDevice == first.id)
  authentication.updateDevices([second])
  #expect(authentication.selectedDevice == second.id)
  authentication.prepare(UUID().uuidString)
  authentication.updateDevices([first])
  #expect(authentication.selectedDevice == second.id)
  authentication.receive(Message("terminal", operation: authentication.operation!, value: "deviceRemoved"))
  authentication.updateDevices([first])
  #expect(authentication.selectedDevice == first.id)
  authentication.updateDevices([])
  #expect(authentication.selectedDevice == nil)
  #expect(!authentication.deviceNotice.isEmpty)
}

@Test @MainActor func presentationRejectsStaleEventsAndPreservesPublishedTickets() async {
  let authentication = Authentication()
  let first = UUID().uuidString
  authentication.prepare(first)
  let prompt = Message("interaction", operation: first, interaction: UUID().uuidString,
    value: "pin", remainingMilliseconds: 5000)
  authentication.receive(prompt)
  #expect(authentication.prompt === prompt)
  #expect(authentication.promptDeadline != nil)
  #expect(!Authentication.validSecret(Data("123".utf8), for: prompt))
  #expect(Authentication.validSecret(Data("1234".utf8), for: prompt))
  #expect(!Authentication.validSecret(Data(repeating: 65, count: 64), for: prompt))
  #expect(!Authentication.validSecret(Data([65, 0, 65, 65]), for: prompt))
  let password = Message("interaction", value: "password")
  #expect(Authentication.validSecret(Data(repeating: 65, count: 4096), for: password))
  #expect(!Authentication.validSecret(Data(repeating: 65, count: 4097), for: password))

  let ticket = TicketMetadata(principal: "user@EXAMPLE.INVALID", realm: "EXAMPLE.INVALID",
    cache: "API:synthetic", expires: 1, renewUntil: 0, forwardable: true, mode: "passkey")
  authentication.receive(Message("terminal", operation: first, value: "ok", ticket: ticket))
  #expect(!authentication.isRunning)
  #expect(authentication.prompt == nil)
  #expect(authentication.promptDeadline == nil)
  let second = UUID().uuidString
  authentication.prepare(second)
  authentication.receive(prompt)
  #expect(authentication.prompt == nil)
  await authentication.respond(to: prompt, secret: Data("1234".utf8))
  #expect(authentication.operation == second)
  #expect(!authentication.sending)
  authentication.receive(Message("terminal", operation: second, value: "publicationFailed"))
  #expect(authentication.ticket?.cache == ticket.cache)
  #expect(authentication.message.contains("couldn’t be published"))
  authentication.receive(Message("terminal", operation: second, value: "ok", ticket: ticket))
  #expect(authentication.terminal?.value == "publicationFailed")
}

@Test @MainActor func cancellationDuringConnectionAndInvalidSettings() async {
  let authentication = Authentication()
  authentication.prepare(UUID().uuidString)
  await authentication.cancel()
  #expect(authentication.terminal?.value == "cancelled")
  #expect(!authentication.isRunning)
  #expect(authentication.prompt == nil)
  await authentication.start(Configuration(principal: ""))
  #expect(!authentication.isRunning)
  #expect(authentication.ticket == nil)
}
