import QtQuick
import QtTest

// The bar clock's default face.
//
//   QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests/tst_format.qml
//
// The format string lives in BarWidget.qml as `defaultFormat`; this pins the
// exact text it renders, because the requirement was written as a sample
// rather than as a pattern:
//
//   Saturday, September 19, 2026 • 08:15:34 PM
TestCase {
  name: "Format"

  // Kept identical to BarWidget.defaultFormat. The bullet is quoted because
  // Qt.formatDateTime reads unquoted characters as field codes.
  readonly property string defaultFormat: "dddd, MMMM d, yyyy '•' hh:mm:ss AP"

  function test_renders_the_requested_face() {
    var when = new Date(2026, 8, 19, 20, 15, 34)   // Sat 19 Sep 2026, 20:15:34
    compare(Qt.formatDateTime(when, defaultFormat),
            "Saturday, September 19, 2026 • 08:15:34 PM")
  }

  // Morning has to stay zero-padded and say AM.
  function test_morning_is_padded_and_am() {
    var when = new Date(2026, 8, 19, 9, 5, 2)
    compare(Qt.formatDateTime(when, defaultFormat),
            "Saturday, September 19, 2026 • 09:05:02 AM")
  }

  function test_noon_and_midnight_read_as_twelve() {
    compare(Qt.formatDateTime(new Date(2026, 8, 19, 12, 0, 0), defaultFormat),
            "Saturday, September 19, 2026 • 12:00:00 PM")
    compare(Qt.formatDateTime(new Date(2026, 8, 19, 0, 0, 0), defaultFormat),
            "Saturday, September 19, 2026 • 12:00:00 AM")
  }

  // The day of the month is not padded: "September 1", not "September 01".
  function test_single_digit_day_is_not_padded() {
    compare(Qt.formatDateTime(new Date(2026, 8, 1, 20, 15, 34), defaultFormat),
            "Tuesday, September 1, 2026 • 08:15:34 PM")
  }
}
