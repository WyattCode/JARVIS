import Combine
import SwiftUI
import UIKit

// MARK: Welcome

/// The brand mark, as a SwiftUI view.
struct MarkRep: UIViewRepresentable {
  func makeUIView(context: Context) -> JarvisMarkView { JarvisMarkView() }
  func updateUIView(_ view: JarvisMarkView, context: Context) {}
}

/// The reactor, as a SwiftUI view.
struct ReactorRep: UIViewRepresentable {
  @Environment(\.colorScheme) private var scheme

  func makeUIView(context: Context) -> ReactorView {
    let view = ReactorView()
    view.isUserInteractionEnabled = false
    view.isAccessibilityElement = true
    view.accessibilityLabel = "JARVIS"
    view.apply(["mode": "idle", "dark": scheme == .dark], animated: false)
    LaunchFigure.shared.pageReactor = view
    return view
  }

  func updateUIView(_ view: ReactorView, context: Context) {
    view.apply(["dark": scheme == .dark], animated: false)
  }
}

/// The home page of an empty conversation, laid out as the Claude app's is: the mark and one line of greeting, centred in the
/// pane and sitting a little above the middle; nothing else on the page but the composer below.
/// Whether the welcome page's own figure shows: while the launch reactor is still flying to its place the figure waits, so that
/// there is one reactor on the page, not two on top of each other.
@MainActor
final class LaunchFigure: ObservableObject {
  static let shared = LaunchFigure()
  @Published var hidden = false
  /// The welcome page's reactor, so that the launch reactor can hand over to it in step (see `ReactorView.adoptClock`).
  weak var pageReactor: ReactorView?
  /// The figure shows at once, not by a fade: it comes up under a reactor that stands on exactly its place and looks the same.
  var instant = false
}

struct WelcomeView: View {
  let greeting: String
  let starters: [Starter]
  let foldable: Bool
  /// A straight phone (the Pro Max sizes): the figure and the lines under it stand in the middle of the room above the cards.
  var straight = false
  var screenHeight: CGFloat = 680
  let onPick: (Starter) -> Void
  /// Where the moving figure stands, in the window (the launch flight lands on it).
  var onFigure: (CGRect) -> Void = { _ in }
  /// The gap between the box and the bottom of the body; the cards stand the same distance above the box.
  var bottomGap: CGFloat = 34
  /// The keyboard is up: the cards step aside, the rest stays where it is.
  var keyboard = false
  /// The width of the pane the page stands in, when the page itself is wider (beside a docked list); its layout goes by this.
  var paneWidth: CGFloat?
  @ObservedObject private var launch = LaunchFigure.shared
  /// The height the page last had with no keyboard: while the keyboard is up the layout is worked out from it.
  @State private var lastHeight: CGFloat = 0
  /// The width it had then: a turn of the device with the keyboard up changes it, and the old height would no longer fit.
  @State private var lastWidth: CGFloat = 0

  /// The figure, the greeting and the line under it must fit in `space` (a phone on its side has little): the line goes first, then
  /// the figure gets smaller, then it goes too.
  static func fit(space: CGFloat, narrow: Bool) -> (figure: CGFloat, showFigure: Bool, showHint: Bool, group: CGFloat) {
    var figure = 150 + 70 * min(max((space - 200) / 170, 0), 1)
    var showFigure = true, showHint = true
    let hintHeight: CGFloat = narrow ? 56 : 36
    func need() -> CGFloat { (showFigure ? figure * 0.9 + 22 : 0) + 28 + (showHint ? hintHeight : 0) + 16 }
    if need() > space { showHint = false }
    if need() > space { figure = (space - 16 - 28 - 22) / 0.9 }
    if figure < 64 { showFigure = false }
    let group = (showFigure ? figure * 0.9 + 22 : 0) + 28 + (showHint ? hintHeight : 0)
    return (figure, showFigure, showHint, group)
  }

  func settle(_ size: CGSize) -> Bool {
    let turned = abs(lastWidth - size.width) > 0.5
    if (!keyboard || turned) && (turned || abs(lastHeight - size.height) > 0.5) {
      DispatchQueue.main.async {
        lastHeight = size.height
        lastWidth = size.width
      }
    }
    return true
  }

  var body: some View {
    GeometryReader { box in
      let _ = settle(box.size)
      // JARVIS's own welcome page: the moving figure, the greeting and one line under it up in the page, and the four starter
      // cards (two rows) down by the box, as far from it as the box is from the bottom of the body. Each part is there only if
      // the pane is tall enough for it.
      let height = keyboard && lastHeight > 0 && abs(lastWidth - box.size.width) < 0.5 ? lastHeight : box.size.height
      let narrow = (paneWidth ?? box.size.width) - 32 < 420
      let showCards = height >= 380
      let cardsHeight: CGFloat = showCards ? StarterCards.height(narrow: narrow) : 0
      let below = max(0, bottomGap - 4)
      let space = height - (showCards ? cardsHeight + below : 0)
      let fit = Self.fit(space: space, narrow: narrow)
      let figure = fit.figure, showFigure = fit.showFigure, showHint = fit.showHint, group = fit.group
      let top = max(8, (space - group) * (straight ? 0.5 : 0.4))
      ZStack(alignment: .top) {
        VStack(spacing: 0) {
          if showFigure {
            ReactorRep()
              .frame(width: figure, height: figure * 0.9)
              .opacity(launch.hidden ? 0 : 1)
              .animation(launch.instant ? nil : .easeInOut(duration: 0.32), value: launch.hidden)
              .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { onFigure($0) }
            Spacer().frame(height: 22)
          }
          Text(foldable ? greeting : "想聊点什么？")
            .font(.system(size: foldable ? 24 : 21, weight: foldable ? .bold : .semibold))
            .foregroundStyle(Color(Palette.onSurface))
            .opacity(keyboard ? 0 : 1)
            .animation(.easeInOut(duration: 0.22), value: keyboard)
          if showHint {
            Spacer().frame(height: 10)
            Text(foldable ? "有什么想聊的？输入问题，或点击麦克风直接说话。" : "写下想法，或直接开口。")
              .font(.system(.subheadline))
              .multilineTextAlignment(.center)
              .foregroundStyle(Color(Palette.onSurfaceVariant))
              .opacity(keyboard ? 0 : 1)
              .animation(.easeInOut(duration: 0.22), value: keyboard)
          }
        }
        .padding(.horizontal, 16)
        .padding(.top, top)
        .frame(maxWidth: .infinity)
      }
    }
  }
}

// MARK: The welcome page's starter cards

/// Four cards in two rows, as wide as the row they are given.
final class StarterCards: UIView {
  private var cards: [UIControl] = []
  private var starters: [Starter] = []
  private var onPick: (Starter) -> Void = { _ in }
  /// A narrow page: a smaller card, with smaller type.
  var narrow = false {
    didSet { if narrow != oldValue { rebuild() } }
  }
  /// A straight phone: the small lines on the cards are one size up (they were hard to read at arm's length).
  var straight = false {
    didSet { if straight != oldValue { rebuild() } }
  }

  static func tile(narrow: Bool) -> CGFloat { narrow ? 78 : 88 }
  static func height(narrow: Bool) -> CGFloat { tile(narrow: narrow) * 2 + 10 }

  func set(_ starters: [Starter], onPick: @escaping (Starter) -> Void) {
    self.onPick = onPick
    guard starters.map(\.title) != self.starters.map(\.title) || starters.map(\.description) != self.starters.map(\.description) else { return }
    self.starters = starters
    rebuild()
  }

  private func rebuild() {
    cards.forEach { $0.removeFromSuperview() }
    cards = starters.prefix(4).map { s in
      let card = StarterCard(narrow: narrow, straight: straight)
      card.set(s)
      card.addAction(UIAction { [weak self] _ in self?.onPick(s) }, for: .touchUpInside)
      addSubview(card)
      return card
    }
    setNeedsLayout()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let tile = Self.tile(narrow: narrow)
    let w = (bounds.width - 10) / 2
    for (i, card) in cards.enumerated() {
      card.frame = CGRect(x: CGFloat(i % 2) * (w + 10), y: CGFloat(i / 2) * (tile + 10), width: w, height: tile)
    }
  }
}

private final class StarterCard: UIControl {
  private let title = UILabel()
  private let detail = UILabel()
  private let narrow: Bool

  init(narrow: Bool, straight: Bool = false) {
    self.narrow = narrow
    super.init(frame: .zero)
    registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: StarterCard, _: UITraitCollection) in
      view.layer.borderColor = Palette.outlineVariant.cgColor
    }
    backgroundColor = Palette.card
    layer.cornerRadius = Radii.large
    layer.cornerCurve = .continuous
    layer.borderWidth = 1
    layer.borderColor = Palette.outlineVariant.cgColor
    title.font = .systemFont(ofSize: narrow && !straight ? 14 : 15, weight: .bold)
    title.textColor = Palette.onSurface
    detail.font = .systemFont(ofSize: narrow && !straight ? 12 : 13)
    detail.textColor = Palette.onSurfaceVariant
    detail.numberOfLines = 2
    for label in [title, detail] {
      label.isUserInteractionEnabled = false
      addSubview(label)
    }
    isAccessibilityElement = true
    accessibilityTraits = .button
  }

  required init?(coder: NSCoder) { fatalError() }

  func set(_ starter: Starter) {
    title.text = starter.title
    detail.text = starter.description ?? ""
    accessibilityLabel = [starter.title, starter.description].compactMap { $0 }.joined(separator: "，")
  }

  override var isHighlighted: Bool {
    didSet { backgroundColor = isHighlighted ? Palette.card.blended(with: Palette.onSurface, 0.08) : Palette.card }
  }


  override func layoutSubviews() {
    super.layoutSubviews()
    let left: CGFloat = narrow ? 16 : 18, right: CGFloat = narrow ? 10 : 18
    let width = max(0, bounds.width - left - right)
    let t = title.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
    let d = detail.text?.isEmpty == false ? detail.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height : 0
    let gap: CGFloat = d > 0 ? 4 : 0
    let top = (bounds.height - (t + gap + d)) / 2
    title.frame = CGRect(x: left, y: top, width: width, height: t)
    detail.frame = CGRect(x: left, y: top + t + gap, width: width, height: d)
  }
}

private extension UIColor {
  /// This colour with `amount` of `other` over it (the pressed tint of a card).
  func blended(with other: UIColor, _ amount: CGFloat) -> UIColor {
    UIColor { trait in
      var a: (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0), b: (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
      self.resolvedColor(with: trait).getRed(&a.0, green: &a.1, blue: &a.2, alpha: &a.3)
      other.resolvedColor(with: trait).getRed(&b.0, green: &b.1, blue: &b.2, alpha: &b.3)
      return UIColor(red: a.0 + (b.0 - a.0) * amount, green: a.1 + (b.1 - a.1) * amount, blue: a.2 + (b.2 - a.2) * amount, alpha: 1)
    }
  }
}

