import Foundation

public enum DockPresenceResolver {
    /// Resolves noisy hardware signals into a stable dock state. An external display is strong
    /// evidence that the workstation dock is attached. The dock is considered detached only when
    /// both the external display and external power disappear. Power without a display is
    /// ambiguous (for example, a sleeping monitor or a standalone charger), so the previous state
    /// is retained.
    public static func resolve(
        previousState: Bool,
        hasExternalDisplay: Bool,
        hasExternalPower: Bool
    ) -> Bool {
        if hasExternalDisplay { return true }
        if !hasExternalPower { return false }
        return previousState
    }
}
