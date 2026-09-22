"""Names on the panel's root must not collide.

A property named like a function replaces it: `editAccount`, a string added
for invitees, silently swallowed the `editAccount()` the Account settings
button called, and the button went dead with nothing in the log. An item id
named like a root member is the same trap one reference away. QML says
nothing about either; this does.
"""
import collections
import os
import re
import unittest

PANEL = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "Panel.qml")
MEMBER = re.compile(r"^  (?:readonly )?(?:property \S+|function|signal) (\w+)")
ITEM_ID = re.compile(r"^\s+id: (\w+)\s*(?://.*)?$")


class PanelNames(unittest.TestCase):
    def setUp(self):
        with open(PANEL) as src:
            self.lines = src.read().split("\n")

    def members(self):
        found = collections.defaultdict(list)
        for number, line in enumerate(self.lines, 1):
            match = MEMBER.match(line)
            if match:
                found[match.group(1)].append(number)
        return found

    def test_no_member_declared_twice(self):
        twice = {name: at for name, at in self.members().items() if len(at) > 1}
        self.assertEqual(twice, {}, "root members declared more than once (line numbers)")

    def test_no_id_named_like_a_member(self):
        members = self.members()
        clash = {}
        for number, line in enumerate(self.lines, 1):
            match = ITEM_ID.match(line)
            if match and match.group(1) in members:
                clash[match.group(1)] = number
        self.assertEqual(clash, {}, "ids that shadow a root member (line numbers)")


if __name__ == "__main__":
    unittest.main()
