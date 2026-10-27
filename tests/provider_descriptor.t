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

    package TestLog;
    sub new { bless { lines => [] }, shift }
    sub is_debug { 1 }
    sub is_info { 1 }
    sub debug { push @{$_[0]{lines}}, ['debug', $_[1]] }
    sub info { push @{$_[0]{lines}}, ['info', $_[1]] }
    sub warn { push @{$_[0]{lines}}, ['warning', $_[1]] }
    sub error { push @{$_[0]{lines}}, ['error', $_[1]] }

    package Slim::Utils::Log;
    our $LOGGER = TestLog->new;
    sub addLogCategory { return $LOGGER }
    $INC{'Slim/Utils/Log.pm'} = __FILE__;
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
is($controls{source}{host_overridable}, 1,
    'hosts may override the acquisition source without receiving the provider-owned API key');
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
is($defaults->{retrieval_policy}, 'online_with_cache', 'API-key graph defaults to online read-through');
is($defaults->{storage_scope}, 'all_returned_artists', 'API-key graph stores all returned artists by default');
is($defaults->{artist_result_limit}, 25, 'API-key graph defaults to 25 similar artists');
is($defaults->{data_budget_mb}, 100, 'API-key graph defaults to the 100 MB service cap');
ok(!exists $controls{retrieval_policy}, 'graph retrieval policy is provider-owned and not host-overridable');

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
ok(
    scalar(grep { $_->[1] eq 'Last.fm: got 1 similar tracks for "Seed Artist - Seed Song"' }
        @{$Slim::Utils::Log::LOGGER->{lines}}),
    'LastMix acquisition logs bounded similar-track results in the provider category',
);
ok(
    scalar(grep { $_->[1] eq 'Last.fm: got 1 similar artists for "Seed Artist"' }
        @{$Slim::Utils::Log::LOGGER->{lines}}),
    'LastMix acquisition logs bounded similar-artist results in the provider category',
);

is_deeply(
    Plugins::LastFmGuidance::Provider::guidance_provider_process_environment_v1({ source => 'api_key' }, {}),
    { BLISS_GUIDANCE_LASTFM_API_KEY => 'test-direct-api-key' },
    'a host source override selects direct acquisition while the provider supplies the API key privately',
);
my $status = Plugins::LastFmGuidance::Provider::guidance_provider_status_v1();
is($status->{reason}, 'native_binary_missing', 'missing native binary is reported before a host can start the provider');

{
    my ($binary_fh, $binary_path) = tempfile();
    close $binary_fh;
    chmod 0755, $binary_path;
    no warnings 'redefine';
    local *Plugins::LastFmGuidance::Provider::_program_path = sub { return $binary_path };
    local *Plugins::LastFmGuidance::Provider::_binary_version = sub {
        return '{"schema_version":1,"program":"bliss-guidance-lastfm","version":"0.1.2","provider_id":"lastfm-guidance","spi_version":2}';
    };
    $Slim::Utils::Prefs::PREFS->set(source => 'api_key');
    $Slim::Utils::Prefs::PREFS->set(api_key => 'test-direct-api-key');
    my $incompatible = Plugins::LastFmGuidance::Provider::guidance_provider_status_v1();
    is($incompatible->{reason}, 'native_binary_incompatible',
        'a native provider without direct acquisition and policy capabilities is rejected');
}

{
    my ($binary_fh, $binary_path) = tempfile();
    close $binary_fh;
    chmod 0755, $binary_path;
    no warnings 'redefine';
    local *Plugins::LastFmGuidance::Provider::_program_path = sub { return $binary_path };
    local *Plugins::LastFmGuidance::Provider::_binary_version = sub {
        return '{"schema_version":1,"program":"bliss-guidance-lastfm","version":"0.1.3","provider_id":"lastfm-guidance","spi_version":2,"acquisition_modes":["artifact","direct"],"offline_graph_schema_version":2,"graph_commands":["status","sync","compact","delete"],"channel_policies":{"lastfm_track":["bounded_influence"],"lastfm_artist":["bounded_influence","target_share"]}}';
    };
    $Slim::Utils::Prefs::PREFS->set(source => 'api_key');
    $Slim::Utils::Prefs::PREFS->set(api_key => 'test-direct-api-key');
    my $compatible = Plugins::LastFmGuidance::Provider::guidance_provider_status_v1();
    ok($compatible->{available},
        'an API-key provider declaring acquisition, policy, and offline-graph capabilities is accepted');
    $Slim::Utils::Prefs::PREFS->set(artist_refresh_days => 30);
    is(Plugins::LastFmGuidance::Provider::guidance_provider_status_v1()->{reason}, 'native_binary_incompatible',
        'an old native provider cannot silently ignore a configured refresh target');
    $Slim::Utils::Prefs::PREFS->set(artist_refresh_days => 0);
}

{
    my ($binary_fh, $binary_path) = tempfile();
    close $binary_fh;
    chmod 0755, $binary_path;
    no warnings 'redefine';
    local *Plugins::LastFmGuidance::Provider::_program_path = sub { return $binary_path };
    local *Plugins::LastFmGuidance::Provider::_binary_version = sub {
        return '{"schema_version":1,"program":"bliss-guidance-lastfm","version":"0.1.3","provider_id":"lastfm-guidance","spi_version":2,"acquisition_modes":["artifact","direct"],"channel_policies":{"lastfm_track":["bounded_influence"],"lastfm_artist":["bounded_influence","target_share"]}}';
    };
    $Slim::Utils::Prefs::PREFS->set(source => 'api_key');
    my $incompatible = Plugins::LastFmGuidance::Provider::guidance_provider_status_v1();
    is($incompatible->{reason}, 'native_binary_incompatible',
        'API-key mode rejects a pre-graph native provider');
}

{
    no warnings 'redefine';
    local *Plugins::LastFmGuidance::Provider::_provider_status_for_source = sub {
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
        {},
    );
    is_deeply($config->{artifacts}, [], 'direct API mode does not require a LastMix artifact');
    is_deeply($config->{options}, {
        acquisition_mode => 'direct',
        store_path => Plugins::LastFmGuidance::Provider::_graph_store_path(),
        legacy_cache_path => Plugins::LastFmGuidance::Provider::_legacy_cache_path(),
        retrieval_policy => 'online_with_cache',
        artist_result_limit => 25,
        budget_bytes => 100_000_000,
        storage_scope => 'all_returned_artists',
        request_deadline_ms => 5000,
        max_concurrent_requests => 2,
        lastfm_track_influence => 25,
        lastfm_artist_mode => 'bounded_influence',
        lastfm_artist_level => 75,
        diagnostic_level => 'debug',
    }, 'direct API mode passes only trusted non-secret native configuration');
    unlike(encode_json($config), qr/test-direct-api-key/,
        'direct native configuration never serializes the API key');
    $Slim::Utils::Prefs::PREFS->set(artist_refresh_days => 30);
    $Slim::Utils::Prefs::PREFS->set(empty_artist_refresh_days => 7);
    my $configured = Plugins::LastFmGuidance::Provider::guidance_provider_native_spi_config_v1({ source => 'api_key' }, {});
    is($configured->{options}{artist_refresh_days}, 30, 'guidance receives the positive-result refresh target');
    is($configured->{options}{empty_artist_refresh_days}, 7, 'guidance receives the empty-result refresh target');
    $Slim::Utils::Prefs::PREFS->set(artist_refresh_days => 0);
    $Slim::Utils::Prefs::PREFS->set(empty_artist_refresh_days => 0);
}

Plugins::LastFmGuidance::Provider::guidance_provider_log_events_v1([
    {
        event_version => 'guidance_log_event_v1', level => 'info', phase => 'prepare',
        event => 'lastfm_lookup_completed', provider_id => 'lastfm-guidance',
        operation => 'artist.getSimilar', source => { label => 'Rotor' },
        cache_state => 'miss', result_count => 25,
    },
    {
        event_version => 'guidance_log_event_v1', level => 'debug', phase => 'score',
        event => 'lastfm_scoring_completed', provider_id => 'lastfm-guidance',
        details => { candidates => 20, similar_track_supported => 1, similar_artist_supported => 4 },
    },
    {
        event_version => 'guidance_log_event_v1', level => 'debug', phase => 'prepare',
        event => 'lastfm_request_json', provider_id => 'lastfm-guidance',
        details => { request => { method => 'artist.getSimilar', api_key => 'must-not-leak' } },
    },
    {
        event_version => 'guidance_log_event_v1', level => 'warning', phase => 'prepare',
        event => 'lastfm_lookup_failed', operation => 'artist.getSimilar',
        source => { label => 'Rotor' }, cache_state => 'miss',
        details => { error => 'HTTP status 429; retryable=yes; retry-after=60s' },
    },
], { host => 'fixture' });
ok(
    scalar(grep { $_->[1] eq 'Last.fm: got 25 similar artists for "Rotor"' }
        @{$Slim::Utils::Log::LOGGER->{lines}}),
    'native lookup event is rendered into the established Last.fm vocabulary',
);
is(Plugins::LastFmGuidance::Provider::_render_log_event({
    event => 'lastfm_lookup_completed', operation => 'artist.getSimilar',
    source => { label => 'Rotor' }, cache_state => 'stale_offline', result_count => 25,
}), 'Last.fm: using stale offline similar artists for "Rotor" (25 results)',
    'expired offline data is identified as cached rather than a fresh network result');
unlike(
    join("\n", map { $_->[1] } @{$Slim::Utils::Log::LOGGER->{lines}}),
    qr/must-not-leak/,
    'provider event rendering redacts API keys defensively',
);
ok(scalar(grep { $_->[0] eq 'warning' && $_->[1] eq 'Last.fm request failed for similar artists "Rotor"; continuing without this result' } @{$Slim::Utils::Log::LOGGER->{lines}}),
    'the existing warning message remains unchanged');
ok(scalar(grep { $_->[0] eq 'debug' && $_->[1] =~ /HTTP status 429/ && $_->[1] =~ /retry-after=60s/ } @{$Slim::Utils::Log::LOGGER->{lines}}),
    'the additional debug line explains the failed request');
ok(
    scalar(grep { $_->[1] eq 'Last.fm scoring: candidates=20, similar-track supported=1, similar-artist supported=4' }
        @{$Slim::Utils::Log::LOGGER->{lines}}),
    'native score event renders bounded debug diagnostics',
);

done_testing;
