import unittest
from html.parser import HTMLParser
from pathlib import Path


class SettingsSections(HTMLParser):
    def __init__(self):
        super().__init__()
        self.stack = []
        self.fields = {}

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag == 'div':
            self.stack.append(attrs.get('id'))
        if attrs.get('name', '').startswith('pref_'):
            self.fields[attrs['name']] = tuple(self.stack)

    def handle_endtag(self, tag):
        if tag == 'div' and self.stack:
            self.stack.pop()


class SettingsSectionTest(unittest.TestCase):
    def test_source_and_key_are_separate_from_guidance_defaults(self):
        path = Path('LastFmGuidance/HTML/EN/plugins/LastFmGuidance/settings/lastfmguidance.html')
        sections = SettingsSections()
        sections.feed(path.read_text(encoding='utf-8'))
        for field in ('pref_source', 'pref_api_key_source', 'pref_api_key'):
            self.assertIn('lastfm-guidance-connection', sections.fields[field])
            self.assertNotIn('lastfm-guidance-defaults', sections.fields[field])
        for field in ('pref_lastfm_track_influence', 'pref_lastfm_artist_mode', 'pref_lastfm_artist_level'):
            self.assertIn('lastfm-guidance-defaults', sections.fields[field])
            self.assertNotIn('lastfm-guidance-connection', sections.fields[field])


if __name__ == '__main__':
    unittest.main()
