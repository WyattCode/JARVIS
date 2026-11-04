import Foundation

/// The order the model lists are shown in: the service's own, except that the models named here go after all the others.
public enum ModelOrder {
  /// What is put last, written without spaces, dashes or case ("MiniMax H3", "minimax-h3" ...).
  static let last = ["minimaxh3"]

  public static func isLast(_ name: String) -> Bool {
    let plain = name.lowercased().filter { $0.isLetter || $0.isNumber }
    return last.contains { plain.contains($0) }
  }

  /// [items] in their order, with those whose name is one of the last ones moved behind the rest (the order inside each part kept).
  public static func apply<T>(_ items: [T], name: (T) -> String) -> [T] {
    items.filter { !isLast(name($0)) } + items.filter { isLast(name($0)) }
  }
}
