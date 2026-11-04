import Combine
import SwiftUI
import UIKit

/// The small grip on the divider beside a docked list: a thin bar that is dragged to fold the list away or bring it back (the list
/// follows the finger; let go, it settles at the nearer end, or the way a flick goes), or touched to do so at once.
///
/// It is shown at first and fades out after two seconds of nothing happening at its place; a touch there (or a fold or an unfold)
/// brings it back, and it goes again two seconds after. While it is gone it can still be touched and dragged (the place is the same).
final class DockGripView: UIView {
  static let width: CGFloat = 24
  /// How long it stays after the last thing that happened at its place, and how long it takes to go.
  static let stays: TimeInterval = 2
  private let thumb = UIView()
  private var fade: DispatchWorkItem?
  var onTap: (() -> Void)?
  var isOpen = true { didSet { accessibilityLabel = isOpen ? "收起会话侧栏" : "展开会话侧栏" } }
  var dragging = false {
    didSet {
      guard dragging != oldValue else { return }
      thumb.backgroundColor = Palette.onSurfaceVariant.withAlphaComponent(dragging ? 0.8 : 0.4)
      // Under the finger it stays; after it, two seconds.
      if dragging { wake(hold: true) } else { wake() }
    }
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    thumb.backgroundColor = Palette.onSurfaceVariant.withAlphaComponent(0.4)
    thumb.layer.cornerRadius = 2
    thumb.isUserInteractionEnabled = false
    addSubview(thumb)
    addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
    isAccessibilityElement = true
    accessibilityTraits = .button
    accessibilityLabel = "收起会话侧栏"
    accessibilityHint = "也可左右拖动"
    wake()
  }

  required init?(coder: NSCoder) { fatalError() }

  /// At the list's edge, in the middle of the height.
  func place(x: CGFloat, height: CGFloat) {
    frame = CGRect(x: x, y: (height - 80) / 2, width: Self.width, height: 80)
    thumb.frame = CGRect(x: 10, y: 18, width: 4, height: 44)
  }

  /// Shown, and set to fade out after two seconds (`hold`: not until told).
  func wake(hold: Bool = false) {
    fade?.cancel()
    fade = nil
    // Only its bar is faded: the view itself stays where touches find it.
    if thumb.alpha < 1 { UIView.animate(withDuration: 0.15, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) { self.thumb.alpha = 1 } }
    guard !hold else { return }
    let work = DispatchWorkItem { [weak self] in
      guard let self, !self.dragging else { return }
      UIView.animate(withDuration: 0.7, delay: 0, options: [.curveEaseInOut, .beginFromCurrentState, .allowUserInteraction]) { self.thumb.alpha = 0 }
    }
    fade = work
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.stays, execute: work)
  }

  @objc private func tapped() {
    wake()
    onTap?()
  }

  override func accessibilityActivate() -> Bool {
    onTap?()
    return true
  }
}
