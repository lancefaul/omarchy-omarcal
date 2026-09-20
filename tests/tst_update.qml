import QtQuick
import QtTest
import "../Logic.js" as Logic

// The updater's reading. Copied from omedia and archamp rather than designed
// again — an updater is not a place to have ideas — so these check the copy.
TestCase {
  name: "update"

  function test_version_parsing() {
    compare(Logic.parseVersion("1.0.0").join("."), "1.0.0")
    compare(Logic.parseVersion("v2.10.3").join("."), "2.10.3")
    compare(Logic.parseVersion("1.0"), null)
    compare(Logic.parseVersion("banana"), null)
    compare(Logic.parseVersion(""), null)
  }

  function test_newer_version() {
    verify(Logic.isNewerVersion("1.0.1", "1.0.0"))
    verify(Logic.isNewerVersion("1.1.0", "1.0.9"))
    verify(Logic.isNewerVersion("2.0.0", "1.99.99"))
    verify(!Logic.isNewerVersion("1.0.0", "1.0.0"))
    verify(!Logic.isNewerVersion("1.0.0", "1.0.1"))
    // Ten is after nine, which a string comparison would get wrong.
    verify(Logic.isNewerVersion("1.10.0", "1.9.0"))
    verify(!Logic.isNewerVersion("banana", "1.0.0"))
  }

  function test_parse_release() {
    var release = Logic.parseLatestRelease(JSON.stringify({
      tag_name: "v1.2.0", published_at: "2026-09-20T12:00:00Z"
    }))
    compare(release.version, "1.2.0")
    compare(release.tag, "v1.2.0")
    compare(release.published, "2026-09-20")
    verify(release.url.indexOf(Logic.releasesPage()) === 0)
  }

  // A draft or a prerelease is not an update, and a tag that is not a version
  // is not one either.
  function test_release_rejects_what_is_not_one() {
    compare(Logic.parseLatestRelease(JSON.stringify({ tag_name: "v1.0.0", draft: true })), null)
    compare(Logic.parseLatestRelease(JSON.stringify({ tag_name: "v1.0.0", prerelease: true })), null)
    compare(Logic.parseLatestRelease(JSON.stringify({ tag_name: "nightly" })), null)
    compare(Logic.parseLatestRelease("not json"), null)
    compare(Logic.parseLatestRelease(null), null)
  }

  // An update reloads the plugin, so what happened is read back afterwards
  // from what was written down before it ran.
  function test_attempt_applied() {
    compare(Logic.updateAttemptState({ version: "1.1.0", at: 1000 }, "1.1.0", 2000),
            "applied")
    compare(Logic.updateAttemptState({ version: "1.1.0", at: 1000 }, "1.2.0", 2000),
            "applied")
  }

  function test_attempt_failed_after_the_timeout() {
    var long = 1000 + 6 * 60 * 1000
    compare(Logic.updateAttemptState({ version: "1.1.0", at: 1000 }, "1.0.0", long),
            "failed")
  }

  function test_attempt_still_running() {
    compare(Logic.updateAttemptState({ version: "1.1.0", at: 1000 }, "1.0.0", 2000), "")
    compare(Logic.updateAttemptState(null, "1.0.0", 2000), "")
  }

  function test_status_line() {
    compare(Logic.updateStatusLine("1.0.0", null, ""),
            "Installed 1.0.0 · not checked yet")
    compare(Logic.updateStatusLine("1.0.0", { version: "1.0.0" }, ""),
            "Installed 1.0.0 · up to date")
    compare(Logic.updateStatusLine("1.0.0", { version: "1.1.0" }, ""),
            "Installed 1.0.0 · 1.1.0 available")
    compare(Logic.updateStatusLine("", null, ""), "Installed ? · not checked yet")
    compare(Logic.updateStatusLine("1.0.0", null, "GitHub could not be reached"),
            "Installed 1.0.0 · GitHub could not be reached")
  }

  // Asked and told there is nothing is not the same as never having asked,
  // and the line under this one would contradict it.
  function test_status_line_knows_it_has_asked() {
    compare(Logic.updateStatusLine("1.0.0", null, "", 0),
            "Installed 1.0.0 · not checked yet")
    compare(Logic.updateStatusLine("1.0.0", null, "", 1789938006000),
            "Installed 1.0.0 · no releases yet")
  }

  function test_checked_line() {
    var now = 10 * 24 * 60 * 60 * 1000
    compare(Logic.updateCheckedLine(0, true, now), "Checking…")
    compare(Logic.updateCheckedLine(0, false, now), "Not checked yet")
    compare(Logic.updateCheckedLine(now - 30 * 1000, false, now), "Checked just now")
    compare(Logic.updateCheckedLine(now - 5 * 60 * 1000, false, now),
            "Checked 5 minutes ago")
    compare(Logic.updateCheckedLine(now - 60 * 60 * 1000, false, now),
            "Checked 1 hour ago")
    compare(Logic.updateCheckedLine(now - 3 * 24 * 60 * 60 * 1000, false, now),
            "Checked 3 days ago")
  }

  function test_check_due() {
    var day = 24 * 60 * 60 * 1000
    verify(Logic.updateCheckDue(0, day, true))
    verify(Logic.updateCheckDue(0, day + 1, true))
    verify(!Logic.updateCheckDue(day, day + 1000, true))
    verify(Logic.updateCheckDue(day, day * 3, true))
    // Off is off, however long it has been.
    verify(!Logic.updateCheckDue(0, day * 99, false))
    // A clock that went backwards is a reason to check, not to wait a day.
    verify(Logic.updateCheckDue(day * 5, day, true))
  }

  function test_commands() {
    compare(Logic.updateCommand().join(" "),
            "omarchy plugin update lancefaul.omarcal --yes")
    compare(Logic.restartCommand().join(" "), "omarchy restart shell")
  }
}
