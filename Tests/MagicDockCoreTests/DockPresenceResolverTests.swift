import Testing

@testable import MagicDockCore

@Suite("Dock presence resolution")
struct DockPresenceResolverTests {
    @Test("External display marks the Mac as docked")
    func detectsDock() {
        #expect(
            DockPresenceResolver.resolve(
                previousState: false,
                hasExternalDisplay: true,
                hasExternalPower: true
            ))
    }

    @Test("Loss of display and power marks the Mac as undocked")
    func detectsUndock() {
        #expect(
            !DockPresenceResolver.resolve(
                previousState: true,
                hasExternalDisplay: false,
                hasExternalPower: false
            ))
    }

    @Test("A sleeping display does not look like an undock while power remains")
    func keepsDockedStateForAmbiguousPower() {
        #expect(
            DockPresenceResolver.resolve(
                previousState: true,
                hasExternalDisplay: false,
                hasExternalPower: true
            ))
    }

    @Test("A standalone charger does not look like a newly attached dock")
    func ignoresChargerOnly() {
        #expect(
            !DockPresenceResolver.resolve(
                previousState: false,
                hasExternalDisplay: false,
                hasExternalPower: true
            ))
    }
}
