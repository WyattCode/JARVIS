import XCTest

@testable import JarvisCore

final class ConversationRowsTests: XCTestCase {
  var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }
  let now = Date(timeIntervalSince1970: 1_800_000_000 + 12 * 3600)

  func id(daysAgo: Double) -> String {
    "\(Int((now.timeIntervalSince1970 - daysAgo * 86400) * 1_000_000))-1"
  }

  func conv(_ title: String, daysAgo: Double?, text: String = "") -> Conversation {
    guard let daysAgo else { return Conversation("old", title: title) }
    return Conversation(id(daysAgo: daysAgo), title: title, messages: text.isEmpty ? [] : [ChatMessage("user", text, id: id(daysAgo: daysAgo))])
  }

  func rows(_ list: [Conversation], _ query: String = "") -> [SidebarRow] {
    ConversationRows.rows(list, query: query, selected: nil, generating: { _ in false }, now: now, calendar: calendar).rows
  }

  func testOneGroupHasNoHeadings() {
    XCTAssertEqual(rows([conv("a", daysAgo: 0), conv("b", daysAgo: 0.1)]).map(\.title), ["a", "b"])
  }

  func testGroupsGetHeadingsInOrder() {
    let list = [conv("今", daysAgo: 0), conv("昨", daysAgo: 1), conv("前", daysAgo: 5), conv("未知", daysAgo: nil)]
    let r = rows(list)
    XCTAssertEqual(r.map(\.title), ["今天", "今", "昨天", "昨", "更早", "前", "未知"])
    XCTAssertEqual(r.filter(\.isHeader).count, 3)
  }

  func testSearchMatchesTitleOrVisibleMessages() {
    var hidden = conv("c", daysAgo: 0, text: "needle")
    hidden.messages[0].hidden = true
    let list = [conv("Needle title", daysAgo: 0), conv("b", daysAgo: 0, text: "has NEEDLE in"), hidden]
    let r = ConversationRows.rows(list, query: "  needle ", selected: nil, generating: { _ in false }, now: now, calendar: calendar)
    XCTAssertEqual(r.found, 2)
    XCTAssertEqual(r.rows.map(\.title), ["Needle title", "b"])
    XCTAssertEqual(ConversationRows.rows(list, query: "zzz", selected: nil, generating: { _ in false }, now: now, calendar: calendar).found, 0)
  }

  func testSelectionAndGenerationAreMarked() {
    let a = conv("a", daysAgo: 0), b = conv("b", daysAgo: 0.5)
    let r = ConversationRows.rows([a, b], query: "", selected: b.id, generating: { $0 == a.id }, now: now, calendar: calendar).rows
    XCTAssertEqual(r.map(\.selected), [false, true])
    XCTAssertEqual(r.map(\.generating), [true, false])
  }

  func testLastActiveReadsTheClockInTheId() {
    XCTAssertNil(ConversationRows.lastActive(Conversation("abc")))
    XCTAssertNil(ConversationRows.lastActive(Conversation("12-3")))
    XCTAssertNotNil(ConversationRows.lastActive(Conversation(id(daysAgo: 2))))
  }
}
