import QtQuick
import QtTest
import "../Logic.js" as Logic

// The settings panel's choices and labels. Everything here is pure, so the
// panel only has to draw what these return.
TestCase {
  name: "settings"

  function test_week_start_covers_the_whole_week() {
    var options = Logic.weekStartOptions()
    compare(options.length, 7)
    compare(options[0].label, "Sunday")
    compare(options[6].label, "Saturday")
    // The value is what Dropdown emits, which is always a string.
    for (var i = 0; i < options.length; i++)
      compare(options[i].value, String(i))
  }

  function test_week_start_label_survives_nonsense() {
    compare(Logic.weekStartLabel(1), "Monday")
    compare(Logic.weekStartLabel("6"), "Saturday")
    compare(Logic.weekStartLabel(9), "Sunday")
    compare(Logic.weekStartLabel(undefined), "Sunday")
  }

  function test_time_formats() {
    var options = Logic.timeFormatOptions()
    compare(options.length, 2)
    compare(options[0].value, "12h")
    compare(options[1].value, "24h")
  }

  function test_refresh_labels() {
    compare(Logic.refreshLabel(5), "5 min")
    compare(Logic.refreshLabel(15), "15 min")
    compare(Logic.refreshLabel(60), "1 hour")
    compare(Logic.refreshLabel(120), "2 hours")
    compare(Logic.refreshLabel(0), "Never")
  }

  function test_clock_presets_start_with_the_shipped_face() {
    var presets = Logic.clockPresets()
    compare(presets[0].format, "dddd, MMMM d, yyyy '•' hh:mm:ss AP")
    compare(presets[0].format, Logic.settingDefault("format"))
    for (var i = 0; i < presets.length; i++)
      verify(presets[i].label.length > 0 && presets[i].format.length > 0)
  }

  // Two faces that render the same are one face with two names, and the
  // dropdown would light up whichever came first.
  function test_clock_presets_are_distinct() {
    var presets = Logic.clockPresets(), seen = {}
    for (var i = 0; i < presets.length; i++) {
      verify(!seen[presets[i].format], presets[i].format + " appears twice")
      seen[presets[i].format] = true
      compare(Logic.clockPresetIndex(presets[i].format), i)
    }
  }

  function test_clock_preset_index() {
    compare(Logic.clockPresetIndex(Logic.clockPresets()[2].format), 2)
    compare(Logic.clockPresetIndex("hh:mm"), -1)
    compare(Logic.clockPresetIndex(""), -1)
  }

  function test_byte_labels() {
    compare(Logic.byteLabel(0), "0 KB")
    compare(Logic.byteLabel(512), "512 B")
    compare(Logic.byteLabel(61440), "60 KB")
    compare(Logic.byteLabel(18 * 1024 * 1024), "18.0 MB")
    compare(Logic.byteLabel(-1), "0 KB")
    compare(Logic.byteLabel(undefined), "0 KB")
  }

  function test_count_label_groups_thousands() {
    compare(Logic.countLabel(0), "0")
    compare(Logic.countLabel(59), "59")
    compare(Logic.countLabel(5405), "5,405")
    compare(Logic.countLabel(1234567), "1,234,567")
    compare(Logic.countLabel(undefined), "0")
  }

  function test_cache_label() {
    compare(Logic.cacheLabel(18 * 1024 * 1024, 5405), "18.0 MB · 5,405 cached")
  }

  function test_wrap_options() {
    var options = Logic.wrapOptions()
    compare(options.length, 2)
    // The values are what a Dropdown emits, which is always a string, and
    // the panel turns them back into the boolean the setting stores.
    compare(options[0].value, "false")
    compare(options[1].value, "true")
    compare(options[0].label, "One line")
  }

  // Cutting off is the default: it keeps every entry the same height and the
  // list scannable, which is what the column is for.
  function test_wrapping_is_off_by_default() {
    compare(Logic.settingDefault("wrapEvents"), false)
  }

  function test_day_window_options() {
    var starts = Logic.dayStartOptions()
    compare(starts.length, 24)
    compare(starts[0].value, "0")
    compare(starts[0].label, "12 AM")
    compare(starts[9].label, "09 AM")

    var ends = Logic.dayEndOptions()
    compare(ends.length, 24)
    compare(ends[0].value, "1")
    // The end runs to midnight of the next day, which is how "all of it" is
    // said without saying "0".
    compare(ends[23].value, "24")
    compare(ends[23].label, "12 AM")
  }

  function test_the_whole_day_is_the_default() {
    compare(Logic.settingDefault("dayStartHour"), 0)
    compare(Logic.settingDefault("dayEndHour"), 24)
  }

  function test_defaults_match_the_widget_manifest() {
    var d = Logic.settingDefaults()
    compare(d.weekStartDay, 0)
    compare(d.timeFormat, "12h")
    compare(d.showWeekNumbers, false)
    compare(d.refreshMinutes, 15)
    compare(d.verticalFormat, "HH\nmm\nss")
  }
}
