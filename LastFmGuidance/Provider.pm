package Plugins::LastFmGuidance::Provider;

use strict;
use warnings;
use Config qw(%Config);
use Digest::SHA qw(sha256_hex);
use File::Basename qw(dirname);
use File::Spec::Functions qw(catfile);
use JSON::PP qw(encode_json);
use POSIX qw(strftime);
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
                option_labels => {
                    lastmix => 'GUIDANCE_LASTFM_SOURCE_LASTMIX',
                    api_key => 'GUIDANCE_LASTFM_SOURCE_API_KEY',
                },
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
                option_labels => {
                    target_share => 'GUIDANCE_LASTFM_ARTIST_MODE_TARGET_SHARE',
                    bounded_influence => 'GUIDANCE_LASTFM_ARTIST_MODE_BOUNDED',
                },
                factory_default => 'target_share', host_overridable => 1,
                label_token => 'GUIDANCE_LASTFM_ARTIST_MODE',
                help_token => 'GUIDANCE_LASTFM_ARTIST_MODE_DESC',
            },
            {
                key => 'lastfm_artist_level', type => 'integer', minimum => 0,
                maximum => 100, factory_default => 75, host_overridable => 1,
                guidance_channel => 'lastfm_artist', render_as => 'slider',
                guidance_policy => 'target_share_or_bounded',
                guidance_mode_key => 'lastfm_artist_mode',
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
            artifact_kinds => ['resolved-lastfm-evidence-v1'],
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
    my $options = {
        acquisition_mode => $effective->{source} eq 'api_key' ? 'direct' : 'artifact',
        lastfm_track_influence => $effective->{lastfm_track_influence},
        lastfm_artist_mode => $effective->{lastfm_artist_mode},
        lastfm_artist_level => $effective->{lastfm_artist_level},
    };
    if ($effective->{source} eq 'lastmix') {
        my $artifact = $trusted_context->{lastfm_relations_artifact};
        die 'Last.fm LastMix mode requires a trusted resolved evidence artifact'
            unless ref($artifact) eq 'HASH' && $artifact->{path} && $artifact->{sha256}
                && ($artifact->{kind} || '') eq 'resolved-lastfm-evidence-v1';
        push @artifacts, {
            kind => 'resolved-lastfm-evidence-v1', path => $artifact->{path}, sha256 => $artifact->{sha256},
        };
    }
    else {
        for my $key (qw(cache_path cache_ttl_seconds request_deadline_ms max_concurrent_requests)) {
            die "Last.fm direct mode requires trusted $key"
                unless exists $trusted_context->{$key};
            $options->{$key} = $trusted_context->{$key};
        }
        if (defined $trusted_context->{api_endpoint} && length $trusted_context->{api_endpoint}) {
            $options->{api_endpoint} = $trusted_context->{api_endpoint};
        }
    }

    return {
        id => 'lastfm-guidance',
        program => $status->{program},
        options => $options,
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
    return $on_complete->({ available => 0, artifacts => [], diagnostic => 'LastMix is not installed' })
        unless _lastmix_available();

    $trusted_context ||= {};
    my $path = $trusted_context->{artifact_path} || '';
    my $sources = $trusted_context->{source_tracks};
    return $on_complete->({ available => 0, artifacts => [], diagnostic => 'trusted LastMix artifact path is missing' })
        unless length $path;
    return $on_complete->({ available => 0, artifacts => [], diagnostic => 'trusted LastMix source tracks are missing' })
        unless ref($sources) eq 'ARRAY';
    return $on_complete->({ available => 0, artifacts => [], diagnostic => 'LastMix API is unavailable' })
        unless eval { require Plugins::LastMix::LFM; 1 };

    my (@requests, %seen_track, %seen_artist);
    for my $track (@$sources) {
        next unless ref($track) eq 'HASH';
        my $artist = $track->{artist} || '';
        my $title = $track->{title} || '';
        my $track_key = _normalize($artist) . '|' . _normalize($title);
        if (length $artist && length $title && !$seen_track{$track_key}++) {
            push @requests, { kind => 'track', %$track };
        }
        my $artist_key = _normalize($artist);
        if (length $artist_key && !$seen_artist{$artist_key}++) {
            push @requests, {
                kind => 'artist', artist => $artist,
                artist_mbid => ref($track->{artist_mbids}) eq 'ARRAY' ? $track->{artist_mbids}[0] : undef,
            };
        }
    }

    my @edges;
    my @errors;
    my $requests = 0;
    my $failures = 0;
    my $next;
    $next = sub {
        unless (@requests) {
            my $state = $failures ? (@edges ? 'partial' : 'failed') : 'fresh';
            my $bundle = {
                schema_version => 1,
                frozen_at => strftime('%Y-%m-%dT%H:%M:%SZ', gmtime(time())),
                providers => [{
                    provider => 'last.fm',
                    dataset_or_algorithm => 'LastMix track.getSimilar + artist.getSimilar',
                    state => $state,
                    request_count => 0 + $requests,
                    failure_count => 0 + $failures,
                    error_codes => \@errors,
                }],
                edges => \@edges,
            };
            my $candidate_tracks = $trusted_context->{candidate_tracks};
            if (ref($candidate_tracks) eq 'ARRAY') {
                $bundle->{edges} = _resolve_candidate_edges(
                    $bundle->{edges}, $candidate_tracks,
                );
            }
            my $fh;
            unless (open $fh, '>', $path) {
                return $on_complete->({ available => 0, artifacts => [], diagnostic => 'cannot write trusted LastMix artifact' });
            }
            print {$fh} encode_json($bundle);
            close $fh;
            open my $read_fh, '<', $path or return $on_complete->({ available => 0, artifacts => [], diagnostic => 'cannot verify trusted LastMix artifact' });
            binmode $read_fh;
            local $/;
            my $sha256 = sha256_hex(<$read_fh>);
            close $read_fh;
            return $on_complete->({
                available => 1,
                artifacts => [{
                    kind => ref($candidate_tracks) eq 'ARRAY'
                        ? 'resolved-lastfm-evidence-v1' : 'semantic-evidence-v1',
                    path => $path,
                    sha256 => $sha256,
                }],
                diagnostic => '',
                statistics => { requests => 0 + $requests, failures => 0 + $failures, edges => scalar @edges },
            });
        }

        my $source = shift @requests;
        $requests++;
        if ($source->{kind} eq 'track') {
            return Plugins::LastMix::LFM->getSimilarTracks(sub {
                my $result = shift;
                if (!ref($result) || ref($result) ne 'HASH' || $result->{error}) {
                    $failures++; push @errors, 'LASTFM_TRACK_FAILED'; return $next->();
                }
                my $rank = 0;
                my $similar = $result->{similartracks}{track};
                $similar = [] unless ref($similar) eq 'ARRAY';
                for my $track (@$similar) {
                    next unless ref($track) eq 'HASH' && $track->{name} && ref($track->{artist}) eq 'HASH' && $track->{artist}{name};
                    last if ++$rank > 25;
                    push @edges, _edge(
                        'LastMix track.getSimilar', _recording_entity($source->{id}, $source->{artist}, $source->{title}, $source->{recording_mbid}),
                        _recording_entity(undef, $track->{artist}{name}, $track->{name}, $track->{mbid}), 'endpoint_local', $rank, $track->{match},
                    );
                }
                $next->();
            }, {
                artist => $source->{artist}, title => $source->{title}, mbid => $source->{recording_mbid},
            });
        }
        return Plugins::LastMix::LFM->getSimilarArtists(sub {
            my $result = shift;
            if (!ref($result) || ref($result) ne 'HASH' || $result->{error}) {
                $failures++; push @errors, 'LASTFM_ARTIST_FAILED'; return $next->();
            }
            my $rank = 0;
            my $similar = $result->{similarartists}{artist};
            $similar = [] unless ref($similar) eq 'ARRAY';
            for my $artist (@$similar) {
                next unless ref($artist) eq 'HASH' && $artist->{name};
                last if ++$rank > 25;
                my $source_entity = _artist_entity($source->{artist}, $source->{artist_mbid});
                my $candidate = _artist_entity($artist->{name}, $artist->{mbid});
                push @edges, _edge('LastMix artist.getSimilar', $source_entity, $candidate, 'endpoint_local', $rank, $artist->{match});
                push @edges, _edge('LastMix artist.getSimilar', $source_entity, $candidate, 'collection_fallback', $rank, $artist->{match});
            }
            $next->();
        }, { artist => $source->{artist}, mbid => $source->{artist_mbid} });
    };
    $next->();
}

sub _normalize {
    my $value = lc(shift || '');
    $value =~ s/^\s+|\s+$//g;
    $value =~ s/\s+/ /g;
    return $value;
}

sub _recording_entity {
    my ($id, $artist, $title, $mbid) = @_;
    return { kind => 'recording', id => $id || 'recording:' . _normalize($artist) . '|' . _normalize($title), name => $artist, title => $title, (defined $mbid && length $mbid ? (mbid => $mbid) : ()) };
}

sub _artist_entity {
    my ($name, $mbid) = @_;
    return { kind => 'artist', id => 'artist:' . _normalize($name), name => $name, (defined $mbid && length $mbid ? (mbid => $mbid) : ()) };
}

sub _edge {
    my ($algorithm, $source, $candidate, $scope, $rank, $score) = @_;
    return {
        provider => 'last.fm', dataset_or_algorithm => $algorithm,
        source => $source, candidate => $candidate, scope => $scope,
        raw_rank => 0 + $rank,
        (defined $score && $score =~ /^\d+(?:\.\d+)?$/ ? (raw_score => 0 + $score) : ()),
        identity_confidence => 1.0,
        observed_at => strftime('%Y-%m-%dT%H:%M:%SZ', gmtime(time())),
        cache_state => 'fresh',
    };
}

sub _resolve_candidate_edges {
    my ($edges, $candidates) = @_;
    $edges = [] unless ref($edges) eq 'ARRAY';
    $candidates = [] unless ref($candidates) eq 'ARRAY';
    my %index = (
        recording_mbid => {}, recording_name => {},
        artist_mbid => {}, artist_name => {},
    );
    for my $candidate (@$candidates) {
        next unless ref($candidate) eq 'HASH';
        my $candidate_id = $candidate->{candidate_id} || $candidate->{id} || '';
        next unless length $candidate_id;
        my $recording_mbid = _normalize($candidate->{recording_mbid});
        push @{$index{recording_mbid}{$recording_mbid}}, $candidate_id
            if length $recording_mbid;
        my $recording_name = _normalize($candidate->{artist}) . "\0"
            . _normalize($candidate->{title});
        push @{$index{recording_name}{$recording_name}}, $candidate_id
            unless $recording_name eq "\0";
        my @artist_mbids = (
            $candidate->{artist_mbid},
            @{ref($candidate->{artist_mbids}) eq 'ARRAY'
                ? $candidate->{artist_mbids} : []},
        );
        for my $artist_mbid (@artist_mbids) {
            $artist_mbid = _normalize($artist_mbid);
            push @{$index{artist_mbid}{$artist_mbid}}, $candidate_id
                if length $artist_mbid;
        }
        my $artist_name = _normalize($candidate->{artist});
        push @{$index{artist_name}{$artist_name}}, $candidate_id
            if length $artist_name;
    }

    my (@resolved, %seen);
    for my $edge (@$edges) {
        next unless ref($edge) eq 'HASH' && ref($edge->{candidate}) eq 'HASH';
        my $candidate = $edge->{candidate};
        my @matches;
        if (($candidate->{kind} || '') eq 'recording') {
            my $mbid = _normalize($candidate->{mbid});
            @matches = @{$index{recording_mbid}{$mbid} || []} if length $mbid;
            if (!@matches) {
                my $key = _normalize($candidate->{name}) . "\0"
                    . _normalize($candidate->{title});
                @matches = @{$index{recording_name}{$key} || []};
            }
        } elsif (($candidate->{kind} || '') eq 'artist') {
            my $mbid = _normalize($candidate->{mbid});
            @matches = @{$index{artist_mbid}{$mbid} || []} if length $mbid;
            if (!@matches) {
                my $name = _normalize($candidate->{name});
                @matches = @{$index{artist_name}{$name} || []};
            }
        }
        for my $candidate_id (@matches) {
            next if $seen{join("\0", $edge->{source}{id} || '', $candidate_id,
                $edge->{source}{kind} || '')}++;
            push @resolved, { %$edge, resolved_candidate_id => $candidate_id };
        }
    }
    return \@resolved;
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
