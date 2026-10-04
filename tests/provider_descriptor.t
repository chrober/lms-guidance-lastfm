use strict;
use warnings;
use File::Temp qw(tempfile);
use JSON::PP qw(decode_json encode_json);
use Test::More;
use lib '.';

{
    package TestPrefs;
    sub new { bless { values => {} }, shift }
    sub init { }
    sub get { $_[0]->{values}{$_[1]} }
    sub set { $_[0]->{values}{$_[1]} = $_[2] }

    package Slim::Utils::Prefs;
    our $PREFS = TestPrefs->new;
    sub import { }
    sub preferences { return $PREFS }
    $INC{'Slim/Utils/Prefs.pm'} = __FILE__;
}

require 'LastFmGuidance/Provider.pm';

my $descriptor = Plugins::LastFmGuidance::Provider::guidance_provider_descriptor_v1();
is($descriptor->{protocol_version}, 1, 'publishes descriptor protocol v1');
is($descriptor->{provider_id}, 'lastfm', 'publishes stable Last.fm provider ID');
is($descriptor->{display_name}, 'Bliss Guidance: Last.fm', 'publishes the Bliss Guidance display name');
is($descriptor->{settings_uri}, 'plugins/LastFmGuidance/settings/lastfmguidance.html', 'owns a separate provider settings page');
is_deeply($descriptor->{capabilities}, [qw(lastfm_similarity lastfm_acquisition)], 'declares Last.fm similarity and acquisition capabilities');
is_deeply($descriptor->{native_spi}{channels}, {
    similar_track => 'lastfm_track',
    similar_artist => 'lastfm_artist',
}, 'maps Last.fm relations to stable native guidance channels');

my %controls = map { $_->{key} => $_ } @{$descriptor->{controls}};
is_deeply($controls{source}{values}, [qw(lastmix api_key)], 'source selector exposes LastMix and API Key');
is_deeply($controls{source}{option_labels}, {
    lastmix => 'GUIDANCE_LASTFM_SOURCE_LASTMIX',
    api_key => 'GUIDANCE_LASTFM_SOURCE_API_KEY',
}, 'source enum publishes localized labels for generic host renderers');
is($controls{source}{host_overridable}, 0, 'source selection remains provider-owned');
is($controls{lastfm_track_influence}{factory_default}, 25, 'track guidance defaults to 25 percent');
is($controls{lastfm_artist_mode}{factory_default}, 'target_share', 'artist strategy defaults to target share');
is_deeply($controls{lastfm_artist_mode}{option_labels}, {
    target_share => 'GUIDANCE_LASTFM_ARTIST_MODE_TARGET_SHARE',
    bounded_influence => 'GUIDANCE_LASTFM_ARTIST_MODE_BOUNDED',
}, 'artist-mode enum publishes localized labels for generic host renderers');
is($controls{lastfm_artist_level}{factory_default}, 75, 'artist guidance defaults to 75 percent');
is($controls{lastfm_artist_level}{guidance_policy}, 'target_share_or_bounded',
    'artist level publishes the shared target-share or bounded policy contract');
is($controls{lastfm_artist_level}{guidance_mode_key}, 'lastfm_artist_mode',
    'artist level identifies the provider-owned strategy control');

my $defaults = Plugins::LastFmGuidance::Provider::guidance_provider_defaults_v1();
is($defaults->{source}, 'lastmix', 'LastMix is the provider default source');
is($defaults->{lastfm_track_influence}, 25, 'track default is available before settings are saved');
is($defaults->{lastfm_artist_level}, 75, 'artist default is available before settings are saved');

$Slim::Utils::Prefs::PREFS->set(source => 'api_key');
$Slim::Utils::Prefs::PREFS->set(api_key => 'test-direct-api-key');
my $environment = Plugins::LastFmGuidance::Provider::guidance_provider_process_environment_v1({}, {});
is_deeply($environment, { BLISS_GUIDANCE_LASTFM_API_KEY => 'test-direct-api-key' }, 'direct mode supplies the API key only as launch environment');
ok(!exists $defaults->{api_key}, 'shared defaults do not expose the stored API key');

{
    package Slim::Utils::PluginManager;
    our @ENABLED;
    sub enabledPlugins { return @ENABLED; }
    $INC{'Slim/Utils/PluginManager.pm'} = __FILE__;
}

@Slim::Utils::PluginManager::ENABLED = ();
ok(!Plugins::LastFmGuidance::Provider::_lastmix_available(), 'missing LastMix is detected rather than silently switching source');
@Slim::Utils::PluginManager::ENABLED = ('Plugins::LastMix::Plugin');
ok(Plugins::LastFmGuidance::Provider::_lastmix_available(), 'enabled LastMix is detected as the selected source backend');
$Slim::Utils::Prefs::PREFS->set(source => 'lastmix');

{
    package Plugins::LastMix::LFM;
    sub getSimilarTracks {
        my ($class, $callback, $args) = @_;
        $callback->({ similartracks => { track => [{
            name => 'Related Song', mbid => 'recording-mbid-2', match => 0.9,
            artist => { name => 'Related Artist', mbid => 'artist-mbid-2' },
        }] } });
    }
    sub getSimilarArtists {
        my ($class, $callback, $args) = @_;
        $callback->({ similarartists => { artist => [{
            name => 'Related Artist', mbid => 'artist-mbid-2', match => 0.8,
        }] } });
    }
    $INC{'Plugins/LastMix/LFM.pm'} = __FILE__;
}

my ($artifact_fh, $artifact_path) = tempfile();
close $artifact_fh;
my $acquisition;
Plugins::LastFmGuidance::Provider::guidance_provider_acquire_artifacts_v1(
    { source => 'lastmix' },
    {
        source_tracks => [{
            id => 'lms-track-1', artist => 'Seed Artist', title => 'Seed Song',
            recording_mbid => 'recording-mbid-1', artist_mbids => ['artist-mbid-1'],
        }],
        candidate_tracks => [{
            candidate_id => 'candidate-1', artist => 'Related Artist', title => 'Related Song',
            recording_mbid => 'recording-mbid-2', artist_mbids => ['artist-mbid-2'],
        }],
        artifact_path => $artifact_path,
    },
    sub { $acquisition = shift; },
);
ok($acquisition->{available}, 'LastMix acquisition completes as an available provider result');
is($acquisition->{artifacts}[0]{kind}, 'resolved-lastfm-evidence-v1', 'LastMix acquisition returns a candidate-resolved evidence artifact');
my $artifact_text = do { open my $fh, '<', $artifact_path or die $!; local $/; <$fh> };
my $artifact = decode_json($artifact_text);
is(scalar @{$artifact->{edges}}, 2, 'LastMix acquisition writes one resolved recording and artist observation per candidate');
is_deeply(
    [ map { $_->{resolved_candidate_id} } @{$artifact->{edges}} ],
    ['candidate-1', 'candidate-1'],
    'LastMix evidence is resolved only against the bounded host candidate set',
);

is_deeply(
    Plugins::LastFmGuidance::Provider::guidance_provider_process_environment_v1({ source => 'api_key' }, {}),
    {},
    'a host policy cannot override the provider-owned source and obtain an API key',
);
my $status = Plugins::LastFmGuidance::Provider::guidance_provider_status_v1();
is($status->{reason}, 'native_binary_missing', 'missing native binary is reported before a host can start the provider');

{
    no warnings 'redefine';
    local *Plugins::LastFmGuidance::Provider::guidance_provider_status_v1 = sub {
        return { available => 1, program => '/trusted/bin/bliss-guidance-lastfm' };
    };
    $Slim::Utils::Prefs::PREFS->set(source => 'api_key');
    $Slim::Utils::Prefs::PREFS->set(api_key => 'test-direct-api-key');
    my $config = Plugins::LastFmGuidance::Provider::guidance_provider_native_spi_config_v1(
        {
            source => 'api_key',
            lastfm_track_influence => 25,
            lastfm_artist_mode => 'bounded_influence',
            lastfm_artist_level => 75,
        },
        {
            cache_path => '/trusted/cache/lastfm-guidance.json',
            cache_ttl_seconds => 3600,
            request_deadline_ms => 5000,
            max_concurrent_requests => 2,
        },
    );
    is_deeply($config->{artifacts}, [], 'direct API mode does not require a LastMix artifact');
    is_deeply($config->{options}, {
        acquisition_mode => 'direct',
        cache_path => '/trusted/cache/lastfm-guidance.json',
        cache_ttl_seconds => 3600,
        request_deadline_ms => 5000,
        max_concurrent_requests => 2,
        lastfm_track_influence => 25,
        lastfm_artist_mode => 'bounded_influence',
        lastfm_artist_level => 75,
    }, 'direct API mode passes only trusted non-secret native configuration');
    unlike(encode_json($config), qr/test-direct-api-key/,
        'direct native configuration never serializes the API key');
}

done_testing;
