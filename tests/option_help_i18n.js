const assert = require('assert');
const fs = require('fs');
const source = fs.readFileSync('LastFmGuidance/strings.txt', 'utf8');
const blocks = new Map([...source.matchAll(/^(\w+)\n\tEN\t([^\n]*)\n\tDE\t([^\n]*)/gm)].map(m => [m[1], {EN:m[2], DE:m[3]}]));
const cases = [
  ['GUIDANCE_LASTFM_SOURCE_DESC', ['LastMix', 'API Key'], ['LastMix', 'API-Schlüssel']],
  ['GUIDANCE_LASTFM_API_KEY_SOURCE_DESC', ['Bliss Guidance: Last.fm', 'LastMix'], ['Bliss Guidance: Last.fm', 'LastMix']],
  ['GUIDANCE_LASTFM_ARTIST_MODE_DESC', ['Target share', 'Per-candidate boost'], ['Zielanteil', 'Verstärkung pro Kandidat']],
  ['PLUGIN_LASTFMGUIDANCE_RETRIEVAL_POLICY_DESC', ['Online with cache', 'Offline preferred'], ['Online mit Cache', 'Offline bevorzugen']],
  ['PLUGIN_LASTFMGUIDANCE_STORAGE_SCOPE_DESC', ['Store all returned artists', 'Store only artists in the Lyrion library'], ['Alle zurückgegebenen Interpreten speichern', 'Nur Interpreten der Lyrion-Mediathek speichern']]
];
for (const [key, en, de] of cases) {
  const block = blocks.get(key);
  assert.ok(block, key + ' has both translations');
  for (const [language, options] of [['EN', en], ['DE', de]]) {
    for (const option of options) assert.ok(block[language].includes('<b>' + option + ':</b>'), key + ' ' + language + ' describes ' + option);
    for (const option of options.slice(1)) assert.ok(block[language].includes('<br/><br/><b>' + option + ':</b>'), key + ' ' + language + ' separates ' + option);
  }
}
assert.doesNotMatch(blocks.get('PLUGIN_LASTFMGUIDANCE_RETRIEVAL_POLICY_DESC').EN, /offline only/i);
assert.doesNotMatch(blocks.get('PLUGIN_LASTFMGUIDANCE_RETRIEVAL_POLICY_DESC').DE, /nur offline/i);
console.log('Last.fm choice explanations: ok');
