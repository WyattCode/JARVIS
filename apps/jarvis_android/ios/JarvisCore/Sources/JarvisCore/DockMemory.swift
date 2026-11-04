/// Whether the conversation list beside the chat (the inner display held sideways) is out, across the things that take the chat away
/// from that arrangement: a turn of the device to upright (where the list is a page opened from a button), and a page with no use for
/// the list (the settings, a call). One place says what comes back, so that the views only report what happened.
public struct DockMemory: Equatable, Sendable {
  /// The list was out when the sideways arrangement was last left.
  private var leftOpen: Bool?
  /// The person opened or closed the list page while the device was upright.
  private var movedUpright = false
  /// The list was out before a page that came up and was left while the device was turned away from sideways.
  private var afterPage: Bool?
  /// A layout has been made at all (the first one has the list out).
  private var started = false

  public init() {}

  /// The first layout in a window is over.
  public mutating func started(_ laidOut: Bool) { if laidOut { started = true } }

  /// The sideways arrangement is left: the list was out or not.
  public mutating func leftSideways(listOut: Bool) {
    leftOpen = listOut
    movedUpright = false
  }

  /// The person opened (true) or closed the list page while the device is not sideways.
  public mutating func movedList(open: Bool) {
    movedUpright = true
    afterPage = nil
  }

  /// A page that had folded the list away is gone: `wasOut` is what the list was before it came. While the device is not sideways the
  /// answer is kept for the next time it is.
  public mutating func pageLeft(wasOut: Bool, sideways: Bool) {
    if !sideways { afterPage = wasOut }
  }

  /// The sideways arrangement is entered again: whether the list is out. `pageOpen`: the list page is open (the device was upright).
  public mutating func enteredSideways(pageOpen: Bool) -> Bool {
    defer {
      afterPage = nil
      movedUpright = false
    }
    guard started else { return true }
    if let afterPage { return afterPage }
    if movedUpright { return pageOpen }
    return leftOpen ?? true
  }
}
