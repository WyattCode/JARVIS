import Testing

@testable import JarvisCore

@Suite struct DockMemoryTests {
  @Test func firstLayoutHasTheListOut() {
    var memory = DockMemory()
    let result1 = memory.enteredSideways(pageOpen: false)
    #expect(result1)
  }

  @Test func aTurnAndBackKeepsWhatItWas() {
    for out in [true, false] {
      var memory = DockMemory()
      memory.started(true)
      memory.leftSideways(listOut: out)
      let result2 = memory.enteredSideways(pageOpen: false)
    #expect(result2 == out)
    }
  }

  @Test func whatThePersonDidUprightWins() {
    var memory = DockMemory()
    memory.started(true)
    memory.leftSideways(listOut: true)
    memory.movedList(open: false)
    let result3 = memory.enteredSideways(pageOpen: false)
    #expect(result3 == false)
    memory.leftSideways(listOut: false)
    memory.movedList(open: true)
    let result4 = memory.enteredSideways(pageOpen: true)
    #expect(result4)
  }

  @Test func aPageLeftWhileTurnedAwayBringsBackWhatWasBeforeIt() {
    var memory = DockMemory()
    memory.started(true)
    memory.leftSideways(listOut: false)  // the page had folded the list: it reads as folded
    memory.pageLeft(wasOut: true, sideways: false)
    let result5 = memory.enteredSideways(pageOpen: false)
    #expect(result5)
  }

  @Test func aPageLeftWhileSidewaysChangesNothingHere() {
    var memory = DockMemory()
    memory.started(true)
    memory.leftSideways(listOut: false)
    memory.pageLeft(wasOut: true, sideways: true)
    let result6 = memory.enteredSideways(pageOpen: false)
    #expect(result6 == false)
  }

  @Test func theMemoryIsUsedOnce() {
    var memory = DockMemory()
    memory.started(true)
    memory.leftSideways(listOut: true)
    memory.movedList(open: false)
    _ = memory.enteredSideways(pageOpen: false)
    // Entered again with nothing done meanwhile: back to what it was when last left.
    memory.leftSideways(listOut: true)
    let result7 = memory.enteredSideways(pageOpen: false)
    #expect(result7)
  }
}
