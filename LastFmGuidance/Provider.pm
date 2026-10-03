package Plugins::LastFmGuidance::Provider;

use strict;
use warnings;
use Config qw(%Config);
use File::Basename qw(dirname);
use File::Spec::Functions qw(catfile);
use Slim::Utils::Prefs;

my $prefs = Slim::Utils::Prefs::preferences('plugin.guidancelastfm');

my %FACTORY_DEFAULTS = (
    source                   => 'lastmix',
    api_key                  => '',
    lastfm_track_influence   => 25,
    lastfm_artist_mode       => 'target_share',
    lastfm_artist_level      => 75,
    settings_revision        => 1,
);

my %RANGES = (
    lastfm_track_influence => [0, 100],
    lastfm_artist_level    => [0, 100],
);

sub init_preferences {
    $prefs->init({ %FACTORY_DEFAULTS });
}

sub guidance_provider_descriptor_v1 {
    return {
        protocol_version => 1,
        provider_id => 'lastfm',
        display_name => 'Bliss Guidance: Last.fm',
        settings_uri => 'plugins/LastFmGuidance/settings/lastfmguidance.html',
        capabilities => [qw(lastfm_similarity lastfm_acquisition)],
        scopes => [qw(global_candidate edge_candidate)],
        settings_schema_version => 1,
        controls => [
            {
                key => 'source', type => 'enum', values => [qw(lastmix api_key)],
                factory_default => 'lastmix', host_overridable => 0,
                label_token => 'GUIDANCE_LASTFM_SOURCE',
                help_token => 'GUIDANCE_LASTFM_SOURCE_DESC',
            },
            {
                key => 'lastfm_track_influence', type => 'integer', minimum => 0,
                maximum => 100, factory_default => 25, host_overridable => 1,
                guidance_channel => 'lastfm_track', render_as => 'slider',
                label_token => 'GUIDANCE_LASTFM_TRACK_INFLUENCE',
                help_token => 'GUIDANCE_LASTFM_TRACK_INFLUENCE_DESC',
            },
            {
                key => 'lastfm_artist_mode', type => 'enum',
                values => [qw(target_share bounded_influence)],
                factory_default => 'target_share', host_overridable => 1,
                label_token => 'GUIDANCE_LASTFM_ARTIST_MODE',
                help_token => 'GUIDANCE_LASTFM_ARTIST_MODE_DESC',
            },
            {
                key => 'lastfm_artist_level', type => 'integer', minimum => 0,
                maximum => 100, factory_default => 75, host_overridable => 1,
                guidance_channel => 'lastfm_artist', render_as => 'slider',
                label_token => 'GUIDANCE_LASTFM_ARTIST_LEVEL',
                help_token => 'GUIDANCE_LASTFM_ARTIST_LEVEL_DESC',
            },
        ],
        native_spi => {
            provider_id => 'lastfm-guidance',
            spi_version => 2,
            protocol => 'bliss-guidance-jsonl-v2',
            channels => {
                similar_track => 'lastfm_track',
                similar_artist => 'lastfm_artist',
            },
            artifact_kinds => ['lastfm-relations-v1'],
            resource_kinds => [],
        },
    };
}

sub guidance_provider_defaults_v1 {
    init_preferences();
    my %defaults;
    $defaults{source} = _source($prefs->get('source'));
    $defaults{lastfm_artist_mode} = _artist_mode($prefs->get('lastfm_artist_mode'));
    for my $key (keys %RANGES) {
        my ($minimum, $maximum) = @{$RANGES{$key}};
        my $value = $prefs->get($key);
        $value = $FACTORY_DEFAULTS{$key} unless defined $value && $value =~ /^\d+$/;
        $value = int($value);
        $value = $minimum if $value < $minimum;
        $value = $maximum if $value > $maximum;
        $defaults{$key} = $value;
    }
    $defaults{settings_revision} = int($prefs->get('settings_revision') || $FACTORY_DEFAULTS{settings_revision});
    return \%defaults;
}

sub guidance_provider_status_v1 {
    my $program = _program_path();
    return { available => 0, reason => 'native_binary_missing', program => '' }
        unless -x $program;

    my $version = _binary_version($program);
    return { available => 0, reason => 'native_binary_incompatible', program => $program }
        unless $version =~ /"provider_id"\s*:\s*"lastfm-guidance"/
            && $version =~ /"spi_version"\s*:\s*2/;

    my $defaults = guidance_provider_defaults_v1();
    if ($defaults->{source} eq 'lastmix') {
        return { available => 0, reason => 'lastmix_unavailable', program => $program }
            unless _lastmix_available();
    }
    else {
        return { available => 0, reason => 'api_key_missing', program => $program }
            unless _api_key();
    }

    return { available => 1, reason => '', program => $program, version => $version };
}

sub guidance_provider_process_environment_v1 {
    my ($resolved_policy, $trusted_context) = @_;
    my $effective = _effective_policy($resolved_policy || {}, guidance_provider_defaults_v1());
    return {} unless $effective->{source} eq 'api_key';
    my $api_key = _api_key();
    return {} unless length $api_key;
    return { BLISS_GUIDANCE_LASTFM_API_KEY => $api_key };
}

sub guidance_provider_native_spi_config_v1 {
    my ($resolved_policy, $trusted_context) = @_;
    $trusted_context ||= {};
    my $status = guidance_provider_status_v1();
    die 'Last.fm guidance provider is unavailable: ' . ($status->{reason} || 'unknown')
        unless $status->{available};

    my $effective = _effective_policy($resolved_policy || {}, guidance_provider_defaults_v1());
    my @artifacts;
    if ($effective->{source} eq 'lastmix') {
        my $artifact = $trusted_context->{lastfm_relations_artifact};
        die 'Last.fm LastMix mode requires a trusted relations artifact'
            unless ref($artifact) eq 'HASH' && $artifact->{path} && $artifact->{sha256}
                && ($artifact->{kind} || '') eq 'lastfm-relations-v1';
        push @artifacts, {
            kind => 'lastfm-relations-v1', path => $artifact->{path}, sha256 => $artifact->{sha256},
        };
    }

    return {
        id => 'lastfm-guidance',
        program => $status->{program},
        options => {
            source => $effective->{source},
            lastfm_track_influence => $effective->{lastfm_track_influence},
            lastfm_artist_mode => $effective->{lastfm_artist_mode},
            lastfm_artist_level => $effective->{lastfm_artist_level},
        },
        artifacts => \@artifacts,
        resources => [],
        timeout_ms => 5000,
    };
}

sub guidance_provider_acquire_artifacts_v1 {
    my ($resolved_policy, $trusted_context, $on_complete) = @_;
    my $effective = _effective_policy($resolved_policy || {}, guidance_provider_defaults_v1());
    return $on_complete->({ available => 1, artifacts => [], diagnostic => '' })
        if $effective->{source} eq 'api_key';
    return $on_complete->({
        available => 0,
        artifacts => [],
        diagnostic => 'LastMix relation acquisition is not connected to this host yet',
    });
}

sub _effective_policy {
    my ($policy, $defaults) = @_;
    my %effective;
    # Source selection and its secret stay provider-owned: descriptors mark this
    # control non-overridable, and the resolver enforces that boundary too.
    $effective{source} = _source($defaults->{source});
    $effective{lastfm_artist_mode} = _artist_mode(
        exists $policy->{lastfm_artist_mode} ? $policy->{lastfm_artist_mode} : $defaults->{lastfm_artist_mode}
    );
    for my $key (keys %RANGES) {
        my ($minimum, $maximum) = @{$RANGES{$key}};
        my $value = exists $policy->{$key} ? $policy->{$key} : $defaults->{$key};
        die "Invalid Last.fm value for $key" unless defined $value && $value =~ /^\d+$/;
        $value = int($value);
        die "Out-of-range Last.fm value for $key" if $value < $minimum || $value > $maximum;
        $effective{$key} = $value;
    }
    return \%effective;
}

sub _source {
    my $value = shift;
    return $value && $value =~ /^(?:lastmix|api_key)$/ ? $value : $FACTORY_DEFAULTS{source};
}

sub _artist_mode {
    my $value = shift;
    return $value && $value =~ /^(?:target_share|bounded_influence)$/ ? $value : $FACTORY_DEFAULTS{lastfm_artist_mode};
}

sub _api_key {
    init_preferences();
    return $prefs->get('api_key') || '';
}

sub _lastmix_available {
    return 0 unless eval { require Slim::Utils::PluginManager; 1 };
    return scalar grep { $_ eq 'Plugins::LastMix::Plugin' }
        Slim::Utils::PluginManager->enabledPlugins();
}

sub _program_path {
    my $directory = dirname(__FILE__);
    my $name = $^O eq 'MSWin32' ? 'bliss-guidance-lastfm.exe' : 'bliss-guidance-lastfm';
    return catfile($directory, 'Bin', _platform(), $name);
}

sub _platform {
    return 'windows' if $^O eq 'MSWin32';
    return 'mac' if $^O eq 'darwin';
    my $arch = lc($Config{archname} || '');
    return 'aarch64-linux' if $arch =~ /(?:aarch64|arm64)/;
    return 'armhf-linux' if $arch =~ /(?:armv6|armv7|armhf|gnueabihf)/;
    return 'x86_64-linux';
}

sub _binary_version {
    my $program = shift;
    my $quoted = $program;
    $quoted =~ s/"/\\"/g;
    return eval { qx("$quoted" version --json) } || '';
}

1;
