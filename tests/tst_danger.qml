import QtQuick
import QtTest
import "../Logic.js" as Logic

TestCase {
  name: "danger"
  function test_red_lifts_to_aa() {
    var backgrounds = ["#0d0f18", "#1e1e2e", "#ffffff", "#fafafa"]
    for (var i = 0; i < backgrounds.length; i++) {
      var out = Logic.ensureContrast("#d76f6a", backgrounds[i], 4.5)
      var ratio = Logic.contrastRatio(out, backgrounds[i])
      console.log(backgrounds[i], "->", out, ratio.toFixed(2) + ":1")
      verify(ratio >= 4.49, backgrounds[i] + " only reached " + ratio)
    }
  }
}
