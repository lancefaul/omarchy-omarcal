import QtQuick
import QtTest
import "../Logic.js" as Logic

// Text drawn in a fixed-width column must stay inside it.
//
//   QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests/tst_truncation.qml
//
// Logic.singleLine is unit-tested in tst_logic.qml; this checks the thing that
// actually went wrong, which is how Text behaves. `elide` trims the last line
// it lays out, so a string carrying a newline still renders every line and the
// extra ones simply run past the column. 77 of 115 occurrences in a real month
// had a multi-line location, so this was the common case rather than an edge.
TestCase {
  name: "Truncation"
  when: windowShown

  property string multiLine: "Northgate Primary School\n908 Kestrel Rise, Dunmore, OX  70508, United States"
  property string longLine: "Consecration Novena to Stella Maris and then some more words"

  Text {
    id: raw
    width: 200
    elide: Text.ElideRight
    text: parent ? "" : ""
  }

  Text {
    id: flattened
    width: 200
    elide: Text.ElideRight
  }

  // The bug: eliding alone does not save a multi-line string.
  function test_elide_alone_does_not_contain_a_multi_line_string() {
    raw.text = multiLine
    verify(raw.lineCount > 1,
           "expected Text to lay out several lines for a string with a newline")
    verify(raw.contentWidth > raw.width,
           "expected the untrimmed line to overflow the column")
  }

  // The fix: one line, inside the column, ellipsised.
  function test_single_line_keeps_it_in_the_column() {
    flattened.text = Logic.singleLine(multiLine)
    compare(flattened.lineCount, 1)
    verify(flattened.contentWidth <= flattened.width + 1,
           "flattened text still wider than its column: "
           + flattened.contentWidth + " > " + flattened.width)
    verify(flattened.truncated, "expected the text to be elided")
  }

  // A long single-line title elides without any help.
  function test_long_title_elides() {
    flattened.text = Logic.singleLine(longLine)
    compare(flattened.lineCount, 1)
    verify(flattened.truncated)
    verify(flattened.contentWidth <= flattened.width + 1)
  }

  // Short text is left alone: no ellipsis, no growth.
  function test_short_text_is_untouched() {
    flattened.text = Logic.singleLine("Swimming lesson")
    compare(flattened.lineCount, 1)
    verify(!flattened.truncated)
  }

  // Drawn as one line per line, every line of every real location fits its
  // column — the shape the day panel actually renders.
  function test_every_location_line_fits_when_split() {
    var request = new XMLHttpRequest()
    request.open("GET", Qt.resolvedUrl("fixture-september.json"), false)
    request.send(null)
    var events = JSON.parse(request.responseText).events
    var lines = 0
    for (var i = 0; i < events.length; i++) {
      if (!events[i].location) continue
      var parts = Logic.locationLines(events[i].location)
      verify(parts.length >= 1, "no lines from " + events[i].location)
      for (var j = 0; j < parts.length; j++) {
        flattened.text = parts[j]
        compare(flattened.lineCount, 1)
        verify(flattened.contentWidth <= flattened.width + 1,
               "line overflows: " + parts[j])
        lines++
      }
    }
    verify(lines > 0, "fixture had no locations")
  }

  // Every location in a real month, through the same column.
  function test_every_real_location_fits() {
    var request = new XMLHttpRequest()
    request.open("GET", Qt.resolvedUrl("fixture-september.json"), false)
    request.send(null)
    var events = JSON.parse(request.responseText).events
    var checked = 0
    for (var i = 0; i < events.length; i++) {
      if (!events[i].location) continue
      flattened.text = Logic.singleLine(events[i].location)
      compare(flattened.lineCount, 1)
      verify(flattened.contentWidth <= flattened.width + 1,
             "location overflows: " + events[i].location)
      checked++
    }
    verify(checked > 0, "fixture had no locations to check")
  }
}
