import Foundation

/// Any JSON value, for the fields the server or the user fills freely (a tool's arguments, a model's metadata). It
/// encodes exactly as it decoded, so what is saved is what was read.
public enum JSONValue: Codable, Equatable, Sendable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])

  public init(from decoder: Decoder) throws {
    let c = try decoder.singleValueContainer()
    if c.decodeNil() { self = .null }
    else if let v = try? c.decode(Bool.self) { self = .bool(v) }
    else if let v = try? c.decode(Double.self) { self = .number(v) }
    else if let v = try? c.decode(String.self) { self = .string(v) }
    else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
    else { self = .object(try c.decode([String: JSONValue].self)) }
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.singleValueContainer()
    switch self {
    case .null: try c.encodeNil()
    case .bool(let v): try c.encode(v)
    case .number(let v):
      if v == v.rounded(), abs(v) < 9e15 { try c.encode(Int64(v)) } else { try c.encode(v) }
    case .string(let v): try c.encode(v)
    case .array(let v): try c.encode(v)
    case .object(let v): try c.encode(v)
    }
  }

  public subscript(key: String) -> JSONValue? {
    if case .object(let o) = self { return o[key] }
    return nil
  }

  public var string: String? { if case .string(let s) = self { return s } else { return nil } }
  public var bool: Bool? { if case .bool(let b) = self { return b } else { return nil } }
  public var double: Double? { if case .number(let n) = self { return n } else { return nil } }
  public var int: Int? { double.flatMap(wholeNumber) }
  public var array: [JSONValue]? { if case .array(let a) = self { return a } else { return nil } }
  public var object: [String: JSONValue]? { if case .object(let o) = self { return o } else { return nil } }
}

/// The integer a number from the server stands for (cut at the point); nil for one that is not finite or too large for an Int, which
/// `Int(_:)` would trap on.
func wholeNumber(_ value: Double) -> Int? {
  guard value.isFinite, abs(value) < 9.0e18 else { return nil }
  return Int(value)
}
